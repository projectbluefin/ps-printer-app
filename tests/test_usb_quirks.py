"""Exercise the real seeder against the installed-file layouts it supports.

These are filesystem tests: they run the shipped ``scripts/seed-usb-quirks.sh``
exactly as the container entry point sources it, with both source directories
redirected into a temporary tree. They say nothing about OCI printing or about
physical USB output.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts/seed-usb-quirks.sh"

# The table the image builds today, plus a second one so the tests cover the
# wildcard rather than one hard-coded name.
CUPS_TABLE = "org.cups.usb-quirks"
VENDOR_TABLE = "net.sf.example.usb-quirks"
TABLES = (CUPS_TABLE, VENDOR_TABLE)


class SeedUSBQuirksTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.state = self.root / "var/lib/ps-printer-app"
        self.cups = self.root / "usr/share/cups"
        self.backend = self.root / "usr/lib/ps-printer-app/backend"
        (self.cups / "usb").mkdir(parents=True)
        self.backend.mkdir(parents=True)
        # The state directory is deliberately absent: the seeder creates it.

    def seed(self, **overrides):
        env = {
            **os.environ,
            "STATE_DIR": str(self.state),
            "CUPS_DATADIR": str(self.cups),
            "BACKEND_DIR": str(self.backend),
        }
        env.update({key: str(value) for key, value in overrides.items()})
        result = subprocess.run(
            ["sh", "-ec", '. "$1"; printf "%s" "${USB_QUIRK_DIR:-}"', "sh", str(SCRIPT)],
            env=env,
            check=True,
            text=True,
            capture_output=True,
        )
        # USB_QUIRK_DIR must name the state parent: CUPS appends "/usb".
        self.assertEqual(result.stdout, env["STATE_DIR"])
        return self.state / "usb"

    def assert_seeded(self, table, content):
        target = self.state / "usb" / table
        self.assertEqual(target.read_text(), content, f"{table} content")
        self.assertTrue(os.access(target, os.R_OK), f"{table} is not readable")

    def test_each_installed_layout_seeds_a_readable_table(self):
        for layout, source_dir in (("rockcraft", self.backend), ("fsdk", self.cups / "usb")):
            with self.subTest(layout=layout):
                for table in TABLES:
                    (source_dir / table).write_text("# upstream defaults\n")
                self.seed()
                for table in TABLES:
                    self.assert_seeded(table, "# upstream defaults\n")
                    (self.state / "usb" / table).unlink()
                    (source_dir / table).unlink()

    def test_tables_split_across_both_layouts_are_both_seeded(self):
        (self.cups / "usb" / CUPS_TABLE).write_text("# CUPS defaults\n")
        (self.backend / VENDOR_TABLE).write_text("# vendor defaults\n")
        self.seed()
        self.assert_seeded(CUPS_TABLE, "# CUPS defaults\n")
        self.assert_seeded(VENDOR_TABLE, "# vendor defaults\n")

    def test_installed_cups_data_path_takes_precedence(self):
        for table in TABLES:
            (self.cups / "usb" / table).write_text("# standard path\n")
            (self.backend / table).write_text("# relocated path\n")
        self.seed()
        for table in TABLES:
            self.assert_seeded(table, "# standard path\n")

    def test_only_quirk_tables_are_copied(self):
        (self.backend / CUPS_TABLE).write_text("# defaults\n")
        (self.backend / "snmp.conf").write_text("Community public\n")
        self.seed()
        self.assertEqual(sorted(path.name for path in (self.state / "usb").iterdir()),
                         [CUPS_TABLE])

    def test_restart_and_upgrade_preserve_edits_and_empty_tables(self):
        for table in TABLES:
            (self.backend / table).write_text("# original\n")
        self.seed()
        # An edit, and an intentionally emptied table, both count as overrides.
        for table, content in zip(TABLES, ("# user override\n", "")):
            (self.state / "usb" / table).write_text(content)
            (self.backend / table).write_text("# upgraded defaults\n")
        self.seed()
        self.assert_seeded(CUPS_TABLE, "# user override\n")
        self.assert_seeded(VENDOR_TABLE, "")

    def test_absent_defaults_leave_the_volume_untouched(self):
        self.seed()
        self.assertEqual(list((self.state / "usb").iterdir()), [])

    def test_a_table_shipped_by_a_later_image_is_seeded(self):
        self.seed()
        self.assertEqual(list((self.state / "usb").iterdir()), [])
        (self.backend / VENDOR_TABLE).write_text("# newly installed\n")
        self.seed()
        self.assert_seeded(VENDOR_TABLE, "# newly installed\n")

    def test_existing_symlinks_are_preserved_and_never_followed(self):
        target_dir = self.state / "usb"
        target_dir.mkdir(parents=True)
        external = self.root / "override"
        external.write_text("# user override\n")
        dangling = self.root / "missing"
        for table, link in zip(TABLES, (external, dangling)):
            (target_dir / table).symlink_to(link)
            (self.backend / table).write_text("# default\n")
        self.seed()
        self.assertEqual(external.read_text(), "# user override\n")
        for table in TABLES:
            self.assertTrue((target_dir / table).is_symlink(), f"{table} was replaced")
        self.assertFalse(dangling.exists(), "a dangling override was populated")


if __name__ == "__main__":
    unittest.main()
