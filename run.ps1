$IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($IsAdmin) {
    $messages = @(
        "[Security Error] Running as Administrator is prohibited due to security restrictions."
        "To learn why this is critical, please refer to the explanation here:"
        "https://madelinemiller.dev/blog/root-minecraft-server/"
    )
    $messages | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    exit 1
}

$OutputEncoding = New-Object -TypeName System.Text.UTF8Encoding
$VerbosePreference = "SilentlyContinue"

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

try {
    $config = Import-PowerShellDataFile -Path "./config.psd1"

    $TotalMemoryGB = [math]::Floor((Get-CimInstance -ClassName Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    $MinRamGB = 2  
    $MaxRamGB = if ($TotalMemoryGB -le 4) { 2 }
                elseif ($TotalMemoryGB -le 8) { 4 }
                elseif ($TotalMemoryGB -le 16) { 8 }
                else { [math]::Min([math]::Floor($TotalMemoryGB * 0.5), 16) }  

    if ($MaxRamGB -lt $MinRamGB) {
        $MaxRamGB = $MinRamGB
    }
}
catch {
    Write-Log "Failed to load configuration file: $_" -Level "ERROR"
    exit 1
}

$ApiBaseUrl = "https://api.papermc.io/v2/projects/paper"
$JavaExecutable = $config.JavaExecutable
$JarFilePattern = $config.JarFilePattern
$JavaAdditionalArgs = $config.JavaAdditionalArgs

$script:paperApiCache = @{}

function New-Directory {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        try {
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
        }
        catch {
            Write-Log "Error creating directory ${Path}: $_" -Level "ERROR"
            $global:LASTEXITCODE = 1
            return
        }
    }
}

function Initialize-ServerDirectories {
    try {
        New-Directory -Path "./plugins"
        Set-Content -Path "./eula.txt" -Value "eula=true" -Encoding ASCII
    }
    catch { 
        Write-Log "Error initializing server directories: $_" -Level "ERROR"
        $global:LASTEXITCODE = 1
        return
    }
}

function Get-VersionDataFromApi {
    param([string]$Version)
    $cacheKey = "versionData-$Version"

    if (-not $script:paperApiCache.ContainsKey($cacheKey)) {
        try {
            $response = Invoke-RestMethod -Uri "$ApiBaseUrl/versions/$Version" -ErrorAction Stop
            if ($response) {
                $script:paperApiCache[$cacheKey] = $response
            }
            else {
                Write-Log "No data received from API for version '$Version'" -Level "ERROR"
                return $null
            }
        }
        catch {
            Write-Log "Failed to fetch API data for version '$Version': $_" -Level "ERROR"
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
        try {
            $checksum = $hashAlgorithm.ComputeHash($fileStream)
        } finally {
            $fileStream.Dispose()
        }
        return [BitConverter]::ToString($checksum) -replace '-'
    }
    catch {
        Write-Log "Failed to calculate checksum for file '$filePath': $_" -Level "ERROR"
        $global:LASTEXITCODE = 1
        return $null
    }
}

function Save-PaperJar {
    param([string]$Version)
    
    try {
        $versionData = Invoke-RestMethod -Uri $ApiBaseUrl -ErrorAction Stop
        if ($config.MinecraftVersion -eq 'latest') {
            $stableVersions = $versionData.versions | Where-Object {
                $_ -match '^\d+\.\d+(\.\d+)?$'
            }
            $versionToDownload = $stableVersions[-1]
        } else {
            $versionToDownload = $config.MinecraftVersion
        }

        $buildData = Get-VersionDataFromApi -Version $versionToDownload
        if (-not $buildData) { return $null }

        $latestBuild = ($buildData.builds | Sort-Object { [int]$_ } -Descending | Select-Object -First 1)
        $downloadData = Invoke-RestMethod -Uri "$ApiBaseUrl/versions/$versionToDownload/builds/$latestBuild" -ErrorAction Stop
        $jarFileName = $downloadData.downloads.application.name
        $downloadUrl = "$ApiBaseUrl/versions/$versionToDownload/builds/$latestBuild/downloads/$jarFileName"

        $ProgressPreference = "SilentlyContinue"
        Invoke-WebRequest -Uri $downloadUrl -OutFile $jarFilePath -ErrorAction Stop

        $jarFilePath = Join-Path -Path $PSScriptRoot -ChildPath $jarFileName

        if (Test-Path $jarFilePath) {
            return $jarFileName
        }

        Invoke-WebRequest -Uri $downloadUrl -OutFile $jarFilePath -ErrorAction Stop

        $expectedChecksum = $downloadData.downloads.application.sha256
        if ($expectedChecksum) {
            $actualChecksum = Get-FileChecksum -filePath $jarFilePath
            if ($actualChecksum -ne $expectedChecksum) {
                Write-Log "Checksum validation failed." -Level "ERROR"
                Remove-Item $jarFilePath -Force
                $global:LASTEXITCODE = 1
                return $null
            }
        }

        return $jarFileName
    }
    catch {
        Write-Log "Paper JAR download failed: $_" -Level "ERROR"
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
            }

            $latestJar = $paperJars | Sort-Object Version, Build -Descending | Select-Object -First 1

            if ($latestJar) {
                return $latestJar.FileName
            }
        }
        return $null
    }
    catch {
        Write-Log "Error searching for Paper JAR file: $_" -Level "ERROR"
        $global:LASTEXITCODE = 1
        return $null
    }
}

function Test-AndUpdatePaperJar {
    param([string]$Version)

    if ($Version -eq 'latest') {
        $versionData = Invoke-RestMethod -Uri $ApiBaseUrl -ErrorAction Stop
        $stableVersions = $versionData.versions | Where-Object {
            $_ -match '^\d+\.\d+(\.\d+)?$'
        }
        $Version = $stableVersions[-1]
        Write-Host "Resolved 'latest' to version $Version" -ForegroundColor Cyan
    }

    $localJar = Find-ExistingPaperJar
    $buildData = Get-VersionDataFromApi -Version $Version
    if (-not $buildData) { return $null }

    $latestBuild = ($buildData.builds | Sort-Object { [int]$_ } -Descending | Select-Object -First 1)

    if ($localJar -and $localJar -match "paper-(\d+\.\d+(?:\.\d+)?)-(\d+)\.jar$") {
        $localVersion = $matches[1]
        $localBuild   = [int]$matches[2]

        if ($localVersion -eq $Version) {
            if ($localBuild -ge $latestBuild) {
                Write-Host "Local Paper JAR is up to date (version $localVersion build $localBuild)" -ForegroundColor Green
                return $localJar
            }
            else {
                Write-Host "Updating Paper JAR: local build $localBuild < latest build $latestBuild" -ForegroundColor Yellow
                $newJar = Save-PaperJar -Version $Version
                if ($newJar -and (Test-Path $localJar)) {
                    try {
                        Remove-Item $localJar -Force
                        Write-Host "Removed old JAR: $localJar" -ForegroundColor DarkGray
                    } catch {
                        Write-Log "Failed to remove old JAR '$localJar': $_" -Level "WARNING"
                    }
                }
                return $newJar
            }
        }
    }

    Write-Host "No valid local Paper JAR found. Downloading latest..." -ForegroundColor Yellow
    return Save-PaperJar -Version $Version
}

function Test-JavaExecutable {
    param()

    if ([string]::IsNullOrEmpty($JavaExecutable)) {
        Write-Log "JavaExecutable path is not defined in config.psd1." -Level "ERROR"
        $global:LASTEXITCODE = 1
        return $false
    }

    $javaCmd = Get-Command $JavaExecutable -ErrorAction SilentlyContinue
    if (-not $javaCmd) {
        Write-Log "Java executable not found at path: '$JavaExecutable'. Please check your config.psd1." -Level "ERROR"
        $global:LASTEXITCODE = 1
        return $false
    }

    try {
        $javaVersionOutput = & $JavaExecutable -version 2>&1 | Out-String

        if ([string]::IsNullOrWhiteSpace($javaVersionOutput)) {
            Write-Log "No output received from Java executable version check. Command: '$JavaExecutable -version'" -Level "ERROR"
            return $false
        }

        if ($javaVersionOutput -match 'version "(\d+)(?:\.\d+)?(?:\.\d+)?(?:_(\d+))?"') {
            if ($matches.Count -gt 1) {
                $majorVersion = [int]$matches[1]
                Write-Host "Detected Java version: $majorVersion" -ForegroundColor Green

                if ($majorVersion -lt 17) {
                    Write-Log "Java 17 or higher is required to run Minecraft Paper server. Detected version: $majorVersion" -Level "ERROR"
                    return $false
                }
            } else {
                Write-Log "Failed to parse Java version from output: '$javaVersionOutput'. Regex did not find expected groups." -Level "ERROR"
                return $false
            }
        }
        else {
            Write-Log "Failed to parse Java version output: '$javaVersionOutput'. Output format unexpected." -Level "ERROR"
            return $false
        }
    }
    catch {
        Write-Log "An error occurred while verifying Java version: $_" -Level "ERROR"
        return $false
    }

    return $true
}

function Start-MinecraftServerWithJar {
    param([string]$JarFile)
    try {
        if (-not (Test-JavaExecutable)) { return }

        $javaArgs = @(
            "-Xms$($MinRamGB)G",
            "-Xmx$($MaxRamGB)G"
        )

        if ($JavaAdditionalArgs) {
            $javaArgs += $JavaAdditionalArgs -split ' '
        }

        $cmdArgs = @($javaArgs + "-jar", $JarFile)

        if ($config.ServerArgs) {
            $cmdArgs += $config.ServerArgs -split ' '
        }

        & $JavaExecutable @cmdArgs
    }
    catch {
        Write-Log "Error starting Minecraft server: $_" -Level "ERROR"
        $global:LASTEXITCODE = 1
    }
}

function Start-MinecraftServer {
    try {
        Initialize-ServerDirectories
        if (-not (Test-JavaExecutable)) {
            Write-Log "Java validation failed. Exiting." -Level "ERROR"
            return
        }
        $paperJar = Test-AndUpdatePaperJar -Version $config.MinecraftVersion
        if (-not $paperJar) {
            Write-Log "Paper JAR file not found. Exiting." -Level "ERROR"
            return
        }
        Test-JavaExecutable
        Clear-Host
        Start-MinecraftServerWithJar -JarFile $paperJar
    }
    catch {
        Write-Log "Unexpected error occurred: $_" -Level "ERROR"
        $global:LASTEXITCODE = 1
    }
}

Start-MinecraftServer
