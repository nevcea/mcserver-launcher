@{
  # The Java executable to use for running the Minecraft server. (Typically, this doesn't need to be changed)
  JavaExecutable = "java"
  
  # The pattern used to identify the Minecraft server .jar file (e.g., paper-1.18.jar). (Usually doesn't need modification)
  JarFilePattern = "paper-*.jar"
  
  # Additional arguments passed to Java when launching the server, such as 'nogui' for no graphical interface. (This is usually fine as is)
  JavaAdditionalArgs = "nogui"
  
  # Minimum RAM allocation for the Minecraft server (in GB). (This value can be adjusted based on your server's needs)
  MinRamGB = 2
  
  # Maximum RAM allocation for the Minecraft server (in GB). (Adjustable based on available system resources)
  MaxRamGB = 4
  
  # The version of Minecraft to run. "latest" will use the most recent version. (This is fine unless you want a specific version)
  MinecraftVersion = "latest"
  
  # The directory where the Minecraft server files are located. (Typically, this should be set to the correct server folder)
  ServerDirectory = "./server"
}
