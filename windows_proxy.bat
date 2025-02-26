@echo off
setlocal EnableDelayedExpansion

:: Clean up any leftover bad proxy rules from previous runs
netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=ADDITIONAL_PORTS_INPUT: >nul 2>&1
netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=N >nul 2>&1

:: Fetch the WSL IP dynamically using PowerShell and only pick the first IP
for /f "tokens=1" %%i in ('powershell -command "wsl hostname -I"') do set WSL_IP=%%i

:: Get the local machine's IP address for user confirmation
for /f "tokens=2 delims=:" %%i in ('ipconfig ^| findstr "IPv4"') do set USER_IP=%%i
set USER_IP=%USER_IP: =%

:: Define default ports
set DEFAULT_PORT=3000
set PLEX_PORT=32400

:: Initialize list of additional ports to process later
set ADDITIONAL_PORTS=

:: Step 1: Ensure port 3000 is proxied
echo Ensuring port %DEFAULT_PORT% is proxied...
call :proxy_port %DEFAULT_PORT%

:: Step 2: Ask if user wants Plex (32400) to be proxied via their machine IP
set /p PROXY_PLEX="Do you want to access Plex via %USER_IP%:%PLEX_PORT%? (Y/N): "
if /i "%PROXY_PLEX%"=="Y" (
    echo Adding Plex port %PLEX_PORT% to the list for proxying...
    set ADDITIONAL_PORTS=%PLEX_PORT%
)

:: Step 3: Ask if user wants to proxy any other ports, one at a time
set /p ADD_PORTS="Do you want to add an additional port to proxy? (Y/N): "
:port_loop
if /i "!ADD_PORTS!"=="Y" (
    set /p NEW_PORT="Enter a port to proxy (e.g., 8080): "
    if not "!NEW_PORT!"=="" if /i not "!NEW_PORT!"=="N" if /i not "!NEW_PORT!"=="Y" (
        if "!ADDITIONAL_PORTS!"=="" (
            set ADDITIONAL_PORTS=!NEW_PORT!
        ) else (
            set ADDITIONAL_PORTS=!ADDITIONAL_PORTS! !NEW_PORT!
        )
    )
    set /p ADD_PORTS="Do you want to add an additional port? (Y/N): "
    goto :port_loop
)

:: Step 4: Process all additional ports collected
if not "!ADDITIONAL_PORTS!"=="" (
    echo Processing the following ports: !ADDITIONAL_PORTS!
    for %%p in (!ADDITIONAL_PORTS!) do (
        call :proxy_port %%p
    )
)

:: End of script
goto :eof

:: Function to proxy a port and configure firewall
:proxy_port
set PORT=%1
echo Checking if port %PORT% is already proxied...

:: Check if the port proxy rule already exists
netsh interface portproxy show v4tov4 | findstr "%PORT%" >nul
if %ERRORLEVEL% equ 0 (
    echo Port forwarding already exists for 0.0.0.0:%PORT%
) else (
    :: Add port forwarding rule to proxy the specified port for all interfaces
    echo Adding port forwarding for 0.0.0.0:%PORT% to WSL2 IP %WSL_IP%:%PORT%
    netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=%PORT% connectaddress=%WSL_IP% connectport=%PORT%
)

:: Always configure the firewall, even if port is already proxied
echo Configuring firewall to allow access to port %PORT%...
netsh advfirewall firewall add rule name="Allow Port %PORT%" dir=in action=allow protocol=TCP localport=%PORT%

:: Verify port proxy rules
echo Current port proxy rules:
netsh interface portproxy show all

echo Firewall rule created for port %PORT%.
goto :eof
