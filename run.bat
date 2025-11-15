@echo off
chcp 949 >nul 2>&1
setlocal enabledelayedexpansion

set "MINECRAFT_VERSION=latest"
set "MIN_RAM=2"
set "MAX_RAM=4"
set "SERVER_ARGS=nogui"

set "RAM_LOW_THRESHOLD=4"
set "RAM_MID_THRESHOLD=8"
set "RAM_HIGH_THRESHOLD=16"

set "JAVA_CMD=java"
where java >nul 2>&1
if !errorlevel! neq 0 (
    echo [ERROR] Java not found. Please install Java.
    pause
    exit /b 1
)

set "ORIGINAL_MAX_RAM=!MAX_RAM!"

set "TOTAL_RAM_GB="
for /f "tokens=2 delims==" %%m in ('wmic computersystem get TotalPhysicalMemory /value 2^>nul ^| findstr /i "TotalPhysicalMemory"') do (
    set /a "TOTAL_RAM_GB=%%m/1024/1024/1024" 2>nul
)

if "!ORIGINAL_MAX_RAM!"=="!MAX_RAM!" (
    if "!TOTAL_RAM_GB!"=="" (
        set /a "MAX_RAM=!MAX_RAM!/2"
        if !MAX_RAM! lss !MIN_RAM! set "MAX_RAM=!MIN_RAM!"
    ) else if !TOTAL_RAM_GB! leq !RAM_LOW_THRESHOLD! (
        set /a "MAX_RAM=!TOTAL_RAM_GB!/2"
        if !MAX_RAM! lss !MIN_RAM! set "MAX_RAM=!MIN_RAM!"
    ) else if !TOTAL_RAM_GB! leq !RAM_MID_THRESHOLD! (
        set /a "MAX_RAM=!TOTAL_RAM_GB!/2"
    ) else if !TOTAL_RAM_GB! leq !RAM_HIGH_THRESHOLD! (
        set "MAX_RAM=8"
    ) else (
        set /a "MAX_RAM=!TOTAL_RAM_GB!/2"
        if !MAX_RAM! gtr !RAM_HIGH_THRESHOLD! set "MAX_RAM=!RAM_HIGH_THRESHOLD!"
    )
)

if !MAX_RAM! lss !MIN_RAM! set "MAX_RAM=!MIN_RAM!"

set "JAR_FILE="

for %%f in (paper-*.jar) do (
    set "JAR_FILE=%%~f"
)

:jar_found
if defined JAR_FILE goto :jar_exists

echo.
echo No Paper JAR file found.
echo Would you like to download automatically? [Y/N]:
set "DOWNLOAD_CHOICE="
set /p DOWNLOAD_CHOICE="> "

if /i "!DOWNLOAD_CHOICE!" NEQ "Y" goto :no_download

echo Downloading...

powershell -NoProfile -Command "try {$ProgressPreference='SilentlyContinue';$api='https://api.papermc.io/v2/projects/paper';$v='%MINECRAFT_VERSION%';if ($v -eq 'latest') {$p=irm $api;$v=$p.versions[-1]};$b=irm \"$api/versions/$v\";$latest=$b.builds[-1];$data=irm \"$api/versions/$v/builds/$latest\";$jar=$data.downloads.application.name;Write-Host \"Downloading $jar...\";$url=\"$api/versions/$v/builds/$latest/downloads/$jar\";irm $url -OutFile $jar;exit 0} catch {Write-Host \"Error: $($_.Exception.Message)\";exit 1}"

if errorlevel 1 goto :download_failed

for %%f in (paper-*.jar) do set "JAR_FILE=%%~f"& goto :jar_downloaded
:jar_downloaded

if not defined JAR_FILE goto :download_not_found

goto :jar_exists

:download_failed
echo.
echo [ERROR] Download failed. Please check your internet connection.
goto :exit_error

:download_not_found
echo [ERROR] JAR file not found after download.
goto :exit_error

:no_download
goto :exit_error

:exit_error
pause
exit /b 1

:jar_exists

if not defined JAR_FILE (
    echo [ERROR] JAR file is not defined.
    goto :exit_error
)

if not exist "!JAR_FILE!" (
    echo [ERROR] JAR file not found: !JAR_FILE!
    goto :exit_error
)

set "EULA_VALID=0"
if exist "eula.txt" (
    findstr /v /c:"#" "eula.txt" 2>nul | findstr /i /c:"eula=true" >nul 2>&1
    if !errorlevel! equ 0 set "EULA_VALID=1"
)

if !EULA_VALID! equ 0 (
    powershell -NoProfile -Command "$content = '#By changing the setting below to TRUE you are indicating your agreement to our EULA (https://aka.ms/MinecraftEULA).' + [Environment]::NewLine + 'eula=true'; [System.IO.File]::WriteAllText('eula.txt', $content, [System.Text.Encoding]::UTF8)" 2>nul
    if errorlevel 1 (
        (
            echo #By changing the setting below to TRUE you are indicating your agreement to our EULA (https://aka.ms/MinecraftEULA^).
            echo eula=true
        ) > "eula.txt"
    )
)

set "JAVA_ARGS=-XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 -XX:+UnlockExperimentalVMOptions -XX:+DisableExplicitGC -XX:+AlwaysPreTouch -XX:G1NewSizePercent=30 -XX:G1MaxNewSizePercent=40 -XX:G1HeapRegionSize=8M -XX:G1ReservePercent=20 -XX:G1HeapWastePercent=5 -XX:G1MixedGCCountTarget=4 -XX:InitiatingHeapOccupancyPercent=15 -XX:G1MixedGCLiveThresholdPercent=90 -XX:G1RSetUpdatingPauseTimePercent=5 -XX:SurvivorRatio=32 -XX:+PerfDisableSharedMem -XX:MaxTenuringThreshold=1 -Dusing.aikars.flags=https://mcflags.emc.gs -Daikars.new.flags=true -Dfile.encoding=UTF-8"

%JAVA_CMD% -Xms!MIN_RAM!G -Xmx!MAX_RAM!G %JAVA_ARGS% -jar "!JAR_FILE!" %SERVER_ARGS%
set SERVER_EXIT_CODE=!errorlevel!

if !SERVER_EXIT_CODE! neq 0 (
    echo.
    echo Server stopped with exit code: !SERVER_EXIT_CODE!
    echo.
)

pause

endlocal
