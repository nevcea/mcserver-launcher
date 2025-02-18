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
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Initialize-ServerDirectory {
  try {
    Ensure-DirectoryExists -Path $config.ServerDirectory
    Ensure-DirectoryExists -Path (Join-Path $config.ServerDirectory "plugins")
    "eula=true" | Out-File -Encoding UTF8 -FilePath (Join-Path $config.ServerDirectory "eula.txt") -Force
    Write-Log "Server directory initialized."
  }
  catch {
    Write-Log "Error initializing server directory: $_" -Level "ERROR"
    $global:LASTEXITCODE = 1
    return
  }
}

function Get-PaperApiData {
  param([string]$Version)
  if (-not $script:paperApiCache.ContainsKey($Version)) {
    try {
      $script:paperApiCache[$Version] = Invoke-RestMethod -Uri "$ApiBaseUrl/versions/$Version" -ErrorAction Stop
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
    $buildData = Get-PaperApiData -Version $versionToDownload
    if (-not $buildData) { return $null }
    $latestBuild = ($buildData.builds | Sort-Object { [int]$_ } -Descending | Select-Object -First 1)
    $downloadData = Invoke-RestMethod -Uri "$ApiBaseUrl/versions/$versionToDownload/builds/$latestBuild" -ErrorAction Stop
    $jarFileName = $downloadData.downloads.application.name
    $downloadUrl = "$ApiBaseUrl/versions/$versionToDownload/builds/$latestBuild/downloads/$jarFileName"
    $jarFilePath = Join-Path $config.ServerDirectory $jarFileName
    if (Test-Path $jarFilePath) {
      Write-Log "Paper JAR file already exists: $jarFileName"
      return $jarFileName
    }
    Write-Log "Downloading Paper JAR file from: $downloadUrl"
    Invoke-WebRequest -Uri $downloadUrl -OutFile $jarFilePath -ErrorAction Stop
    Write-Log "Paper JAR file download complete: $jarFileName"
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
    $jarFiles = Get-ChildItem -Path $config.ServerDirectory -Filter $JarFilePattern -File
    if ($jarFiles) {
      $latestJar = $jarFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1
      Write-Log "Found existing Paper JAR file: $($latestJar.Name)"
      return $latestJar.Name
    }
    Write-Log "No Paper JAR file found in the server directory."
    return $null
  }
  catch {
    Write-Log "Error searching for Paper JAR file: $_" -Level "ERROR"
    $global:LASTEXITCODE = 1
    return $null
  }
}

function Start-MinecraftServer {
  param([string]$JarFile)
  try {
    Write-Log "Starting Minecraft server with Paper JAR file: $JarFile"
    $javaArgs = @("-Xms$($config.MinRamGB)G", "-Xmx$($config.MaxRamGB)G", "-jar", $JarFile)
    if ($JavaAdditionalArgs) {
      $javaArgs += $JavaAdditionalArgs -split ' '
    }
    Write-Log "Executing: $JavaExecutable $($javaArgs -join ' ')"
    $process = Start-Process -FilePath $JavaExecutable -ArgumentList $javaArgs -WorkingDirectory $config.ServerDirectory -PassThru
    $process.WaitForExit()
  }
  catch {
    Write-Log "Error starting Minecraft server: $_" -Level "ERROR"
    $global:LASTEXITCODE = 1
  }
}

function Run-Server {
  try {
    Initialize-ServerDirectory
    $paperJar = Find-ExistingPaperJar
    if (-not $paperJar) {
      $paperJar = Download-PaperJar
    }
    if (-not $paperJar) {
      Write-Log "Paper JAR file not found. Exiting." -Level "ERROR"
      return
    }
    Clear-Host
    Start-MinecraftServer -JarFile $paperJar
  }
  catch {
    Write-Log "Unexpected error occurred: $_" -Level "ERROR"
    $global:LASTEXITCODE = 1
  }
}

Run-Server