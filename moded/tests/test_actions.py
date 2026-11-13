import os
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path

from phi_moded.actions import RecordingRunner, apply_mode, apply_power
from phi_moded.config import Config, PowerProfile
from phi_moded.policy import Mode


class ActionsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.hooks = self.root / "hooks"
        self.hooks.mkdir()
        self.cfg = replace(
            Config(),
            enter_desktop_hooks=str(self.hooks / "enter"),
            leave_desktop_hooks=str(self.hooks / "leave"),
            cpufreq_root=str(self.root / "cpufreq"),
            wireless_root=str(self.root / "net"),
        )
        self.runner = RecordingRunner()

    def tearDown(self):
        self.tmp.cleanup()

    def test_isolates_desktop_target(self):
        result = apply_mode(self.cfg, Mode.DESKTOP, "test", self.runner)
        self.assertTrue(result.ok)
        self.assertEqual(self.runner.calls[0], ["systemctl", "isolate", "phi-desktop.target"])

    def test_isolates_phone_target(self):
        result = apply_mode(self.cfg, Mode.PHONE, "test", self.runner)
        self.assertTrue(result.ok)
        self.assertEqual(self.runner.calls[0], ["systemctl", "isolate", "phi-phone.target"])

    def test_target_failure_is_reported_and_stops(self):
        class Failing(RecordingRunner):
            def run(self, argv):
                super().run(argv)
                return 1
        result = apply_mode(self.cfg, Mode.DESKTOP, "test", Failing())
        self.assertFalse(result.ok)

    def test_hooks_run_in_order_with_env(self):
        d = self.hooks / "enter"
        d.mkdir()
        for name in ("20-second", "10-first"):
            p = d / name
            p.write_text("#!/bin/sh\nexit 0\n")
            p.chmod(0o755)
        (d / "not-executable").write_text("#!/bin/sh\n")   # must be skipped
        cfg = replace(self.cfg, desktop_power=PowerProfile())

        result = apply_mode(cfg, Mode.DESKTOP, "dock-detected", self.runner)
        self.assertEqual(result.hooks_run, ["10-first", "20-second"])
        hook_calls = [c for c in self.runner.calls if c[0] == "env"]
        self.assertEqual(hook_calls[0][1], "PHI_MODE=desktop")
        self.assertEqual(hook_calls[0][2], "PHI_REASON=dock-detected")

    def test_failing_hook_does_not_abort_switch(self):
        d = self.hooks / "enter"
        d.mkdir()
        bad = d / "10-bad"
        bad.write_text("#!/bin/sh\nexit 1\n")
        bad.chmod(0o755)

        class OneFails(RecordingRunner):
            def run(self, argv):
                super().run(argv)
                return 1 if argv[0] == "env" else 0

        result = apply_mode(replace(self.cfg, desktop_power=PowerProfile()),
                            Mode.DESKTOP, "test", OneFails())
        self.assertEqual(result.hooks_failed, ["10-bad"])
        self.assertTrue(result.ok)

    def test_power_knobs_written(self):
        policy0 = self.root / "cpufreq" / "policy0"
        policy0.mkdir(parents=True)
        (policy0 / "scaling_governor").write_text("schedutil\n")
        (policy0 / "energy_performance_preference").write_text("default\n")
        profile = PowerProfile(governor="powersave", epp="power")

        from phi_moded.actions import ActionResult
        result = ActionResult(mode=Mode.PHONE, target_ok=True)
        apply_power(self.cfg, profile, self.runner, result, dry_run=False)

        self.assertEqual((policy0 / "scaling_governor").read_text().strip(), "powersave")
        self.assertEqual((policy0 / "energy_performance_preference").read_text().strip(), "power")
        self.assertEqual(len(result.knobs_applied), 2)
        self.assertEqual(result.knobs_failed, [])

    def test_missing_knob_is_not_fatal(self):
        from phi_moded.actions import ActionResult
        profile = PowerProfile(governor="schedutil", epp="power")
        result = ActionResult(mode=Mode.PHONE, target_ok=True)
        apply_power(self.cfg, profile, self.runner, result, dry_run=False)
        self.assertTrue(result.ok)
        self.assertEqual(result.knobs_applied, [])

    def test_dry_run_changes_nothing(self):
        from phi_moded.actions import ActionResult
        policy0 = self.root / "cpufreq" / "policy0"
        policy0.mkdir(parents=True)
        gov = policy0 / "scaling_governor"
        gov.write_text("schedutil\n")

        result = ActionResult(mode=Mode.DESKTOP, target_ok=True)
        apply_power(self.cfg, PowerProfile(governor="performance"), self.runner, result, dry_run=True)
        self.assertEqual(gov.read_text().strip(), "schedutil")

    def test_wifi_powersave_skipped_without_iw(self):
        net = self.root / "net" / "wlan0"
        (net / "wireless").mkdir(parents=True)
        from phi_moded.actions import ActionResult
        result = ActionResult(mode=Mode.PHONE, target_ok=True)
        apply_power(self.cfg, PowerProfile(wifi_powersave=True), self.runner, result, dry_run=False)
        iw_calls = [c for c in self.runner.calls if c[0] == "iw"]
        # either iw is installed and called correctly, or the call is skipped
        for call in iw_calls:
            self.assertEqual(call[:4], ["iw", "dev", "wlan0", "set"])


if __name__ == "__main__":
    unittest.main()
