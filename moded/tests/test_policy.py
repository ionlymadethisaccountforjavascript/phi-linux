import json
import tempfile
import unittest
from pathlib import Path

from phi_moded.policy import Mode, Override, Policy, make_override


class DebounceTest(unittest.TestCase):
    def setUp(self):
        self.p = Policy(debounce_enter=1.5, debounce_leave=3.0)

    def test_no_switch_before_debounce(self):
        self.assertFalse(self.p.step(0.0, docked=True).changed)
        self.assertFalse(self.p.step(1.0, docked=True).changed)
        self.assertIs(self.p.mode, Mode.PHONE)

    def test_switch_after_debounce(self):
        self.p.step(0.0, docked=True)
        d = self.p.step(1.6, docked=True)
        self.assertTrue(d.changed)
        self.assertIs(d.mode, Mode.DESKTOP)
        self.assertEqual(d.reason, "dock-detected")

    def test_brief_connection_never_switches(self):
        """A cable bumped for under a second must not reconfigure the screen."""
        self.p.step(0.0, docked=True)
        self.p.step(0.4, docked=False)     # reset
        self.p.step(0.5, docked=True)      # timer restarts here
        self.assertFalse(self.p.step(1.9, docked=True).changed)
        self.assertIs(self.p.mode, Mode.PHONE)

    def test_leave_is_slower_than_enter(self):
        self.p.prime(0.0, docked=True)
        self.assertIs(self.p.mode, Mode.DESKTOP)
        self.assertFalse(self.p.step(0.0, docked=False).changed)
        self.assertFalse(self.p.step(2.0, docked=False).changed)
        self.assertTrue(self.p.step(3.1, docked=False).changed)

    def test_changed_only_fires_once(self):
        self.p.step(0.0, docked=True)
        self.assertTrue(self.p.step(2.0, docked=True).changed)
        self.assertFalse(self.p.step(4.0, docked=True).changed)
        self.assertFalse(self.p.step(6.0, docked=True).changed)

    def test_override_beats_pending_dock(self):
        self.p.prime(0.0, docked=False)
        pending = self.p.step(1.0, docked=True)
        self.assertEqual(pending.reason, "pending:desktop")
        # user docks and manually asks for phone mode before debounce ends
        ov = Override(mode=Mode.PHONE, expires_at=None, reason="reason:test")
        d = self.p.step(1.2, docked=True, override=ov)
        self.assertFalse(d.changed)
        self.assertIs(self.p.mode, Mode.PHONE)


class PrimeTest(unittest.TestCase):
    def test_prime_docked_goes_desktop_immediately(self):
        p = Policy(1.5, 3.0)
        d = p.prime(0.0, docked=True)
        self.assertIs(d.mode, Mode.DESKTOP)
        self.assertEqual(d.reason, "boot")

    def test_prime_respects_active_override(self):
        p = Policy(1.5, 3.0)
        ov = make_override(Mode.PHONE, None, now=0.0)
        d = p.prime(0.0, docked=True, override=ov)
        self.assertIs(d.mode, Mode.PHONE)
        self.assertTrue(d.reason.startswith("override:"))


class OverrideTest(unittest.TestCase):
    def test_override_is_instant(self):
        p = Policy(1.5, 3.0)
        p.prime(0.0, docked=False)
        ov = make_override(Mode.DESKTOP, None, now=10.0)
        d = p.step(10.0, docked=False, override=ov)
        self.assertTrue(d.changed)
        self.assertIs(d.mode, Mode.DESKTOP)

    def test_expired_override_falls_back_to_hardware(self):
        p = Policy(1.5, 3.0)
        p.prime(0.0, docked=True)                 # desktop
        ov = Override(mode=Mode.PHONE, expires_at=100.0)

        d = p.step(50.0, docked=True, override=ov)
        self.assertIs(d.mode, Mode.PHONE)         # override still active

        d = p.step(150.0, docked=True, override=ov)
        self.assertEqual(d.reason, "pending:desktop")   # hardware takes over

        d = p.step(160.0, docked=True, override=ov)
        self.assertTrue(d.changed)
        self.assertIs(d.mode, Mode.DESKTOP)

    def test_ttl_math(self):
        ov = make_override(Mode.DESKTOP, ttl=120, now=1000.0)
        self.assertEqual(ov.expires_at, 1120.0)
        self.assertTrue(ov.active(1119.0))
        self.assertFalse(ov.active(1120.0))

    def test_roundtrip_and_corrupt_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "ov.json"
            ov = make_override(Mode.DESKTOP, ttl=None)
            ov.save(path)
            loaded = Override.load(path)
            self.assertEqual(loaded.mode, Mode.DESKTOP)
            self.assertIsNone(loaded.expires_at)

            path.write_text("{not json")
            self.assertIsNone(Override.load(path))
            self.assertIsNone(Override.load(Path(tmp) / "missing.json"))

            path.write_text(json.dumps({"mode": "nonsense"}))
            self.assertIsNone(Override.load(path))


if __name__ == "__main__":
    unittest.main()
