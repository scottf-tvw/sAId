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
mv|rename-exclusive)
  native=""
  if [ "$name" = rename-exclusive ]; then native=$1; shift; fi
  if [ "${FAIL_AT:-}" = race_install ] && [[ "$1" == */new.app ]]; then
    /bin/mkdir "$2"; printf competing > "$2/competitor"
  fi
  if [ "${FAIL_AT:-}" = race_rollback ]; then
    if [[ "$1" == */new.app ]]; then exit 45; fi
    if [[ "$1" == */previous.app ]]; then /bin/mkdir "$2"; printf competing > "$2/competitor"; fi
  fi
  if [ "${FAIL_AT:-}" = race_release ] && [[ "$1" == */final.zip ]]; then printf 'existing notarized artifact' > "$2"; fi
  if [[ "${FAIL_AT:-}" == swap || "${FAIL_AT:-}" == rollback ]] && [[ "$1" == */new.app ]]; then exit 45; fi
  if [ "${FAIL_AT:-}" = rollback ] && [[ "$1" == */previous.app ]]; then exit 49; fi
  if [ -n "$native" ]; then exec "$native" "$@"; else /bin/mv "$@"; fi ;;
xcrun)
  if [ "$1" = --sdk ]; then
    /usr/bin/xcrun "$@"
  elif [ "$1" = clang ]; then
    shift
    /usr/bin/clang "$@"
    output=${@: -1}
    /bin/mv "$output" "$output.native"
    # Only the compiler tool is stubbed: inject the race, then invoke the REAL primitive.
    printf '%s\n' '#!/bin/bash' 'exec "$TEST_BIN/rename-exclusive" "$0.native" "$@"' > "$output"
    /bin/chmod +x "$output"
  elif [ "$1" = notarytool ]; then
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
        for name in ["security", "xcodegen", "xcodebuild", "codesign", "ditto", "lipo", "mv", "rename-exclusive", "xcrun", "swift"]:
            p = self.bin / name; p.write_text(STUB); p.chmod(0o755)
        self.destination = self.root / "Applications/sAId.app"
        self.destination.mkdir(parents=True)
        (self.destination / "sentinel").write_text("previous app")
        self.env = dict(os.environ, PATH=str(self.bin) + ":" + os.environ["PATH"],
                        TEST_LOG=str(self.root / "calls.log"), TEST_TEMPLATE=str(self.template), TEST_BIN=str(self.bin),
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
        self.assertFalse((self.destination.parent / ".sAId-install.lock").exists())
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
    def test_install_destination_appears_before_publish_preserves_both_apps(self):
        self.assert_install_race_preserved("race_install")
    def test_install_destination_appears_before_rollback_preserves_both_apps(self):
        self.assert_install_race_preserved("race_rollback")
    def assert_install_race_preserved(self, failure):
        result = self.run_script("install.sh", fail=failure)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual((self.destination / "competitor").read_text(), "competing")
        self.assertFalse((self.destination / "new.app").exists())
        self.assertFalse((self.destination / "previous.app").exists())
        saved = list(self.destination.parent.glob(".said-install.*/previous.app/sentinel"))
        self.assertEqual(len(saved), 1, result.stdout)
        self.assertEqual(saved[0].read_text(), "previous app")
        self.assertNotIn("Installed ", result.stdout)
        self.assertIn("recover", result.stdout)
    def test_new_install_race_leaves_appearing_destination_and_reports_no_restore(self):
        import shutil
        shutil.rmtree(self.destination)
        result = self.run_script("install.sh", fail="race_install")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual((self.destination / "competitor").read_text(), "competing")
        self.assertFalse((self.destination / "new.app").exists())
        self.assertNotIn("previous app restored", result.stdout)
        self.assertNotIn("Installed ", result.stdout)
        self.assertEqual(list(self.destination.parent.glob(".said-install.*")), [])
    def test_release_destination_appears_before_publish_keeps_existing_archive(self):
        result = self.run_script("release.sh", "2.3.4", fail="race_release")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual((self.root / "dist output/sAId-2.3.4.zip").read_text(), "existing notarized artifact")
        self.assertNotIn("Notarized and stapled release:", result.stdout)
    def test_install_refuses_existing_lock_without_changing_previous_app(self):
        lock = self.destination.parent / ".sAId-install.lock"
        lock.mkdir()
        result = self.run_script("install.sh")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual((self.destination / "sentinel").read_text(), "previous app")
        self.assertTrue(lock.is_dir())
        self.assertIn("Another installation may be active", result.stdout)
    def test_make_and_bench_propagate_failure(self):
        for target in ["build", "test", "app", "install"]:
            result = subprocess.run(["/usr/bin/make", target], cwd=ROOT, env=dict(self.env, FAIL_AT="build"), capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0, result.stdout)
        result = self.run_script("bench.sh", "--help")
        self.assertEqual(result.returncode, 48, result.stdout)

class ExclusiveRenameTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="said native rename ")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.root = Path(cls.temp.name)
        cls.helper = cls.root / "rename-exclusive"
        sdk = subprocess.check_output(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
        subprocess.run(["/usr/bin/clang", "-isysroot", sdk, "-Wall", "-Wextra", "-Werror",
                        str(ROOT / "scripts/rename-exclusive.c"), "-o", str(cls.helper)], check=True)
    def test_existing_file_directory_and_symlink_are_never_replaced_or_nested(self):
        for kind in ["file", "directory", "symlink"]:
            with self.subTest(kind=kind):
                root = self.root / kind; root.mkdir()
                source = root / "source.app"; source.mkdir()
                (source / "sentinel").write_text("source")
                destination = root / "destination"
                if kind == "file": destination.write_text("existing")
                elif kind == "directory": destination.mkdir(); (destination / "sentinel").write_text("existing")
                else: destination.symlink_to(root / "missing-target")
                result = subprocess.run([str(self.helper), str(source), str(destination)], capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((source / "sentinel").read_text(), "source")
                if kind == "file": self.assertEqual(destination.read_text(), "existing")
                elif kind == "directory": self.assertEqual(list(destination.iterdir()), [destination / "sentinel"])
                else: self.assertTrue(destination.is_symlink())
    def test_concurrent_native_publish_has_exactly_one_winner_and_retains_loser(self):
        from concurrent.futures import ThreadPoolExecutor
        import threading
        destination = self.root / "published.zip"
        sources = [self.root / "one.zip", self.root / "two.zip"]
        for source in sources: source.write_text(source.name)
        barrier = threading.Barrier(2)
        def publish(source):
            barrier.wait()
            return subprocess.run([str(self.helper), str(source), str(destination)], capture_output=True).returncode
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(publish, sources))
        self.assertEqual(sorted(results), [0, 1])
        winner = sources[results.index(0)]; loser = sources[results.index(1)]
        self.assertEqual(destination.read_text(), winner.name)
        self.assertFalse(winner.exists())
        self.assertEqual(loser.read_text(), loser.name)

if __name__ == "__main__": unittest.main()
