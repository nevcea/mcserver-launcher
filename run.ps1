$OutputEncoding = New-Object -TypeName System.Text.UTF8Encoding
$VerbosePreference = "SilentlyContinue"

try {
  $config = Import-PowerShellDataFile -Path "./config.psd1"  
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

function Ensure-DirectoryExists {
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
    Ensure-DirectoryExists -Path "./plugins"
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
    $checksum = $hashAlgorithm.ComputeHash([System.IO.File]::OpenRead($filePath))
    return [BitConverter]::ToString($checksum) -replace '-'
  }
  catch {
    Write-Log "Failed to calculate checksum for file '$filePath': $_" -Level "ERROR"
    $global:LASTEXITCODE = 1
    return $null
  }
}

function Download-PaperJar {
  param([string]$Version)
  try {
    $versionData = Invoke-RestMethod -Uri $ApiBaseUrl -ErrorAction Stop
    $versionToDownload = if ($config.MinecraftVersion -eq 'latest') {
      $versionData.versions[-1]
    } else {
      $config.MinecraftVersion
    }
    
    $buildData = Get-VersionDataFromApi -Version $versionToDownload
    if (-not $buildData) { return $null }

    $latestBuild = ($buildData.builds | Sort-Object { [int]$_ } -Descending | Select-Object -First 1)
    $downloadData = Invoke-RestMethod -Uri "$ApiBaseUrl/versions/$versionToDownload/builds/$latestBuild" -ErrorAction Stop
    $jarFileName = $downloadData.downloads.application.name
    $downloadUrl = "$ApiBaseUrl/versions/$versionToDownload/builds/$latestBuild/downloads/$jarFileName"
    
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
        if ($_ -match "paper-(\d+\.\d+\.\d+)-(\d+)\.jar$") {
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

function Validate-JavaExecutable {
  $javaCmd = Get-Command $JavaExecutable -ErrorAction SilentlyContinue
  if (-not $javaCmd) {
    Write-Log "Java executable not found: $JavaExecutable" -Level "ERROR"
    $global:LASTEXITCODE = 1
    return $false
  }

  try {
    $javaVersionOutput = & $JavaExecutable -version 2>&1
    if ($javaVersionOutput -match 'version "(\d+)(?:\.(\d+))?') {
      $majorVersion = [int]$matches[1]
      if ($majorVersion -lt 17) {
        Write-Log "Java 17 or higher is required. Detected version: $majorVersion" -Level "ERROR"
        return $false
      }
    }
  }
  catch {
    Write-Log "Failed to verify Java version: $_" -Level "ERROR"
    return $false
  }

  return $true
}


function Start-MinecraftServerWithJar {
  param([string]$JarFile)
  try {
    if (-not (Validate-JavaExecutable)) { return }
    
    $javaArgs = @("-Xms$($config.MinRamGB)G", "-Xmx$($config.MaxRamGB)G", "-jar", $JarFile)
    if ($JavaAdditionalArgs) {
      $javaArgs += $JavaAdditionalArgs -split ' '
    }
    
    & $JavaExecutable @javaArgs
  }
  catch {
    Write-Log "Error starting Minecraft server: $_" -Level "ERROR"
    $global:LASTEXITCODE = 1
  }
}

function Run-MinecraftServer {
  try {
    Initialize-ServerDirectories
    if (-not (Validate-JavaExecutable)) {
      Write-Log "Java validation failed. Exiting." -Level "ERROR"
      return
    }
    $paperJar = Find-ExistingPaperJar
    if (-not $paperJar) {
      $paperJar = Download-PaperJar -Version $config.MinecraftVersion
    }
    if (-not $paperJar) {
      Write-Log "Paper JAR file not found. Exiting." -Level "ERROR"
      return
    }
    Validate-JavaExecutable
    Clear-Host
    Start-MinecraftServerWithJar -JarFile $paperJar
  }
  catch {
    Write-Log "Unexpected error occurred: $_" -Level "ERROR"
    $global:LASTEXITCODE = 1
  }
}

Run-MinecraftServer
