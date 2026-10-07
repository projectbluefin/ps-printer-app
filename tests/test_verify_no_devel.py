"""Exercise the ``just verify-no-devel`` image guard against crafted root filesystems.

``just verify`` only ever runs this guard on a clean image, so nothing proved that
it rejects the content it exists to keep out. These tests run the real recipe from
the Justfile with a ``podman`` stub on PATH whose ``export`` streams a tar built
here, then require a refusal naming the offending path for every devel pattern
the recipe lists (headers, static and libtool archives, pkg-config and CMake
directories), acceptance for clean trees and for license notices, a failure when
the export fails part-way, and cleanup of the container and the extraction
directory.

They need ``just`` and run without an image or a container runtime.
"""
import io
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
JUSTFILE = REPO / "Justfile"
IMAGE = "registry.invalid/ps-printer-app:under-test"
CONTAINER = "ctr-under-test"

PODMAN_STUB = """#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$PODMAN_LOG"
case "$1" in
  create) printf '%s\\n' "$PODMAN_CONTAINER" ;;
  export)
    cat "$PODMAN_EXPORT_TAR"
    if [[ -n "${PODMAN_EXPORT_FAIL:-}" ]]; then
      echo "stub: export failed" >&2
      exit 125
    fi
    ;;
  rm) printf '%s\\n' "$2" ;;
  *) echo "stub: unexpected podman $1" >&2; exit 99 ;;
esac
"""

BASELINE = ["usr/bin/ps-printer-app", "usr/lib/libcups.so.2", "etc/cups/snmp.conf"]


def build_tar(path, files=(), dirs=()):
    with tarfile.open(path, "w") as archive:
        for name in dirs:
            info = tarfile.TarInfo(name)
            info.type = tarfile.DIRTYPE
            info.mode = 0o755
            archive.addfile(info)
        for name in files:
            data = b"fixture\n"
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mode = 0o644
            archive.addfile(info, io.BytesIO(data))


@unittest.skipUnless(shutil.which("just"), "just is not installed")
class VerifyNoDevelTest(unittest.TestCase):
    def setUp(self):
        self.work = Path(tempfile.mkdtemp(prefix="verify-no-devel-"))
        self.addCleanup(shutil.rmtree, self.work, ignore_errors=True)
        self.bin = self.work / "bin"
        self.bin.mkdir()
        podman = self.bin / "podman"
        podman.write_text(PODMAN_STUB)
        podman.chmod(0o755)
        self.recipe_tmp = self.work / "recipe-tmp"
        self.recipe_tmp.mkdir()
        self.log = self.work / "podman.log"
        self.tar = self.work / "rootfs.tar"

    def verify(self, files=(), dirs=(), export_fail=False):
        build_tar(self.tar, files=[*BASELINE, *files], dirs=dirs)
        env = {
            **os.environ,
            "PATH": f"{self.bin}{os.pathsep}{os.environ.get('PATH', '')}",
            "IMAGE_REF": IMAGE,
            "PODMAN_LOG": str(self.log),
            "PODMAN_CONTAINER": CONTAINER,
            "PODMAN_EXPORT_TAR": str(self.tar),
            "TMPDIR": str(self.recipe_tmp),
        }
        env.pop("PODMAN_EXPORT_FAIL", None)
        if export_fail:
            env["PODMAN_EXPORT_FAIL"] = "1"
        return subprocess.run(
            ["just", "--justfile", str(JUSTFILE), "verify-no-devel"],
            cwd=REPO,
            env=env,
            text=True,
            capture_output=True,
        )

    def assert_refused(self, result, offending):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"devel content in {IMAGE}: ./{offending}", result.stderr)
        self.assertNotIn("OK:", result.stdout)

    def assert_cleaned_up(self):
        self.assertEqual(
            self.log.read_text().splitlines(),
            [f"create {IMAGE} /none", f"export {CONTAINER}", f"rm {CONTAINER}"],
        )
        self.assertEqual(sorted(p.name for p in self.recipe_tmp.iterdir() if p.name.startswith("tmp.")), [])

    def test_a_runtime_only_tree_passes(self):
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"OK: {IMAGE} carries no devel content", result.stdout)
        self.assert_cleaned_up()

    def test_headers_are_refused(self):
        result = self.verify(files=["usr/include/cups/cups.h"])
        self.assert_refused(result, "usr/include")
        self.assert_cleaned_up()

    def test_an_empty_include_directory_is_refused(self):
        self.assert_refused(self.verify(dirs=["usr/include"]), "usr/include")

    def test_a_static_library_is_refused(self):
        self.assert_refused(self.verify(files=["usr/lib/libcupsfilters.a"]), "usr/lib/libcupsfilters.a")

    def test_a_libtool_archive_is_refused(self):
        self.assert_refused(self.verify(files=["usr/lib/libppd.la"]), "usr/lib/libppd.la")

    def test_a_pkgconfig_directory_is_refused(self):
        result = self.verify(files=["usr/lib/pkgconfig/cups.pc"])
        self.assert_refused(result, "usr/lib/pkgconfig")

    def test_a_cmake_directory_is_refused(self):
        result = self.verify(files=["usr/lib/cmake/Foo/FooConfig.cmake"])
        self.assert_refused(result, "usr/lib/cmake")

    def test_devel_patterns_outside_usr_lib_are_refused(self):
        self.assert_refused(self.verify(dirs=["usr/share/pkgconfig"]), "usr/share/pkgconfig")

    def test_license_notices_never_count_as_devel_content(self):
        result = self.verify(
            files=[
                "usr/share/licenses/cmake/libfoo.a",
                "usr/share/licenses/foo/pkgconfig/COPYING",
                "usr/share/licenses/bar/notice.la",
            ],
            dirs=["usr/share/licenses/cmake", "usr/share/licenses/foo/pkgconfig"],
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("carries no devel content", result.stdout)

    def test_files_named_like_devel_directories_pass(self):
        result = self.verify(files=["usr/bin/cmake", "usr/bin/pkgconfig"])
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_an_export_that_fails_after_a_clean_stream_fails_closed(self):
        # tar accepts what arrived, so only the export's own status can stop the
        # guard from vouching for a filesystem it never fully saw.
        result = self.verify(export_fail=True)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("OK:", result.stdout)
        self.assert_cleaned_up()


if __name__ == "__main__":
    unittest.main()
