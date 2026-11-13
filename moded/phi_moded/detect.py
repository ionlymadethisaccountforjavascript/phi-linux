"""Hardware state discovery from sysfs.

Two independent signals say "a desktop is attached":

  * a DRM connector that is not the internal panel reports ``connected``
  * the USB-C port has negotiated DisplayPort alternate mode

They are independent on purpose. A USB-C hub can enumerate peripherals without
ever bringing up DP, and a device can drive DP without a second signal. Either
one is enough to consider the phone docked.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

# Connector names belonging to the phone's own display. Everything else is
# something a user plugged in.
INTERNAL_PREFIXES = ("DSI", "eDP", "LVDS", "DPI", "Writeback", "Virtual")


@dataclass(frozen=True)
class Connector:
    name: str
    status: str

    @property
    def connected(self) -> bool:
        return self.status == "connected"

    @property
    def external(self) -> bool:
        return not self.name.startswith(INTERNAL_PREFIXES)


@dataclass(frozen=True)
class TypecPort:
    name: str
    data_role: str | None = None
    dp_active: bool | None = None


@dataclass(frozen=True)
class DockState:
    connectors: tuple[Connector, ...] = ()
    typec: tuple[TypecPort, ...] = ()

    @property
    def external_connectors(self) -> tuple[Connector, ...]:
        return tuple(c for c in self.connectors if c.external and c.connected)

    @property
    def dp_active(self) -> bool:
        return any(p.dp_active for p in self.typec)

    @property
    def docked(self) -> bool:
        return bool(self.external_connectors) or self.dp_active

    def describe(self) -> str:
        bits = [c.name for c in self.external_connectors]
        if self.dp_active:
            bits.append("typec-dp")
        return ", ".join(bits) if bits else "no external display"


def _read(path: Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8", errors="replace").strip()
    except OSError:
        return None


def scan_drm(root: str | Path = "/sys/class/drm") -> tuple[Connector, ...]:
    """Read every DRM connector's status.

    Directory names look like ``card0-DP-1``; the connector name is the part
    after the first dash group, e.g. ``DP-1``.
    """
    base = Path(root)
    out: list[Connector] = []
    if not base.is_dir():
        return ()
    for entry in sorted(base.iterdir()):
        name = entry.name
        if not name.startswith("card") or "-" not in name:
            continue
        connector = name.split("-", 1)[1]
        status = _read(entry / "status")
        if status is None:
            continue
        out.append(Connector(name=connector, status=status))
    return tuple(out)


def scan_typec(root: str | Path = "/sys/class/typec") -> tuple[TypecPort, ...]:
    """Read USB-C data role and DisplayPort altmode state.

    Altmode directories appear as ``port0/port0.0`` with a ``mode`` file, or as
    ``port0/displayport`` carrying ``active``. Both layouts exist across kernel
    versions, so accept either and report ``dp_active=None`` when unknown
    rather than guessing False.
    """
    base = Path(root)
    out: list[TypecPort] = []
    if not base.is_dir():
        return ()

    for port_dir in sorted(base.glob("port*")):
        if not port_dir.is_dir():
            continue
        data_role = _read(port_dir / "data_role")
        dp: bool | None = None

        for candidate in port_dir.rglob("*"):
            if not candidate.is_dir():
                continue
            label = candidate.name.lower()
            is_dp = "displayport" in label
            if not is_dp and (candidate / "mode").is_file():
                is_dp = "displayport" in (_read(candidate / "mode") or "").lower()
            if not is_dp:
                continue
            raw = _read(candidate / "active")
            if raw is None:
                continue
            dp = raw.strip().lower() in {"1", "yes", "true", "active"}
            break

        out.append(TypecPort(name=port_dir.name, data_role=data_role, dp_active=dp))
    return tuple(out)


def read_state(
    drm_root: str | Path = "/sys/class/drm",
    typec_root: str | Path = "/sys/class/typec",
) -> DockState:
    return DockState(connectors=scan_drm(drm_root), typec=scan_typec(typec_root))
