"""Configuration for phi-moded."""

from __future__ import annotations

import tomllib
from dataclasses import dataclass, field
from pathlib import Path

DEFAULT_CONFIG_PATH = "/etc/phi/moded.toml"


class ConfigError(Exception):
    pass


@dataclass(frozen=True)
class PowerProfile:
    """What to ask of the platform in a given posture.

    Every field is optional: a VM or an early port will not have these knobs,
    and a missing knob must never stop a mode switch.
    """

    governor: str | None = None
    epp: str | None = None            # energy_performance_preference
    wifi_powersave: bool | None = None


@dataclass(frozen=True)
class Config:
    poll_interval: float = 2.0
    debounce_enter: float = 1.5
    debounce_leave: float = 3.0
    state_dir: str = "/run/phi"
    log_level: str = "info"

    phone_target: str = "phi-phone.target"
    desktop_target: str = "phi-desktop.target"

    enter_desktop_hooks: str = "/usr/lib/phi/moded/hooks/enter-desktop.d"
    leave_desktop_hooks: str = "/usr/lib/phi/moded/hooks/leave-desktop.d"

    phone_power: PowerProfile = field(default_factory=PowerProfile)
    desktop_power: PowerProfile = field(default_factory=PowerProfile)

    # sysfs roots, overridable so the daemon can be tested against a fixture
    drm_root: str = "/sys/class/drm"
    typec_root: str = "/sys/class/typec"
    cpufreq_root: str = "/sys/devices/system/cpu/cpufreq"
    wireless_root: str = "/sys/class/net"

    @property
    def override_path(self) -> Path:
        return Path(self.state_dir) / "mode-override.json"

    @property
    def state_path(self) -> Path:
        return Path(self.state_dir) / "mode-state.json"


def _power(data: dict, section: str) -> PowerProfile:
    raw = data.get("power", {}).get(section, {}) if data else {}
    return PowerProfile(
        governor=raw.get("governor"),
        epp=raw.get("epp"),
        wifi_powersave=raw.get("wifi_powersave"),
    )


def load(path: str | Path | None = None) -> Config:
    """Load config, falling back to defaults when the file is absent."""
    p = Path(path or DEFAULT_CONFIG_PATH)
    data: dict = {}
    if p.is_file():
        try:
            with p.open("rb") as fh:
                data = tomllib.load(fh)
        except tomllib.TOMLDecodeError as exc:
            raise ConfigError(f"{p}: {exc}") from exc

    moded = data.get("moded", {})
    targets = data.get("targets", {})
    hooks = data.get("hooks", {})

    cfg = Config(
        poll_interval=float(moded.get("poll_interval", 2.0)),
        debounce_enter=float(moded.get("debounce_enter", 1.5)),
        debounce_leave=float(moded.get("debounce_leave", 3.0)),
        state_dir=str(moded.get("state_dir", "/run/phi")),
        log_level=str(moded.get("log_level", "info")),
        phone_target=targets.get("phone", "phi-phone.target"),
        desktop_target=targets.get("desktop", "phi-desktop.target"),
        enter_desktop_hooks=hooks.get(
            "enter_desktop", "/usr/lib/phi/moded/hooks/enter-desktop.d"
        ),
        leave_desktop_hooks=hooks.get(
            "leave_desktop", "/usr/lib/phi/moded/hooks/leave-desktop.d"
        ),
        phone_power=_power(data, "phone"),
        desktop_power=_power(data, "desktop"),
    )

    if cfg.poll_interval < 0.25:
        raise ConfigError("moded.poll_interval must be >= 0.25s")
    if cfg.debounce_enter < 0 or cfg.debounce_leave < 0:
        raise ConfigError("debounce values must be >= 0")
    return cfg
