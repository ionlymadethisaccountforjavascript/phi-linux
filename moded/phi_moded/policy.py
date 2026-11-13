"""Mode decision logic.

Deliberately pure: no sysfs, no subprocesses, no clocks it does not receive as
an argument. Mode flapping is the failure users notice most (the screen
reconfigures while they walk past a dock), so this is the part that gets tested
hard.
"""

from __future__ import annotations

import json
import time
from dataclasses import dataclass
from enum import Enum
from pathlib import Path


class Mode(str, Enum):
    PHONE = "phone"
    DESKTOP = "desktop"


@dataclass(frozen=True)
class Override:
    """A user command that outranks hardware detection for a while.

    ``expires_at`` of None means it never expires, which is what you want when
    a user explicitly asks for desktop mode on a defective dock.
    """

    mode: Mode
    expires_at: float | None = None
    reason: str = "manual"

    def active(self, now: float) -> bool:
        return self.expires_at is None or now < self.expires_at

    def to_json(self) -> dict:
        return {"mode": self.mode.value, "expires_at": self.expires_at, "reason": self.reason}

    @classmethod
    def from_json(cls, data: dict) -> "Override":
        return cls(
            mode=Mode(str(data["mode"])),
            expires_at=data.get("expires_at"),
            reason=str(data.get("reason", "manual")),
        )

    @classmethod
    def load(cls, path: str | Path) -> "Override | None":
        try:
            raw = json.loads(Path(path).read_text(encoding="utf-8"))
        except (OSError, ValueError, KeyError):
            return None
        try:
            return cls.from_json(raw)
        except (KeyError, ValueError):
            return None

    def save(self, path: str | Path) -> None:
        p = Path(path)
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp = p.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.to_json()), encoding="utf-8")
        tmp.replace(p)


@dataclass(frozen=True)
class Decision:
    mode: Mode
    changed: bool
    reason: str


class Policy:
    """Debounced two-state machine with an override lane."""

    def __init__(self, debounce_enter: float, debounce_leave: float, mode: Mode = Mode.PHONE):
        self.debounce_enter = debounce_enter
        self.debounce_leave = debounce_leave
        self.mode = mode
        self._pending: Mode | None = None
        self._pending_since: float | None = None

    def _delay_for(self, target: Mode) -> float:
        return self.debounce_enter if target is Mode.DESKTOP else self.debounce_leave

    def prime(self, now: float, docked: bool, override: Override | None = None) -> Decision:
        """Set the initial mode without debouncing.

        At boot the hardware is already in whatever state it is in; making the
        user wait 3 seconds of "phone" before the desktop appears looks broken.
        """
        if override is not None and override.active(now):
            self.mode = override.mode
            return Decision(self.mode, True, f"override:{override.reason}")
        self.mode = Mode.DESKTOP if docked else Mode.PHONE
        return Decision(self.mode, True, "boot")

    def step(self, now: float, docked: bool, override: Override | None = None) -> Decision:
        # 1. an active override is instantaneous
        if override is not None and override.active(now):
            if self.mode is not override.mode:
                self.mode = override.mode
                self._pending = None
                self._pending_since = None
                return Decision(self.mode, True, f"override:{override.reason}")
            return Decision(self.mode, False, f"override:{override.reason}")

        desired = Mode.DESKTOP if docked else Mode.PHONE
        reason = "dock-detected" if docked else "dock-removed"

        # 2. already settled
        if desired is self.mode:
            self._pending = None
            self._pending_since = None
            return Decision(self.mode, False, "steady")

        # 3. candidate seen: start or continue the timer
        if self._pending is not desired or self._pending_since is None:
            self._pending = desired
            self._pending_since = now
            return Decision(self.mode, False, f"pending:{desired.value}")

        if now - self._pending_since >= self._delay_for(desired):
            self.mode = desired
            self._pending = None
            self._pending_since = None
            return Decision(self.mode, True, reason)

        return Decision(self.mode, False, f"pending:{desired.value}")


def make_override(mode: Mode, ttl: float | None, now: float | None = None) -> Override:
    if ttl is None:
        return Override(mode=mode, expires_at=None)
    return Override(mode=mode, expires_at=(now if now is not None else time.time()) + ttl)
