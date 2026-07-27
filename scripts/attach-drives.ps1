<#
.SYNOPSIS
  Attaches every connected USB optical drive into the WSL2 VM so containers see
  them as /dev/sr0, /dev/sr1, ...

.DESCRIPTION
  Run this after every reboot or `wsl --shutdown` — usbip attachments do not
  survive either. Binding persists; attaching does not.

  Drives are matched by USB instance ID rather than vendor/product ID, so two
  identical drives are never confused for one another.

  Note on the attach method: usbipd's own `attach --wsl` fails here because it
  insists on modprobe-ing vhci_hcd, which cannot work when the driver is built
  into the kernel (as it is in our custom build). We therefore drive the usbip
  client directly. It MUST run with --network host: the TCP socket backing the
  virtual USB port lives in the caller's network namespace, so if it ran in a
  normal container namespace the socket would die with the container and leave
  the device wedged in unkillable I/O.

.PARAMETER Detach
  Detach all optical drives and return them to Windows.

.EXAMPLE
  .\scripts\attach-drives.ps1
  .\scripts\attach-drives.ps1 -Detach
#>
[CmdletBinding()]
param([switch]$Detach)

$ErrorActionPreference = 'Stop'
$repo      = Split-Path $PSScriptRoot -Parent
$usbipdExe = Join-Path $env:ProgramFiles 'usbipd-win\usbipd.exe'
$image     = 'auto-dvd-backup:latest'

function Info { param($m) Write-Host $m -ForegroundColor Cyan }
function Ok   { param($m) Write-Host "  $m" -ForegroundColor Green }
function Warn { param($m) Write-Host "  $m" -ForegroundColor Yellow }
function Die  { param($m) Write-Host $m -ForegroundColor Red; exit 1 }

if (-not (Test-Path $usbipdExe)) { Die "usbipd-win not installed. Run scripts\setup-windows.ps1 first." }
docker version --format '{{.Server.Version}}' *> $null
if ($LASTEXITCODE -ne 0) { Die "Docker not running. Start Docker Desktop, then re-run." }

# --- find optical drives and map them to usbipd bus IDs ---------------------
Info "`nLooking for USB optical drives"

$cdroms = @(Get-PnpDevice -Class CDROM -ErrorAction SilentlyContinue |
            Where-Object { $_.Present -and $_.InstanceId -like 'USBSTOR*' })
if ($cdroms.Count -eq 0) {
  Die "No USB optical drives found. Plug one in. (Internal SATA drives cannot be forwarded into WSL2.)"
}

$state = (& $usbipdExe state | ConvertFrom-Json).Devices
$targets = @()

foreach ($cd in $cdroms) {
  $parent = (Get-PnpDeviceProperty -InstanceId $cd.InstanceId -KeyName 'DEVPKEY_Device_Parent').Data
  $match  = $state | Where-Object { $_.InstanceId -eq $parent }
  if ($match) {
    $targets += [pscustomobject]@{ BusId = $match.BusId; Name = $cd.FriendlyName }
    Ok "$($cd.FriendlyName)  ->  bus $($match.BusId)"
  } else {
    Warn "$($cd.FriendlyName) — no matching USB device (built-in drive?), skipping"
  }
}
if ($targets.Count -eq 0) { Die "No drives could be mapped to a USB bus ID." }

# --- detach mode ------------------------------------------------------------
if ($Detach) {
  Info "`nDetaching"
  foreach ($t in $targets) {
    & $usbipdExe detach --busid $t.BusId 2>&1 | Out-Null
    Ok "bus $($t.BusId) returned to Windows"
  }
  Write-Host ""
  exit 0
}

# --- bind (needs admin; one prompt for all drives) --------------------------
$needBind = @($targets | Where-Object {
  $line = & $usbipdExe list | Select-String "^$($_.BusId)\s"
  $line -notmatch 'Shared|Attached'
})

if ($needBind.Count -gt 0) {
  Info "`nBinding $($needBind.Count) drive(s) — accept the UAC prompt"
  $cmd = ($needBind | ForEach-Object { "bind --busid $($_.BusId)" }) -join '; & "' + $usbipdExe + '" '
  $args = "-NoProfile -Command `"& '$usbipdExe' " + (($needBind | ForEach-Object { "bind --busid $($_.BusId)" }) -join "; & '$usbipdExe' ") + "`""
  $p = Start-Process powershell -ArgumentList $args -Verb RunAs -Wait -PassThru
  if ($p.ExitCode -ne 0) { Die "Bind failed (exit $($p.ExitCode)). Try manually: usbipd bind --busid <id>" }
  foreach ($t in $needBind) { Ok "bound bus $($t.BusId)" }
} else {
  Ok "All drives already bound"
}

# --- ensure the image exists (it carries the usbip client) ------------------
docker image inspect $image *> $null
if ($LASTEXITCODE -ne 0) {
  Info "`nBuilding image (first run)"
  Push-Location $repo; docker compose build; Pop-Location
}

# --- attach -----------------------------------------------------------------
Info "`nAttaching into the WSL VM"
foreach ($t in $targets) {
  $out = docker run --rm --privileged --network host -v /dev:/dev `
           --entrypoint usbip $image attach -r host.docker.internal -b $t.BusId 2>&1
  if ($LASTEXITCODE -eq 0) {
    Ok "bus $($t.BusId) attached"
  } elseif ($out -match 'already used|busy') {
    Ok "bus $($t.BusId) already attached"
  } else {
    Warn "bus $($t.BusId) failed: $out"
  }
}

Start-Sleep -Seconds 3

# --- verify -----------------------------------------------------------------
Info "`nVerifying"
$devs = docker run --rm --privileged -v /dev:/dev --entrypoint sh $image -c "ls /dev/sr* 2>/dev/null"
if ([string]::IsNullOrWhiteSpace($devs)) {
  Die "No /dev/sr* appeared. Is the custom kernel active? Re-run scripts\setup-windows.ps1."
}
foreach ($d in ($devs -split "`n" | Where-Object { $_ -match '\S' })) { Ok $d.Trim() }

Write-Host "`nReady. Start ripping with:" -ForegroundColor Green
Write-Host "  docker compose up -d"
Write-Host "  docker compose logs -f"
Write-Host ""
