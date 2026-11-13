"""Minimal sd_notify so systemd knows the daemon is alive.

Implemented in ~20 lines instead of pulling in a dependency: the protocol is a
datagram to $NOTIFY_SOCKET, and this keeps the package stdlib-only so it can
ship in a minimal rootfs.
"""

from __future__ import annotations

import os
import socket


def notify(message: str) -> bool:
    addr = os.environ.get("NOTIFY_SOCKET")
    if not addr:
        return False
    if addr.startswith("@"):
        addr = "\0" + addr[1:]
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as sock:
            sock.connect(addr)
            sock.sendall(message.encode("utf-8"))
        return True
    except OSError:
        return False


def ready() -> bool:
    return notify("READY=1")


def watchdog() -> bool:
    return notify("WATCHDOG=1")


def status(text: str) -> bool:
    return notify(f"STATUS={text}")
