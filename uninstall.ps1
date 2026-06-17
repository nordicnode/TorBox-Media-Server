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

Write-Host "  ╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║           TorBox Media Server - Uninstall                   ║" -ForegroundColor Cyan
Write-Host "  ╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

if (-not (Test-Path $InstallDir)) {
    Write-LogError "Installation directory not found: $InstallDir"
    Write-LogError "Nothing to uninstall."
    return
}

Write-Host "This will remove:" -ForegroundColor Yellow
Write-Host "  - All Docker containers and the media-network"
Write-Host "  - Installation directory: $InstallDir"
Write-Host "`nYour TorBox account and cloud-stored media are NOT affected.`n" -ForegroundColor Red

if (-not $NonInteractive) {
    $confirm = Read-Host "Are you sure you want to uninstall? [y/N]"
    if ($confirm.ToLower() -ne 'y') {
        Write-LogInfo "Uninstall cancelled."
        return
    }
}

if (-not $NonInteractive) {
    $createBackup = Read-Host "Do you want to create a backup of your configuration before uninstalling? [Y/n]"
    if ($createBackup.ToLower() -ne 'n') {
        Write-LogInfo "Creating configuration backup..."
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $backupDir = "$InstallDir\..\torbox_backup_$timestamp"
        if (Test-Path $InstallDir) {
            Copy-Item -Path $InstallDir -Destination $backupDir -Recurse -Force
            Write-LogInfo "Backup created at $backupDir"
        } else {
            Write-LogWarn "Nothing to backup."
        }
    }
}

Write-LogInfo "Stopping and removing Docker containers..."

$partialUninstall = $false

if ((Test-Path $EnvFile) -and (Test-Path $ComposeFile)) {
    Set-Location $InstallDir
    docker compose down --remove-orphans 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-LogWarn "Docker compose down failed. Attempting manual cleanup..."
        $partialUninstall = $true
        $svcs = @("decypharr", "prowlarr", "byparr", "radarr", "sonarr", "seerr", "plex", "jellyfin")
        foreach ($svc in $svcs) {
            docker rm -f $svc 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-LogWarn "Failed to remove container: $svc"
            }
        }
    }
} else {
    Write-LogWarn "Missing .env or docker-compose.yml. Skipping compose down."
    $partialUninstall = $true
    $svcs = @("decypharr", "prowlarr", "byparr", "radarr", "sonarr", "seerr", "plex", "jellyfin")
    foreach ($svc in $svcs) {
        docker rm -f $svc 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-LogWarn "Failed to remove container: $svc"
        }
    }
}

$projectName = (Split-Path $InstallDir -Leaf).ToLower() -replace '[^a-z0-9_-]', ''
docker network rm "${projectName}_media-network" 2>&1 | Out-Null

if ($partialUninstall) {
    Write-LogWarn "Docker teardown had failures. Skipping local file deletion to preserve state."
    Write-LogInfo "Installation directory preserved: $InstallDir"
} else {
    Write-LogInfo "Removing installation directory..."
    if ($InstallDir -match "torbox-media-server$") {
        Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path $InstallDir)) {
            Write-LogInfo "Removed: $InstallDir"
        } else {
            Write-LogError "Failed to remove: $InstallDir"
        }
    } else {
        Write-LogError "Installation directory path is invalid: $InstallDir"
        return
    }
}

if (-not $NonInteractive) {
    $removeImages = Read-Host "Remove Docker images to free ~5-8 GB of disk space? [y/N]"
} else {
    $removeImages = "n"
}

if ($removeImages.ToLower() -eq 'y') {
    Write-LogInfo "Removing Docker images..."
    if ((Test-Path $EnvFile) -and (Test-Path $ComposeFile)) {
        Set-Location $InstallDir
        docker compose down --rmi all --volumes --remove-orphans 2>&1 | Out-Null
        Write-LogInfo "Removed project images and volumes."
    } else {
        Write-LogInfo "Compose file not available. Skipping image removal."
    }
} else {
    Write-LogInfo "Docker images kept."
}

Write-Host "`nUninstall complete." -ForegroundColor Green
Write-Host "Your TorBox account and cloud-stored media are unaffected."
Write-Host "To reinstall, run: .\setup.ps1"
