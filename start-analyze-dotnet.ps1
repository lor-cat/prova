param(
    [string]$RootDir = ".",
    [string]$OutputDir = "AnalysisReports",
    [string]$SolutionPath = "Tmed.sln",
    [string]$SarifFileName = "complete.sarif",
    [switch]$FailOnError
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Folders whose diagnostics are excluded from the final SARIF output.
# Paths are relative to the solution root; both forward and back slashes are
# accepted. Matching is case-insensitive and limited to exact path segments
# (e.g. 'Tmed.Core/Migrations' will NOT match 'Tmed.Core/MigrationsBackup'
# or 'OldTmed.Core/Migrations').
# ---------------------------------------------------------------------------
$ExcludedFolders = @(
    'Tmed.Core/Migrations'
)

# Pre-compute regex patterns from $ExcludedFolders once at startup.
# Each pattern anchors the folder to path-segment boundaries.
$ExcludedFolderPatterns = @(
    $ExcludedFolders |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object {
            '(^|/)' + [regex]::Escape($_.ToLower().Replace('\', '/').Trim('/')) + '(/|$)'
        }
)

function Log   { param([string]$msg) Write-Host "  $msg" }
function LogOk { param([string]$msg) Write-Host "  [OK]  $msg" -ForegroundColor Green }
function LogWn { param([string]$msg) Write-Host "  [WRN] $msg" -ForegroundColor Yellow }
function LogEr { param([string]$msg) Write-Host "  [ERR] $msg" -ForegroundColor Red }

function Test-IsExcludedUri {
    <#
    .SYNOPSIS
        Returns $true when the given SARIF artifact URI falls inside one of the
        excluded folders. Accepts pre-normalized regex patterns (built from
        $ExcludedFolderPatterns) to avoid recomputing them on every call.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$RawUri,
        [string[]]$ExcludedFolderPatterns = @()
    )

    if ($ExcludedFolderPatterns.Count -eq 0) { return $false }

    # Normalize the URI once: lowercase + forward slashes.
    $normalizedUri = $RawUri.ToLower().Replace('\', '/')

    foreach ($pattern in $ExcludedFolderPatterns) {
        if ($normalizedUri -match $pattern) { return $true }
    }

    return $false
}

function Resolve-FullPath {
    param([Parameter(Mandatory = $true)][string]$PathValue)

    try {
        if (Test-Path -LiteralPath $PathValue) {
            return (Resolve-Path -LiteralPath $PathValue).Path
        }
    }
    catch { }

    try {
        return [System.IO.Path]::GetFullPath($PathValue)
    }
    catch {
        throw "Invalid path: $PathValue"
    }
}

function Merge-SarifFiles {
    param(
        [Parameter(Mandatory = $true)][string[]]$InputFiles,
        [Parameter(Mandatory = $true)][string]$OutputFile,
        [string]$RepoRootUri = '',
        [string[]]$ExcludedFolderPatterns = @()
    )

    $allRuns              = [System.Collections.Generic.List[object]]::new()
    $totalDroppedEmptyUri = 0
    $totalDroppedExcluded = 0

    foreach ($file in $InputFiles) {
        if (-not (Test-Path -LiteralPath $file)) { continue }
        try {
            $json = Get-Content -LiteralPath $file -Raw -Encoding UTF8
            try   { $sarif = $json | ConvertFrom-Json -Depth 100 }
            catch { $sarif = $json | ConvertFrom-Json }

            if (-not ($sarif.PSObject.Properties['runs'] -and $sarif.runs)) { continue }

            foreach ($run in @($sarif.runs)) {

                # ------------------------------------------------------------------
                # 1. Inject originalUriBaseIds so the SARIF Viewer can resolve paths
                # ------------------------------------------------------------------
                if (-not [string]::IsNullOrWhiteSpace($RepoRootUri)) {
                    if (-not $run.PSObject.Properties['originalUriBaseIds'] -or
                        $null -eq $run.originalUriBaseIds) {
                        $run | Add-Member -NotePropertyName 'originalUriBaseIds' `
                                          -NotePropertyValue ([PSCustomObject]@{
                                              '%SRCROOT%' = [PSCustomObject]@{ uri = $RepoRootUri }
                                          }) -Force
                    }
                }

                # ------------------------------------------------------------------
                # 2. Drop results whose primary location has an empty / missing URI
                #    or falls inside an excluded folder.
                #    Empty URIs cause "URI non valido: URI vuoto" in the SARIF Viewer.
                # ------------------------------------------------------------------
                if ($run.PSObject.Properties['results'] -and $run.results) {
                    $before = @($run.results).Count
                    $droppedEmptyUri = 0
                    $droppedExcluded = 0
                    
                    # First pass: categorize each result
                    $kept = [System.Collections.ArrayList]::new()
                    foreach ($result in @($run.results)) {
                        $loc = $null
                        if ($result.PSObject.Properties['locations'] -and $result.locations) {
                            $loc = @($result.locations)[0]
                        }
                        if (-not $loc) { 
                            $droppedEmptyUri++
                            continue
                        }

                        $pl = $null
                        if ($loc.PSObject.Properties['physicalLocation'] -and $loc.physicalLocation) {
                            $pl = $loc.physicalLocation
                        }
                        if (-not $pl) { 
                            $droppedEmptyUri++
                            continue
                        }

                        $al = $null
                        if ($pl.PSObject.Properties['artifactLocation'] -and $pl.artifactLocation) {
                            $al = $pl.artifactLocation
                        }
                        if (-not $al) { 
                            $droppedEmptyUri++
                            continue
                        }

                        # Drop if uri is absent or empty
                        if (-not ($al.PSObject.Properties['uri'] -and
                                  -not [string]::IsNullOrWhiteSpace([string]$al.uri))) {
                            $droppedEmptyUri++
                            continue
                        }

                        # Drop if the file is in an excluded folder
                        if (Test-IsExcludedUri -RawUri ([string]$al.uri) -ExcludedFolderPatterns $ExcludedFolderPatterns) {
                            $droppedExcluded++
                            continue
                        }

                        # Keep this result
                        [void]$kept.Add($result)
                    }
                    
                    $totalDroppedEmptyUri += $droppedEmptyUri
                    $totalDroppedExcluded += $droppedExcluded
                    
                    if ($droppedEmptyUri -gt 0 -or $droppedExcluded -gt 0) {
                        $msgParts = @()
                        if ($droppedEmptyUri -gt 0) {
                            $msgParts += "$droppedEmptyUri with empty URI"
                        }
                        if ($droppedExcluded -gt 0) {
                            $msgParts += "$droppedExcluded in excluded folders"
                        }
                        LogWn "  Dropped from $(Split-Path -Leaf $file): $($msgParts -join ', ')"
                    }
                    $run.results = $kept.ToArray()
                }

                $allRuns.Add($run)
            }
        }
        catch { LogWn "Could not parse SARIF: $(Split-Path -Leaf $file)" }
    }

    if ($totalDroppedEmptyUri -gt 0) {
        LogWn "Total results dropped (empty URI): $totalDroppedEmptyUri"
    }
    if ($totalDroppedExcluded -gt 0) {
        LogWn "Total results dropped (excluded folders): $totalDroppedExcluded"
    }

    $merged = [ordered]@{
        '$schema' = 'https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/Schemata/sarif-schema-2.1.0.json'
        version   = '2.1.0'
        runs      = $allRuns.ToArray()
    }

    $merged | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $OutputFile -Encoding UTF8
    LogOk "Merged $($allRuns.Count) run(s) into complete SARIF"
}

function Remove-EmptyUriResults {
    <#
    .SYNOPSIS
        Strips results without a valid physicalLocation URI, or whose location
        falls inside an excluded folder, from a per-project SARIF file.
    .NOTES
        Results without a source location are project-level diagnostics (e.g.
        EnableGenerateDocumentationFile) that Roslyn/MSBuild emits without a
        source file.  The SARIF Viewer for Visual Studio cannot handle them and
        raises "URI non valido: URI vuoto" when it tries to open the file.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$SarifFile,
        [string[]]$ExcludedFolderPatterns = @()
    )

    if (-not (Test-Path -LiteralPath $SarifFile)) { return }

    try {
        $json = Get-Content -LiteralPath $SarifFile -Raw -Encoding UTF8
        try   { $sarif = $json | ConvertFrom-Json -Depth 100 }
        catch { $sarif = $json | ConvertFrom-Json }

        if (-not ($sarif.PSObject.Properties['runs'] -and $sarif.runs)) { return }

        $totalDroppedEmptyUri = 0
        $totalDroppedExcluded = 0
        
        foreach ($run in @($sarif.runs)) {
            if (-not ($run.PSObject.Properties['results'] -and $run.results)) { continue }

            $before = @($run.results).Count
            $droppedEmptyUri = 0
            $droppedExcluded = 0
            
            # Process each result
            $kept = [System.Collections.ArrayList]::new()
            foreach ($result in @($run.results)) {
                $loc = $null
                if ($result.PSObject.Properties['locations'] -and $result.locations) {
                    $loc = @($result.locations)[0]
                }
                if (-not $loc) { 
                    $droppedEmptyUri++
                    continue
                }

                $pl = $null
                if ($loc.PSObject.Properties['physicalLocation'] -and $loc.physicalLocation) {
                    $pl = $loc.physicalLocation
                }
                if (-not $pl) { 
                    $droppedEmptyUri++
                    continue
                }

                $al = $null
                if ($pl.PSObject.Properties['artifactLocation'] -and $pl.artifactLocation) {
                    $al = $pl.artifactLocation
                }
                if (-not $al) { 
                    $droppedEmptyUri++
                    continue
                }

                # Drop if uri is absent or empty
                if (-not ($al.PSObject.Properties['uri'] -and
                          -not [string]::IsNullOrWhiteSpace([string]$al.uri))) {
                    $droppedEmptyUri++
                    continue
                }

                # Drop if the file is in an excluded folder
                if (Test-IsExcludedUri -RawUri ([string]$al.uri) -ExcludedFolderPatterns $ExcludedFolderPatterns) {
                    $droppedExcluded++
                    continue
                }

                # Keep this result
                [void]$kept.Add($result)
            }

            $run.results = $kept.ToArray()
            $totalDroppedEmptyUri += $droppedEmptyUri
            $totalDroppedExcluded += $droppedExcluded
        }

        if ($totalDroppedEmptyUri -gt 0 -or $totalDroppedExcluded -gt 0) {
            $msgParts = @()
            if ($totalDroppedEmptyUri -gt 0) {
                $msgParts += "$totalDroppedEmptyUri with empty URI"
            }
            if ($totalDroppedExcluded -gt 0) {
                $msgParts += "$totalDroppedExcluded in excluded folders"
            }
            LogWn "  Removed from $(Split-Path -Leaf $SarifFile): $($msgParts -join ', ')"
            $sarif | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $SarifFile -Encoding UTF8
        }
    }
    catch {
        LogWn "Could not clean empty-URI results from $(Split-Path -Leaf $SarifFile): $_"
    }
}

function Invoke-AnalyzerBuild {
    param(
        [Parameter(Mandatory = $true)][string]$SolutionPath,
        [Parameter(Mandatory = $true)][string]$PerProjectSarifDir,
        [Parameter(Mandatory = $true)][string]$FinalSarifPath,
        [Parameter(Mandatory = $true)][string]$EditorConfigPath,
        [array]$Projects = @(),
        [string[]]$ExcludedFolderPatterns = @()
    )

    $solutionDir  = Split-Path -Parent $SolutionPath
    $tempTargets  = Join-Path $solutionDir 'Directory.Build.targets'
    $sarifDirNorm = $PerProjectSarifDir.TrimEnd('/\') + [System.IO.Path]::DirectorySeparatorChar

    if (Test-Path -LiteralPath $tempTargets) {
        throw "Directory.Build.targets already exists in '$solutionDir' - remove it before running the analyzer."
    }

    New-Item -ItemType Directory -Path $PerProjectSarifDir -Force | Out-Null

    # Temporary per-project .editorconfig content.
    # .editorconfig files closer to the source files take precedence over parent ones, so a
    # file placed in each project directory overrides the root .editorconfig and demotes all
    # error-severity diagnostics to warnings. This prevents compiler errors from blocking DLL
    # output and keeps dependent projects from failing due to missing reference assemblies.
    # All diagnostics are still emitted to the SARIF (as warnings); the root .editorconfig
    # is never modified.
    
    # Read configuration from external .editorconfig.analysis file
    if (Test-Path -LiteralPath $EditorConfigPath) {
        $tempEditorConfigContent = Get-Content -LiteralPath $EditorConfigPath -Raw
    }
    else {
        throw ".editorconfig.analysis file not found at: $EditorConfigPath"
    }

    # Each .csproj writes to its own SARIF; comma is literal inside XML (no %2C needed).
    # Properties in Directory.Build.targets are evaluated AFTER the .csproj, so they
    # override any per-project settings (e.g. RunAnalyzersDuringBuild=False in Tmed.Web).
    $targetsContent = @"
<Project>
  <PropertyGroup Condition="'`$(MSBuildProjectExtension)' == '.csproj'">
    <RunAnalyzers>true</RunAnalyzers>
    <RunAnalyzersDuringBuild>true</RunAnalyzersDuringBuild>
    <EnforceCodeStyleInBuild>true</EnforceCodeStyleInBuild>
    <GenerateDocumentationFile>true</GenerateDocumentationFile>
    <TreatWarningsAsErrors>false</TreatWarningsAsErrors>
    <WarningsAsErrors></WarningsAsErrors>
    <ErrorLog>$sarifDirNorm`$(MSBuildProjectName).sarif,version=2.1</ErrorLog>
  </PropertyGroup>
</Project>
"@

    $buildLog = Join-Path (Split-Path -Parent $FinalSarifPath) 'build.log'

    # Track which per-project .editorconfig files we create so we can remove them afterwards.
    $createdEditorConfigs = [System.Collections.Generic.List[string]]::new()

    $buildExitCode = 1
    try {
        # Create a temporary .editorconfig in each project directory. Because .editorconfig
        # files closer to the source file take precedence over parent files, this overrides
        # the root .editorconfig error severities without modifying it. We skip any project
        # directory that already contains an .editorconfig (e.g. the solution root itself).
        foreach ($proj in $Projects) {
            if (-not $proj.Found) { continue }
            $projDir = Split-Path -Parent $proj.FullPath
            $projEditorConfig = Join-Path $projDir '.editorconfig'
            if (-not (Test-Path -LiteralPath $projEditorConfig)) {
                Set-Content -LiteralPath $projEditorConfig -Value $tempEditorConfigContent -Encoding UTF8
                $createdEditorConfigs.Add($projEditorConfig)
            }
        }
        if ($createdEditorConfigs.Count -gt 0) {
            LogOk "Created $($createdEditorConfigs.Count) temporary .editorconfig override(s) in project directories"
        }

        Set-Content -LiteralPath $tempTargets -Value $targetsContent -Encoding UTF8

        & dotnet clean "$SolutionPath" -nologo -v:quiet 2>&1 | Set-Content -LiteralPath $buildLog -Encoding UTF8

        & dotnet build "$SolutionPath" `
            -restore `
            -nologo `
            -v:minimal `
            --no-incremental `
            -p:RunAnalyzers=true `
            -p:RunAnalyzersDuringBuild=true `
            -p:EnableNETAnalyzers=true `
            -p:EnforceCodeStyleInBuild=true `
            -p:AnalysisLevel=latest `
            -p:AnalysisMode=AllEnabledByDefault `
            2>&1 | Set-Content -LiteralPath $buildLog -Encoding UTF8

        $buildExitCode = $LASTEXITCODE
    }
    finally {
        Remove-Item -LiteralPath $tempTargets -Force -ErrorAction SilentlyContinue
        foreach ($ec in $createdEditorConfigs) {
            Remove-Item -LiteralPath $ec -Force -ErrorAction SilentlyContinue
        }
    }

    Log "Build log: $buildLog"

    $sarifFiles = @(Get-ChildItem -Path $PerProjectSarifDir -Filter '*.sarif' -ErrorAction SilentlyContinue |
                    Select-Object -ExpandProperty FullName)
    if ($sarifFiles.Count -gt 0) {
        LogOk "Per-project SARIF files generated ($($sarifFiles.Count)):"
        foreach ($sf in $sarifFiles) { Log "    $(Split-Path -Leaf $sf)" }

        # Remove results with empty/missing URIs (and results in excluded folders) from each
        # per-project SARIF so that the SARIF Viewer for Visual Studio does not raise
        # "URI non valido: URI vuoto" when these files are opened directly.
        # The same filter is applied again inside Merge-SarifFiles as a safety net, but
        # cleaning the source files here ensures individual per-project files are also safe.
        Log "Cleaning empty-URI results from per-project SARIF files..."
        foreach ($sf in $sarifFiles) { Remove-EmptyUriResults -SarifFile $sf -ExcludedFolderPatterns $ExcludedFolderPatterns }

        # Build a file:/// URI for the repo root so originalUriBaseIds is populated
        $repoRootUri = ''
        try {
            $repoRootNorm = $solutionDir.TrimEnd('\/') + '/'
            $repoRootUri  = [System.Uri]::new($repoRootNorm).AbsoluteUri
        } catch { }

        Merge-SarifFiles -InputFiles $sarifFiles -OutputFile $FinalSarifPath -RepoRootUri $repoRootUri -ExcludedFolderPatterns $ExcludedFolderPatterns
    }
    else {
        LogWn "No per-project SARIF files generated - check that analyzers ran"
    }

    return $buildExitCode
}

function Test-CommandAvailable {
    param([Parameter(Mandatory = $true)][string]$CommandName)

    return $null -ne (Get-Command $CommandName -ErrorAction SilentlyContinue)
}

function Resolve-SarifUri {
    param(
        [Parameter(Mandatory = $true)][string]$RawUri,
        [string]$BaseId,
        [hashtable]$BaseUris
    )

    if ($RawUri -match '^file:///') {
        try { return ([System.Uri]$RawUri).LocalPath } catch { return $null }
    }

    if ($RawUri -match '^[A-Za-z]:[\\/]') {
        return $RawUri
    }

    # Relative URI: resolve via uriBaseId -> originalUriBaseIds
    if (-not [string]::IsNullOrWhiteSpace($BaseId) -and $BaseUris.ContainsKey($BaseId)) {
        return $BaseUris[$BaseId] + $RawUri.TrimStart('/')
    }

    return $null
}

function Get-ProjectDiagnosticCounts {
    param(
        [Parameter(Mandatory = $true)][string]$SarifPath,
        [Parameter(Mandatory = $true)][array]$Projects
    )

    $counts = @{}
    foreach ($proj in $Projects) {
        $counts[$proj.FullPath] = [PSCustomObject]@{ Errors = 0; Warnings = 0; Notes = 0 }
    }

    try {
        $json = Get-Content -LiteralPath $SarifPath -Raw -Encoding UTF8
        try   { $sarif = $json | ConvertFrom-Json -Depth 100 }
        catch { $sarif = $json | ConvertFrom-Json }
    }
    catch {
        return $null
    }

    # Pre-compute project dirs once
    $projDirs = @{}
    foreach ($proj in $Projects) {
        if (-not $proj.Found) { continue }
        $projDirs[$proj.FullPath] = (Split-Path -Parent $proj.FullPath).TrimEnd('\/') + [System.IO.Path]::DirectorySeparatorChar
    }

    $sarifRuns = if ($sarif.PSObject.Properties['runs'] -and $null -ne $sarif.runs) { @($sarif.runs) } else { @() }

    foreach ($run in $sarifRuns) {
        if ($null -eq $run) { continue }

        # Build uriBaseId -> absolute base path map from originalUriBaseIds
        $baseUris = @{}
        if ($run.PSObject.Properties['originalUriBaseIds'] -and $null -ne $run.originalUriBaseIds) {
            foreach ($prop in $run.originalUriBaseIds.PSObject.Properties) {
                $baseVal = $prop.Value
                if ($null -ne $baseVal -and $baseVal.PSObject.Properties['uri'] -and $baseVal.uri) {
                    $resolved = Resolve-SarifUri -RawUri ([string]$baseVal.uri) -BaseId '' -BaseUris @{}
                    if ($resolved) {
                        $baseUris[$prop.Name] = $resolved.TrimEnd('\/') + [System.IO.Path]::DirectorySeparatorChar
                    }
                }
            }
        }

        # Build artifacts index lookup
        $artifactsArray = @()
        if ($run.PSObject.Properties['artifacts'] -and $null -ne $run.artifacts) {
            $artifactsArray = @($run.artifacts)
        }

        $runResults = if ($run.PSObject.Properties['results'] -and $null -ne $run.results) { @($run.results) } else { @() }

        foreach ($result in $runResults) {
            if ($null -eq $result) { continue }

            $level = 'warning'
            if ($result.PSObject.Properties['level'] -and $result.level) {
                $level = [string]$result.level
            }

            $localPath = $null

            if ($result.PSObject.Properties['locations'] -and $null -ne $result.locations) {
                $locArray = @($result.locations)
                $first    = if ($locArray.Count -gt 0) { $locArray[0] } else { $null }

                if ($null -ne $first -and $first.PSObject.Properties['physicalLocation'] -and $null -ne $first.physicalLocation) {
                    $pl = $first.physicalLocation
                    if ($pl.PSObject.Properties['artifactLocation'] -and $null -ne $pl.artifactLocation) {
                        $al = $pl.artifactLocation

                        $rawUri = $null
                        if ($al.PSObject.Properties['uri'] -and $al.uri) {
                            $rawUri = [string]$al.uri
                        }
                        elseif ($artifactsArray.Count -gt 0 -and $al.PSObject.Properties['index'] -and $null -ne $al.index) {
                            $idx = [int]$al.index
                            if ($idx -ge 0 -and $idx -lt $artifactsArray.Count) {
                                $art = $artifactsArray[$idx]
                                if ($null -ne $art -and $art.PSObject.Properties['location'] -and $null -ne $art.location -and
                                    $art.location.PSObject.Properties['uri'] -and $art.location.uri) {
                                    $rawUri = [string]$art.location.uri
                                }
                            }
                        }

                        if (-not [string]::IsNullOrWhiteSpace($rawUri)) {
                            $baseId = $null
                            if ($al.PSObject.Properties['uriBaseId'] -and $al.uriBaseId) {
                                $baseId = [string]$al.uriBaseId
                            }
                            $localPath = Resolve-SarifUri -RawUri $rawUri -BaseId $baseId -BaseUris $baseUris
                        }
                    }
                }

                # SARIF 1.0 fallback: locations[0].resultFile.uri
                if ($null -ne $first -and [string]::IsNullOrWhiteSpace($localPath) -and
                    $first.PSObject.Properties['resultFile'] -and $null -ne $first.resultFile -and
                    $first.resultFile.PSObject.Properties['uri'] -and $first.resultFile.uri) {
                    $localPath = Resolve-SarifUri -RawUri ([string]$first.resultFile.uri) -BaseId $null -BaseUris $baseUris
                }
            }

            if ([string]::IsNullOrWhiteSpace($localPath)) { continue }

            $localPath = $localPath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)

            foreach ($proj in $Projects) {
                if (-not $proj.Found) { continue }
                if ($localPath.StartsWith($projDirs[$proj.FullPath], [System.StringComparison]::OrdinalIgnoreCase)) {
                    switch ($level) {
                        'error'   { $counts[$proj.FullPath].Errors++ }
                        'warning' { $counts[$proj.FullPath].Warnings++ }
                        'note'    { $counts[$proj.FullPath].Notes++ }
                    }
                    break
                }
            }
        }
    }

    return $counts
}

function Get-ProjectBuildStatuses {
    param(
        [Parameter(Mandatory = $true)][string]$BuildLogPath,
        [Parameter(Mandatory = $true)][array]$Projects
    )

    $statuses = @{}
    foreach ($proj in $Projects) { $statuses[$proj.Name] = 'unknown' }

    if (-not (Test-Path -LiteralPath $BuildLogPath)) { return $statuses }

    foreach ($line in (Get-Content -LiteralPath $BuildLogPath -Encoding UTF8)) {
        # MSBuild -v:minimal emits "  AssemblyName -> /path/Output.dll"
        if ($line -match '->\s+\S+\.(dll|exe)\s*$') {
            $dllName = [System.IO.Path]::GetFileNameWithoutExtension(($line -split '->',2)[1].Trim())
            if ($statuses.ContainsKey($dllName)) { $statuses[$dllName] = 'success' }
        }
    }

    foreach ($proj in $Projects) {
        if ($statuses[$proj.Name] -eq 'unknown') { $statuses[$proj.Name] = 'failed' }
    }

    return $statuses
}

function Get-SolutionProjects {
    param([Parameter(Mandatory = $true)][string]$SolutionFile)

    $solutionDir = Split-Path -Parent $SolutionFile
    $projects = @()

    foreach ($line in (Get-Content -LiteralPath $SolutionFile)) {
        if ($line -match 'Project\("\{[^\}]+\}"\)\s*=\s*"([^"]+)",\s*"([^"]+\.csproj)"') {
            $name = $matches[1]
            $relativePath = $matches[2] -replace '\\', [System.IO.Path]::DirectorySeparatorChar
            $fullPath = [System.IO.Path]::GetFullPath((Join-Path -Path $solutionDir -ChildPath $relativePath))
            $exists = Test-Path -LiteralPath $fullPath
            $projects += [PSCustomObject]@{
                Name     = $name
                Path     = $relativePath
                FullPath = $fullPath
                Found    = $exists
            }
        }
    }

    return $projects
}

Write-Host ""
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "  .NET Static Analysis  |  Single SARIF Output" -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-CommandAvailable -CommandName "dotnet")) {
    LogEr "dotnet command not found in PATH"
    exit 1
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Resolve-FullPath -PathValue (Join-Path $ScriptDir "..")
$OutputDirFull = Join-Path -Path $RootDir -ChildPath $OutputDir

New-Item -ItemType Directory -Path $OutputDirFull -Force | Out-Null
LogOk "Output directory ready: $OutputDirFull"

$sarifPath = Join-Path -Path $OutputDirFull -ChildPath $SarifFileName
if (Test-Path -LiteralPath $sarifPath) {
    Remove-Item -LiteralPath $sarifPath -Force
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$editorConfigPath = Join-Path -Path $ScriptDir -ChildPath ".editorconfig.analysis"
if (Test-Path -LiteralPath $editorConfigPath) {
    LogOk "Using .editorconfig"
}
else {
    LogWn ".editorconfig not found - default rules will apply"
}

$SolutionPath = Resolve-FullPath -PathValue (Join-Path -Path $RootDir -ChildPath "Tmed.sln")
if (-not (Test-Path -LiteralPath $SolutionPath)) {
    LogEr "Solution not found: $SolutionPath"
    exit 1
}

LogOk "Solution selected: $SolutionPath"

$solutionProjects = Get-SolutionProjects -SolutionFile $SolutionPath
LogOk "Found $($solutionProjects.Count) project(s) in solution"

if ($ExcludedFolders.Count -gt 0) {
    LogWn "Excluded folders ($($ExcludedFolders.Count)):"
    foreach ($ef in $ExcludedFolders) { Log "    $ef" }
}

$perProjectSarifDir = Join-Path -Path $OutputDirFull -ChildPath 'per-project'
Log "Running analyzer build for solution..."

$buildExitCode = Invoke-AnalyzerBuild `
    -SolutionPath          $SolutionPath `
    -PerProjectSarifDir    $perProjectSarifDir `
    -FinalSarifPath        $sarifPath `
    -EditorConfigPath      $editorConfigPath `
    -Projects              $solutionProjects `
    -ExcludedFolderPatterns $ExcludedFolderPatterns

if ($buildExitCode -ne 0) {
    LogWn "dotnet build exited with code $buildExitCode"
}
else {
    LogOk "Build completed"
}

if (Test-Path -LiteralPath $sarifPath) {
    LogOk "SARIF generated: $sarifPath"
}
else {
    LogEr "SARIF file not generated: $sarifPath"
    exit 1
}

$diagCounts = $null
if (Test-Path -LiteralPath $sarifPath) {
    $diagCounts = Get-ProjectDiagnosticCounts -SarifPath $sarifPath -Projects $solutionProjects
}

$buildLog = Join-Path $OutputDirFull 'build.log'
$buildStatuses = @{}
if (Test-Path -LiteralPath $buildLog) {
    $buildStatuses = Get-ProjectBuildStatuses -BuildLogPath $buildLog -Projects $solutionProjects
}

Write-Host ""
Write-Host "=================== PROJECTS ANALYZED ==================" -ForegroundColor Cyan
foreach ($proj in ($solutionProjects | Sort-Object Name)) {
    if (-not $proj.Found) {
        Write-Host "  [----] " -NoNewline -ForegroundColor DarkGray
        Write-Host ("{0,-40} [NOT FOUND ON DISK]" -f $proj.Name) -ForegroundColor DarkYellow
        continue
    }

    $buildStatus = if ($buildStatuses.ContainsKey($proj.Name)) { $buildStatuses[$proj.Name] } else { 'unknown' }
    $statusTag   = if ($buildStatus -eq 'success') { '[OK]  ' } else { '[FAIL]' }
    $statusColor = if ($buildStatus -eq 'success') { 'Green'  } else { 'Red'   }

    $projSarifFile = Join-Path -Path $perProjectSarifDir -ChildPath "$($proj.Name).sarif"
    if (-not (Test-Path -LiteralPath $projSarifFile)) {
        $noSarifMsg = if ($buildStatus -eq 'failed') { '[BUILD FAILED - check build.log]' } else { '[NO SARIF - analyzers may have been skipped]' }
        Write-Host ("  {0} " -f $statusTag) -NoNewline -ForegroundColor $statusColor
        Write-Host ("{0,-40} {1}" -f $proj.Name, $noSarifMsg) -ForegroundColor DarkYellow
        continue
    }

    Write-Host ("  {0} " -f $statusTag) -NoNewline -ForegroundColor $statusColor
    if ($null -ne $diagCounts -and $diagCounts.ContainsKey($proj.FullPath)) {
        $c = $diagCounts[$proj.FullPath]
        $errColor  = if ($c.Errors   -gt 0) { 'Red'    } else { 'DarkGray' }
        $wrnColor  = if ($c.Warnings -gt 0) { 'Yellow' } else { 'DarkGray' }
        $noteColor = if ($c.Notes    -gt 0) { 'Cyan'   } else { 'DarkGray' }
        Write-Host ("{0,-40}" -f $proj.Name) -NoNewline -ForegroundColor White
        Write-Host " E: " -NoNewline -ForegroundColor DarkGray
        Write-Host ("{0,-5}" -f $c.Errors)   -NoNewline -ForegroundColor $errColor
        Write-Host " W: " -NoNewline -ForegroundColor DarkGray
        Write-Host ("{0,-5}" -f $c.Warnings) -NoNewline -ForegroundColor $wrnColor
        Write-Host " N: " -NoNewline -ForegroundColor DarkGray
        Write-Host ("{0}"   -f $c.Notes)     -ForegroundColor $noteColor
    }
    else {
        Write-Host ("{0,-40} (no diagnostics data)" -f $proj.Name) -ForegroundColor White
    }
}
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""

if ($FailOnError.IsPresent -and $buildExitCode -ne 0) {
    exit 1
}

exit $buildExitCode