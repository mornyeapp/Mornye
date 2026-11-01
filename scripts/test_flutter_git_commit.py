"""Check mobile build revisions without building the native applications."""

import base64
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


class FlutterGitCommitTest(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.project = Path(directory.name)
        scripts = self.project / "scripts"
        scripts.mkdir()
        self.script = scripts / "flutter_git_commit.sh"
        shutil.copyfile(Path(__file__).with_name(self.script.name), self.script)
        tools = self.project / "tools"
        tools.mkdir()
        git = tools / "git"
        git.write_text('#!/bin/sh\nprintf "%s\\n" "${BUILD_TEST_COMMIT:-}"\n')
        git.chmod(0o755)
        self.env = os.environ.copy()
        self.env.update(
            PATH=str(tools) + os.pathsep + os.defpath,
            BUILD_TEST_COMMIT="1234abcd",
        )

    @staticmethod
    def encode(value):
        return base64.b64encode(value.encode()).decode()

    def defines(self, existing=""):
        result = subprocess.run(
            ["/bin/bash", str(self.script), existing],
            cwd=self.project, env=self.env, text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def test_direct_build_supplies_current_revision(self):
        self.assertEqual(self.defines(), self.encode("GIT_COMMIT=1234abcd"))

    def test_other_defines_are_preserved(self):
        existing = self.encode("FEATURE=true") + "," + self.encode("LABEL=hello, world")
        self.assertEqual(
            self.defines(existing), existing + "," + self.encode("GIT_COMMIT=1234abcd"),
        )

    def test_explicit_revision_takes_precedence_without_duplicates(self):
        existing = self.encode("GIT_COMMIT=87654321") + "," + self.encode("FEATURE=true")
        self.assertEqual(self.defines(existing), existing)

    def test_explicit_empty_revision_is_preserved(self):
        existing = self.encode("GIT_COMMIT=")
        self.assertEqual(self.defines(existing), existing)

    def test_source_archive_preserves_existing_defines(self):
        self.env["BUILD_TEST_COMMIT"] = ""
        existing = self.encode("FEATURE=true")
        self.assertEqual(self.defines(existing), existing)
        self.assertEqual(self.defines(), "")

    def test_non_revision_git_output_is_ignored(self):
        self.env["BUILD_TEST_COMMIT"] = "invalid revision"
        self.assertEqual(self.defines(), "")

    def test_ios_build_phase_exports_revision_to_flutter(self):
        project_file = (
            Path(__file__).resolve().parent.parent
            / "ios/Runner.xcodeproj/project.pbxproj"
        )
        phase = next(
            line.strip() for line in project_file.read_text().splitlines()
            if "shellScript =" in line and "flutter_git_commit.sh" in line
        )
        command = json.loads(phase.removeprefix("shellScript = ").removesuffix(";"))
        flutter_root = self.project / "flutter"
        backend = flutter_root / "packages/flutter_tools/bin/xcode_backend.sh"
        backend.parent.mkdir(parents=True)
        backend.write_text(
            '#!/bin/sh\n[ "$1" = build ] || exit 1\n'
            'printf "%s\\n" "$DART_DEFINES"\n'
        )
        (self.project / "ios").mkdir()
        self.env.update(
            SRCROOT=str(self.project / "ios"), FLUTTER_ROOT=str(flutter_root),
        )
        for revision in (None, "87654321"):
            with self.subTest(revision=revision):
                existing = self.encode("FEATURE=true")
                expected = existing + "," + self.encode("GIT_COMMIT=1234abcd")
                if revision is not None:
                    existing += "," + self.encode("GIT_COMMIT=" + revision)
                    expected = existing
                self.env["DART_DEFINES"] = existing
                result = subprocess.run(
                    ["/bin/sh", "-c", command], env=self.env, text=True, capture_output=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), expected)


if __name__ == "__main__":
    unittest.main()
