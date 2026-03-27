<#
.SYNOPSIS
    Divide tutti i file SARIF presenti in una cartella in chunk da N MB,
    organizzando l'output in ChunkedSarif\

.DESCRIPTION
    Questo script analizza tutti i file SARIF in una cartella specificata e li divide
    in chunk più piccoli di dimensione configurabile (in MB). I file divisi vengono
    salvati in una sottocartella ChunkedSarif\ mantenendo l'integrità del formato SARIF.
    
    Ogni chunk conterrà un sottoinsieme dei risultati (results) del file SARIF originale,
    mantenendo la struttura del documento SARIF conforme allo schema 2.1.0.

.PARAMETER InputFolder
    Percorso della cartella contenente i file SARIF da processare.
    Default: cartella corrente (.)

.PARAMETER ChunkSizeMB
    Dimensione massima di ogni chunk in megabyte.
    Default: 5 MB

.PARAMETER OutputFolder
    Nome della cartella di output relativa a InputFolder.
    Default: ChunkedSarif

.PARAMETER Force
    Se specificato, sovrascrive la cartella di output esistente.

.EXAMPLE
    .\_SarifSplitter.ps1
    Divide tutti i file SARIF nella cartella corrente in chunk da 5 MB

.EXAMPLE
    .\_SarifSplitter.ps1 -InputFolder "C:\Reports" -ChunkSizeMB 10
    Divide tutti i file SARIF in C:\Reports in chunk da 10 MB

.EXAMPLE
    .\_SarifSplitter.ps1 -InputFolder "." -ChunkSizeMB 3 -Force
    Divide i file SARIF in chunk da 3 MB, sovrascrivendo l'output esistente

.NOTES
    Version: 1.2.0
    Requires: PowerShell 5.1 or higher
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$InputFolder = ".",
    
    [Parameter(Mandatory=$false)]
    [ValidateRange(0.1, 100)]
    [double]$ChunkSizeMB = 5,
    
    [Parameter(Mandatory=$false)]
    [string]$OutputFolder = "ChunkedSarif",
    
    [Parameter(Mandatory=$false)]
    [switch]$Force
)

function Log   { param([string]$m) Write-Host $m }
function LogOk { param([string]$m) Write-Host $m -ForegroundColor Green }
function LogWn { param([string]$m) Write-Host $m -ForegroundColor Yellow }
function LogEr { param([string]$m) Write-Host $m -ForegroundColor Red }

# ─────────────────────────────────────────────────────────────────────────────
# Serializza un chunk SARIF come JSON con struttura ordinata ($schema → version
# → ... → runs) usando la stessa funzione sia per la stima overhead sia per
# il file finale — in modo che le dimensioni siano coerenti.
# ─────────────────────────────────────────────────────────────────────────────
function Build-SarifChunkJson {
    param(
        [object]$OriginalSarif,   # PSCustomObject da ConvertFrom-Json
        [array]$Results           # array di risultati per questo chunk
    )

    # Radice con ordine garantito tramite [ordered]
    $root = [ordered]@{}

    $schemaVal = $OriginalSarif.'$schema'
    $root['$schema'] = if ($schemaVal) { $schemaVal } else { 'http://json.schemastore.org/sarif-2.1.0' }

    $versionVal = $OriginalSarif.version
    $root['version'] = if ($versionVal) { $versionVal } else { '2.1.0' }

    # Eventuali proprietà root aggiuntive (oltre $schema / version / runs)
    foreach ($prop in $OriginalSarif.PSObject.Properties) {
        if ($prop.Name -notin @('$schema', 'version', 'runs')) {
            $root[$prop.Name] = $prop.Value
        }
    }

    # Ricostruisce i run: tool → altre props → results
    $runs = @()
    foreach ($origRun in $OriginalSarif.runs) {
        $newRun = [ordered]@{}
        $newRun['tool'] = $origRun.tool
        foreach ($prop in $origRun.PSObject.Properties) {
            if ($prop.Name -notin @('tool', 'results')) {
                $newRun[$prop.Name] = $prop.Value
            }
        }
        $newRun['results'] = if ($Results) { $Results } else { @() }
        $runs += $newRun
    }
    $root['runs'] = $runs

    # ConvertTo-Json con -Depth 100 e indentazione (uguale all'originale)
    return ($root | ConvertTo-Json -Depth 100)
}

# ─────────────────────────────────────────────────────────────────────────────
function Split-SarifFile {
    param(
        [string]$FilePath,
        [string]$OutputDir,
        [long]$MaxSizeBytes
    )

    try {
        Log "Processando: $FilePath"

        $sarifContent = Get-Content -Path $FilePath -Raw | ConvertFrom-Json

        if (-not $sarifContent.runs) {
            LogWn "  Il file non contiene runs SARIF validi. Saltato."
            return 0
        }

        # Aggrega risultati da tutti i run
        $allResults = [System.Collections.Generic.List[object]]::new()
        foreach ($run in $sarifContent.runs) {
            if ($run.results) {
                foreach ($r in $run.results) { $allResults.Add($r) }
            }
        }

        if ($allResults.Count -eq 0) {
            LogWn "  Nessun risultato trovato nel file. Saltato."
            return 0
        }

        Log "  Trovati $($allResults.Count) risultati"

        $originalSize = (Get-Item $FilePath).Length
        Log "  Dimensione originale: $([math]::Round($originalSize / 1MB, 2)) MB"

        # File già sotto il limite → copia diretta
        if ($originalSize -le $MaxSizeBytes) {
            $dest = Join-Path $OutputDir ([System.IO.Path]::GetFileName($FilePath))
            Copy-Item -Path $FilePath -Destination $dest -Force
            LogOk "  File già sotto il limite. Copiato senza modifiche."
            return 1
        }

        # Ordina per criticità poi ruleId
        $severityOrder = @{ 'error' = 0; 'warning' = 1; 'note' = 2; 'none' = 3 }
        $sortedResults = @($allResults | Sort-Object -Property @(
            @{ Expression = {
                $lvl = $_.level
                if ($lvl -and $severityOrder.ContainsKey($lvl)) { $severityOrder[$lvl] } else { 4 }
            }; Ascending = $true },
            @{ Expression = { if ($_.ruleId) { $_.ruleId } else { '' } }; Ascending = $true }
        ))

        # ── Overhead: dimensione del documento senza risultati ──────────────
        # Usa la stessa funzione di serializzazione del loop finale → coerenza
        $overheadJson  = Build-SarifChunkJson -OriginalSarif $sarifContent -Results @()
        $overheadBytes = [System.Text.Encoding]::UTF8.GetByteCount($overheadJson)

        # Budget netto per i risultati; riserva 2 % per separatori/rientri extra
        $budget = [long](($MaxSizeBytes - $overheadBytes) * 0.98)

        if ($budget -le 0) {
            LogEr "  Overhead del documento ($overheadBytes byte) supera già il limite. Impossibile dividere."
            return 0
        }

        # Pre-calcola la dimensione serializzata di ogni risultato con -Depth 100
        # (stesso serializzatore usato in Build-SarifChunkJson)
        $resultSizes = @($sortedResults | ForEach-Object {
            $json = $_ | ConvertTo-Json -Depth 100
            [System.Text.Encoding]::UTF8.GetByteCount($json)
        })

        # Stimato overhead per separatore tra elementi nell'array JSON
        # ConvertTo-Json produce "," + newline + indentazione ≈ 10 byte
        $separatorBytes = 10

        # ── Costruisce i bucket ─────────────────────────────────────────────
        $chunks      = [System.Collections.ArrayList]::new()
        $bucket      = [System.Collections.ArrayList]::new()
        $bucketBytes = 0L

        for ($i = 0; $i -lt $sortedResults.Count; $i++) {
            $needed = $resultSizes[$i]
            if ($bucket.Count -gt 0) { $needed += $separatorBytes }

            if ($bucketBytes + $needed -gt $budget -and $bucket.Count -gt 0) {
                [void]$chunks.Add($bucket.ToArray())
                $bucket      = [System.Collections.ArrayList]::new()
                $bucketBytes = 0L
                $needed      = $resultSizes[$i]
            }

            [void]$bucket.Add($sortedResults[$i])
            $bucketBytes += $needed
        }
        if ($bucket.Count -gt 0) { [void]$chunks.Add($bucket.ToArray()) }

        # ── Salva su disco ──────────────────────────────────────────────────
        $baseName  = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
        $extension = [System.IO.Path]::GetExtension($FilePath)
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)

        $savedChunks = 0
        for ($i = 0; $i -lt $chunks.Count; $i++) {
            $json      = Build-SarifChunkJson -OriginalSarif $sarifContent -Results $chunks[$i]
            $chunkPath = Join-Path $OutputDir "$baseName-chunk$($i + 1)$extension"

            [System.IO.File]::WriteAllText($chunkPath, $json, $utf8NoBom)

            $chunkSizeMB = [math]::Round((Get-Item $chunkPath).Length / 1MB, 2)
            Log "  Chunk $($i + 1): $chunkSizeMB MB ($($chunks[$i].Count) risultati)"
            $savedChunks++
        }

        LogOk "  Completato: $savedChunks chunk creati"
        return $savedChunks
    }
    catch {
        LogEr "  Errore durante il processamento: $_"
        return 0
    }
}

# ============================================================================
# Script principale
# ============================================================================

try {
    Log ""
    Log "=========================================="
    Log "SARIF Splitter - Divisione file SARIF"
    Log "=========================================="
    Log ""

    $InputFolder  = Resolve-Path -Path $InputFolder -ErrorAction Stop
    Log "Cartella input: $InputFolder"
    Log "Dimensione chunk: $ChunkSizeMB MB"

    $maxSizeBytes = [long]($ChunkSizeMB * 1MB)
    $outputPath   = Join-Path $InputFolder $OutputFolder

    if (Test-Path $outputPath) {
        if ($Force) {
            LogWn "Cartella di output esistente. Rimozione in corso..."
            Remove-Item -Path $outputPath -Recurse -Force
        }
        else {
            LogEr "La cartella di output '$outputPath' esiste già."
            LogEr "Usa il parametro -Force per sovrascriverla."
            exit 1
        }
    }

    New-Item -Path $outputPath -ItemType Directory -Force | Out-Null
    LogOk "Cartella di output creata: $outputPath"
    Log ""

    $sarifFiles = Get-ChildItem -Path $InputFolder -Filter "*.sarif" -File |
                  Where-Object { $_.DirectoryName -ne $outputPath }

    if ($sarifFiles.Count -eq 0) {
        LogWn "Nessun file SARIF trovato in $InputFolder"
        exit 0
    }

    Log "Trovati $($sarifFiles.Count) file SARIF da processare"
    Log ""

    $totalChunks    = 0
    $processedFiles = 0

    foreach ($file in $sarifFiles) {
        $n = Split-SarifFile -FilePath $file.FullName -OutputDir $outputPath -MaxSizeBytes $maxSizeBytes
        if ($n -gt 0) {
            $totalChunks    += $n
            $processedFiles++
        }
        Log ""
    }

    Log "=========================================="
    LogOk "Completato!"
    Log "File processati: $processedFiles / $($sarifFiles.Count)"
    Log "Chunk totali creati: $totalChunks"
    Log "Output salvato in: $outputPath"
    Log "=========================================="

    exit 0
}
catch {
    LogEr ""
    LogEr "=========================================="
    LogEr "ERRORE CRITICO"
    LogEr "=========================================="
    LogEr $_.Exception.Message
    LogEr $_.ScriptStackTrace
    exit 1
}
