<#
.SYNOPSIS
  One-time Windows setup for AutoDVDBackup.

.DESCRIPTION
  Docker Desktop's WSL2 kernel ships without optical-drive support
  (CONFIG_BLK_DEV_SR and CONFIG_USB_STORAGE are both disabled), so no container
  can ever see a DVD drive. This script:

    1. builds a WSL2 kernel with those drivers enabled (inside a container)
    2. points %USERPROFILE%\.wslconfig at it, preserving any existing settings
    3. installs usbipd-win for USB passthrough
    4. restarts the WSL VM and verifies the drivers are live

  Safe to re-run: each step is skipped if already done. Use -Force to rebuild
  the kernel from scratch.

.PARAMETER Force
  Rebuild the kernel even if one is already present.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\setup-windows.ps1
#>
[CmdletBinding()]
param([switch]$Force)

$ErrorActionPreference = 'Stop'
$repo       = Split-Path $PSScriptRoot -Parent
$kernelDir  = Join-Path $env:USERPROFILE 'wsl-kernel'
$bzImage    = Join-Path $kernelDir 'bzImage'
$wslConfig  = Join-Path $env:USERPROFILE '.wslconfig'
$usbipdExe  = Join-Path $env:ProgramFiles 'usbipd-win\usbipd.exe'

function Info { param($m) Write-Host $m -ForegroundColor Cyan }
function Ok   { param($m) Write-Host "  $m" -ForegroundColor Green }
function Warn { param($m) Write-Host "  $m" -ForegroundColor Yellow }
function Die  { param($m) Write-Host $m -ForegroundColor Red; exit 1 }

Write-Host "`nAutoDVDBackup — Windows setup`n" -ForegroundColor White

# ---------------------------------------------------------------- 1. prereqs
Info "[1/5] Checking prerequisites"
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  Die "Docker not found. Install Docker Desktop with the WSL2 backend, then re-run."
}
docker version --format '{{.Server.Version}}' *> $null
if ($LASTEXITCODE -ne 0) { Die "Docker daemon not reachable. Start Docker Desktop, then re-run." }
Ok "Docker is running"

$dd = Get-Process 'Docker Desktop' -ErrorAction SilentlyContinue
if ($dd) { $script:DockerDesktopExe = $dd[0].Path } else {
  $script:DockerDesktopExe = Join-Path $env:ProgramFiles 'Docker\Docker\frontend\Docker Desktop.exe'
}

# ------------------------------------------------------------- 2. the kernel
Info "`n[2/5] Custom WSL2 kernel"
if ((Test-Path $bzImage) -and -not $Force) {
  Ok "Already built at $bzImage (use -Force to rebuild)"
} else {
  Warn "Building — this compiles Linux and takes roughly 10-30 minutes."
  New-Item -ItemType Directory -Force $kernelDir | Out-Null
  docker run --rm `
    -v "${kernelDir}:/out" `
    -v "$(Join-Path $repo 'kernel'):/build:ro" `
    debian:bookworm bash /build/build-wsl-kernel.sh
  if ($LASTEXITCODE -ne 0) { Die "Kernel build failed." }
  Ok "Built $bzImage"
}

# ----------------------------------------------------------- 3. wire .wslconfig
Info "`n[3/5] Pointing WSL at the kernel"
# WSL wants doubled backslashes in this file.
$kernelLine = "kernel=" + ($bzImage -replace '\\', '\\')

if (Test-Path $wslConfig) {
  $content = Get-Content $wslConfig -Raw
  if ($content -match [regex]::Escape($kernelLine)) {
    Ok ".wslconfig already correct"
  } else {
    Copy-Item $wslConfig "$wslConfig.bak" -Force
    Warn "Existing .wslconfig backed up to .wslconfig.bak"
    if ($content -match '(?m)^\s*kernel\s*=') {
      $content = $content -replace '(?m)^\s*kernel\s*=.*$', $kernelLine
    } elseif ($content -match '(?m)^\[wsl2\]') {
      $content = $content -replace '(?m)^\[wsl2\]', "[wsl2]`n$kernelLine"
    } else {
      $content = "[wsl2]`n$kernelLine`n`n$content"
    }
    Set-Content $wslConfig $content -Encoding ASCII
    Ok "Updated .wslconfig (existing settings preserved)"
    $script:NeedRestart = $true
  }
} else {
  @"
[wsl2]
# Custom kernel with optical-drive support. Delete this line to revert.
$kernelLine
"@ | Set-Content $wslConfig -Encoding ASCII
  Ok "Created .wslconfig"
  $script:NeedRestart = $true
}

# --------------------------------------------------------------- 4. usbipd
Info "`n[4/5] usbipd-win (USB passthrough)"
if (Test-Path $usbipdExe) {
  Ok "Already installed ($(& $usbipdExe --version 2>&1 | Select-Object -First 1))"
} else {
  Warn "Installing — accept the UAC prompt when it appears."
  winget install --id dorssel.usbipd-win --exact --accept-source-agreements --accept-package-agreements
  if (-not (Test-Path $usbipdExe)) {
    Die "usbipd-win did not install. Run manually: winget install --id dorssel.usbipd-win --exact"
  }
  Ok "Installed"
}

# ------------------------------------------------------- 5. restart + verify
Info "`n[5/5] Applying and verifying"
$running = docker run --rm --privileged alpine sh -c "zcat /proc/config.gz | grep -c '^CONFIG_BLK_DEV_SR=y'" 2>$null
if ($running -eq '1' -and -not $script:NeedRestart) {
  Ok "Custom kernel already active"
} else {
  Warn "Restarting the WSL VM (this stops Docker Desktop briefly)"
  Get-Process 'Docker Desktop' -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Seconds 3
  wsl --shutdown
  Start-Sleep -Seconds 6
  Start-Process $script:DockerDesktopExe | Out-Null
  Write-Host "  waiting for Docker to come back..." -NoNewline
  $deadline = (Get-Date).AddMinutes(5)
  while ((Get-Date) -lt $deadline) {
    docker version --format '{{.Server.Version}}' *> $null
    if ($LASTEXITCODE -eq 0) { break }
    Write-Host "." -NoNewline
    Start-Sleep -Seconds 8
  }
  Write-Host ""
  docker version --format '{{.Server.Version}}' *> $null
  if ($LASTEXITCODE -ne 0) { Die "Docker did not restart. Start Docker Desktop manually, then re-run." }
}

$check = docker run --rm --privileged alpine sh -c `
  "uname -r; zcat /proc/config.gz | grep -E '^CONFIG_(BLK_DEV_SR|USB_STORAGE)=y' | wc -l" 2>$null
$lines = $check -split "`n"
Ok "Kernel: $($lines[0].Trim())"
if ($lines[1].Trim() -eq '2') {
  Ok "Optical drivers enabled (BLK_DEV_SR + USB_STORAGE)"
} else {
  Die "Drivers missing. The custom kernel may not have loaded — check $wslConfig."
}

Info "`nBuilding the ripper image"
Push-Location $repo
docker compose build
Pop-Location

Write-Host "`nSetup complete.`n" -ForegroundColor Green
Write-Host "Next:" -ForegroundColor White
Write-Host "  1. Plug in your USB DVD drive(s)"
Write-Host "  2. .\scripts\attach-drives.ps1     # after every reboot"
Write-Host "  3. docker compose up -d"
Write-Host ""
Write-Host "  ISOs are written to .\out\" -ForegroundColor DarkGray
Write-Host ""
