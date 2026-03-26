param(
    [string]$RootDir = ".",
    [string]$OutputDir = "AnalysisReports",
    [string]$SolutionPath = "Tmed.sln",
    [string]$SarifFileName = "complete.sarif",
    [switch]$FailOnError
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Log   { param([string]$msg) Write-Host "  $msg" }
function LogOk { param([string]$msg) Write-Host "  [OK]  $msg" -ForegroundColor Green }
function LogWn { param([string]$msg) Write-Host "  [WRN] $msg" -ForegroundColor Yellow }
function LogEr { param([string]$msg) Write-Host "  [ERR] $msg" -ForegroundColor Red }

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
        [string]$RepoRootUri = ''
    )

    $allRuns      = [System.Collections.Generic.List[object]]::new()
    $totalDropped = 0

    foreach ($file in $InputFiles) {
        if (-not (Test-Path -LiteralPath $file)) { continue }
        try {
            $json = Get-Content -LiteralPath $file -Raw -Encoding UTF8
            try   { $sarif = $json | ConvertFrom-Json -Depth 100 }
            catch { $sarif = $json | ConvertFrom-Json }

            if (-not ($sarif.PSObject.Properties['runs'] -and $sarif.runs)) { continue }

            foreach ($run in @($sarif.runs)) {

                if (-not [string]::IsNullOrWhiteSpace($RepoRootUri)) {
                    if (-not $run.PSObject.Properties['originalUriBaseIds'] -or
                        $null -eq $run.originalUriBaseIds) {
                        $run | Add-Member -NotePropertyName 'originalUriBaseIds' `
                                          -NotePropertyValue ([PSCustomObject]@{
                                              '%SRCROOT%' = [PSCustomObject]@{ uri = $RepoRootUri }
                                          }) -Force
                    }
                }

                if ($run.PSObject.Properties['results'] -and $run.results) {
                    $before = @($run.results).Count
                    $kept   = @($run.results) | Where-Object {
                        $loc = $null
                        if ($_.PSObject.Properties['locations'] -and $_.locations) {
                            $loc = @($_.locations)[0]
                        }
                        if (-not $loc) { return $false }

                        $pl = $null
                        if ($loc.PSObject.Properties['physicalLocation'] -and $loc.physicalLocation) {
                            $pl = $loc.physicalLocation
                        }
                        if (-not $pl) { return $false }

                        $al = $null
                        if ($pl.PSObject.Properties['artifactLocation'] -and $pl.artifactLocation) {
                            $al = $pl.artifactLocation
                        }
                        if (-not $al) { return $false }

                        return ($al.PSObject.Properties['uri'] -and
                                -not [string]::IsNullOrWhiteSpace([string]$al.uri))
                    }
                    $dropped = $before - @($kept).Count
                    $totalDropped += $dropped
                    if ($dropped -gt 0) {
                        LogWn "  Dropped $dropped result(s) with empty URI from $(Split-Path -Leaf $file)"
                    }
                    $run.results = $kept
                }

                $allRuns.Add($run)
            }
        }
        catch { LogWn "Could not parse SARIF: $(Split-Path -Leaf $file)" }
    }

    if ($totalDropped -gt 0) {
        LogWn "Total results dropped (empty URI): $totalDropped"
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
    param([Parameter(Mandatory = $true)][string]$SarifFile)

    if (-not (Test-Path -LiteralPath $SarifFile)) { return }

    try {
        $json = Get-Content -LiteralPath $SarifFile -Raw -Encoding UTF8
        try   { $sarif = $json | ConvertFrom-Json -Depth 100 }
        catch { $sarif = $json | ConvertFrom-Json }

        if (-not ($sarif.PSObject.Properties['runs'] -and $sarif.runs)) { return }

        $totalDropped = 0
        foreach ($run in @($sarif.runs)) {
            if (-not ($run.PSObject.Properties['results'] -and $run.results)) { continue }

            $before = @($run.results).Count
            $run.results = @($run.results) | Where-Object {
                $loc = $null
                if ($_.PSObject.Properties['locations'] -and $_.locations) {
                    $loc = @($_.locations)[0]
                }
                if (-not $loc) { return $false }

                $pl = $null
                if ($loc.PSObject.Properties['physicalLocation'] -and $loc.physicalLocation) {
                    $pl = $loc.physicalLocation
                }
                if (-not $pl) { return $false }

                $al = $null
                if ($pl.PSObject.Properties['artifactLocation'] -and $pl.artifactLocation) {
                    $al = $pl.artifactLocation
                }
                if (-not $al) { return $false }

                return ($al.PSObject.Properties['uri'] -and
                        -not [string]::IsNullOrWhiteSpace([string]$al.uri))
            }

            $dropped = $before - @($run.results).Count
            $totalDropped += $dropped
        }

        if ($totalDropped -gt 0) {
            LogWn "  Removed $totalDropped result(s) with empty URI from $(Split-Path -Leaf $SarifFile)"
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
        [Parameter(Mandatory = $true)][string]$EditorConfigAnalysisPath,
        [array]$Projects = @()
    )

    $solutionDir  = Split-Path -Parent $SolutionPath
    $tempTargets  = Join-Path $solutionDir 'Directory.Build.targets'
    $sarifDirNorm = $PerProjectSarifDir.TrimEnd('/\') + [System.IO.Path]::DirectorySeparatorChar

    if (Test-Path -LiteralPath $tempTargets) {
        throw "Directory.Build.targets already exists in '$solutionDir' - remove it before running the analyzer."
    }

    New-Item -ItemType Directory -Path $PerProjectSarifDir -Force | Out-Null

    # Resolve absolute path to .editorconfig.analysis so MSBuild can find it
    # regardless of the working directory of each project.
    $editorConfigFullPath = (Resolve-Path -LiteralPath $EditorConfigAnalysisPath).Path

    # Directory.Build.targets is evaluated AFTER each .csproj, so properties here
    # override any per-project settings (e.g. RunAnalyzersDuringBuild=False).
    #
    # Key design decisions:
    #   - TreatWarningsAsErrors=false + WarningsAsErrors empty: ensures the build
    #     never stops on analyzer/compiler errors, so every project produces a DLL
    #     and dependent projects can be analyzed too.
    #   - EditorConfigFiles Remove/Include: replaces ALL .editorconfig files
    #     discovered by Roslyn's directory traversal with ONLY our
    #     .editorconfig.analysis. This means the normal .editorconfig at the
    #     solution root is ignored during analysis builds, and we don't need to
    #     create temporary override files in each project directory.
    $targetsContent = @"
<Project>
  <PropertyGroup Condition='`$(MSBuildProjectExtension)' == '.csproj'>
    <RunAnalyzers>true</RunAnalyzers>
    <RunAnalyzersDuringBuild>true</RunAnalyzersDuringBuild>
    <EnforceCodeStyleInBuild>true</EnforceCodeStyleInBuild>
    <GenerateDocumentationFile>true</GenerateDocumentationFile>
    <TreatWarningsAsErrors>false</TreatWarningsAsErrors>
    <WarningsAsErrors></WarningsAsErrors>
    <ErrorLog>$sarifDirNorm`$(MSBuildProjectName).sarif,version=2.1</ErrorLog>
  </PropertyGroup>
  <ItemGroup Condition='`$(MSBuildProjectExtension)' == '.csproj'>
    <EditorConfigFiles Remove="@(EditorConfigFiles)" />
    <EditorConfigFiles Include="$editorConfigFullPath" />
  </ItemGroup>
</Project>
"@

    $buildLog = Join-Path (Split-Path -Parent $FinalSarifPath) 'build.log'

    $buildExitCode = 1
    try {
        Set-Content -LiteralPath $tempTargets -Value $targetsContent -Encoding UTF8
        LogOk "Created temporary Directory.Build.targets with EditorConfigFiles override"

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
    }

    Log "Build log: $buildLog"

    $sarifFiles = @(Get-ChildItem -Path $PerProjectSarifDir -Filter '*.sarif' -ErrorAction SilentlyContinue |
                    Select-Object -ExpandProperty FullName)
    if ($sarifFiles.Count -gt 0) {
        LogOk "Per-project SARIF files generated ($($sarifFiles.Count)):" 
        foreach ($sf in $sarifFiles) { Log "    $(Split-Path -Leaf $sf)" }

        Log "Cleaning empty-URI results from per-project SARIF files..."
        foreach ($sf in $sarifFiles) { Remove-EmptyUriResults -SarifFile $sf }

        $repoRootUri = ''
        try {
            $repoRootNorm = $solutionDir.TrimEnd('\/') + '/'
            $repoRootUri  = [System.Uri]::new($repoRootNorm).AbsoluteUri
        } catch { }

        Merge-SarifFiles -InputFiles $sarifFiles -OutputFile $FinalSarifPath -RepoRootUri $repoRootUri
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

    $projDirs = @{}
    foreach ($proj in $Projects) {
        if (-not $proj.Found) { continue }
        $projDirs[$proj.FullPath] = (Split-Path -Parent $proj.FullPath).TrimEnd('\/') + [System.IO.Path]::DirectorySeparatorChar
    }

    $sarifRuns = if ($sarif.PSObject.Properties['runs'] -and $null -ne $sarif.runs) { @($sarif.runs) } else { @() }

    foreach ($run in $sarifRuns) {
        if ($null -eq $run) { continue }

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
        if ($line -match 'Project\("{[^"]+}"\)\s*=\s*"([^"]+)",\s*"([^"]+\.csproj)"') {
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

$editorConfigPath = Join-Path -Path $ScriptDir -ChildPath ".editorconfig.analysis"
if (Test-Path -LiteralPath $editorConfigPath) {
    LogOk "Using .editorconfig.analysis"
}
else {
    LogEr ".editorconfig.analysis not found at: $editorConfigPath"
    exit 1
}

$SolutionPath = Resolve-FullPath -PathValue (Join-Path -Path $RootDir -ChildPath "Tmed.sln")
if (-not (Test-Path -LiteralPath $SolutionPath)) {
    LogEr "Solution not found: $SolutionPath"
    exit 1
}

LogOk "Solution selected: $SolutionPath"

$solutionProjects = Get-SolutionProjects -SolutionFile $SolutionPath
LogOk "Found $($solutionProjects.Count) project(s) in solution"

$perProjectSarifDir = Join-Path -Path $OutputDirFull -ChildPath 'per-project'
Log "Running analyzer build for solution..."

$buildExitCode = Invoke-AnalyzerBuild `
    -SolutionPath              $SolutionPath `
    -PerProjectSarifDir        $perProjectSarifDir `
    -FinalSarifPath            $sarifPath `
    -EditorConfigAnalysisPath  $editorConfigPath `
    -Projects                  $solutionProjects

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