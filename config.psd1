@{
  JavaExecutable    = "java"                # Path to Java executable (default "java" recommended)
  JarFilePattern    = "paper-*.jar"         # Server JAR file pattern (usually no need to change)
  JavaAdditionalArgs = "nogui"               # Additional Java arguments (e.g., disable GUI)
  
  $TotalMemoryGB = [math]::Round((Get-CimInstance -ClassName Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
  $MinRamGB = 2                              # Minimum RAM (GB)
  $MaxRamGB = if ($TotalMemoryGB -le 4) { 2 }
              elseif ($TotalMemoryGB -le 8) { 4 }
              elseif ($TotalMemoryGB -le 16) { 8 }
              else { [math]::Floor($TotalMemoryGB * 0.5) }  # Maximum RAM (GB)

  MinecraftVersion = "latest"                # Minecraft version ("latest" or specific version)
}