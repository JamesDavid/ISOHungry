<#
.SYNOPSIS
  Attaches every connected USB optical drive into the WSL2 VM so containers see
  them as /dev/sr0, /dev/sr1, ...

.DESCRIPTION
  Run this after every reboot or `wsl --shutdown` - usbip attachments do not
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
$image     = 'isohungry:latest'

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
$state = (& $usbipdExe state | ConvertFrom-Json).Devices

# A drive that is already attached has left Windows entirely, so it no longer
# appears as a CDROM device here. Finding none is therefore normal when
# everything is already attached - not a reason to tell the user to plug a
# drive in.
$attached = @($state | Where-Object { $_.ClientIPAddress })
if ($cdroms.Count -eq 0) {
  if ($attached.Count -gt 0 -and -not $Detach) {
    Ok "$($attached.Count) device(s) already attached to WSL; nothing new to attach"
    foreach ($a in $attached) { Ok "  bus $($a.BusId)  $($a.Description)" }
    $devs = docker run --rm --privileged -v /dev:/dev --entrypoint sh $image -c "ls /dev/sr* 2>/dev/null"
    if ($devs) {
      Info "`nVisible to containers:"
      foreach ($d in ($devs -split "`n" | Where-Object { $_ -match '\S' })) { Ok $d.Trim() }
    }
    Write-Host ""
    exit 0
  }
  Die "No USB optical drives found. Plug one in. (Internal SATA drives cannot be forwarded into WSL2.)"
}

$targets = @()

foreach ($cd in $cdroms) {
  $parent = (Get-PnpDeviceProperty -InstanceId $cd.InstanceId -KeyName 'DEVPKEY_Device_Parent').Data
  $match  = $state | Where-Object { $_.InstanceId -eq $parent }
  if ($match) {
    $targets += [pscustomobject]@{ BusId = $match.BusId; Name = $cd.FriendlyName }
    Ok "$($cd.FriendlyName)  ->  bus $($match.BusId)"
  } else {
    Warn "$($cd.FriendlyName) - no matching USB device (built-in drive?), skipping"
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
# Bound state comes from the state JSON, not the text table: the table prints
# "Not shared" for unbound devices, and a naive -match 'Shared' matches that
# too, so every unbound drive looked bound and the attach then failed.
$needBind = @($targets | Where-Object {
  $d = $state | Where-Object BusId -eq $_.BusId
  -not $d.PersistedGuid
})

if ($needBind.Count -gt 0) {
  Info "`nBinding $($needBind.Count) drive(s) - accept the UAC prompt"
  # One elevation for all drives. Written to a script file rather than passed
  # inline: quoting a -Command string through Start-Process is fragile, and
  # $args is a reserved automatic variable that must not be assigned.
  $bindScript = Join-Path $env:TEMP 'isohungry-bind.ps1'
  $lines = @("`$ErrorActionPreference='Stop'", "try {")
  foreach ($t in $needBind) { $lines += "  & '$usbipdExe' bind --busid $($t.BusId)" }
  $lines += "  'OK' | Set-Content '$env:TEMP\isohungry-bind.log'"
  $lines += "} catch { `"ERR: `$(`$_.Exception.Message)`" | Set-Content '$env:TEMP\isohungry-bind.log' }"
  $lines -join "`n" | Set-Content $bindScript -Encoding UTF8

  Remove-Item "$env:TEMP\isohungry-bind.log" -ErrorAction SilentlyContinue
  $p = Start-Process powershell -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',$bindScript
      ) -Verb RunAs -Wait -PassThru
  $bindResult = if (Test-Path "$env:TEMP\isohungry-bind.log") {
                  Get-Content "$env:TEMP\isohungry-bind.log" -Raw
                } else { 'no result (UAC declined?)' }
  if ($p.ExitCode -ne 0 -or $bindResult -notmatch '^OK') {
    Die "Bind failed: $($bindResult.Trim())`nTry manually from an admin shell: usbipd bind --busid <id>"
  }
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

# --- verify -----------------------------------------------------------------
# USB enumeration after an attach is not instant, and is slower when a drive
# has just been reset. Poll rather than checking once: a premature failure here
# used to send people off to rebuild their kernel for no reason.
Info "`nVerifying"
$devs = ''
$deadline = (Get-Date).AddSeconds(45)
while ((Get-Date) -lt $deadline) {
  $devs = docker run --rm --privileged -v /dev:/dev --entrypoint sh $image -c "ls /dev/sr* 2>/dev/null"
  if (-not [string]::IsNullOrWhiteSpace($devs)) { break }
  Write-Host "  waiting for the kernel to enumerate..." -ForegroundColor DarkGray
  Start-Sleep -Seconds 5
}
if ([string]::IsNullOrWhiteSpace($devs)) {
  Die @"
No /dev/sr* appeared after 45s.
  - if this worked before, the USB stack may be wedged: 'wsl --shutdown',
    restart Docker Desktop, then re-run this script
  - if it has never worked, the custom kernel may not be active:
    docker run --rm --privileged alpine uname -r     # should end in '+'
"@
}
foreach ($d in ($devs -split "`n" | Where-Object { $_ -match '\S' })) { Ok $d.Trim() }

Write-Host "`nReady. Start ripping with:" -ForegroundColor Green
Write-Host "  docker compose up -d"
Write-Host "  docker compose logs -f"
Write-Host ""
