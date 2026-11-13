import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

from phi_moded.main import main


def build_fixture(root: Path, docked: bool) -> None:
    drm = root / "drm"
    drm.mkdir(parents=True)
    (drm / "card0-DSI-1").mkdir()
    (drm / "card0-DSI-1" / "status").write_text("connected\n")
    (drm / "card0-DP-1").mkdir()
    (drm / "card0-DP-1" / "status").write_text("connected\n" if docked else "disconnected\n")
    (root / "typec").mkdir()


class CliTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.config = self.root / "moded.toml"
        self.config.write_text(
            "[moded]\n"
            "poll_interval = 0.25\n"
            "debounce_enter = 0.0\n"
            "debounce_leave = 0.0\n"
            "state_dir = \"/run/phi\"\n"
            "[targets]\n"
            "phone = \"phi-phone.target\"\n"
            "desktop = \"phi-desktop.target\"\n"
        )

    def tearDown(self):
        self.tmp.cleanup()

    def run_cli(self, *args):
        """Run the CLI quietly; returns (exit_code, stdout)."""
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(io.StringIO()):
            code = main([*args, "--config", str(self.config), "--simulate", str(self.root)])
        return code, buf.getvalue()

    def test_once_undocked_reports_phone(self):
        build_fixture(self.root, docked=False)
        code, out = self.run_cli("run", "--once", "--dry-run")
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out)["mode"], "phone")
        # --once prints JSON to stdout; assert by re-reading the state file
        state = json.loads((self.root / "run" / "mode-state.json").read_text())
        self.assertEqual(state["mode"], "phone")
        self.assertFalse(state["docked"])

    def test_once_docked_reports_desktop(self):
        build_fixture(self.root, docked=True)
        code, out = self.run_cli("run", "--once", "--dry-run")
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out)["detail"], "DP-1")
        state = json.loads((self.root / "run" / "mode-state.json").read_text())
        self.assertEqual(state["mode"], "desktop")
        self.assertIn("DP-1", state["detail"])

    def test_set_and_clear_override(self):
        build_fixture(self.root, docked=False)
        self.assertEqual(self.run_cli("set", "desktop", "--ttl", "60")[0], 0)
        ov = self.root / "run" / "mode-override.json"
        self.assertTrue(ov.is_file())
        self.assertEqual(json.loads(ov.read_text())["mode"], "desktop")

        self.assertEqual(self.run_cli("clear")[0], 0)
        self.assertFalse(ov.exists())

    def test_override_wins_over_hardware(self):
        build_fixture(self.root, docked=False)
        self.run_cli("set", "desktop")
        self.run_cli("run", "--once", "--dry-run")
        state = json.loads((self.root / "run" / "mode-state.json").read_text())
        self.assertEqual(state["mode"], "desktop")
        self.assertEqual(state["reason"], "override:manual")

    def test_status_exits_cleanly(self):
        build_fixture(self.root, docked=True)
        code, out = self.run_cli("status")
        self.assertEqual(code, 0)
        self.assertIn("docked", out)

    def test_bad_config_is_a_clean_error(self):
        self.config.write_text("[moded]\npoll_interval = 0.01\n")
        self.assertEqual(self.run_cli("status")[0], 2)


if __name__ == "__main__":
    unittest.main()
