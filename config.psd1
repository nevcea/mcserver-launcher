@{
  # The path to the Java executable used to run the Minecraft server. (Usually, the default "java" is sufficient)
  JavaExecutable = "java"
  
  # The pattern used to match the Minecraft server .jar file (e.g., paper-1.18.jar). (Typically, this does not need to be modified)
  JarFilePattern = "paper-*.jar"
  
  # Additional arguments passed to the Java process when launching the Minecraft server (e.g., 'nogui' to disable the graphical interface).
  JavaAdditionalArgs = "nogui"
  
  # Minimum amount of RAM (in GB) allocated to the Minecraft server. (Adjust based on the server's needs)
  MinRamGB = 2
  
  # Maximum amount of RAM (in GB) allocated to the Minecraft server. (Adjust based on available system resources)
  MaxRamGB = 4
  
  # The Minecraft version to run. Use "latest" for the most up-to-date version or specify a particular version number.
  MinecraftVersion = "latest"
}