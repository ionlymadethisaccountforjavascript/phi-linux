"""Applying a mode to the running system.

The switch itself is boring by design: isolate a systemd target, run the
posture's hooks, nudge the platform's power knobs. Anything clever (shell
handoff, output layout) lives in the hooks so it can be fixed without
touching the daemon.
"""

from __future__ import annotations

import logging
import os
import shutil
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

from .config import Config, PowerProfile
from .policy import Mode

log = logging.getLogger("phi_moded.actions")


class Runner:
    def run(self, argv: list[str]) -> int:  # pragma: no cover - interface
        raise NotImplementedError


class SubprocessRunner(Runner):
    def __init__(self, logger: logging.Logger | None = None, dry_run: bool = False):
        self.log = logger or log
        self.dry_run = dry_run

    def run(self, argv: list[str]) -> int:
        if self.dry_run:
            self.log.info("[dry-run] %s", " ".join(argv))
            return 0
        self.log.info("run: %s", " ".join(argv))
        try:
            return subprocess.run(
                argv, capture_output=True, text=True, timeout=30, check=False
            ).returncode
        except (OSError, subprocess.TimeoutExpired) as exc:
            self.log.error("failed: %s: %s", " ".join(argv), exc)
            return 1


class RecordingRunner(Runner):
    """Test double."""

    def __init__(self) -> None:
        self.calls: list[list[str]] = []

    def run(self, argv: list[str]) -> int:
        self.calls.append(list(argv))
        return 0


@dataclass
class ActionResult:
    mode: Mode
    target_ok: bool
    hooks_run: list[str] = field(default_factory=list)
    hooks_failed: list[str] = field(default_factory=list)
    knobs_applied: list[str] = field(default_factory=list)
    knobs_failed: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return self.target_ok


def _write_knob(path: Path, value: str, result: ActionResult, dry_run: bool) -> None:
    label = f"{path}={value}"
    if dry_run:
        log.info("[dry-run] write %s", label)
        result.knobs_applied.append(label)
        return
    try:
        path.write_text(f"{value}\n", encoding="utf-8")
        result.knobs_applied.append(label)
    except OSError as exc:
        # A missing knob is normal on a young port or a VM. Never fatal.
        log.debug("knob unavailable %s: %s", label, exc)
        result.knobs_failed.append(label)


def apply_power(cfg: Config, profile: PowerProfile, runner: Runner,
                result: ActionResult, dry_run: bool) -> None:
    if profile.governor:
        for policy in sorted(Path(cfg.cpufreq_root).glob("policy*")):
            gov = policy / "scaling_governor"
            if gov.exists() or dry_run:
                _write_knob(gov, profile.governor, result, dry_run)
    if profile.epp:
        for policy in sorted(Path(cfg.cpufreq_root).glob("policy*")):
            epp = policy / "energy_performance_preference"
            if epp.exists() or dry_run:
                _write_knob(epp, profile.epp, result, dry_run)
    if profile.wifi_powersave is not None:
        for net in sorted(Path(cfg.wireless_root).glob("w*")):
            if not (net / "wireless").is_dir() and not (net / "phy80211").exists():
                continue
            if shutil.which("iw") is None:
                log.debug("iw not installed; skipping wifi power save")
                break
            runner.run(["iw", "dev", net.name, "set", "power_save",
                        "on" if profile.wifi_powersave else "off"])


def run_hooks(directory: str, mode: Mode, reason: str, runner: Runner,
              result: ActionResult) -> None:
    d = Path(directory)
    if not d.is_dir():
        return
    for script in sorted(p for p in d.iterdir() if p.is_file() and os.access(p, os.X_OK)):
        env_cmd = ["env", f"PHI_MODE={mode.value}", f"PHI_REASON={reason}", str(script)]
        if runner.run(env_cmd) == 0:
            result.hooks_run.append(script.name)
        else:
            result.hooks_failed.append(script.name)
            log.warning("hook failed: %s", script)


def apply_mode(cfg: Config, mode: Mode, reason: str, runner: Runner | None = None,
               dry_run: bool = False) -> ActionResult:
    runner = runner or SubprocessRunner(dry_run=dry_run)
    result = ActionResult(mode=mode, target_ok=True)

    target = cfg.desktop_target if mode is Mode.DESKTOP else cfg.phone_target
    if runner.run(["systemctl", "isolate", target]) != 0:
        result.target_ok = False
        log.error("could not isolate %s", target)
        return result

    hooks = cfg.enter_desktop_hooks if mode is Mode.DESKTOP else cfg.leave_desktop_hooks
    run_hooks(hooks, mode, reason, runner, result)

    profile = cfg.desktop_power if mode is Mode.DESKTOP else cfg.phone_power
    apply_power(cfg, profile, runner, result, dry_run)

    log.info(
        "mode=%s reason=%s hooks=%d/%d knobs=%d",
        mode.value, reason, len(result.hooks_run),
        len(result.hooks_run) + len(result.hooks_failed), len(result.knobs_applied),
    )
    return result
