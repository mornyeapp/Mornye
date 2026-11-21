"""Check release selection and audits without building APKs or deleting artifacts."""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


FLUTTER_STUB = """import json, os, sys
from pathlib import Path
args = sys.argv[1:]
if Path(sys.argv[0]).name == 'fvm':
    assert args.pop(0) in ('flutter', 'dart')
with open(os.environ['BUILD_TEST_LOG'], 'a') as log:
    log.write(json.dumps({'tool': Path(sys.argv[0]).name, 'args': args,
        'sdk': os.environ.get('MORNYE_DISCORD_SDK', '1')}) + '\\n')
if args == ['scripts/prepare_flutter_sdk.dart']:
    sys.exit(int(os.environ.get('BUILD_TEST_PATCH_FAIL', '0')))
elif args == ['scripts/gen_l10n.dart']:
    sys.exit(0)
elif args == ['--version', '--machine']:
    print(json.dumps({'frameworkVersion': os.environ.get('BUILD_TEST_FLUTTER_VERSION', '3.47.5')}))
else:
    assert args[:2] == ['build', 'apk']
    output = Path('build/app/outputs/flutter-apk')
    output.mkdir(parents=True, exist_ok=True)
    for abi in os.environ['MORNYE_RUST_ANDROID_ABIS'].split(','):
        (output / ('app-' + abi + '-release.apk')).write_bytes(b'fixture split')
    (output / 'app-release.apk').write_bytes(b'fixture universal')
"""

PYTHON_STUB = """import json, os, sys
if sys.argv[1] == 'scripts/check_backend_apk.py':
    with open(os.environ['BUILD_TEST_LOG'], 'a') as log:
        log.write(json.dumps({'tool': 'audit', 'args': sys.argv[2:]}) + '\\n')
else:
    os.execv(sys.executable, [sys.executable, *sys.argv[1:]])
"""


class AndroidBuildScriptTest(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.project = Path(directory.name)
        (self.project / "scripts").mkdir()
        shutil.copyfile(Path(__file__).with_name("build_android.sh"), self.project / "scripts/build_android.sh")
        (self.project / ".fvmrc").write_text('{"flutter":"3.47.5"}')
        sdk = self.project / "third_party/mornye_discord/sdk"
        sdk.mkdir(parents=True)
        (sdk / "discord_partner_sdk.aar").write_bytes(b"staged fixture")
        for name in (
            "notices/Discord-License-Notices.txt",
            "android/prefab/modules/discord_partner_sdk/include/discordpp.h",
            "android/jni/arm64-v8a/libdiscord_partner_sdk.so",
            "android/jni/armeabi-v7a/libdiscord_partner_sdk.so",
        ):
            path = sdk / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"staged fixture")
        self.tools = self.project / "tools"
        self.tools.mkdir()
        self.log = self.project / "calls.jsonl"
        self.env = os.environ.copy()
        for key in ("MORNYE_DISCORD_SDK", "MORNYE_RUST_ANDROID_ABIS"):
            self.env.pop(key, None)
        self.env.update(PATH=str(self.tools) + os.pathsep + os.defpath, BUILD_TEST_LOG=str(self.log))
        self.tool(self.tools / "python3", PYTHON_STUB)
        git = self.tools / "git"
        git.write_text("#!/bin/sh\necho 1234abcd\n")
        git.chmod(0o755)
        self.pinned = self.project / ".fvm/flutter_sdk/bin/flutter"
        self.tool(self.pinned, FLUTTER_STUB)
        self.tool(self.pinned.with_name("dart"), FLUTTER_STUB)

    def tool(self, path, source):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!" + sys.executable + "\n" + source)
        path.chmod(0o755)

    def run_build(self, *args):
        return subprocess.run(
            ["/bin/bash", str(self.project / "scripts/build_android.sh"), *args],
            cwd=self.project, env=self.env, text=True, capture_output=True,
        )

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_default_full_audits_two_splits_and_universal(self):
        result = self.run_build("--verbose")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        build = next(call for call in calls if call["args"][:2] == ["build", "apk"])
        preparation = next(call for call in calls if call["args"] == ["scripts/prepare_flutter_sdk.dart"])
        self.assertEqual(preparation["tool"], "dart")
        self.assertLess(calls.index(preparation), calls.index(build))
        self.assertIn("android-arm64,android-arm", build["args"])
        self.assertIn("--dart-define=MORNYE_MOBILE=true", build["args"])
        self.assertIn("--verbose", build["args"])
        audits = [call["args"] for call in calls if call["tool"] == "audit"]
        self.assertEqual([Path(args[0]).name for args in audits], [
            "app-arm64-v8a-release.apk", "app-armeabi-v7a-release.apk", "app-release.apk",
        ])
        self.assertTrue(all("--discord-sdk" in args for args in audits))
        self.assertEqual(audits[-1][audits[-1].index("--abis") + 1], "arm64-v8a,armeabi-v7a")

    def test_lite_single_abi_ignores_and_preserves_previous_artifacts(self):
        self.env["MORNYE_RUST_ANDROID_ABIS"] = "arm64-v8a"
        output = self.project / "build/app/outputs/flutter-apk"
        output.mkdir(parents=True)
        previous = output / "app-armeabi-v7a-release.apk"
        previous.write_bytes(b"previous build")
        result = self.run_build("--lite")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        build = next(call for call in calls if call["args"][:2] == ["build", "apk"])
        self.assertEqual(build["sdk"], "0")
        self.assertNotIn("--lite", build["args"])
        self.assertIn("android-arm64", build["args"])
        audits = [call["args"] for call in calls if call["tool"] == "audit"]
        self.assertEqual(len(audits), 2)
        self.assertTrue(all("--discord-sdk" not in args for args in audits))
        self.assertTrue(all(args[args.index("--abis") + 1] == "arm64-v8a" for args in audits))
        self.assertEqual(previous.read_bytes(), b"previous build")

    def test_explicit_sdk_disable_is_honored_without_lite_argument(self):
        self.env["MORNYE_DISCORD_SDK"] = "0"
        self.env["MORNYE_RUST_ANDROID_ABIS"] = "armeabi-v7a"
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stderr)
        audits = [call["args"] for call in self.calls() if call["tool"] == "audit"]
        self.assertEqual(len(audits), 2)
        self.assertTrue(all("--discord-sdk" not in args for args in audits))
        self.assertTrue(all(args[args.index("--abis") + 1] == "armeabi-v7a" for args in audits))

    def test_fvm_fallback_uses_pinned_version(self):
        self.pinned.unlink()
        self.tool(self.tools / "fvm", FLUTTER_STUB)
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls()[0]["tool"], "fvm")
        preparation = next(call for call in self.calls() if call["args"] == ["scripts/prepare_flutter_sdk.dart"])
        self.assertEqual(preparation["tool"], "fvm")

    def test_production_requires_full_even_with_inherited_sdk_disable(self):
        self.env["MORNYE_DISCORD_SDK"] = "0"
        result = self.run_build("--production")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        build = next(call for call in calls if call["args"][:2] == ["build", "apk"])
        self.assertEqual(build["sdk"], "1")
        self.assertNotIn("--production", build["args"])
        self.assertTrue(all("--discord-sdk" in call["args"] for call in calls if call["tool"] == "audit"))

    def test_production_rejects_lite_in_either_argument_order(self):
        for arguments in (("--production", "--lite"), ("--lite", "--production")):
            result = self.run_build(*arguments)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("cannot be combined", result.stderr)
        self.assertFalse(self.log.exists())

    def test_production_missing_sdk_components_stops_before_flutter(self):
        sdk = self.project / "third_party/mornye_discord/sdk"
        for name in (
            "discord_partner_sdk.aar", "notices/Discord-License-Notices.txt",
            "android/prefab/modules/discord_partner_sdk/include/discordpp.h",
            "android/jni/arm64-v8a/libdiscord_partner_sdk.so",
            "android/jni/armeabi-v7a/libdiscord_partner_sdk.so",
        ):
            with self.subTest(component=name):
                path = sdk / name
                data = path.read_bytes()
                path.unlink()
                result = self.run_build("--production")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("production requires", result.stderr)
                path.write_bytes(data)
        self.assertFalse(self.log.exists())

    def test_wrong_flutter_version_stops_before_build_or_audit(self):
        self.env["BUILD_TEST_FLUTTER_VERSION"] = "0.0.0"
        result = self.run_build()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Flutter 3.47.5 is required", result.stderr)
        self.assertEqual(len(self.calls()), 1)

    def test_failed_flutter_patch_stops_before_build_or_audit(self):
        self.env["BUILD_TEST_PATCH_FAIL"] = "1"
        result = self.run_build()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([call["args"] for call in self.calls()], [
            ["--version", "--machine"],
            ["scripts/prepare_flutter_sdk.dart"],
        ])

    def test_invalid_or_overridden_abis_stop_before_flutter(self):
        for abis in ("", "x86_64", "arm64-v8a,arm64-v8a", "armeabi-v7a, arm64-v8a"):
            with self.subTest(abis=abis):
                self.env["MORNYE_RUST_ANDROID_ABIS"] = abis
                self.assertNotEqual(self.run_build().returncode, 0)
        self.env.pop("MORNYE_RUST_ANDROID_ABIS")
        self.assertNotEqual(self.run_build("--target-platform=android-x64").returncode, 0)
        self.assertFalse(self.log.exists())


if __name__ == "__main__":
    unittest.main()
