import tempfile
import unittest
from pathlib import Path

from phi_moded import detect


def make_sysfs(root: Path, connectors: dict[str, str], typec: dict | None = None) -> None:
    drm = root / "drm"
    drm.mkdir(parents=True)
    for name, status in connectors.items():
        d = drm / f"card0-{name}"
        d.mkdir()
        (d / "status").write_text(status + "\n")

    if typec:
        tc = root / "typec"
        tc.mkdir()
        for port, info in typec.items():
            p = tc / port
            p.mkdir()
            if info.get("data_role"):
                (p / "data_role").write_text(info["data_role"] + "\n")
            if info.get("dp_active") is not None:
                alt = p / "displayport"
                alt.mkdir()
                (alt / "active").write_text(str(info["dp_active"]) + "\n")


class DetectTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def state(self):
        return detect.read_state(self.root / "drm", self.root / "typec")

    def test_phone_alone_is_not_docked(self):
        make_sysfs(self.root, {"DSI-1": "connected", "DP-1": "disconnected"})
        s = self.state()
        self.assertFalse(s.docked)
        self.assertEqual(s.external_connectors, ())

    def test_external_connector_docks(self):
        make_sysfs(self.root, {"DSI-1": "connected", "DP-1": "connected"})
        s = self.state()
        self.assertTrue(s.docked)
        self.assertEqual([c.name for c in s.external_connectors], ["DP-1"])

    def test_internal_connector_never_counts(self):
        for internal in ("DSI-1", "eDP-1", "LVDS-1", "DPI-1"):
            with self.subTest(internal=internal):
                tmp = tempfile.TemporaryDirectory()
                try:
                    root = Path(tmp.name)
                    make_sysfs(root, {internal: "connected"})
                    s = detect.read_state(root / "drm", root / "typec")
                    self.assertFalse(s.docked)
                finally:
                    tmp.cleanup()

    def test_dp_altmode_alone_docks(self):
        # Hub negotiated DP but the connector has not reported yet.
        make_sysfs(self.root, {"DSI-1": "connected"},
                   {"port0": {"data_role": "[host] device", "dp_active": True}})
        s = self.state()
        self.assertTrue(s.dp_active)
        self.assertTrue(s.docked)
        self.assertIn("typec-dp", s.describe())

    def test_altmode_directory_with_mode_file(self):
        drm = self.root / "drm"
        drm.mkdir(parents=True)
        alt = self.root / "typec" / "port0" / "port0.0"
        alt.mkdir(parents=True)
        (alt / "mode").write_text("displayport\n")
        (alt / "active").write_text("1\n")
        s = self.state()
        self.assertTrue(s.dp_active)

    def test_unknown_altmode_is_none_not_false(self):
        make_sysfs(self.root, {"DSI-1": "connected"},
                   {"port0": {"data_role": "device"}})
        s = self.state()
        self.assertIsNone(s.typec[0].dp_active)
        self.assertFalse(s.dp_active)

    def test_missing_sysfs_is_survivable(self):
        s = detect.read_state(self.root / "nope", self.root / "also-nope")
        self.assertEqual(s.connectors, ())
        self.assertFalse(s.docked)
        self.assertEqual(s.describe(), "no external display")

    def test_unreadable_status_files_are_skipped(self):
        drm = self.root / "drm"
        (drm / "card0-DP-1").mkdir(parents=True)      # no status file
        good = drm / "card0-HDMI-A-1"
        good.mkdir()
        (good / "status").write_text("connected\n")
        s = self.state()
        self.assertEqual([c.name for c in s.connectors], ["HDMI-A-1"])


if __name__ == "__main__":
    unittest.main()
