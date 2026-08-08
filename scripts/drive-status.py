#!/usr/bin/env python3
"""
Report an optical drive's tray state without disturbing it.

Polling a drive is not free: a blocking open() of /dev/srN makes Linux's cdrom
driver close the tray so it can try to read (drivers default to autoclose=1).
A ripper that probes every few seconds therefore fights the person trying to
put a disc in — press eject, and the tray shuts again before you reach it.

Opening with O_NONBLOCK takes the ioctl-only path instead, which skips the
autoclose, so CDROM_DRIVE_STATUS can be asked safely.

Prints one of: open, empty, notready, disc, unknown
Exit status is 0 for "disc", 1 otherwise, so shell callers can branch either way.
"""
import fcntl
import os
import sys

CDROM_DRIVE_STATUS = 0x5326
STATES = {
    0: "unknown",     # CDS_NO_INFO
    1: "empty",       # CDS_NO_DISC
    2: "open",        # CDS_TRAY_OPEN
    3: "notready",    # CDS_DRIVE_NOT_READY  (spinning up, or mid-eject)
    4: "disc",        # CDS_DISC_OK
}


def drive_status(device):
    fd = None
    try:
        fd = os.open(device, os.O_RDONLY | os.O_NONBLOCK)
        return STATES.get(fcntl.ioctl(fd, CDROM_DRIVE_STATUS, 0), "unknown")
    except OSError:
        return "unknown"
    finally:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass


if __name__ == "__main__":
    state = drive_status(sys.argv[1] if len(sys.argv) > 1 else "/dev/sr0")
    print(state)
    sys.exit(0 if state == "disc" else 1)
