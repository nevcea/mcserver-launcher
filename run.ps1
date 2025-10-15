$IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($IsAdmin) {
    $messages = @(
        "[Security Error] Running as Administrator is prohibited due to security restrictions."
        "To learn why this is critical, please refer to:"
        "https://madelinemiller.dev/blog/root-minecraft-server/"
    )
    $messages | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    exit 1
}

function Write-Log {
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ValidateSet("WARNING", "ERROR")]
        [string]$Level = "ERROR"
    )
    $logMethods = @{
        WARNING = { Write-Host "[WARNING] $Message" -ForegroundColor Yellow }
        ERROR   = { Write-Host "[ERROR]   $Message" -ForegroundColor Red }
    }
    $logMethods[$Level].Invoke()
}

$DefaultJavaArgs = @(
    "-XX:+UseG1GC",
    "-XX:+ParallelRefProcEnabled",
    "-XX:MaxGCPauseMillis=200",
    "-XX:+UnlockExperimentalVMOptions",
    "-XX:+DisableExplicitGC",
    "-XX:+AlwaysPreTouch",
    "-XX:G1NewSizePercent=30",
    "-XX:G1MaxNewSizePercent=40",
    "-XX:G1HeapRegionSize=8M",
    "-XX:G1ReservePercent=20",
    "-XX:G1HeapWastePercent=5",
    "-XX:G1MixedGCCountTarget=4",
    "-XX:InitiatingHeapOccupancyPercent=15",
    "-XX:G1MixedGCLiveThresholdPercent=90",
    "-XX:G1RSetUpdatingPauseTimePercent=5",
    "-XX:SurvivorRatio=32",
    "-XX:+PerfDisableSharedMem",
    "-XX:MaxTenuringThreshold=1",
    "-Dusing.aikars.flags=https://mcflags.emc.gs",
    "-Daikars.new.flags=true",
    "-Dfile.encoding=UTF-8"
)

try {
    $config = Import-PowerShellDataFile -Path "./config.psd1"

    if (-not $config.JavaExecutable)     { $config.JavaExecutable = "java" }
    if (-not $config.JarFilePattern)     { $config.JarFilePattern = "paper-*.jar" }
    if (-not $config.JavaAdditionalArgs) { $config.JavaAdditionalArgs = $DefaultJavaArgs }
    elseif (-is [string] $config.JavaAdditionalArgs) {
        $config.JavaAdditionalArgs = $config.JavaAdditionalArgs -split ' '
    }
    if (-not $config.ServerArgs)         { $config.ServerArgs = "nogui" }

    $TotalMemoryGB = [math]::Floor((Get-CimInstance -ClassName Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    $MinRamGB = 2  
    $MaxRamGB = if ($TotalMemoryGB -le 4) { 2 }
                elseif ($TotalMemoryGB -le 8) { 4 }
                elseif ($TotalMemoryGB -le 16) { 8 }
                else { [math]::Min([math]::Floor($TotalMemoryGB * 0.5), 16) }  

    if ($MaxRamGB -lt $MinRamGB) { $MaxRamGB = $MinRamGB }
}
catch {
    Write-Log "Failed to load configuration file. Ensure config.psd1 exists. Details: $_" -Level "ERROR"
    exit 1
}

$ApiBaseUrl = "https://api.papermc.io/v2/projects/paper"
$JavaExecutable = $config.JavaExecutable
$JarFilePattern = $config.JarFilePattern

$script:paperApiCache = @{}

function New-Directory {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        try { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
        catch {
            Write-Log "Error creating directory '${Path}'. Check permissions. Details: $_" -Level "ERROR"
            $global:LASTEXITCODE = 1
        }
    }
}

function Initialize-ServerDirectories {
    try {
        New-Directory -Path "./plugins"
        Set-Content -Path "./eula.txt" -Value "eula=true" -Encoding ASCII
    }
    catch { 
        Write-Log "Failed to initialize server directories. Details: $_" -Level "ERROR"
        $global:LASTEXITCODE = 1
    }
}

function Get-VersionDataFromApi {
    param([string]$Version)
    $cacheKey = "versionData-$Version"
    if (-not $script:paperApiCache.ContainsKey($cacheKey)) {
        try {
            $response = Invoke-RestMethod -Uri "$ApiBaseUrl/versions/$Version" -ErrorAction Stop
            if ($response) { $script:paperApiCache[$cacheKey] = $response }
            else {
                Write-Log "Empty response from API for version '$Version'. Check network or API status." -Level "ERROR"
                return $null
            }
        }
        catch {
            Write-Log "Failed to fetch API data for version '$Version'. Network or API error. Details: $_" -Level "ERROR"
            return $null
        }
    }
    return $script:paperApiCache[$cacheKey]
}

function Get-FileChecksum {
    param([string]$filePath)
    try {
        $hashAlgorithm = [System.Security.Cryptography.SHA256]::Create()
        $fileStream = [System.IO.File]::OpenRead($filePath)
        try { $checksum = $hashAlgorithm.ComputeHash($fileStream) }
        finally { $fileStream.Dispose() }
        return [BitConverter]::ToString($checksum) -replace '-'
    }
    catch {
        Write-Log "Failed to calculate checksum for '$filePath'. File might be locked or missing. Details: $_" -Level "ERROR"
        $global:LASTEXITCODE = 1
        return $null
    }
}

function Save-PaperJar {
    param([string]$Version)
    try {
        $buildData = Get-VersionDataFromApi -Version $Version
        if (-not $buildData) { return $null }

        $latestBuild  = ($buildData.builds | Sort-Object { [int]$_ } -Descending | Select-Object -First 1)
        $downloadData = Invoke-RestMethod -Uri "$ApiBaseUrl/versions/$Version/builds/$latestBuild" -ErrorAction Stop
        $jarFileName  = $downloadData.downloads.application.name
        $downloadUrl  = "$ApiBaseUrl/versions/$Version/builds/$latestBuild/downloads/$jarFileName"

        $jarFilePath = Join-Path -Path $PSScriptRoot -ChildPath $jarFileName

        if (-not (Test-Path $jarFilePath)) {
            $ProgressPreference = "SilentlyContinue"
            Invoke-WebRequest -Uri $downloadUrl -OutFile $jarFilePath -ErrorAction Stop
        }

        $expectedChecksum = $downloadData.downloads.application.sha256
        if ($expectedChecksum) {
            $expected = ($expectedChecksum -replace '-', '').ToUpperInvariant()
            $actual   = Get-FileChecksum -filePath $jarFilePath
            if (-not $actual) { return $null }
            $actual   = ($actual -replace '-', '').ToUpperInvariant()

            if ($actual -ne $expected) {
                Write-Log "Checksum mismatch. Expected=$expected, Actual=$actual. File will be removed." -Level "ERROR"
                Remove-Item $jarFilePath -Force
                $global:LASTEXITCODE = 1
                return $null
            }
        }
        return $jarFileName
    }
    catch {
        Write-Log "Failed to download Paper JAR. Check internet connection or API status. Details: $_" -Level "ERROR"
        $global:LASTEXITCODE = 1
        return $null
    }
}

function Find-ExistingPaperJar {
    try {
        $jarFiles = Get-ChildItem -Path $PSScriptRoot -Filter $JarFilePattern -File
        if ($jarFiles) {
            $paperJars = $jarFiles | ForEach-Object {
                if ($_.Name -match "paper-(\d+\.\d+(?:\.\d+)?)-(\d+)\.jar$") {
                    [PSCustomObject]@{
                        FileName = $_.Name
                        Version  = [System.Version]$matches[1]
                        Build    = [int]$matches[2]
                    }
                }
            } | Where-Object { $_ -ne $null }

            return ($paperJars | Sort-Object Version, Build -Descending | Select-Object -First 1).FileName
        }
        return $null
    }
    catch {
        Write-Log "Error while searching for Paper JAR. Details: $_" -Level "ERROR"
        $global:LASTEXITCODE = 1
        return $null
    }
}

function Test-AndUpdatePaperJar {
    param([string]$Version)

    $resolvedVersion = $Version
    if ($Version -eq 'latest') {
        $versionData = Invoke-RestMethod -Uri $ApiBaseUrl -ErrorAction Stop
        $stableVersions = $versionData.versions | Where-Object { $_ -match '^\d+\.\d+(\.\d+)?$' }
        $resolvedVersion = $stableVersions[-1]
        Write-Host "Resolved 'latest' to version $resolvedVersion" -ForegroundColor Cyan
    }

    $localJar = Find-ExistingPaperJar
    $buildData = Get-VersionDataFromApi -Version $resolvedVersion
    if (-not $buildData) { return $null }

    $latestBuild = ($buildData.builds | Sort-Object { [int]$_ } -Descending | Select-Object -First 1)

    if ($localJar -and $localJar -match "paper-(\d+\.\d+(?:\.\d+)?)-(\d+)\.jar$") {
        $localVersion = $matches[1]
        $localBuild   = [int]$matches[2]

        if ($localVersion -eq $resolvedVersion) {
            if ($localBuild -ge $latestBuild) {
                Write-Host "Local Paper JAR is up to date ($localVersion build $localBuild)" -ForegroundColor Green
                return $localJar
            }
            else {
                Write-Host "Updating Paper JAR (local build $localBuild < latest build $latestBuild)" -ForegroundColor Yellow
                $newJar = Save-PaperJar -Version $resolvedVersion
                if ($newJar -and $localJar) {
                    try {
                        $oldJarPath = Join-Path -Path $PSScriptRoot -ChildPath $localJar
                        if (Test-Path $oldJarPath) {
                            Remove-Item $oldJarPath -Force
                            Write-Host "Removed old JAR: $oldJarPath" -ForegroundColor DarkGray
                        }
                    } catch {
                        Write-Log "Could not remove old JAR '$localJar'. Details: $_" -Level "WARNING"
                    }
                }
                return $newJar
            }
        }
    }

    Write-Host "No valid local Paper JAR found. Downloading latest..." -ForegroundColor Yellow
    return Save-PaperJar -Version $resolvedVersion
}

function Test-JavaExecutable {
    if ([string]::IsNullOrEmpty($JavaExecutable)) {
        Write-Log "JavaExecutable path not set in config.psd1." -Level "ERROR"
        return $false
    }

    $javaCmd = Get-Command $JavaExecutable -ErrorAction SilentlyContinue
    if (-not $javaCmd) {
        Write-Log "Java not found at path '$JavaExecutable'. Please verify config.psd1." -Level "ERROR"
        return $false
    }

    try {
        $javaVersionOutput = & $JavaExecutable -version 2>&1 | Out-String
        if ([string]::IsNullOrWhiteSpace($javaVersionOutput)) {
            Write-Log "Java executable gave no output. Command: '$JavaExecutable -version'" -Level "ERROR"
            return $false
        }

        if ($javaVersionOutput -match 'version "(\d+)(?:\.\d+)?') {
            $majorVersion = [int]$matches[1]
            Write-Host "Detected Java version: $majorVersion" -ForegroundColor Green
            if ($majorVersion -lt 17) {
                Write-Log "Java 17+ is required. Detected version: $majorVersion" -Level "ERROR"
                return $false
            }
        }
        else {
            Write-Log "Could not parse Java version. Output: '$javaVersionOutput'" -Level "ERROR"
            return $false
        }
    }
    catch {
        Write-Log "Java check failed. Details: $_" -Level "ERROR"
        return $false
    }
    return $true
}

function Start-MinecraftServerWithJar {
    param([string]$JarFile)
    try {
        $jarPath = if ([System.IO.Path]::IsPathRooted($JarFile)) { $JarFile } else { Join-Path $PSScriptRoot $JarFile }

        $javaArgs = @("-Xms$($MinRamGB)G", "-Xmx$($MaxRamGB)G") + $config.JavaAdditionalArgs
        $cmdArgs  = @($javaArgs + "-jar", $jarPath)
        if ($config.ServerArgs) { $cmdArgs += $config.ServerArgs -split ' ' }

        & $JavaExecutable @cmdArgs
    }
    catch {
        Write-Log "Failed to start Minecraft server. Details: $_" -Level "ERROR"
        $global:LASTEXITCODE = 1
    }
}

function Start-MinecraftServer {
    try {
        Initialize-ServerDirectories
        if (-not (Test-JavaExecutable)) {
            Write-Log "Java validation failed. Server will not start." -Level "ERROR"
            return
        }
        $paperJar = Test-AndUpdatePaperJar -Version $config.MinecraftVersion
        if (-not $paperJar) {
            Write-Log "No valid Paper JAR found. Exiting." -Level "ERROR"
            return
        }
        Start-MinecraftServerWithJar -JarFile $paperJar
    }
    catch {
        Write-Log "Unexpected fatal error. Details: $_" -Level "ERROR"
        $global:LASTEXITCODE = 1
    }
}

Start-MinecraftServer
