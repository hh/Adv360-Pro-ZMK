#!/usr/bin/env python3
"""Send a zmk-hogp serial command (!help, !hogp, !boot, ...) to the Adv360.

Usage: kb-serial-cmd.py [!command] [left|right]   (default: !help, left)

Opens the chosen half's CDC-ACM console (the right half exposes one
from the game-hogp builds onward; product string "Adv360 Pro rt"),
asserts DTR/RTS, sends the command, and echoes up to 2s of response.
The console also streams debug logs, so expect noise around the reply.
Needs rw on the tty (dialout group or sudo).
"""
import fcntl, glob, os, select, struct, sys, termios, time

cmd = sys.argv[1] if len(sys.argv) > 1 else "!help"
side = sys.argv[2] if len(sys.argv) > 2 else "left"
if not cmd.startswith("!"):
    sys.exit("commands start with '!' (see zmk-hogp README)")

devs = glob.glob("/dev/serial/by-id/usb-Kinesis_Corporation_Adv360_Pro_*")
devs = [d for d in devs if ("_rt_" in d) == (side == "right")]
if not devs:
    sys.exit(f"no Adv360 {side}-half serial console found (connected via USB?)")

fd = os.open(devs[0], os.O_RDWR | os.O_NOCTTY)
attrs = termios.tcgetattr(fd)
attrs[0] = 0; attrs[1] = 0
attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
attrs[3] = 0
attrs[4] = attrs[5] = termios.B115200
attrs[6][termios.VMIN] = 0
attrs[6][termios.VTIME] = 1
termios.tcsetattr(fd, termios.TCSANOW, attrs)
for bit in (0x002, 0x004):  # TIOCM_DTR, TIOCM_RTS
    fcntl.ioctl(fd, 0x5416, struct.pack("I", bit))  # TIOCMBIS
time.sleep(0.2)

os.write(fd, cmd.encode() + b"\r\n")
deadline = time.time() + 2.0
buf = b""
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 0.2)
    if not r:
        continue
    try:
        chunk = os.read(fd, 4096)
    except OSError:  # device rebooted out from under us (e.g. !boot) — success
        break
    if chunk:
        buf += chunk
try:
    os.close(fd)
except OSError:
    pass
sys.stdout.write(buf.decode(errors="replace"))
