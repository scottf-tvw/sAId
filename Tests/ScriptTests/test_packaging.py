"""Failure-path tests: stub external build/sign/notary tools; never touch /Applications."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
STUB = r'''#!/bin/bash
set -eu
name=${0##*/}
printf '%s %s\n' "$name" "$*" >> "$TEST_LOG"
case "$name" in
security) echo '1) ABC "Developer ID Application: Scott DL Freeman (M2TEAF948X)"' ;;
xcodegen) [ "${FAIL_AT:-}" != generate ] ;;
xcodebuild)
  [ "${FAIL_AT:-}" != build ] || exit 41
  /bin/mkdir -p "$SAID_BUILD_DIR/Build/Products/${SAID_CONFIGURATION:-Release}"
  /bin/cp -R "$TEST_TEMPLATE" "$SAID_BUILD_DIR/Build/Products/${SAID_CONFIGURATION:-Release}/sAId.app"
  ;;
codesign)
  if [[ "$*" == *--verify* ]]; then
    [ "${FAIL_AT:-}" != verify ] || exit 42
    if [[ "${FAIL_AT:-}" == stage_verify && "$*" == *.said-install.* ]]; then exit 43; fi
  elif [[ "$*" == *--entitlements* && "$*" == *-d* ]]; then
    if [ "${FAIL_AT:-}" = extra_entitlement ]; then
      echo '<plist version="1.0"><dict><key>com.apple.security.device.audio-input</key><true/><key>com.apple.security.cs.disable-library-validation</key><true/></dict></plist>'
    else /bin/cat "$TEST_ENTITLEMENTS"; fi
  else
    echo 'flags=0x10000(runtime)' >&2
    echo 'TeamIdentifier=M2TEAF948X' >&2
  fi ;;
ditto)
  [ "${FAIL_AT:-}" != copy ] || exit 44
  if [ "$1" = -c ]; then /usr/bin/touch "${@: -1}"; else /bin/cp -R "$1" "$2"; fi ;;
lipo) [ "$2" = -verify_arch ] && [ "$3" = arm64 ] ;;
mv)
  if [[ "${FAIL_AT:-}" == swap || "${FAIL_AT:-}" == rollback ]] && [[ "$1" == */new.app ]]; then exit 45; fi
  if [ "${FAIL_AT:-}" = rollback ] && [[ "$1" == */previous.app ]]; then exit 49; fi
  /bin/mv "$@" ;;
xcrun)
  if [ "$1" = notarytool ]; then
    [ "${FAIL_AT:-}" != notary ] || exit 46
    echo '{"id":"stub-submission","status":"'"${NOTARY_STATUS:-Accepted}"'"}'
  elif [ "$1" = stapler ]; then [ "${FAIL_AT:-}" != staple ] || exit 47; fi ;;
swift) exit 48 ;;
*) exit 99 ;;
esac
'''

class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="said script test ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"; self.bin.mkdir()
        self.template = self.root / "template.app"
        (self.template / "Contents/MacOS").mkdir(parents=True)
        exe = self.template / "Contents/MacOS/sAId"; exe.write_text("new"); exe.chmod(0o755)
        import plistlib
        with (self.template / "Contents/Info.plist").open("wb") as f:
            plistlib.dump({"CFBundleIdentifier": "org.tvw.said", "CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "1"}, f)
        resources = self.template / "Contents/Resources"; resources.mkdir()
        for source in (ROOT / "Resources").rglob("*"):
            if source.is_file(): (resources / source.name).write_bytes(source.read_bytes())
        for name in ["security", "xcodegen", "xcodebuild", "codesign", "ditto", "lipo", "mv", "xcrun", "swift"]:
            p = self.bin / name; p.write_text(STUB); p.chmod(0o755)
        self.destination = self.root / "Applications/sAId.app"
        self.destination.mkdir(parents=True)
        (self.destination / "sentinel").write_text("previous app")
        self.env = dict(os.environ, PATH=str(self.bin) + ":" + os.environ["PATH"],
                        TEST_LOG=str(self.root / "calls.log"), TEST_TEMPLATE=str(self.template),
                        TEST_ENTITLEMENTS=str(ROOT / "sAId.entitlements"),
                        SAID_BUILD_DIR=str(self.root / "build output"), SAID_INSTALL_DEST=str(self.destination),
                        SAID_DIST_DIR=str(self.root / "dist output"), SAID_CONFIGURATION="Release")
    def run_script(self, name, *args, fail="", **env):
        return subprocess.run(["/bin/bash", str(ROOT / "scripts" / name), *args], env=dict(self.env, FAIL_AT=fail, **env),
                              text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    def test_install_failure_transitions_preserve_old_app(self):
        for failure in ["generate", "build", "copy", "verify", "stage_verify", "extra_entitlement", "swap"]:
            with self.subTest(failure=failure):
                result = self.run_script("install.sh", fail=failure)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual((self.destination / "sentinel").read_text(), "previous app")
                self.assertNotIn("No such file or directory", result.stdout)
    def test_rollback_failure_preserves_recoverable_previous_app(self):
        result = self.run_script("install.sh", fail="rollback")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        saved = list(self.destination.parent.glob(".said-install.*/previous.app/sentinel"))
        self.assertEqual(len(saved), 1, result.stdout)
        self.assertEqual(saved[0].read_text(), "previous app")
        self.assertIn("recover", result.stdout)
    def test_install_success_and_no_launch(self):
        result = self.run_script("install.sh")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual((self.destination / "Contents/MacOS/sAId").read_text(), "new")
        self.assertFalse((self.destination / "sentinel").exists())
        self.assertNotIn("open ", (self.root / "calls.log").read_text())
        self.assertEqual(list(self.destination.parent.glob(".said-install.*")), [])
    def test_install_refuses_symlink_destination(self):
        import shutil
        shutil.rmtree(self.destination)
        self.destination.symlink_to(self.template, target_is_directory=True)
        result = self.run_script("install.sh")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertTrue(self.destination.is_symlink())
    def test_release_failure_never_leaves_final_archive(self):
        for failure in ["build", "verify", "notary", "staple"]:
            with self.subTest(failure=failure):
                result = self.run_script("release.sh", "2.3.4", fail=failure)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertFalse((self.root / "dist output/sAId-2.3.4.zip").exists())
                self.assertNotIn("No such file or directory", result.stdout)
                if failure == "notary": self.assertIn("store-credentials said-notary", result.stdout)
    def test_release_requires_accepted_notarization(self):
        result = self.run_script("release.sh", "2.3.4", NOTARY_STATUS="Invalid")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse((self.root / "dist output/sAId-2.3.4.zip").exists())
    def test_release_success_version_and_staple_before_final_zip(self):
        result = self.run_script("release.sh", "2.3.4")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertTrue((self.root / "dist output/sAId-2.3.4.zip").exists())
        calls = (self.root / "calls.log").read_text()
        self.assertLess(calls.index("stapler staple"), calls.rindex("ditto -c"))
        self.assertIn("MARKETING_VERSION=2.3.4", calls)
    def test_make_and_bench_propagate_failure(self):
        for target in ["build", "test", "app", "install"]:
            result = subprocess.run(["/usr/bin/make", target], cwd=ROOT, env=dict(self.env, FAIL_AT="build"), capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0, result.stdout)
        result = self.run_script("bench.sh", "--help")
        self.assertEqual(result.returncode, 48, result.stdout)

if __name__ == "__main__": unittest.main()
