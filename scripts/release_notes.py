#!/usr/bin/env python3
"""Write a release's notes: CHANGELOG.md for people, the commit list folded."""

import argparse
import html
import re
import sys
from pathlib import Path
from typing import Optional, Tuple


PROJECT_ROOT = Path(__file__).resolve().parent.parent
SECTION = re.compile(r"^## \[?([^\]\s]+)\]?")
TRAILING_RULE = re.compile(r"(\n[ \t]*-{3,}[ \t]*)+\s*$")
# What git-cliff adds around its list; the workflow writes its own footer.
COMMIT_NOISE = re.compile(r"^## [0-9][0-9.A-Za-z-]*$|^\*\*Full Changelog\*\*")
CREDIT = re.compile(r" by (\[@[^\]]*\]\([^)]*\)|@[A-Za-z0-9_-]+)")
LINK = re.compile(r"\[([^\]]*)\]\([^)]*\)")
BOLD = re.compile(r"\*\*([^*]*)\*\*")
ITALIC = re.compile(r"(?<![*\w])\*([^*\s][^*]*)\*(?![*\w])")
CODE = re.compile(r"`([^`]+)`")
TELEGRAM_LIMIT = 2500
NO_NOTES = "See release notes on GitHub for details."


def written_notes(changelog: str, version: str) -> Optional[Tuple[str, str]]:
    """The section written for this version, else the Unreleased one."""
    sections = {}
    current = None
    for line in changelog.splitlines():
        match = SECTION.match(line)
        if match:
            name = match.group(1).lstrip("v").lower()
            # A repeated heading keeps the first section.
            current = None if name in sections else sections.setdefault(name, [])
        elif current is not None:
            current.append(line)
    for name in (version.lstrip("v").lower(), "unreleased"):
        # A rule that closes the section is the file's, not the notes'.
        text = TRAILING_RULE.sub("", "\n".join(sections.get(name, []))).strip()
        if text:
            return name, text
    return None


def commit_list(text: str) -> str:
    lines = [line.rstrip() for line in text.splitlines()
             if not COMMIT_NOISE.match(line.strip())]
    return "\n".join(lines).strip()


def body(notes: Optional[str], commits: str) -> str:
    """The notes lead; the app's update dialog reads up to the first rule."""
    if not notes:
        return commits
    parts = ["## What's New", "", notes]
    if commits:
        parts += ["", "---", "", "<details>", "<summary>All changes</summary>",
                  "", commits, "", "</details>"]
    return "\n".join(parts)


def telegram(notes: Optional[str], commits: str) -> str:
    """Telegram HTML, cut at a line so no tag is left open."""
    lines = []
    for line in (notes or commits).splitlines():
        line = LINK.sub(r"\1", CREDIT.sub("", line.strip()))
        if not line:
            continue
        line = BOLD.sub(r"<b>\1</b>", html.escape(line, quote=False))
        line = CODE.sub(r"<code>\1</code>", ITALIC.sub(r"<i>\1</i>", line))
        heading = re.match(r"^#{2,3} (.*)$", line)
        if heading:
            lines += ["", f"<b>{heading.group(1)}</b>"]
        else:
            lines.append(re.sub(r"^[-*] ", "• ", line))
    kept = []
    for line in lines:
        if len("\n".join(kept + [line])) > TELEGRAM_LIMIT:
            kept.append("...")
            break
        kept.append(line)
    return "\n".join(kept).strip() or NO_NOTES


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("format", choices=("body", "telegram"))
    parser.add_argument("--version", required=True)
    parser.add_argument("--commits", type=Path, required=True,
                        help="git-cliff's list for this release")
    parser.add_argument("--changelog", type=Path,
                        default=PROJECT_ROOT / "CHANGELOG.md")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    changelog = args.changelog.read_text(encoding="utf-8") if args.changelog.is_file() else ""
    commits = args.commits.read_text(encoding="utf-8") if args.commits.is_file() else ""
    found = written_notes(changelog, args.version)
    if found:
        print(f"::notice::Release notes for {args.version} come from the "
              f"[{found[0]}] section of {args.changelog.name}")
    else:
        print(f"::warning::{args.changelog.name} has no notes for "
              f"{args.version}; the release lists commits only")
    notes = found[1] if found else None
    write = body if args.format == "body" else telegram
    args.output.write_text(write(notes, commit_list(commits)) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
