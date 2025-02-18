$OutputEncoding = New-Object -TypeName System.Text.UTF8Encoding
$VerbosePreference = "SilentlyContinue"

$config = Import-PowerShellDataFile -Path "./config.psd1"

$ApiBaseUrl = "https://api.papermc.io/v2/projects/paper"
$JavaExecutable = $config.JavaExecutable
$JarFilePattern = $config.JarFilePattern
$JavaAdditionalArgs = $config.JavaAdditionalArgs

$script:paperApiCache = @{ }
$script:versionData = $null

function Write-Log {
  param(
    [Parameter(Mandatory)]
    [string]$Message,
    [ValidateSet("INFO", "WARNING", "ERROR")]
    [string]$Level = "INFO"
  )
  $logMethods = @{
    INFO    = { Write-Host "[INFO]    $Message" -ForegroundColor Green }
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
      Write-Log "Directory created: $Path"
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
    "eula=true" | Out-File -Encoding UTF8 -FilePath "./eula.txt" -Force
    Write-Log "Server directories initialized."
  }
  catch {
    Write-Log "Error initializing server directories: $_" -Level "ERROR"
    $global:LASTEXITCODE = 1
    return
  }
}

function Get-VersionDataFromApi {
  param([string]$Version)
  if (-not $script:paperApiCache.ContainsKey($Version)) {
    try {
      $response = Invoke-RestMethod -Uri "$ApiBaseUrl/versions/$Version" -ErrorAction Stop
      if ($response) {
        $script:paperApiCache[$Version] = $response
      }
      else {
        Write-Log "No data received from API for version '$Version'" -Level "ERROR"
        $global:LASTEXITCODE = 1
        return $null
      }
    }
    catch {
      Write-Log "Failed to fetch API data for version '$Version': $_" -Level "ERROR"
      $global:LASTEXITCODE = 1
      return $null
    }
  }
  return $script:paperApiCache[$Version]
}

function Download-PaperJar {
  try {
    if (-not $script:versionData) {
      Write-Log "Fetching version data..."
      $script:versionData = Invoke-RestMethod -Uri $ApiBaseUrl -ErrorAction Stop
    }
    $versionToDownload = if ($config.MinecraftVersion -eq 'latest') {
      $script:versionData.versions[-1]
    } else {
      $config.MinecraftVersion
    }
    $buildData = Get-VersionDataFromApi -Version $versionToDownload
    if (-not $buildData) { return $null }
    $latestBuild = ($buildData.builds | Sort-Object { [int]$_ } -Descending | Select-Object -First 1)
    $downloadData = Invoke-RestMethod -Uri "$ApiBaseUrl/versions/$versionToDownload/builds/$latestBuild" -ErrorAction Stop
    $jarFileName = $downloadData.downloads.application.name
    $downloadUrl = "$ApiBaseUrl/versions/$versionToDownload/builds/$latestBuild/downloads/$jarFileName"
    $jarFilePath = "./$jarFileName"

    if (Test-Path $jarFilePath) {
      Write-Log "Paper JAR file already exists: $jarFileName"
      return $jarFileName
    }

    Write-Log "Downloading Paper JAR file from: $downloadUrl"
    Invoke-WebRequest -Uri $downloadUrl -OutFile $jarFilePath -ErrorAction Stop
    Write-Log "Paper JAR file download complete: $jarFileName"

    $expectedChecksum = $downloadData.downloads.application.sha256
    if ($expectedChecksum) {
      $actualChecksum = Get-FileHash -Path $jarFilePath -Algorithm SHA256
      if ($actualChecksum.Hash -eq $expectedChecksum) {
        Write-Log "Checksum validated successfully."
      }
      else {
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
    $jarFiles = Get-ChildItem -Path "./" -Filter $JarFilePattern -File
    if ($jarFiles) {
      $latestJar = $jarFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1
      Write-Log "Found existing Paper JAR file: $($latestJar.Name)"
      return $latestJar.Name
    }
    Write-Log "No Paper JAR file found in the current directory."
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
  $script:JavaExecutable = $javaCmd.Source
  return $true
}

function Start-MinecraftServerWithJar {
  param([string]$JarFile)
  try {
    if (-not (Validate-JavaExecutable)) { return }

    Write-Log "Starting Minecraft server with Paper JAR file: $JarFile"
    $javaArgs = @("-Xms$($config.MinRamGB)G", "-Xmx$($config.MaxRamGB)G", "-jar", $JarFile)
    if ($JavaAdditionalArgs) {
      $javaArgs += $JavaAdditionalArgs -split ' '
    }
    Write-Log "Executing: $JavaExecutable $($javaArgs -join ' ')"
    $process = Start-Process -FilePath $JavaExecutable -ArgumentList $javaArgs -WorkingDirectory "./" -PassThru
    $process.WaitForExit()
  }
  catch {
    Write-Log "Error starting Minecraft server: $_" -Level "ERROR"
    $global:LASTEXITCODE = 1
  }
}

function Run-MinecraftServer {
  try {
    Initialize-ServerDirectories
    $paperJar = Find-ExistingPaperJar
    if (-not $paperJar) {
      $paperJar = Download-PaperJar
    }
    if (-not $paperJar) {
      Write-Log "Paper JAR file not found. Exiting." -Level "ERROR"
      return
    }
    Clear-Host
    Start-MinecraftServerWithJar -JarFile $paperJar
  }
  catch {
    Write-Log "Unexpected error occurred: $_" -Level "ERROR"
    $global:LASTEXITCODE = 1
  }
}

Run-MinecraftServer