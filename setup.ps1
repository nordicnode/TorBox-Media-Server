<#
.SYNOPSIS
TorBox Media Server - All-in-One Setup Script
Automated setup for a debrid-powered media server using Docker on Windows

.DESCRIPTION
Components: Prowlarr, Byparr, Decypharr, Seerr,
            Radarr, Sonarr, rclone/WinFSP mount, Plex or Jellyfin
#>

$Version = "1.1.0"
$DryRun = $false
$ServicesStarted = $false
$NonInteractive = $false

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$InstallDir = Join-Path $ScriptDir "torbox-media-server"
$ConfigDir = Join-Path $InstallDir "configs"
$DataDir = Join-Path $InstallDir "data"
$MountDir = "C:\torbox-media"
$EnvFile = Join-Path $InstallDir ".env"
$ComposeFile = Join-Path $InstallDir "docker-compose.yml"
$SetupCompleteFile = Join-Path $InstallDir ".setup_complete"

function Write-LogInfo ($Message) { Write-Host "[INFO] $Message" -ForegroundColor Green }
function Write-LogWarn ($Message) { Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-LogError ($Message) { Write-Host "[ERROR] $Message" -ForegroundColor Red }
function Write-LogStep ($Message) { Write-Host "[STEP] $Message" -ForegroundColor Blue }
function Write-LogSection ($Message) {
    Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "  $Message" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n" -ForegroundColor Cyan
}

function Invoke-PrintBanner {
    Write-Host "  ╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║           TorBox Media Server - All-in-One Setup            ║" -ForegroundColor Cyan
    Write-Host "  ║                                                             ║" -ForegroundColor Cyan
    Write-Host "  ║   Prowlarr · Byparr · Decypharr · Seerr                    ║" -ForegroundColor Cyan
    Write-Host "  ║   Radarr · Sonarr · rclone/WinFSP · Plex/Jellyfin            ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
}

function New-ApiKey {
    $bytes = New-Object Byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
    return -join ($bytes | ForEach-Object { $_.ToString("x2") })
}

function New-AdminPass {
    $bytes = New-Object Byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
    $pass = [Convert]::ToBase64String($bytes).Replace('/', '').Replace('+', '').Replace('=', '')
    if ($pass.Length -gt 32) { $pass = $pass.Substring(0, 32) }
    return $pass
}

function Get-MaskedKey ($Key) {
    if ($Key.Length -gt 4) {
        return "$($Key.Substring(0, 4))...$($Key.Substring($Key.Length - 4))"
    }
    return $Key
}

# Write a UTF-8 text file WITHOUT a byte-order mark. Windows PowerShell 5.1's
# `Set-Content -Encoding UTF8` prepends a BOM, which corrupts the first .env
# variable for Docker Compose and breaks *arr config.xml parsing.
function Write-TextFile ($Path, $Content) {
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

# Parse a KEY=value .env file into a hashtable. Used to preserve existing
# API keys / credentials across re-runs so integrations don't break.
function Read-EnvFile ($Path) {
    $result = @{}
    if (-not (Test-Path $Path)) { return $result }
    foreach ($line in (Get-Content -Path $Path)) {
        $trimmed = $line.Trim()
        if ($trimmed -eq "" -or $trimmed.StartsWith("#")) { continue }
        $idx = $trimmed.IndexOf("=")
        if ($idx -lt 1) { continue }
        $name = $trimmed.Substring(0, $idx).Trim()
        $value = $trimmed.Substring($idx + 1).Trim().Trim('"').Trim("'")
        $result[$name] = $value
    }
    return $result
}

$SvcOrder = @('decypharr', 'prowlarr', 'byparr', 'radarr', 'sonarr', 'seerr')
$SvcPorts = @{
    'decypharr' = 8282; 'prowlarr' = 9696; 'byparr' = 8191;
    'radarr' = 7878; 'sonarr' = 8989; 'seerr' = 5055
}
$SvcLabels = @{
    'decypharr' = 'Decypharr'; 'prowlarr' = 'Prowlarr'; 'byparr' = 'Byparr';
    'radarr' = 'Radarr'; 'sonarr' = 'Sonarr'; 'seerr' = 'Seerr'
}

function Invoke-PrintServiceUrls {
    foreach ($svc in $SvcOrder) {
        Write-Host "  $($SvcLabels[$svc])" -NoNewline
        Write-Host " http://localhost:$($SvcPorts[$svc])"
    }
    if ($global:MediaServer -eq 'plex') {
        Write-Host "  Plex http://localhost:32400/web"
    } else {
        Write-Host "  Jellyfin http://localhost:8096"
    }
}

function Test-Dependencies {
    Write-LogSection "System Checks"
    
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-LogWarn "Not running as Administrator. Creating the default mount directory (C:\torbox-media) or initializing system mounts may fail without elevated privileges."
    }

    $missing = @()
    if (-not (Get-Command "docker" -ErrorAction SilentlyContinue)) {
        $missing += "Docker Desktop"
    }
    if (-not (Get-Command "curl" -ErrorAction SilentlyContinue)) {
        $missing += "curl"
    }

    if ($missing.Count -gt 0) {
        Write-LogError "Missing required dependencies: $($missing -join ', ')"
        Write-LogError "Please install Docker Desktop and other tools manually on Windows."
        return $false
    }

    $dockerInfo = docker info 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-LogError "Docker daemon is not running or accessible. Please start Docker Desktop."
        return $false
    }
    Write-LogInfo "All dependencies satisfied."
    return $true
}

function Test-PortConflicts {
    $portsToCheck = @()
    foreach ($svc in $SvcOrder) { $portsToCheck += $SvcPorts[$svc] }
    if ($global:MediaServer -eq 'plex') { $portsToCheck += 32400 }
    elseif ($global:MediaServer -eq 'jellyfin') { $portsToCheck += 8096 }

    $conflicts = $false
    $netstatOutput = netstat -ano

    foreach ($port in $portsToCheck) {
        if ($netstatOutput -match ":$port\s+") {
            Write-LogWarn "Port $port is already in use."
            $conflicts = $true
        }
    }

    if ($conflicts) {
        Write-LogWarn "Some ports are in use. Services using those ports may fail to start."
        if ($NonInteractive) {
            Write-LogWarn "Non-interactive mode: continuing despite port conflicts."
        } else {
            $ans = Read-Host "Continue anyway? [Y/n]"
            if ($ans.ToLower() -eq 'n') {
                Write-LogError "Setup cancelled."
                return $false
            }
        }
    }
    return $true
}

function Invoke-CheckExistingInstallation {
    # Populated with values preserved from a prior install; empty otherwise.
    $global:ExistingEnv = @{}

    if (Test-Path $SetupCompleteFile) {
        Write-LogSection "Existing Installation Detected"
        Write-LogWarn "A previous installation was found at: $InstallDir"
        Write-Host ""
        Write-Host "  Re-running will regenerate Docker Compose and configs."
        Write-Host "  Your existing API keys will be PRESERVED to avoid breaking integrations."
        Write-Host ""

        if (-not $NonInteractive) {
            $rerun = Read-Host "Continue with re-configuration? [y/N]"
            if ($rerun.ToLower() -ne 'y') {
                Write-LogInfo "Setup cancelled. Your existing installation is unchanged."
                exit 0
            }
        }

        # Back up existing generated files before overwriting.
        $backupTs = Get-Date -Format "yyyyMMdd_HHmmss"
        foreach ($bf in @($EnvFile, $ComposeFile, "$ConfigDir\decypharr\config.json")) {
            if (Test-Path $bf) { Copy-Item -Path $bf -Destination "$bf.bak.$backupTs" -Force }
        }
        Write-LogInfo "Backed up existing config files (.bak.$backupTs)."

        $global:ExistingEnv = Read-EnvFile $EnvFile

        # Drop API keys that aren't valid 32-char hex so they get regenerated.
        foreach ($k in @('RADARR_API_KEY', 'SONARR_API_KEY', 'PROWLARR_API_KEY')) {
            if ($global:ExistingEnv.ContainsKey($k) -and $global:ExistingEnv[$k] -notmatch '^[0-9a-f]{32}$') {
                Write-LogWarn "Corrupted API key detected for $k. Will regenerate."
                $global:ExistingEnv.Remove($k)
            }
        }
        if ($global:ExistingEnv.ContainsKey('RADARR_API_KEY')) {
            Write-LogInfo "Existing API keys loaded and will be preserved."
        }
        Write-Host ""
    } elseif ((Test-Path $EnvFile) -and -not (Test-Path $SetupCompleteFile)) {
        # .env exists but setup never completed — a prior run was interrupted.
        Write-LogSection "Incomplete Installation Detected"
        Write-LogWarn "A previous setup was interrupted before completion."
        Write-LogWarn "Starting fresh (incomplete state will be cleaned up)."
        Write-Host ""
        Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Reuse a preserved value from a prior install, or fall back to a generator.
function Get-OrNew ($EnvKey, [scriptblock]$Generator) {
    if ($global:ExistingEnv -and $global:ExistingEnv.ContainsKey($EnvKey) -and -not [string]::IsNullOrEmpty($global:ExistingEnv[$EnvKey])) {
        return $global:ExistingEnv[$EnvKey]
    }
    return (& $Generator)
}

function Invoke-GatherConfig {
    Write-LogSection "Configuration"

    Write-Host "TorBox API Key" -ForegroundColor White
    Write-Host "  Get your API key from: https://torbox.app/settings"

    $TorboxApiKey = $env:TORBOX_API_KEY
    $existingTorboxKey = ""
    if ($global:ExistingEnv -and $global:ExistingEnv.ContainsKey('TORBOX_API_KEY')) {
        $existingTorboxKey = $global:ExistingEnv['TORBOX_API_KEY']
    }
    if ([string]::IsNullOrEmpty($TorboxApiKey)) {
        if (-not [string]::IsNullOrEmpty($existingTorboxKey)) {
            # Re-run: keep the saved key unless the user enters a new one.
            if ($NonInteractive) {
                $TorboxApiKey = $existingTorboxKey
                Write-LogInfo "Reusing existing TorBox API key."
            } else {
                Write-Host "  An existing TorBox API key was found ($(Get-MaskedKey $existingTorboxKey))."
                $secureStr = Read-Host -AsSecureString "  Enter a new TorBox API key (or press Enter to keep existing)"
                $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureStr)
                $TorboxApiKey = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
                [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
                if ([string]::IsNullOrEmpty($TorboxApiKey)) { $TorboxApiKey = $existingTorboxKey }
            }
        } elseif ($NonInteractive) {
            Write-LogError "Non-interactive mode requires TORBOX_API_KEY environment variable."
            return $false
        } else {
            while ([string]::IsNullOrEmpty($TorboxApiKey)) {
                $secureStr = Read-Host -AsSecureString "  Enter your TorBox API key"
                $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureStr)
                $TorboxApiKey = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
                [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
                if ([string]::IsNullOrEmpty($TorboxApiKey)) { Write-LogError "API key cannot be empty." }
            }
        }
    }

    if ($TorboxApiKey -notmatch "^[a-zA-Z0-9._-]+$") {
        Write-LogError "API key contains invalid characters."
        return $false
    }
    Write-LogInfo "API key received ($($TorboxApiKey.Length) characters)."
    $global:TorboxApiKey = $TorboxApiKey

    Write-Host "`nMedia Server" -ForegroundColor White
    $MediaServer = $env:TORBOX_MEDIA_SERVER
    if ([string]::IsNullOrEmpty($MediaServer)) {
        if ($NonInteractive) {
            $MediaServer = "plex"
            Write-LogInfo "Non-interactive mode: defaulting to Plex."
        } else {
            Write-Host "  1) Plex"
            Write-Host "  2) Jellyfin"
            while ($true) {
                $choice = Read-Host "  Choose your media server [1/2]"
                if ($choice -eq '1') { $MediaServer = "plex"; break }
                if ($choice -eq '2') { $MediaServer = "jellyfin"; break }
                Write-LogError "Please enter 1 or 2."
            }
        }
    }
    if ($MediaServer -notin @("plex", "jellyfin")) { $MediaServer = "plex" }
    $global:MediaServer = $MediaServer

    $PlexClaim = $env:TORBOX_PLEX_CLAIM
    if ($MediaServer -eq "plex" -and [string]::IsNullOrEmpty($PlexClaim) -and -not $NonInteractive) {
        Write-Host "`nPlex Claim Token (optional, for first-time setup)" -ForegroundColor White
        $PlexClaim = Read-Host "  Plex claim token"
    }
    $global:PlexClaim = $PlexClaim

    $global:MountDir = $env:TORBOX_MOUNT_DIR
    if ([string]::IsNullOrEmpty($global:MountDir)) { $global:MountDir = "C:\torbox-media" }
    if (-not $NonInteractive) {
        $customMount = Read-Host "`nMount Directory [$global:MountDir] (Press Enter to accept)"
        if (-not [string]::IsNullOrEmpty($customMount)) { $global:MountDir = $customMount }
    }

    $global:PUID = 1000
    $global:PGID = 1000
    $global:TZ = [System.TimeZoneInfo]::Local.Id

    # Preserve existing keys/credentials across re-runs; only generate when absent.
    $global:RadarrApiKey = Get-OrNew 'RADARR_API_KEY' { New-ApiKey }
    $global:SonarrApiKey = Get-OrNew 'SONARR_API_KEY' { New-ApiKey }
    $global:ProwlarrApiKey = Get-OrNew 'PROWLARR_API_KEY' { New-ApiKey }

    $global:RadarrAdminUser = Get-OrNew 'RADARR_ADMIN_USER' { "admin" }
    $global:RadarrAdminPass = Get-OrNew 'RADARR_ADMIN_PASS' { New-AdminPass }
    $global:SonarrAdminUser = Get-OrNew 'SONARR_ADMIN_USER' { "admin" }
    $global:SonarrAdminPass = Get-OrNew 'SONARR_ADMIN_PASS' { New-AdminPass }
    $global:ProwlarrAdminUser = Get-OrNew 'PROWLARR_ADMIN_USER' { "admin" }
    $global:ProwlarrAdminPass = Get-OrNew 'PROWLARR_ADMIN_PASS' { New-AdminPass }

    $global:DecypharrUser = Get-OrNew 'DECYPHARR_USER' { "torbox" }
    $global:DecypharrPass = Get-OrNew 'DECYPHARR_PASS' { New-AdminPass }
    return $true
}

function Invoke-CreateDirectories {
    Write-LogSection "Preparing Directories"
    $dirs = @(
        $InstallDir,
        "$ConfigDir\prowlarr",
        "$ConfigDir\radarr",
        "$ConfigDir\sonarr",
        "$ConfigDir\seerr",
        "$ConfigDir\decypharr",
        "$ConfigDir\$global:MediaServer",
        "$DataDir\media\movies",
        "$DataDir\media\tv",
        "$DataDir\downloads\radarr",
        "$DataDir\downloads\sonarr"
    )
    foreach ($dir in $dirs) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
    }
    if (-not (Test-Path $global:MountDir)) {
        New-Item -ItemType Directory -Force -Path $global:MountDir | Out-Null
    }
}

function Invoke-GenerateDecypharrConfig {
    Write-LogStep "Generating Decypharr config..."
    $configJson = @"
{
  "log_level": "info",
  "log_timestamps": true,
  "web_server": {
    "host": "0.0.0.0",
    "port": 8282
  },
  "rclone": {
    "vfs_cache_mode": "full",
    "vfs_cache_max_size": "20G",
    "vfs_read_chunk_size": "128M",
    "vfs_read_chunk_size_limit": "2G",
    "vfs_read_ahead": "256M",
    "dir_cache_time": "1m",
    "read_only": true,
    "allow_other": true,
    "uid": $($global:PUID),
    "gid": $($global:PGID),
    "umask": "022",
    "no_modtime": true,
    "poll_interval": "1m",
    "buffer_size": "256M"
  },
  "torbox": {
    "api_key": "$($global:TorboxApiKey)"
  },
  "webdav": {
    "enabled": true,
    "port": 8383,
    "users": [
      {
        "username": "$($global:DecypharrUser)",
        "password": "$($global:DecypharrPass)"
      }
    ]
  }
}
"@
    Write-TextFile -Path "$ConfigDir\decypharr\config.json" -Content $configJson
}

function Invoke-GenerateArrConfigs {
    Write-LogStep "Generating configs for *arr apps..."
    $arrs = @(
        @{ name = "radarr"; key = $global:RadarrApiKey },
        @{ name = "sonarr"; key = $global:SonarrApiKey },
        @{ name = "prowlarr"; key = $global:ProwlarrApiKey }
    )

    foreach ($arr in $arrs) {
        $name = $arr.name
        $key = $arr.key

        $configXml = @"
<Config>
  <LogLevel>info</LogLevel>
  <UpdateMechanism>Docker</UpdateMechanism>
  <AuthenticationMethod>Forms</AuthenticationMethod>
  <AuthenticationRequired>Enabled</AuthenticationRequired>
  <AnalyticsEnabled>False</AnalyticsEnabled>
  <ApiKey>$key</ApiKey>
</Config>
"@
        Write-TextFile -Path "$ConfigDir\$name\config.xml" -Content $configXml
    }
}

function Invoke-GenerateDockerCompose {
    Write-LogStep "Setting up Docker Compose..."

    $SourceFile = Join-Path $ScriptDir "docker-compose.yml"
    if (-not (Test-Path $SourceFile)) {
        Write-LogWarn "Source docker-compose.yml not found at: $SourceFile"
        Write-LogStep "Failed to set up Docker Compose."
        return
    }

    Copy-Item -Path $SourceFile -Destination $ComposeFile -Force
    Write-LogInfo "Copied docker-compose.yml to: $ComposeFile"

    $OverrideFile = Join-Path $InstallDir "docker-compose.override.yml"
    if (Test-Path $OverrideFile) { Remove-Item -Path $OverrideFile -Force }

    try {
        Set-Location $InstallDir
        docker compose config -q 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-LogInfo "Docker Compose file at $ComposeFile validated successfully."
        } else {
            Write-LogWarn "Docker Compose validation failed for $ComposeFile."
        }
    } catch {
        Write-LogWarn "Docker daemon not accessible or compose failed."
    }
}

function Invoke-GenerateEnvFile {
    Write-LogStep "Generating .env file..."

    $envContent = @"
# ============================================================================
#  TorBox Media Server - Environment Configuration
# ============================================================================

# User / System
PUID=$($global:PUID)
PGID=$($global:PGID)
TZ=$($global:TZ)

# Directories
INSTALL_DIR=$InstallDir
CONFIG_DIR=$ConfigDir
DATA_DIR=$DataDir
MOUNT_DIR=$global:MountDir

# Core Credentials
TORBOX_API_KEY=$global:TorboxApiKey
MEDIA_SERVER=$global:MediaServer

# Decypharr
DECYPHARR_USER=$global:DecypharrUser
DECYPHARR_PASS=$global:DecypharrPass

# Radarr
RADARR_API_KEY=$global:RadarrApiKey
RADARR_ADMIN_USER=$global:RadarrAdminUser
RADARR_ADMIN_PASS=$global:RadarrAdminPass

# Sonarr
SONARR_API_KEY=$global:SonarrApiKey
SONARR_ADMIN_USER=$global:SonarrAdminUser
SONARR_ADMIN_PASS=$global:SonarrAdminPass

# Prowlarr
PROWLARR_API_KEY=$global:ProwlarrApiKey
PROWLARR_ADMIN_USER=$global:ProwlarrAdminUser
PROWLARR_ADMIN_PASS=$global:ProwlarrAdminPass

COMPOSE_PROFILES=$global:MediaServer
"@

    if (-not [string]::IsNullOrEmpty($global:PlexClaim)) {
        $envContent += "`nPLEX_CLAIM=$global:PlexClaim"
    }

    Write-TextFile -Path $EnvFile -Content ($envContent + "`n")
}

function Invoke-StartServices {
    Write-LogSection "Starting Services"
    $startNow = 'y'
    if (-not $NonInteractive) {
        $startNow = Read-Host "Start all services now? [Y/n]"
    }

    if ($startNow.ToLower() -ne 'n') {
        Write-LogStep "Starting Docker containers..."
        Set-Location $InstallDir
        docker compose --env-file .env up -d --remove-orphans
        if ($LASTEXITCODE -ne 0) {
            Write-LogError "Failed to start services."
            return
        }
        Write-LogInfo "All services starting! Give them 30-60 seconds to initialize."
        $global:ServicesStarted = $true
    } else {
        Write-LogInfo "You can start services later manually via docker compose."
        $global:ServicesStarted = $false
    }
}
function Wait-ForService {
    param (
        [string]$Name,
        [string]$Url,
        [string]$ApiKey,
        [int]$MaxWait = 90,
        [string]$ApiVer = "v3"
    )
    $elapsed = 0
    $interval = 3

    while ($elapsed -lt $MaxWait) {
        try {
            $headers = @{}
            if ($ApiKey) { $headers["X-Api-Key"] = $ApiKey }
            $res = Invoke-RestMethod -Uri "$Url/api/$ApiVer/system/status" -Method Get -Headers $headers -ErrorAction Stop
            Write-LogInfo "$Name is ready. ($($elapsed)s)"
            return $true
        } catch {
            Write-Host -NoNewline "`r  Waiting for $Name... $($elapsed)s/$($MaxWait)s"
            Start-Sleep -Seconds $interval
            $elapsed += $interval
        }
    }
    Write-LogWarn "$Name did not become ready within $MaxWait seconds."
    return $false
}

function Invoke-ConfigureArrAuth {
    param (
        [string]$Name,
        [string]$Url,
        [string]$ApiKey,
        [string]$ApiVer = "v3"
    )
    try {
        $headers = @{ "X-Api-Key" = $ApiKey; "Content-Type" = "application/json" }
        $settingsUrl = if ($ApiVer -eq "v1") { "$Url/api/v1/config/host" } else { "$Url/api/v3/config/host" }

        $config = Invoke-RestMethod -Uri $settingsUrl -Method Get -Headers $headers -ErrorAction Stop

        $userVar = "$($Name)AdminUser"
        $passVar = "$($Name)AdminPass"
        $user = (Get-Variable -Name $userVar -Scope Global -ValueOnly -ErrorAction SilentlyContinue)
        $pass = (Get-Variable -Name $passVar -Scope Global -ValueOnly -ErrorAction SilentlyContinue)

        if ($user -and $pass) {
            $config.authenticationMethod = "forms"
            $config.authenticationRequired = "enabled"
            $config.username = $user
            $config.password = $pass

            Invoke-RestMethod -Uri $settingsUrl -Method Put -Headers $headers -Body ($config | ConvertTo-Json -Depth 10) -ErrorAction Stop | Out-Null
            Write-LogInfo "  $Name authentication configured (Forms)."
        }
    } catch {
        Write-LogWarn "  Failed to configure authentication for $Name."
    }
}

function Invoke-AddDefaultIndexer {
    try {
        $headers = @{ "X-Api-Key" = $global:ProwlarrApiKey; "Content-Type" = "application/json" }
        $url = "http://localhost:$($SvcPorts['prowlarr'])/api/v1/indexer"

        $indexers = Invoke-RestMethod -Uri $url -Method Get -Headers $headers -ErrorAction Stop
        $exists = $false
        foreach ($i in $indexers) {
            if ($i.name -eq "1337x") { $exists = $true; break }
        }

        if (-not $exists) {
            $body = @{
                enable = $true
                name = "1337x"
                implementation = "Cardigann"
                configContract = "CardigannSettings"
                protocol = "torrent"
                appProfileId = 1
                fields = @(
                    @{ name = "baseUrl"; value = "https://1337x.to/" },
                    @{ name = "indexerProxyAccessType"; value = "proxy" }
                )
            }
            Invoke-RestMethod -Uri $url -Method Post -Headers $headers -Body ($body | ConvertTo-Json -Depth 10) -ErrorAction Stop | Out-Null
            Write-LogInfo "  Added default indexer (1337x) to Prowlarr."
        }
    } catch {
        Write-LogWarn "  Failed to add default indexer to Prowlarr."
    }
}

function Invoke-ConfigureSeerr {
    Write-LogStep "Auto-configuring Seerr..."
    $seerrUrl = "http://localhost:$($SvcPorts['seerr'])"

    $elapsed = 0; $maxWait = 60; $interval = 3
    $ready = $false
    while ($elapsed -lt $maxWait) {
        try {
            Invoke-RestMethod -Uri "$seerrUrl/api/v1/status" -Method Get -ErrorAction Stop | Out-Null
            Write-LogInfo "Seerr is ready. ($($elapsed)s)"
            $ready = $true
            break
        } catch {
            Start-Sleep -Seconds $interval
            $elapsed += $interval
        }
    }

    if (-not $ready) {
        Write-LogWarn "Seerr did not become ready."
        return $false
    }

    try {
        $radarrProfiles = Invoke-RestMethod -Uri "http://localhost:$($SvcPorts['radarr'])/api/v3/qualityprofile" -Headers @{"X-Api-Key"=$global:RadarrApiKey}
        $radarrProfileId = if ($radarrProfiles.Count -gt 0) { $radarrProfiles[0].id } else { 1 }

        $sonarrProfiles = Invoke-RestMethod -Uri "http://localhost:$($SvcPorts['sonarr'])/api/v3/qualityprofile" -Headers @{"X-Api-Key"=$global:SonarrApiKey}
        $sonarrProfileId = if ($sonarrProfiles.Count -gt 0) { $sonarrProfiles[0].id } else { 1 }

        $radarrBody = @{
            name = "Radarr"
            hostname = "radarr"
            port = 7878
            apiKey = $global:RadarrApiKey
            useSsl = $false
            baseUrl = ""
            activeProfileId = $radarrProfileId
            activeProfileName = ""
            activeDirectory = "/data/media/movies"
            is4k = $false
            isDefault = $true
            syncEnabled = $true
            preventSearch = $false
        }
        Invoke-RestMethod -Uri "$seerrUrl/api/v1/settings/radarr" -Method Post -Body ($radarrBody | ConvertTo-Json -Depth 10) -ContentType "application/json" -ErrorAction Stop | Out-Null
        Write-LogInfo "  Radarr added to Seerr."

        $sonarrBody = @{
            name = "Sonarr"
            hostname = "sonarr"
            port = 8989
            apiKey = $global:SonarrApiKey
            useSsl = $false
            baseUrl = ""
            activeProfileId = $sonarrProfileId
            activeProfileName = ""
            activeDirectory = "/data/media/tv"
            activeLanguageProfileId = 1
            activeAnimeProfileId = $sonarrProfileId
            activeAnimeLanguageProfileId = 1
            activeAnimeDirectory = "/data/media/tv"
            is4k = $false
            isDefault = $true
            syncEnabled = $true
            preventSearch = $false
        }
        Invoke-RestMethod -Uri "$seerrUrl/api/v1/settings/sonarr" -Method Post -Body ($sonarrBody | ConvertTo-Json -Depth 10) -ContentType "application/json" -ErrorAction Stop | Out-Null
        Write-LogInfo "  Sonarr added to Seerr."

        return $true
    } catch {
        Write-LogWarn "  Failed to configure Seerr integrations."
        return $false
    }
}

function Invoke-ConfigurePlexLibraries {
    if ($global:MediaServer -ne "plex") { return $true }

    $plexUrl = "http://localhost:32400"
    $elapsed = 0; $maxWait = 60; $interval = 3
    $ready = $false

    while ($elapsed -lt $maxWait) {
        try {
            $status = Invoke-RestMethod -Uri "$plexUrl/identity" -Method Get -ErrorAction Stop
            if ($status) { $ready = $true; break }
        } catch {
            Start-Sleep -Seconds $interval
            $elapsed += $interval
        }
    }

    if (-not $ready) {
        Write-LogWarn "Plex did not become ready."
        return $false
    }

    try {
        $prefs = Invoke-RestMethod -Uri "$plexUrl/web/index.html" -Method Get -ErrorAction SilentlyContinue
        # Getting the token directly from local Plex is difficult without user login,
        # so this might not work perfectly. We'll skip complex library setup for Plex as it usually requires
        # a valid X-Plex-Token obtained after user claim/login which can be tricky to automate locally on windows without sed-ing Preferences.xml easily.
        # But we can try to find Preferences.xml
        $plexConfigDir = "$ConfigDir\plex\Library\Application Support\Plex Media Server"
        $prefsFile = "$plexConfigDir\Preferences.xml"
        $token = ""
        if (Test-Path $prefsFile) {
            $content = Get-Content $prefsFile -Raw
            if ($content -match 'PlexOnlineToken="([^"]+)"') {
                $token = $matches[1]
            }
        }

        if ($token) {
            # Check libraries
            $libs = Invoke-RestMethod -Uri "$plexUrl/library/sections" -Headers @{"X-Plex-Token"=$token} -ErrorAction SilentlyContinue
            # Creating libraries via API is complex, we will log it.
            Write-LogInfo "Plex Token found. Library creation via API is complex, please create them manually."
        } else {
            Write-LogWarn "Plex token not found. Please create libraries manually."
        }
        return $true
    } catch {
        Write-LogWarn "Failed to configure Plex libraries."
        return $false
    }
}

function Invoke-ConfigureArrService {
    param (
        [string]$Name,
        [string]$Url,
        [string]$ApiKey,
        [string]$Type,
        [int]$Port,
        [string]$RootPath,
        [hashtable]$NamingUpdates
    )

    try {
        $headers = @{ "X-Api-Key" = $ApiKey; "Content-Type" = "application/json" }

        # Add Download Client (Decypharr as qBittorrent)
        $clients = Invoke-RestMethod -Uri "$Url/api/v3/downloadclient" -Headers $headers -ErrorAction Stop
        $clientExists = $false
        foreach ($c in $clients) {
            if ($c.name -eq "Decypharr") { $clientExists = $true; break }
        }

        if (-not $clientExists) {
            # Decypharr presents itself as a qBittorrent mock. It identifies the
            # calling *arr via username=internal URL + password=API key, and routes
            # by category. These fields must match setup.sh for the integration to work.
            $internalUrl = "http://$($Type):$($Port)"
            if ($Type -eq "sonarr") {
                $catField = "tvCategory"; $catImportedField = "tvImportedCategory"
            } else {
                $catField = "movieCategory"; $catImportedField = "movieImportedCategory"
            }
            $body = @{
                enable = $true
                name = "Decypharr"
                implementation = "QBittorrent"
                configContract = "QBittorrentSettings"
                protocol = "torrent"
                priority = 1
                removeCompletedDownloads = $true
                removeFailedDownloads = $true
                fields = @(
                    @{ name = "host"; value = "decypharr" },
                    @{ name = "port"; value = 8282 },
                    @{ name = "useSsl"; value = $false },
                    @{ name = "username"; value = $internalUrl },
                    @{ name = "password"; value = $ApiKey },
                    @{ name = $catField; value = $Type },
                    @{ name = $catImportedField; value = "" },
                    @{ name = "initialState"; value = 0 },
                    @{ name = "sequentialOrder"; value = $false },
                    @{ name = "firstAndLastFirst"; value = $false }
                )
            }
            Invoke-RestMethod -Uri "$Url/api/v3/downloadclient?forceSave=true" -Method Post -Headers $headers -Body ($body | ConvertTo-Json -Depth 10) -ErrorAction Stop | Out-Null
            Write-LogInfo "  Decypharr download client added to $Name."
        }

        # Add Root Folder
        $folders = Invoke-RestMethod -Uri "$Url/api/v3/rootfolder" -Headers $headers -ErrorAction Stop
        $folderExists = $false
        foreach ($f in $folders) {
            if ($f.path -eq $RootPath) { $folderExists = $true; break }
        }

        if (-not $folderExists) {
            $body = @{ path = $RootPath }
            Invoke-RestMethod -Uri "$Url/api/v3/rootfolder" -Method Post -Headers $headers -Body ($body | ConvertTo-Json -Depth 10) -ErrorAction Stop | Out-Null
            Write-LogInfo "  Root folder $RootPath added to $Name."
        }

        # Update Media Management (Hardlinks disabled)
        $mm = Invoke-RestMethod -Uri "$Url/api/v3/config/mediamanagement" -Headers $headers -ErrorAction Stop
        $mm.copyUsingHardlinks = $false
        Invoke-RestMethod -Uri "$Url/api/v3/config/mediamanagement" -Method Put -Headers $headers -Body ($mm | ConvertTo-Json -Depth 10) -ErrorAction Stop | Out-Null

        # Update Naming
        $naming = Invoke-RestMethod -Uri "$Url/api/v3/config/naming" -Headers $headers -ErrorAction Stop
        foreach ($key in $NamingUpdates.Keys) {
            $naming.$key = $NamingUpdates[$key]
        }
        Invoke-RestMethod -Uri "$Url/api/v3/config/naming" -Method Put -Headers $headers -Body ($naming | ConvertTo-Json -Depth 10) -ErrorAction Stop | Out-Null
        Write-LogInfo "  Media management and naming configured for $Name."

    } catch {
        Write-LogWarn "  Failed to configure $Name."
    }
}

function Invoke-ConfigureArrs {
    Write-LogSection "Configuring Services via API"

    $radarrUrl = "http://localhost:$($SvcPorts['radarr'])"
    $sonarrUrl = "http://localhost:$($SvcPorts['sonarr'])"
    $prowlarrUrl = "http://localhost:$($SvcPorts['prowlarr'])"

    $radarrReady = Wait-ForService -Name "Radarr" -Url $radarrUrl -ApiKey $global:RadarrApiKey -MaxWait 90 -ApiVer "v3"
    $sonarrReady = Wait-ForService -Name "Sonarr" -Url $sonarrUrl -ApiKey $global:SonarrApiKey -MaxWait 90 -ApiVer "v3"
    $prowlarrReady = Wait-ForService -Name "Prowlarr" -Url $prowlarrUrl -ApiKey $global:ProwlarrApiKey -MaxWait 90 -ApiVer "v1"

    Start-Sleep -Seconds 3

    if ($radarrReady) {
        $radarrNaming = @{
            renameMovies = $true
            replaceIllegalCharacters = $true
            colonReplacementFormat = "dash"
            standardMovieFormat = "{Movie CleanTitle} ({Release Year}) [{Quality Full}]"
            movieFolderFormat = "{Movie CleanTitle} ({Release Year}) [imdbid-{ImdbId}]"
        }
        Invoke-ConfigureArrService -Name "Radarr" -Url $radarrUrl -ApiKey $global:RadarrApiKey -Type "radarr" -Port 7878 -RootPath "/data/media/movies" -NamingUpdates $radarrNaming
    }

    if ($sonarrReady) {
        $sonarrNaming = @{
            renameEpisodes = $true
            replaceIllegalCharacters = $true
            colonReplacementFormat = 4
            standardEpisodeFormat = "{Series TitleYear} - S{season:00}E{episode:00} - {Episode CleanTitle} [{Quality Full}]"
            dailyEpisodeFormat = "{Series TitleYear} - {Air-Date} - {Episode CleanTitle} [{Quality Full}]"
            animeEpisodeFormat = "{Series TitleYear} - S{season:00}E{episode:00} - {Episode CleanTitle} [{Quality Full}]"
            seasonFolderFormat = "Season {season:00}"
            seriesFolderFormat = "{Series TitleYear}"
        }
        Invoke-ConfigureArrService -Name "Sonarr" -Url $sonarrUrl -ApiKey $global:SonarrApiKey -Type "sonarr" -Port 8989 -RootPath "/data/media/tv" -NamingUpdates $sonarrNaming
    }

    if ($prowlarrReady) {
        Write-LogStep "Configuring Prowlarr..."
        try {
            $headers = @{ "X-Api-Key" = $global:ProwlarrApiKey; "Content-Type" = "application/json" }

            # Byparr proxy
            $proxyBody = @{
                name = "Byparr"
                implementation = "FlareSolverr"
                configContract = "FlareSolverrSettings"
                fields = @(
                    @{ name = "host"; value = "http://byparr:8191" },
                    @{ name = "requestTimeout"; value = 60 }
                )
                tags = @()
            }
            Invoke-RestMethod -Uri "$prowlarrUrl/api/v1/indexerProxy?forceSave=true" -Method Post -Headers $headers -Body ($proxyBody | ConvertTo-Json -Depth 10) -ErrorAction Stop | Out-Null
            Write-LogInfo "  Byparr proxy added."
        } catch { Write-LogWarn "  Failed to add Byparr proxy." }

        try {
            # Radarr app
            $radarrAppBody = @{
                name = "Radarr"
                implementation = "Radarr"
                configContract = "RadarrSettings"
                syncLevel = "fullSync"
                fields = @(
                    @{ name = "prowlarrUrl"; value = "http://prowlarr:9696" },
                    @{ name = "baseUrl"; value = "http://radarr:7878" },
                    @{ name = "apiKey"; value = $global:RadarrApiKey },
                    @{ name = "syncCategories"; value = @(2000, 2010, 2020, 2030, 2040, 2045, 2050, 2060, 2070, 2080) }
                )
                tags = @()
            }
            Invoke-RestMethod -Uri "$prowlarrUrl/api/v1/applications?forceSave=true" -Method Post -Headers $headers -Body ($radarrAppBody | ConvertTo-Json -Depth 10) -ErrorAction Stop | Out-Null
            Write-LogInfo "  Radarr app added to Prowlarr."
        } catch { Write-LogWarn "  Failed to add Radarr app." }

        try {
            # Sonarr app
            $sonarrAppBody = @{
                name = "Sonarr"
                implementation = "Sonarr"
                configContract = "SonarrSettings"
                syncLevel = "fullSync"
                fields = @(
                    @{ name = "prowlarrUrl"; value = "http://prowlarr:9696" },
                    @{ name = "baseUrl"; value = "http://sonarr:8989" },
                    @{ name = "apiKey"; value = $global:SonarrApiKey },
                    @{ name = "syncCategories"; value = @(5000, 5010, 5020, 5030, 5040, 5045, 5050, 5060, 5070, 5080) }
                )
                tags = @()
            }
            Invoke-RestMethod -Uri "$prowlarrUrl/api/v1/applications?forceSave=true" -Method Post -Headers $headers -Body ($sonarrAppBody | ConvertTo-Json -Depth 10) -ErrorAction Stop | Out-Null
            Write-LogInfo "  Sonarr app added to Prowlarr."
        } catch { Write-LogWarn "  Failed to add Sonarr app." }
    }

    Invoke-ConfigureSeerr
    Invoke-ConfigurePlexLibraries

    if ($prowlarrReady) { Invoke-AddDefaultIndexer }

    if ($radarrReady) { Invoke-ConfigureArrAuth -Name "Radarr" -Url $radarrUrl -ApiKey $global:RadarrApiKey }
    if ($sonarrReady) { Invoke-ConfigureArrAuth -Name "Sonarr" -Url $sonarrUrl -ApiKey $global:SonarrApiKey }
    if ($prowlarrReady) { Invoke-ConfigureArrAuth -Name "Prowlarr" -Url $prowlarrUrl -ApiKey $global:ProwlarrApiKey -ApiVer "v1" }

    Write-LogInfo "All auto-configuration steps completed."
}

function Invoke-PrintPostInstall {
    Write-LogSection "Installation Complete!"
    Write-LogInfo "Setup is finished! Please read the following instructions."

    Write-Host "`n━━━━ Service URLs ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor White
    Invoke-PrintServiceUrls

    Write-Host "`n━━━━ Auto-Generated Admin Credentials ━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor White
    Write-Host "  Radarr    Username: $($global:RadarrAdminUser)  Password: $($global:RadarrAdminPass)"
    Write-Host "  Sonarr    Username: $($global:SonarrAdminUser)  Password: $($global:SonarrAdminPass)"
    Write-Host "  Prowlarr  Username: $($global:ProwlarrAdminUser)  Password: $($global:ProwlarrAdminPass)"
    Write-Host "  Decypharr Username: $($global:DecypharrUser)  Password: $($global:DecypharrPass)"

    Write-Host "`n━━━━ Remaining Manual Steps ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor White
    Write-Host "1. Decypharr (do first) - Open http://localhost:8282"
    Write-Host "2. Prowlarr - Open http://localhost:9696"
    Write-Host "3. Radarr - Open http://localhost:7878"
    Write-Host "4. Sonarr - Open http://localhost:8989"
    if ($global:MediaServer -eq "plex") {
        Write-Host "5. Plex - Open http://localhost:32400/web"
    } else {
        Write-Host "5. Jellyfin - Open http://localhost:8096"
    }
    Write-Host "6. Seerr - Open http://localhost:5055"
}

function Main {
    foreach ($arg in $args) {
        switch ($arg) {
            "-y" { $script:NonInteractive = $true }
            "--yes" { $script:NonInteractive = $true }
            "--non-interactive" { $script:NonInteractive = $true }
            "-d" { $script:DryRun = $true }
            "--dry-run" { $script:DryRun = $true }
            "-h" {
                Write-Host "TorBox Media Server Setup v$Version"
                Write-Host "Usage: .\setup.ps1 [OPTIONS]"
                return
            }
            "--help" {
                Write-Host "TorBox Media Server Setup v$Version"
                Write-Host "Usage: .\setup.ps1 [OPTIONS]"
                return
            }
        }
    }

    Invoke-PrintBanner
    if (-not (Test-Dependencies)) { return }
    Invoke-CheckExistingInstallation
    if (-not (Invoke-GatherConfig)) { return }
    if (-not (Test-PortConflicts)) { return }

    if ($script:DryRun) {
        Write-LogSection "Dry Run - Preview of Actions"
        Write-LogInfo "Would create directories, generate configs, and start services."
        return
    }

    Invoke-CreateDirectories
    Invoke-GenerateDecypharrConfig
    Invoke-GenerateArrConfigs
    Invoke-GenerateEnvFile
    Invoke-GenerateDockerCompose
    Invoke-StartServices

    if ($global:ServicesStarted) {
        Invoke-ConfigureArrs
    }
    Invoke-PrintPostInstall
    New-Item -ItemType File -Path $SetupCompleteFile -Force | Out-Null
}

if ($MyInvocation.InvocationName -ne '.') {
    Main $args
}
