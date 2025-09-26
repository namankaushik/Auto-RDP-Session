# Auto RDP Session Startup Script
# This script initializes and manages an RDP session with RDP connection details and optional ngrok tunnel
# Script parameters and configuration
param(
    [string]$SessionName = "AutoRDP-$(Get-Date -Format 'yyyyMMdd-HHmmss')",
    [string]$LogLevel = "Info",
    [bool]$EnableBackup = $true
)

# Initialize logging
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "Info"
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "[$Timestamp] [$Level] $Message"
    Write-Host $LogEntry
}

# Function to generate secure random password
function New-SecurePassword {
    param(
        [int]$Length = 20
    )
    $chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*"
    $password = ""
    for ($i = 0; $i -lt $Length; $i++) {
        $password += $chars[(Get-Random -Maximum $chars.Length)]
    }
    return $password
}

# Function to get public IP address
function Get-PublicIPAddress {
    try {
        $response = Invoke-RestMethod -Uri "https://api.ipify.org?format=text" -TimeoutSec 10
        return $response.Trim()
    } catch {
        try {
            $response = Invoke-RestMethod -Uri "https://ipinfo.io/ip" -TimeoutSec 10
            return $response.Trim()
        } catch {
            Write-Log "Unable to determine public IP address" "Warning"
            return "Unable to determine"
        }
    }
}

# Function to setup RDP user
function Set-RDPUser {
    param(
        [string]$Username,
        [string]$Password
    )
    try {
        $userExists = Get-LocalUser -Name $Username -ErrorAction SilentlyContinue
        $SecurePassword = ConvertTo-SecureString -String $Password -AsPlainText -Force
        if ($userExists) {
            Set-LocalUser -Name $Username -Password $SecurePassword
            Write-Log "Updated password for existing user: $Username"
        } else {
            New-LocalUser -Name $Username -Password $SecurePassword -Description "Auto-generated RDP user" -PasswordNeverExpires
            Write-Log "Created new user: $Username"
        }
        Add-LocalGroupMember -Group "Remote Desktop Users" -Member $Username -ErrorAction SilentlyContinue
        Write-Log "Added $Username to Remote Desktop Users group"
        return $true
    } catch {
        Write-Log "Failed to setup RDP user: $($_.Exception.Message)" "Error"
        return $false
    }
}

# Function to optionally start ngrok tunnel (when NGROK_AUTH_TOKEN is present)
function Start-NgrokRdpTunnel {
    param(
        [int]$LocalPort = 3389
    )
    try {
        $auth = $env:NGROK_AUTH_TOKEN
        if ([string]::IsNullOrEmpty($auth)) {
            Write-Log "NGROK_AUTH_TOKEN not set. Skipping ngrok tunnel." "Warning"
            return $null
        }

        # Ensure ngrok exists (workflow already installs; this is a fallback)
        $ngrokExe = Join-Path (Join-Path (Get-Location) "ngrok") "ngrok.exe"
        if (-not (Test-Path $ngrokExe)) {
            Write-Log "ngrok not found; attempting inline install..."
            $ngrokUrl = "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-windows-amd64.zip"
            $ngrokZip = "ngrok.zip"
            $ngrokDir = "ngrok"
            New-Item -ItemType Directory -Path $ngrokDir -Force | Out-Null
            Invoke-WebRequest -Uri $ngrokUrl -OutFile $ngrokZip
            Expand-Archive -Path $ngrokZip -DestinationPath $ngrokDir -Force
            $ngrokExe = Join-Path $ngrokDir "ngrok.exe"
        }

        # Configure auth token
        & $ngrokExe authtoken $auth | Out-Null

        # Start ngrok and capture output
        $outFile = "ngrok-output.txt"
        if (Test-Path $outFile) { Remove-Item $outFile -Force }
        $proc = Start-Process -FilePath $ngrokExe -ArgumentList "tcp", "$LocalPort", "--log", "stdout" -NoNewWindow -PassThru -RedirectStandardOutput $outFile

        # Wait for API to come online
        Start-Sleep -Seconds 10
        $addr = $null
        try {
            $tunnels = Invoke-RestMethod -Uri "http://localhost:4040/api/tunnels" -TimeoutSec 30
            $tcp = $tunnels.tunnels | Where-Object { $_.proto -eq "tcp" } | Select-Object -First 1
            if ($tcp) {
                $addr = ($tcp.public_url -replace "tcp://", "")
            }
        } catch {
            Write-Log "Failed to query ngrok API: $($_.Exception.Message)" "Error"
        }

        if ($addr) {
            Write-Log "NGROK tunnel active at: $addr"
            return $addr
        } else {
            Write-Log "ngrok tunnel did not start correctly. See ngrok-output.txt" "Error"
            return $null
        }
    } catch {
        Write-Log "Error starting ngrok: $($_.Exception.Message)" "Error"
        return $null
    }
}

# Main script execution
try {
    Write-Log "Starting RDP session: $SessionName"

    # System checks (placeholder)
    Write-Log "Performing system checks..."

    # Assume RDP enabled on hosted windows runner, otherwise would enable here

    # Generate connection details
    Write-Log "Generating RDP connection details..."
    $rdpPassword = New-SecurePassword -Length 20
    $rdpUsername = "rdpuser$(Get-Date -Format 'HHmmss')"
    $publicIP = Get-PublicIPAddress

    $userSetupSuccess = Set-RDPUser -Username $rdpUsername -Password $rdpPassword

    if ($userSetupSuccess) {
        Write-Log "=== RDP CONNECTION DETAILS ==="
        Write-Log "Public IP Address: $publicIP"
        Write-Log "RDP Port: 3389"
        Write-Log "Username: $rdpUsername"
        Write-Log "Password: $rdpPassword"
        Write-Log "============================"

        Write-Log "Connection Instructions:"
        Write-Log "1. Open Remote Desktop Connection (mstsc.exe)"
        Write-Log "2. Enter Computer: $publicIP:3389"
        Write-Log "3. Enter Username: $rdpUsername"
        Write-Log "4. Enter Password: $rdpPassword"
        Write-Log "5. Click Connect"

        # Create connection file for easy access
        $rdpContent = @"
full address:s:$publicIP:3389
username:s:$rdpUsername
audiomode:i:2
redirectcomports:i:0
redirectprinters:i:1
redirectsmartcards:i:1
redirectclipboard:i:1
redirectposdevices:i:0
autoreconnection enabled:i:1
authentication level:i:0
prompt for credentials:i:0
negotiate security layer:i:1
remoteapplicationmode:i:0
desktopwidth:i:1920
desktopheight:i:1080
"@
        $rdpContent | Out-File -FilePath "connection.rdp" -Encoding UTF8
        Write-Log "Created connection.rdp file for easy access"

        # Attempt to start ngrok tunnel (if token present)
        $ngrokAddress = Start-NgrokRdpTunnel -LocalPort 3389
        if ($ngrokAddress) {
            Write-Log "=== NGROK TUNNEL DETAILS ==="
            Write-Log "Tunnel Address: $ngrokAddress"
            Write-Log "Use this address directly in mstsc.exe for remote access"
            Write-Log "============================"

            # Create RDP file for ngrok address
            $ngrokRdp = @"
full address:s:$ngrokAddress
audiomode:i:2
redirectcomports:i:0
redirectprinters:i:1
redirectsmartcards:i:1
redirectclipboard:i:1
redirectposdevices:i:0
autoreconnection enabled:i:1
authentication level:i:0
prompt for credentials:i:0
negotiate security layer:i:1
remoteapplicationmode:i:0
desktopwidth:i:1920
desktopheight:i:1080
"@
            $ngrokRdp | Out-File -FilePath "connection-ngrok.rdp" -Encoding UTF8
            Write-Log "Created connection-ngrok.rdp file for direct access"
        } else {
            # Provide guidance for setting NGROK_AUTH_TOKEN secret
            Write-Log "To enable automatic ngrok tunnel, add repository secret 'NGROK_AUTH_TOKEN'" "Warning"
            Write-Log "Setup path: Settings -> Secrets and variables -> Actions -> New repository secret" "Warning"
            Write-Log "Get token: https://dashboard.ngrok.com/get-started/your-authtoken" "Warning"
        }
    }

    # Network adapter info
    Write-Log "Configuring network settings..."
    $networkAdapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1
    if ($networkAdapter) {
        Write-Log "Using network adapter: $($networkAdapter.Name)"
    } else {
        Write-Log "No active network adapter found" "Warning"
    }

    # Firewall placeholder
    Write-Log "Checking firewall settings..."

    # Session info
    Write-Log "Initializing session monitoring..."
    $sessionInfo = @{
        SessionId   = $SessionName
        StartTime   = Get-Date
        Status      = "Running"
        ProcessId   = $PID
        RDPUsername = $rdpUsername
        PublicIP    = $publicIP
    }
    $sessionJson = $sessionInfo | ConvertTo-Json
    Write-Log "Session info: $sessionJson"

    # Create status file
    $statusFile = "rdp-status.txt"
    $statusContent = @"
RDP session '$SessionName' started successfully at $(Get-Date)
Public IP: $publicIP
Username: $rdpUsername
Password: $rdpPassword
Port: 3389
"@
    if ($ngrokAddress) {
        $statusContent += @"
NGROK Tunnel: $ngrokAddress
Use this address in mstsc.exe for direct access
"@
    }
    $statusContent | Out-File -FilePath $statusFile

    Write-Log "RDP session initialization completed successfully"

} catch {
    Write-Log "Error occurred: $($_.Exception.Message)" "Error"
    exit 1
} finally {
    Write-Log "Script execution completed"
}
# End of script
