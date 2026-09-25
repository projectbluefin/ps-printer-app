"""Exercise the state volume and the advertisement identity of the launcher.

These are filesystem and process tests: they run the shipped scripts the way the
container service runs them, with the state volume and the application binary
redirected into a temporary tree. They say nothing about printing, about two
containers on one LAN, or about physical USB output; see
``docs/state-and-device-isolation.md`` for what is still unverified.
"""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
SCRIPTS = REPO / "scripts"
INSTANCE_SCRIPT = SCRIPTS / "instance-name.sh"
STATE_SCRIPT = SCRIPTS / "prepare-state.sh"
LAUNCHER = SCRIPTS / "start-server.sh"
ROCKCRAFT = REPO / "rockcraft.yaml"
APP_SOURCE = REPO / "ps-printer-app.c"

DEFAULT_INSTANCE = "ps-printer-app"

# The stub stands in for the application: it records the command line and the
# state environment the launcher handed it, then exits without serving.
STUB_APP = """#!/bin/sh
printf '%s\\n' "$@" > "$STUB_OUT_DIR/argv"
printf '%s\\n' "${STATE_DIR:-}" > "$STUB_OUT_DIR/state_dir"
printf '%s\\n' "${SPOOL_DIR:-}" > "$STUB_OUT_DIR/spool_dir"
printf '%s\\n' "${CUPS_SERVERROOT:-}" > "$STUB_OUT_DIR/cups_serverroot"
printf '%s\\n' "${PRINTER_APP_INSTANCE:-}" > "$STUB_OUT_DIR/instance"
exit 0
"""

# Variables the scripts own. Cleared before each run so a value left in the
# ambient environment cannot make a test pass for the wrong reason.
OWNED = ("PRINTER_APP_INSTANCE", "STATE_DIR", "STATE_FILE", "SPOOL_DIR",
         "USER_PPD_DIR", "CUPS_SERVERROOT", "PPD_PATHS", "BACKEND_DIR", "PORT")


def source(script, command, **overrides):
    """Source ``script`` and run ``command``, with the environment overridden."""
    env = dict(os.environ)
    for name in OWNED:
        env.pop(name, None)
    env.update({name: str(value) for name, value in overrides.items()})
    return subprocess.run(
        ["sh", "-ec", '. "$1"; ' + command, "sh", str(script)],
        env=env,
        text=True,
        capture_output=True,
    )


class TemporaryTreeTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.state = self.root / "var/lib/ps-printer-app"
        self.spool = self.root / "var/spool/ps-printer-app"
        self.backend = self.root / "usr/lib/ps-printer-app/backend"
        self.out = self.root / "out"
        self.bin = self.root / "bin"
        self.out.mkdir()
        self.bin.mkdir()
        self.backend.mkdir(parents=True)
        self.stub = self.bin / "ps-printer-app"
        self.stub.write_text(STUB_APP)
        self.stub.chmod(0o755)

    def launch(self, **env_overrides):
        """Run the real launcher against the stub application."""
        env = dict(os.environ)
        for name in OWNED:
            env.pop(name, None)
        pid_file = self.root / "avahi.pid"
        pid_file.write_text("1\n")
        env.update({
            "PATH": f"{self.bin}{os.pathsep}{env['PATH']}",
            "STUB_OUT_DIR": str(self.out),
            "AVAHI_PID_FILE": str(pid_file),
            "STATE_DIR": str(self.state),
            "SPOOL_DIR": str(self.spool),
            "BACKEND_DIR": str(self.backend),
        })
        env.update({name: str(value) for name, value in env_overrides.items()})
        return subprocess.run(
            ["sh", str(LAUNCHER)], env=env, text=True, capture_output=True
        )

    def argv(self):
        return (self.out / "argv").read_text().splitlines()

    def option(self, name):
        """The value the launcher passed as ``-o name=value``, if any."""
        argv = self.argv()
        prefix = f"{name}="
        for index, item in enumerate(argv):
            if item == "-o" and argv[index + 1].startswith(prefix):
                return argv[index + 1][len(prefix):]
        return None


class InstanceIdentityTest(TemporaryTreeTest):
    """The advertisement name is what stops two instances from colliding."""

    def resolve(self, instance=None):
        overrides = {} if instance is None else {"PRINTER_APP_INSTANCE": instance}
        result = source(
            INSTANCE_SCRIPT,
            'printf "%s\\n%s\\n" "$PRINTER_APP_INSTANCE" "$PRINTER_APP_SYSTEM_NAME"',
            **overrides,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.splitlines()

    def test_unset_instance_keeps_the_shipped_advertisement(self):
        instance, system_name = self.resolve()
        self.assertEqual(instance, DEFAULT_INSTANCE)
        # The default must stay the string compiled into the application, so an
        # existing single-instance deployment advertises exactly what it did.
        compiled = re.search(
            r'#define SYSTEM_NAME "([^"]+)"', APP_SOURCE.read_text()
        ).group(1)
        self.assertEqual(system_name, compiled)

    def test_instance_is_suffixed_into_the_advertisement(self):
        instance, system_name = self.resolve("lab-a")
        self.assertEqual(instance, "lab-a")
        self.assertEqual(system_name, "PostScript Printer Application (lab-a)")

    def test_two_instances_advertise_different_names(self):
        self.assertNotEqual(self.resolve("lab-a")[1], self.resolve("lab-b")[1])

    def test_identity_is_sanitized_into_a_dns_label(self):
        for raw, expected in (
            ("Lab A/2", "Lab-A-2"),
            ("a  b", "a-b"),
            ("-edge-", "edge"),
            ("café", "caf"),
            ("a.b.c", "a-b-c"),
        ):
            with self.subTest(raw=raw):
                self.assertEqual(self.resolve(raw)[0], expected)

    def test_identity_is_capped_so_the_advertised_name_stays_legal(self):
        # Avahi rejects a service instance name of 63 bytes or more, so the
        # composed name has to stay under that even for an absurd identity.
        instance, system_name = self.resolve("x" * 200)
        self.assertEqual(len(instance), 24)
        self.assertLess(len(system_name.encode()), 64)

    def test_identity_with_no_usable_character_is_refused(self):
        result = source(INSTANCE_SCRIPT, "true", PRINTER_APP_INSTANCE="///")
        self.assertEqual(result.returncode, 64)
        self.assertIn("PRINTER_APP_INSTANCE", result.stderr)


class PrepareStateTest(TemporaryTreeTest):
    """The state volume is the appliance's only writable root."""

    def prepare(self, command, **overrides):
        overrides.setdefault("STATE_DIR", str(self.state))
        overrides.setdefault("SPOOL_DIR", str(self.spool))
        overrides.setdefault("BACKEND_DIR", str(self.backend))
        return source(STATE_SCRIPT, command, **overrides)

    def test_layout_is_created_and_exported(self):
        result = self.prepare(
            'printf "%s\\n%s\\n%s\\n%s\\n" "$STATE_DIR" "$SPOOL_DIR" '
            '"$STATE_FILE" "$CUPS_SERVERROOT"'
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [
            str(self.state),
            str(self.spool),
            str(self.state / "ps-printer-app.state"),
            str(self.state / "cups"),
        ])
        self.assertTrue((self.state / "ppd").is_dir())
        self.assertTrue((self.state / "cups" / "ssl").is_dir())
        self.assertTrue(self.spool.is_dir())

    def test_paths_that_are_already_set_are_honoured(self):
        elsewhere = self.root / "elsewhere"
        result = self.prepare(
            'printf "%s\\n%s\\n" "$STATE_DIR" "$STATE_FILE"',
            STATE_DIR=str(elsewhere),
            STATE_FILE=str(elsewhere / "custom.state"),
        )
        self.assertEqual(result.stdout.splitlines(),
                         [str(elsewhere), str(elsewhere / "custom.state")])
        self.assertTrue((elsewhere / "ppd").is_dir())

    def test_snmp_conf_is_seeded_from_the_staged_backend_copy(self):
        (self.backend / "snmp.conf").write_text("Community public\n")
        self.prepare("true")
        self.assertEqual(
            (self.state / "cups" / "snmp.conf").read_text(), "Community public\n"
        )

    def test_a_configured_state_and_edited_snmp_conf_survive_a_restart(self):
        (self.backend / "snmp.conf").write_text("Community public\n")
        self.prepare("true")
        (self.state / "ps-printer-app.state").write_text("ConfiguredPrinters yes\n")
        (self.state / "cups" / "snmp.conf").write_text("# user override\n")

        # A second start, as a restart of the same container would do.
        self.prepare("true")

        self.assertEqual(
            (self.state / "ps-printer-app.state").read_text(),
            "ConfiguredPrinters yes\n",
        )
        self.assertEqual(
            (self.state / "cups" / "snmp.conf").read_text(), "# user override\n"
        )

    @unittest.skipIf(os.geteuid() == 0, "root can write any directory")
    def test_unwritable_volume_is_refused_with_the_fix(self):
        self.state.mkdir(parents=True)
        self.state.chmod(0o500)
        self.addCleanup(self.state.chmod, 0o700)
        result = self.prepare("true")
        self.assertEqual(result.returncode, 64)
        self.assertIn("cannot prepare the state volume", result.stderr)
        self.assertIn("chown", result.stderr)
        self.assertIn("docs/state-and-device-isolation.md", result.stderr)


class LauncherTest(TemporaryTreeTest):
    """What the launcher hands the application, and what it refuses to start."""

    def test_start_advertises_a_unique_name_and_the_given_port(self):
        result = self.launch(PORT="18081", PRINTER_APP_INSTANCE="lab-a")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.option("server-port"), "18081")
        self.assertEqual(
            self.option("system-name"), "PostScript Printer Application (lab-a)"
        )
        self.assertEqual((self.out / "instance").read_text().strip(), "lab-a")

    def test_start_keeps_the_default_advertisement_when_no_instance_is_set(self):
        result = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.option("system-name"), "PostScript Printer Application"
        )

    def test_start_without_a_port_does_not_pin_one(self):
        result = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNone(self.option("server-port"))

    def test_two_instances_get_separate_advertisements_and_ports(self):
        self.launch(PORT="18081", PRINTER_APP_INSTANCE="lab-a")
        first_name, first_port = self.option("system-name"), self.option("server-port")
        self.launch(PORT="18082", PRINTER_APP_INSTANCE="lab-b")
        second_name, second_port = self.option("system-name"), self.option("server-port")
        self.assertNotEqual(first_name, second_name)
        self.assertNotEqual(first_port, second_port)

    def test_state_volume_is_prepared_and_used_before_the_application_starts(self):
        result = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.out / "state_dir").read_text().strip(), str(self.state))
        self.assertEqual((self.out / "spool_dir").read_text().strip(), str(self.spool))
        self.assertTrue((self.state / "ppd").is_dir())
        # The log lives in the state volume, so two instances do not share one
        # log and the log survives the container.
        self.assertEqual(
            self.option("log-file"), str(self.state / "ps-printer-app.log")
        )

    def test_restart_reuses_the_configuration_left_in_the_volume(self):
        self.launch()
        (self.state / "ps-printer-app.state").write_text("ConfiguredPrinters yes\n")
        result = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            (self.state / "ps-printer-app.state").read_text(),
            "ConfiguredPrinters yes\n",
        )

    def test_a_port_that_is_not_a_number_is_refused_before_start(self):
        result = self.launch(PORT="not-a-port")
        self.assertEqual(result.returncode, 64)
        self.assertIn("PORT must be a valid number", result.stderr)
        self.assertFalse((self.out / "argv").exists())

    def test_a_port_outside_the_usable_range_is_refused(self):
        for port in ("0", "65536", "99999"):
            with self.subTest(port=port):
                result = self.launch(PORT=port)
                self.assertEqual(result.returncode, 64)
                self.assertIn("between 1 and 65535", result.stderr)
                self.assertFalse((self.out / "argv").exists())


class ImageContractTest(TemporaryTreeTest):
    """The image must ship what the launcher expects to find."""

    def setUp(self):
        super().setUp()
        self.rock = ROCKCRAFT.read_text()

    def test_image_stages_the_launcher_helpers(self):
        for line in (
            "instance-name.sh: /scripts/instance-name.sh",
            "prepare-state.sh: /scripts/prepare-state.sh",
            "start-server.sh: /scripts/start-server.sh",
        ):
            self.assertIn(line, self.rock)

    def test_image_runs_as_the_numeric_user_the_volume_is_chowned_to(self):
        self.assertRegex(self.rock, r"(?m)^run-user: _daemon_$")
        self.assertIn('chown 584792:584792 "$STATE_DIR/ppd"', self.rock)
        self.assertIn('chown 584792:584792 "$SPOOL_DIR"', self.rock)

    def test_image_creates_the_state_layout_the_launcher_expects(self):
        self.assertIn('mkdir -p "$STATE_DIR/ppd" "$STATE_DIR/cups/ssl"', self.rock)
        self.assertIn('mkdir -p "$SPOOL_DIR"', self.rock)

    def test_launcher_default_state_root_matches_the_image(self):
        # The default cannot be exercised at run time here: it points at the
        # real /var/lib path, which the test user must not create. Compare the
        # default the launcher declares with the path the image prepares
        # instead, which is the agreement that actually has to hold.
        default = re.search(
            r'^: "\$\{STATE_DIR:=([^}]+)\}"', STATE_SCRIPT.read_text(), re.M
        ).group(1)
        self.assertEqual(default, "/var/lib/ps-printer-app")
        self.assertIn(f'STATE_DIR="$CRAFT_PRIME{default}"', self.rock)


if __name__ == "__main__":
    unittest.main()
