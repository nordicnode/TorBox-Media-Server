<#
.SYNOPSIS
TorBox Media Server - Uninstall Script
Removes all containers, configs, and data on Windows.
#>

$NonInteractive = $false
foreach ($arg in $args) {
    if ($arg -eq "-y" -or $arg -eq "--yes" -or $arg -eq "--non-interactive") {
        $NonInteractive = $true
    }
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$InstallDir = Join-Path $ScriptDir "torbox-media-server"
$EnvFile = Join-Path $InstallDir ".env"
$ComposeFile = Join-Path $InstallDir "docker-compose.yml"

function Write-LogInfo ($Message) { Write-Host "[INFO] $Message" -ForegroundColor Green }
function Write-LogWarn ($Message) { Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-LogError ($Message) { Write-Host "[ERROR] $Message" -ForegroundColor Red }

# Safe variant of "$x.ToLower()" that handles $null/empty input without throwing.
# PowerShell's .ToLower() on $null raises a NullPointerException, which would
# abort the whole uninstall — leaving Docker network/images as orphans.
function Test-YesAnswer($Answer) {
    return (-not [string]::IsNullOrEmpty($Answer) -and $Answer.Trim().ToLower() -eq 'y')
}
function Test-NoAnswer($Answer) {
    return (-not [string]::IsNullOrEmpty($Answer) -and $Answer.Trim().ToLower() -eq 'n')
}

Write-Host "  ╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║           TorBox Media Server - Uninstall                   ║" -ForegroundColor Cyan
Write-Host "  ╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

if (-not (Test-Path $InstallDir)) {
    Write-LogError "Installation directory not found: $InstallDir"
    Write-LogError "Nothing to uninstall."
    exit 1
}

Write-Host "This will remove:" -ForegroundColor Yellow
Write-Host "  - All Docker containers and the media-network"
Write-Host "  - Installation directory: $InstallDir"
Write-Host "`nYour TorBox account and cloud-stored media are NOT affected.`n" -ForegroundColor Red

if (-not $NonInteractive) {
    $confirm = Read-Host "Are you sure you want to uninstall? [y/N]"
    if (-not (Test-YesAnswer $confirm)) {
        Write-LogInfo "Uninstall cancelled."
        exit 0
    }
}

# Capture image list BEFORE deleting the install dir — the image-removal step
# later checks for the compose file, which would already be gone by then.
$_capturedImages = @()
if (Test-Path $ComposeFile) {
    try {
        $_capturedImages = Select-String -Path $ComposeFile -Pattern '^\s*image:\s*(.+)$' |
            ForEach-Object { ($_.Matches.Groups[1].Value -replace '"', '' -replace "'", '').Trim() } |
            Where-Object { $_ }
    } catch {
        Write-LogWarn "Could not parse image list from docker-compose.yml: $($_.Exception.Message)"
    }
}

if (-not $NonInteractive) {
    $createBackup = Read-Host "Do you want to create a backup of your configuration before uninstalling? [Y/n]"
    if (-not (Test-NoAnswer $createBackup)) {
        Write-LogInfo "Creating configuration backup..."
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $backupDir = "$InstallDir\..\torbox_backup_$timestamp"
        if (Test-Path $InstallDir) {
            # Stop containers first to release file locks (SQLite DBs in configs/)
            if ((Test-Path $EnvFile) -and (Test-Path $ComposeFile)) {
                Push-Location $InstallDir
                try {
                    docker compose down --remove-orphans 2>&1 | Out-Null
                } finally {
                    Pop-Location
                }
            }
            # Only back up configs and .env — the data dir can be many GB and is
            # re-downloadable from TorBox; backing it up makes uninstall take hours.
            New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
            if (Test-Path $EnvFile) { Copy-Item -Path $EnvFile -Destination $backupDir -Force }
            if (Test-Path $ComposeFile) { Copy-Item -Path $ComposeFile -Destination $backupDir -Force }
            $configsSrc = Join-Path $InstallDir "configs"
            if (Test-Path $configsSrc) {
                Copy-Item -Path $configsSrc -Destination $backupDir -Recurse -Force
            }
            Write-LogInfo "Backup created at $backupDir"
        } else {
            Write-LogWarn "Nothing to backup."
        }
    }
}

Write-LogInfo "Stopping and removing Docker containers..."

$partialUninstall = $false

if ((Test-Path $EnvFile) -and (Test-Path $ComposeFile)) {
    Push-Location $InstallDir
    try {
        docker compose down --remove-orphans 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-LogWarn "Docker compose down failed. Attempting manual cleanup..."
            $partialUninstall = $true
            $svcs = @("decypharr", "prowlarr", "byparr", "radarr", "sonarr", "seerr", "plex", "jellyfin")
            foreach ($svc in $svcs) {
                docker rm -f $svc 2>&1 | Out-Null
                # Ignore non-zero exit — containers may already be gone.
            }
        }
    } finally {
        Pop-Location
    }
} else {
    Write-LogWarn "Missing .env or docker-compose.yml. Skipping compose down."
    $partialUninstall = $true
    $svcs = @("decypharr", "prowlarr", "byparr", "radarr", "sonarr", "seerr", "plex", "jellyfin")
    foreach ($svc in $svcs) {
        docker rm -f $svc 2>&1 | Out-Null
    }
}

$projectName = (Split-Path $InstallDir -Leaf).ToLower() -replace '[^a-z0-9_-]', ''
docker network rm "${projectName}_media-network" 2>&1 | Out-Null

if ($partialUninstall) {
    Write-LogWarn "Docker teardown had failures. Skipping local file deletion to preserve state."
    Write-LogInfo "Installation directory preserved: $InstallDir"
} else {
    Write-LogInfo "Removing installation directory..."
    # Anchor with [\\/] so we only match an exact trailing 'torbox-media-server'
    # segment, not 'old-torbox-media-server' or 'torbox-media-server-backup'.
    if ($InstallDir -match "[\\/]torbox-media-server$") {
        Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path $InstallDir)) {
            Write-LogInfo "Removed: $InstallDir"
        } else {
            Write-LogError "Failed to remove: $InstallDir (may be locked — stop Docker Desktop and retry)"
        }
    } else {
        Write-LogError "Installation directory path is invalid: $InstallDir"
        # Don't exit — fall through to image cleanup so we don't orphan images.
    }
}

if (-not $NonInteractive) {
    $removeImages = Read-Host "Remove Docker images to free ~5-8 GB of disk space? [y/N]"
} else {
    $removeImages = "n"
}

if (Test-YesAnswer $removeImages) {
    Write-LogInfo "Removing Docker images..."
    $removedCount = 0
    foreach ($img in $_capturedImages) {
        if (-not [string]::IsNullOrEmpty($img)) {
            docker rmi $img 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-LogInfo "  Removed: $img"
                $removedCount++
            }
        }
    }
    if ($removedCount -gt 0) {
        Write-LogInfo "Removed $removedCount Docker image(s)."
    } else {
        Write-LogWarn "No images were removed (they may have already been cleaned up)."
    }
} else {
    Write-LogInfo "Docker images kept. Remove them later with: docker rmi <image-name>"
}

Write-Host "`nUninstall complete." -ForegroundColor Green
Write-Host "Your TorBox account and cloud-stored media are unaffected."
Write-Host "To reinstall, run: .\setup.ps1"
