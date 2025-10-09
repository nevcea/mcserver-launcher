@{
  # Path to Java executable (default: "java")
  JavaExecutable     = "java"

  # Pattern to match the Paper server JAR file (usually no need to change)
  JarFilePattern     = "paper-*.jar"

  # JVM arguments (GC, encoding, etc. – do not include memory settings here)
  JavaAdditionalArgs = "-XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 -XX:+UnlockExperimentalVMOptions -XX:+DisableExplicitGC -XX:+AlwaysPreTouch -XX:G1NewSizePercent=30 -XX:G1MaxNewSizePercent=40 -XX:G1HeapRegionSize=8M -XX:G1ReservePercent=20 -XX:G1HeapWastePercent=5 -XX:G1MixedGCCountTarget=4 -XX:InitiatingHeapOccupancyPercent=15 -XX:G1MixedGCLiveThresholdPercent=90 -XX:G1RSetUpdatingPauseTimePercent=5 -XX:SurvivorRatio=32 -XX:+PerfDisableSharedMem -XX:MaxTenuringThreshold=1 -Dusing.aikars.flags=https://mcflags.emc.gs -Daikars.new.flags=true -Dfile.encoding=UTF-8"

  # Server launch arguments (typically "nogui" is enough)
  ServerArgs         = "nogui"

  # Minecraft version ("latest" for the newest release, or specify exact version e.g., "1.21.1")
  MinecraftVersion   = "latest"
}