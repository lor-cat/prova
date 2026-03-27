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
    Author: Generated for TMED Analysis Reports
    Version: 1.0.0
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

# Funzioni di logging
function Log {
    param([string]$Message)
    Write-Host $Message
}

function LogOk {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Green
}

function LogWn {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Yellow
}

function LogEr {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Red
}

# Funzione per ottenere la dimensione di un oggetto JSON in byte
function Get-JsonSize {
    param([object]$JsonObject)
    
    try {
        $json = $JsonObject | ConvertTo-Json -Depth 100 -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        return $bytes.Length
    }
    catch {
        LogEr "Errore nel calcolo della dimensione JSON: $_"
        return 0
    }
}

# Funzione per creare un chunk SARIF valido
function New-SarifChunk {
    param(
        [object]$OriginalSarif,
        [array]$Results,
        [int]$ChunkIndex
    )
    
    # Crea una copia della struttura SARIF originale
    $chunk = @{
        '$schema' = $OriginalSarif.'$schema'
        'version' = $OriginalSarif.version
        'runs' = @()
    }
    
    # Se ci sono proprietà aggiuntive a livello root, mantienile
    foreach ($prop in $OriginalSarif.PSObject.Properties) {
        if ($prop.Name -notin @('$schema', 'version', 'runs')) {
            $chunk[$prop.Name] = $prop.Value
        }
    }
    
    # Per ogni run nell'originale, crea una copia con i risultati filtrati
    foreach ($run in $OriginalSarif.runs) {
        $newRun = @{
            'tool' = $run.tool
        }
        
        # Mantieni altre proprietà del run (originalUriBaseIds, etc.)
        foreach ($prop in $run.PSObject.Properties) {
            if ($prop.Name -notin @('tool', 'results')) {
                $newRun[$prop.Name] = $prop.Value
            }
        }
        
        # Aggiungi i risultati per questo chunk
        $newRun['results'] = $Results
        
        $chunk.runs += $newRun
    }
    
    return $chunk
}

# Funzione per dividere un file SARIF in chunk
function Split-SarifFile {
    param(
        [string]$FilePath,
        [string]$OutputDir,
        [int]$MaxSizeBytes
    )
    
    try {
        Log "Processando: $FilePath"
        
        # Leggi il file SARIF
        $sarifContent = Get-Content -Path $FilePath -Raw | ConvertFrom-Json
        
        # Verifica che sia un SARIF valido
        if (-not $sarifContent.runs) {
            LogWn "  Il file non contiene runs SARIF validi. Saltato."
            return 0
        }
        
        # Estrai tutti i risultati da tutti i run
        $allResults = @()
        foreach ($run in $sarifContent.runs) {
            if ($run.results) {
                $allResults += $run.results
            }
        }
        
        if ($allResults.Count -eq 0) {
            LogWn "  Nessun risultato trovato nel file. Saltato."
            return 0
        }
        
        Log "  Trovati $($allResults.Count) risultati"
        
        # Calcola la dimensione del file originale
        $originalSize = (Get-Item $FilePath).Length
        $originalSizeMB = [math]::Round($originalSize / 1MB, 2)
        
        Log "  Dimensione originale: $originalSizeMB MB"
        
        # Se il file è già sotto il limite, copialo semplicemente
        if ($originalSize -le $MaxSizeBytes) {
            $fileName = [System.IO.Path]::GetFileName($FilePath)
            $outputPath = Join-Path $OutputDir $fileName
            Copy-Item -Path $FilePath -Destination $outputPath -Force
            LogOk "  File già sotto il limite. Copiato senza modifiche."
            return 1
        }
        
        # Divide i risultati in chunk
        $chunks = @()
        $currentChunk = @()
        $chunkIndex = 0
        
        foreach ($result in $allResults) {
            $currentChunk += $result
            
            # Crea un chunk temporaneo per verificare la dimensione
            $tempChunk = New-SarifChunk -OriginalSarif $sarifContent -Results $currentChunk -ChunkIndex $chunkIndex
            $chunkSize = Get-JsonSize -JsonObject $tempChunk
            
            # Se il chunk supera il limite, salva il chunk precedente e inizia uno nuovo
            if ($chunkSize -gt $MaxSizeBytes -and $currentChunk.Count -gt 1) {
                # Rimuovi l'ultimo risultato aggiunto
                $currentChunk = $currentChunk[0..($currentChunk.Count - 2)]
                
                # Salva il chunk corrente
                $chunks += ,@($currentChunk)
                
                # Inizia un nuovo chunk con l'ultimo risultato
                $currentChunk = @($result)
                $chunkIndex++
            }
        }
        
        # Aggiungi l'ultimo chunk se non è vuoto
        if ($currentChunk.Count -gt 0) {
            $chunks += ,@($currentChunk)
        }
        
        # Salva tutti i chunk
        $baseFileName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
        $extension = [System.IO.Path]::GetExtension($FilePath)
        
        $savedChunks = 0
        for ($i = 0; $i -lt $chunks.Count; $i++) {
            $chunk = New-SarifChunk -OriginalSarif $sarifContent -Results $chunks[$i] -ChunkIndex ($i + 1)
            $chunkFileName = "$baseFileName-chunk$($i + 1)$extension"
            $chunkPath = Join-Path $OutputDir $chunkFileName
            
            $chunk | ConvertTo-Json -Depth 100 | Set-Content -Path $chunkPath -Encoding UTF8
            
            $chunkSize = (Get-Item $chunkPath).Length
            $chunkSizeMB = [math]::Round($chunkSize / 1MB, 2)
            
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
    
    # Risolvi il percorso assoluto della cartella di input
    $InputFolder = Resolve-Path -Path $InputFolder -ErrorAction Stop
    Log "Cartella input: $InputFolder"
    Log "Dimensione chunk: $ChunkSizeMB MB"
    
    # Calcola la dimensione massima in byte
    $maxSizeBytes = $ChunkSizeMB * 1MB
    
    # Crea il percorso della cartella di output
    $outputPath = Join-Path $InputFolder $OutputFolder
    
    # Verifica se la cartella di output esiste
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
    
    # Crea la cartella di output
    New-Item -Path $outputPath -ItemType Directory -Force | Out-Null
    LogOk "Cartella di output creata: $outputPath"
    Log ""
    
    # Trova tutti i file SARIF
    $sarifFiles = Get-ChildItem -Path $InputFolder -Filter "*.sarif" -File | 
                  Where-Object { $_.DirectoryName -ne $outputPath }
    
    if ($sarifFiles.Count -eq 0) {
        LogWn "Nessun file SARIF trovato in $InputFolder"
        exit 0
    }
    
    Log "Trovati $($sarifFiles.Count) file SARIF da processare"
    Log ""
    
    # Processa ogni file SARIF
    $totalChunks = 0
    $processedFiles = 0
    
    foreach ($file in $sarifFiles) {
        $chunks = Split-SarifFile -FilePath $file.FullName -OutputDir $outputPath -MaxSizeBytes $maxSizeBytes
        if ($chunks -gt 0) {
            $totalChunks += $chunks
            $processedFiles++
        }
        Log ""
    }
    
    # Riepilogo finale
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
