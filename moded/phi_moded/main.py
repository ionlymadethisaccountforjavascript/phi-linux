"""phi-moded entry point and CLI."""

from __future__ import annotations

import argparse
import json
import logging
import signal
import sys
import threading
import time
from dataclasses import replace
from pathlib import Path

from . import __version__, config as config_mod, detect, notify, policy
from .actions import SubprocessRunner, apply_mode
from .policy import Mode, Override, Policy

log = logging.getLogger("phi_moded")


def _configure_logging(level: str) -> None:
    logging.basicConfig(
        level=getattr(logging, level.upper(), logging.INFO),
        format="%(levelname)s %(name)s: %(message)s",
        stream=sys.stderr,
    )


def _load(args) -> config_mod.Config:
    cfg = config_mod.load(args.config)
    if args.simulate:
        sim = Path(args.simulate)
        cfg = replace(
            cfg,
            drm_root=str(sim / "drm"),
            typec_root=str(sim / "typec"),
            cpufreq_root=str(sim / "cpufreq"),
            wireless_root=str(sim / "net"),
            state_dir=str(sim / "run"),
        )
    if args.log_level:
        cfg = replace(cfg, log_level=args.log_level)
    return cfg


def _write_state(cfg: config_mod.Config, mode: Mode, reason: str, state: detect.DockState) -> None:
    payload = {
        "mode": mode.value,
        "reason": reason,
        "docked": state.docked,
        "detail": state.describe(),
        "updated": time.time(),
    }
    try:
        path = cfg.state_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(payload), encoding="utf-8")
    except OSError:
        log.debug("could not write state file")


def cmd_run(args) -> int:
    cfg = _load(args)
    _configure_logging(cfg.log_level)

    pol = Policy(cfg.debounce_enter, cfg.debounce_leave)
    runner = SubprocessRunner(dry_run=args.dry_run)
    stop = threading.Event()
    wake = threading.Event()

    def on_stop(signum, _frame):
        log.info("signal %s: stopping", signum)
        stop.set()

    def on_wake(signum, _frame):
        # udev triggers this on DRM changes so the switch does not wait out a
        # full poll interval.
        wake.set()

    signal.signal(signal.SIGTERM, on_stop)
    signal.signal(signal.SIGINT, on_stop)
    signal.signal(signal.SIGHUP, on_wake)

    log.info("phi-moded %s starting (poll=%.1fs, dry_run=%s)",
             __version__, cfg.poll_interval, args.dry_run)

    primed = False
    first = True
    while not stop.is_set():
        state = detect.read_state(cfg.drm_root, cfg.typec_root)
        override = Override.load(cfg.override_path)
        now = time.time()

        if not primed:
            decision = pol.prime(now, state.docked, override)
            primed = True
        else:
            decision = pol.step(now, state.docked, override)

        if decision.changed:
            log.info("mode -> %s (%s; %s)", decision.mode.value, decision.reason, state.describe())
            result = apply_mode(cfg, decision.mode, decision.reason, runner, args.dry_run)
            if not result.ok:
                log.error("mode switch incomplete; staying in %s", decision.mode.value)
            _write_state(cfg, decision.mode, decision.reason, state)
            notify.status(f"{decision.mode.value}: {state.describe()}")
        elif first:
            _write_state(cfg, decision.mode, decision.reason, state)
        first = False

        if args.once:
            print(json.dumps({
                "mode": decision.mode.value,
                "changed": decision.changed,
                "reason": decision.reason,
                "docked": state.docked,
                "detail": state.describe(),
            }))
            return 0

        notify.watchdog()
        wake.wait(cfg.poll_interval)
        wake.clear()

    log.info("phi-moded stopped in %s mode", pol.mode.value)
    return 0


def cmd_status(args) -> int:
    cfg = _load(args)
    state = detect.read_state(cfg.drm_root, cfg.typec_root)
    override = Override.load(cfg.override_path)
    recorded = None
    try:
        recorded = json.loads(cfg.state_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        pass

    print(f"phi-moded {__version__}")
    print(f"  docked       : {state.docked} ({state.describe()})")
    if recorded:
        age = time.time() - recorded.get("updated", 0)
        print(f"  mode         : {recorded.get('mode')} (reason {recorded.get('reason')}, {age:.0f}s ago)")
    else:
        print("  mode         : unknown (daemon has not written state)")
    if override and override.active(time.time()):
        exp = "never" if override.expires_at is None else f"{override.expires_at - time.time():.0f}s"
        print(f"  override     : {override.mode.value} (expires {exp})")
    else:
        print("  override     : none")
    for c in state.connectors:
        print(f"  connector    : {c.name:<10} {c.status:<12} {'external' if c.external else 'internal'}")
    for p in state.typec:
        print(f"  typec        : {p.name:<10} dp_active={p.dp_active} role={p.data_role}")
    return 0


def cmd_set(args) -> int:
    cfg = _load(args)
    mode = Mode(args.mode)
    override = policy.make_override(mode, args.ttl)
    override.save(cfg.override_path)
    print(f"override set: {mode.value}"
          + (f" for {args.ttl}s" if args.ttl else " (no expiry)"))
    print(f"  {cfg.override_path}")
    print("  the daemon applies it on its next poll; use SIGHUP to apply now")
    return 0


def cmd_clear(args) -> int:
    cfg = _load(args)
    path = cfg.override_path
    try:
        path.unlink()
        print(f"override cleared: {path}")
    except FileNotFoundError:
        print("no override set")
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="phi-moded", description="Phi Linux mode manager")
    p.add_argument("--version", action="version", version=f"phi-moded {__version__}")

    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--config", default=None, help="path to moded.toml")
    common.add_argument("--simulate", default=None,
                        help="directory with drm/ typec/ fixtures (testing)")
    common.add_argument("--log-level", default=None, choices=["debug", "info", "warning", "error"])

    sub = p.add_subparsers(dest="command", required=True)

    run = sub.add_parser("run", parents=[common], help="run the daemon")
    run.add_argument("--dry-run", action="store_true", help="log actions, change nothing")
    run.add_argument("--once", action="store_true", help="evaluate once, print JSON, exit")
    run.set_defaults(func=cmd_run)

    st = sub.add_parser("status", parents=[common], help="show current posture and hardware")
    st.set_defaults(func=cmd_status)

    se = sub.add_parser("set", parents=[common], help="force a mode")
    se.add_argument("mode", choices=[m.value for m in Mode])
    se.add_argument("--ttl", type=float, default=None, help="seconds until the override expires")
    se.set_defaults(func=cmd_set)

    cl = sub.add_parser("clear", parents=[common], help="clear a forced mode")
    cl.set_defaults(func=cmd_clear)

    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except config_mod.ConfigError as exc:
        print(f"config error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
