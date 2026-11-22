"""Release notes: the written section leads and the commit list is folded."""

import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import release_notes as notes


CHANGELOG = """# Changelog

How this file is used.

## [Unreleased]

### New

- **Upcoming**: Not out yet.

## [5.5.0] - 2026-12-01

### New

- **Equalizer**: Tune the sound with your own filters.

### Fixed

- A song that stopped after a call.

## [5.4.0]
"""

COMMITS = """## 5.5.0

### New Features

- **equalizer**: Parametric filters ([#12](https://example.com/pull/12)) by [@someone](https://github.com/someone)
- **home**: Shelves <b> & more

**Full Changelog**: [v5.4.0...v5.5.0](https://example.com/compare)
"""

# The update dialog of installed versions finds its text this way.
DIALOG_START = re.compile(r"###?\s*What'?s\s*New\s*\n", re.IGNORECASE)
DIALOG_END = re.compile(r"\n---|\n###?\s*Downloads", re.IGNORECASE)


class ReleaseNotesTest(unittest.TestCase):
    def test_a_version_reads_its_own_section(self):
        for version in ("v5.5.0", "5.5.0"):
            name, text = notes.written_notes(CHANGELOG, version)
            self.assertEqual(name, "5.5.0")
            self.assertTrue(text.startswith("### New"))
            self.assertTrue(text.endswith("- A song that stopped after a call."))
            self.assertNotIn("Upcoming", text)

    def test_an_unlisted_version_reads_unreleased(self):
        name, text = notes.written_notes(CHANGELOG, "v5.6.0")
        self.assertEqual(name, "unreleased")
        self.assertIn("Upcoming", text)

    def test_a_rule_that_closes_a_section_is_left_out(self):
        changelog = "## [5.4.5] - Unreleased\n\n### Added\n\n- One\n\n---\n\n## [5.4.0]\n"
        name, text = notes.written_notes(changelog, "v5.4.5")
        self.assertEqual((name, text), ("5.4.5", "### Added\n\n- One"))
        self.assertEqual(notes.body(text, "- commit").count("\n---\n"), 1)
        self.assertIsNone(notes.written_notes("## [5.4.5]\n\n---\n\n## [5.4.0]\n", "v5.4.5"))

    def test_an_empty_section_is_no_notes(self):
        self.assertIsNone(notes.written_notes("## [5.4.0]\n\n## [5.3.0]\n- x", "v5.4.0"))
        self.assertIsNone(notes.written_notes("", "v5.4.0"))

    def test_the_commit_list_loses_its_heading_and_footer(self):
        commits = notes.commit_list(COMMITS)
        self.assertTrue(commits.startswith("### New Features"))
        self.assertNotIn("Full Changelog", commits)
        self.assertNotIn("## 5.5.0", commits)

    def test_notes_lead_and_commits_are_folded(self):
        _, text = notes.written_notes(CHANGELOG, "v5.5.0")
        body = notes.body(text, notes.commit_list(COMMITS))
        self.assertTrue(body.startswith("## What's New\n\n### New\n"))
        # A blank line before the rule, or Markdown reads a heading.
        self.assertIn("call.\n\n---\n\n<details>\n<summary>All changes</summary>\n\n### New Features", body)
        self.assertTrue(body.endswith("\n\n</details>"))

        start = DIALOG_START.search(body).end()
        shown = body[start:DIALOG_END.search(body, start).start()]
        self.assertIn("Tune the sound", shown)
        self.assertNotIn("Parametric filters", shown)

    def test_without_notes_the_body_is_the_commit_list(self):
        commits = notes.commit_list(COMMITS)
        self.assertEqual(notes.body(None, commits), commits)
        self.assertEqual(notes.body("- Only notes", ""), "## What's New\n\n- Only notes")

    def test_telegram_text_is_escaped_html(self):
        _, text = notes.written_notes(CHANGELOG, "v5.5.0")
        self.assertEqual(
            notes.telegram(text, "ignored"),
            "<b>New</b>\n• <b>Equalizer</b>: Tune the sound with your own filters.\n\n"
            "<b>Fixed</b>\n• A song that stopped after a call.",
        )
        fallback = notes.telegram(None, notes.commit_list(COMMITS))
        self.assertIn("• <b>equalizer</b>: Parametric filters (#12)\n", fallback)
        self.assertIn("Shelves &lt;b&gt; &amp; more", fallback)
        self.assertEqual(notes.telegram(None, ""), notes.NO_NOTES)
        self.assertEqual(
            notes.telegram("- **Cards**: A *Style* pane, `URL` columns and 2 * 3 * 4", ""),
            "• <b>Cards</b>: A <i>Style</i> pane, <code>URL</code> columns and 2 * 3 * 4",
        )

    def test_long_telegram_text_ends_on_a_whole_line(self):
        text = "\n".join(f"- **Item {index}**: " + "word " * 20 for index in range(60))
        message = notes.telegram(text, "")
        self.assertLessEqual(len(message), notes.TELEGRAM_LIMIT + 4)
        self.assertTrue(message.endswith("\n..."))
        self.assertEqual(message.count("<b>"), message.count("</b>"))

    def test_the_command_writes_the_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "CHANGELOG.md").write_text(CHANGELOG, encoding="utf-8")
            (root / "commits.txt").write_text(COMMITS, encoding="utf-8")
            script = Path(notes.__file__)
            # A missing commit list still leaves the written notes.
            for commits in ("commits.txt", "missing.txt"):
                result = subprocess.run(
                    [sys.executable, str(script), "body", "--version", "v5.5.0",
                     "--changelog", str(root / "CHANGELOG.md"),
                     "--commits", str(root / commits),
                     "--output", str(root / "body.md")],
                    check=True, capture_output=True, text=True,
                )
                self.assertIn("::notice::", result.stdout)
                self.assertTrue((root / "body.md").read_text(encoding="utf-8")
                                .startswith("## What's New\n"))
            result = subprocess.run(
                [sys.executable, str(script), "telegram", "--version", "v9.9.9",
                 "--changelog", str(root / "none.md"),
                 "--commits", str(root / "commits.txt"),
                 "--output", str(root / "telegram.txt")],
                check=True, capture_output=True, text=True,
            )
            self.assertIn("::warning::", result.stdout)
            self.assertIn("Parametric filters", (root / "telegram.txt").read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
