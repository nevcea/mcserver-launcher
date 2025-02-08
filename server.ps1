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

function Get-PaperApiData {
  param(
    [Parameter(Mandatory)]
    [string]$Version
  )
  if ($script:paperApiCache.ContainsKey($Version)) {
    return $script:paperApiCache[$Version]
  }
  try {
    $apiUrl = "$ApiBaseUrl/versions/$Version"
    $data = Invoke-RestMethod -Uri $apiUrl
    $script:paperApiCache[$Version] = $data
    return $data
  }
  catch {
    Write-Log "Failed to fetch API data for version '$Version': $_" -Level "ERROR"
    exit 1
  }
}

function Initialize-ServerDirectory {
  try {
    New-Item -ItemType Directory -Path $config.ServerDirectory, (Join-Path $config.ServerDirectory "plugins") -Force | Out-Null
    Set-Content -Path (Join-Path $config.ServerDirectory "eula.txt") -Value "eula=true"
    Write-Log "Server directory initialized."
  }
  catch {
    Write-Log "Error initializing server directory: $_" -Level "ERROR"
    exit 1
  }
}

function Download-PaperJar {
  try {
    if (-not $script:versionData) {
      Write-Log "Fetching version data..."
      $script:versionData = Invoke-RestMethod -Uri $ApiBaseUrl
    }
    $versionToDownload = if ($config.MinecraftVersion -eq 'latest') {
      $script:versionData.versions[-1]
    }
    else {
      $config.MinecraftVersion
    }
    $buildData = Get-PaperApiData -Version $versionToDownload
    $latestBuild = ($buildData.builds | Sort-Object { [int]$_ } -Descending | Select-Object -First 1)
    $downloadData = Invoke-RestMethod -Uri "$ApiBaseUrl/versions/$versionToDownload/builds/$latestBuild"
    $jarFileName = $downloadData.downloads.application.name
    $downloadUrl = "$ApiBaseUrl/versions/$versionToDownload/builds/$latestBuild/downloads/$jarFileName"
    $jarFilePath = Join-Path $config.ServerDirectory $jarFileName
    if (Test-Path $jarFilePath) {
      Write-Log "Paper JAR file already exists: $jarFileName"
      return $jarFileName
    }
    Write-Log "Downloading Paper JAR file from: $downloadUrl"
    Invoke-WebRequest -Uri $downloadUrl -OutFile $jarFilePath
    Write-Log "Paper JAR file download complete: $jarFileName"
    return $jarFileName
  }
  catch {
    Write-Log "Paper JAR download failed: $_" -Level "ERROR"
    exit 1
  }
}

function Find-ExistingPaperJar {
  try {
    $jarFiles = Get-ChildItem -Path $config.ServerDirectory -Filter $JarFilePattern -File
    if ($jarFiles) {
      if ($config.MinecraftVersion -eq 'latest') {
        $latestJar = $jarFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        Write-Log "Latest Paper JAR file found: $($latestJar.Name)"
        return $latestJar.Name
      }
      else {
        foreach ($file in $jarFiles) {
          $match = [regex]::Match($file.Name, "paper-(\d+\.\d+\.\d+)")
          if ($match.Success -and $match.Groups[1].Value -eq $config.MinecraftVersion) {
            Write-Log "Matching Paper JAR file found: $($file.Name)"
            return $file.Name
          }
        }
        Write-Log "Jar file exists but doesn't match the specified version ($($config.MinecraftVersion))." -Level "WARNING"
        Write-Log "Version mismatch, stopping server startup." -Level "ERROR"
        exit 1
      }
    }
    Write-Log "No Paper JAR file found in the server directory."
    return $null
  }
  catch {
    Write-Log "Error searching for Paper JAR file: $_" -Level "ERROR"
    exit 1
  }
}

function Get-OrDownloadPaperJar {
  $jar = Find-ExistingPaperJar
  if (-not $jar) {
    $jar = Download-PaperJar
  }
  return $jar
}

function Start-MinecraftServer {
  param(
    [Parameter(Mandatory)]
    [string]$JarFile
  )
  try {
    Write-Log "Starting Minecraft server with Paper JAR file ($JarFile)."
    Start-Process -FilePath $JavaExecutable -ArgumentList @("-Xms$($config.MinRamGB)G", "-Xmx$($config.MaxRamGB)G", "-jar", $JarFile, $JavaAdditionalArgs) -WorkingDirectory $config.ServerDirectory -NoNewWindow -Wait
  }
  catch {
    Write-Log "Error starting Minecraft server: $_" -Level "ERROR"
    exit 1
  }
}

function Run-Server {
  try {
    if (-not (Test-Path $config.ServerDirectory)) {
      Initialize-ServerDirectory
    }
    $paperJar = Get-OrDownloadPaperJar
    if (-not $paperJar) {
      Write-Log "Paper JAR file not found. Exiting." -Level "ERROR"
      exit 1
    }
    Clear-Host
    Start-MinecraftServer -JarFile $paperJar
  }
  catch {
    Write-Log "Unexpected error occurred: $_" -Level "ERROR"
    exit 1
  }
}

Run-Server