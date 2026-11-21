#!/usr/bin/env python3
"""Optimize bundled variable fonts and generate third_party/mornye_symbols.

Usage (from repository root):
    python3 scripts/optimize_fonts.py
    python3 scripts/optimize_fonts.py --symbols-pkg-dir /path/to/material_symbols_icons

Requires fontTools (`pip install fonttools`).
"""

from __future__ import annotations

import argparse
import glob
import os
import re
import sys
from io import BytesIO
from pathlib import Path
from typing import Dict, Set, Tuple

from fontTools import subset as ft_subset
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer


REPO_ROOT = Path(__file__).resolve().parent.parent


def _reload_font(font: TTFont) -> TTFont:
    buf = BytesIO()
    font.save(buf)
    buf.seek(0)
    return TTFont(buf)


def _clamp_axes(font: TTFont, requested: Dict[str, object]) -> Dict[str, object]:
    """Filter requested axis specs to axes still present in fvar."""
    if "fvar" not in font:
        return {}
    present = {axis.axisTag for axis in font["fvar"].axes}
    return {tag: spec for tag, spec in requested.items() if tag in present}


def optimize_google_sans_flex() -> None:
    src = REPO_ROOT / "assets/fonts/GoogleSansFlex.ttf"
    orig_size = src.stat().st_size
    font = TTFont(str(src))
    # AppTheme uses ROND (0 and 100) and wght (400..900); wdth stays at 100.
    axes = _clamp_axes(font, {"wdth": 100, "wght": (400, 900), "ROND": (0, 100)})
    if axes:
        instancer.instantiateVariableFont(font, axes, inplace=True)
    font.save(str(src))
    new_size = src.stat().st_size
    print(
        f"GoogleSansFlex.ttf: {orig_size:,} -> {new_size:,} bytes "
        f"(saved {orig_size - new_size:,} bytes, glyphs: {len(font.getGlyphOrder())})"
    )


def optimize_inter() -> None:
    src = REPO_ROOT / "assets/fonts/InterVariable.ttf"
    orig_size = src.stat().st_size
    font = TTFont(str(src))

    # Song titles, artists and lyrics are user text: keep every character Inter
    # draws (Greek, IPA, shapes), and drop only its private-use alternates.
    unicodes = {cp for cp in font.getBestCmap() if not 0xE000 <= cp <= 0xF8FF}

    options = ft_subset.Options()
    options.layout_features = [
        "kern",
        "liga",
        "calt",
        "tnum",
        "pnum",
        "locl",
        "ccmp",
        "mark",
        "mkmk",
        "case",
        "cpsp",
        "frac",
        "zero",
        "ss01",
        "ss02",
    ]
    options.name_IDs = ["*"]
    options.name_legacy = True
    options.name_languages = ["*"]
    options.notdef_outline = True
    options.drop_tables += ["DSIG"]

    # Subset first, then reload and instance variable axes so gvar stays consistent.
    subsetter = ft_subset.Subsetter(options=options)
    subsetter.populate(unicodes=unicodes)
    subsetter.subset(font)
    font = _reload_font(font)

    # MornyeTheme uses Inter at default optical size (14) and weights 400..900.
    axes = _clamp_axes(font, {"opsz": 14, "wght": (400, 900)})
    if axes:
        instancer.instantiateVariableFont(font, axes, inplace=True)
    font.save(str(src))
    new_size = src.stat().st_size
    print(
        f"InterVariable.ttf: {orig_size:,} -> {new_size:,} bytes "
        f"(saved {orig_size - new_size:,} bytes, glyphs: {len(font.getGlyphOrder())})"
    )


def find_material_symbols_pkg(explicit: str | None) -> Path:
    if explicit:
        path = Path(explicit)
        if not (path / "lib/fonts/MaterialSymbolsRounded.ttf").is_file():
            raise FileNotFoundError(f"MaterialSymbolsRounded.ttf not found under {path}")
        return path
    candidates = sorted(
        glob.glob(
            os.path.expanduser(
                "~/.pub-cache/hosted/pub.dev/material_symbols_icons-*"
            )
        )
    )
    for candidate in reversed(candidates):
        p = Path(candidate)
        if (p / "lib/fonts/MaterialSymbolsRounded.ttf").is_file():
            return p
    raise FileNotFoundError(
        "material_symbols_icons not found in ~/.pub-cache; pass --symbols-pkg-dir"
    )


def collect_used_symbol_names() -> Set[str]:
    names: Set[str] = set()
    pattern = re.compile(r"\bSymbols\.([a-z0-9_]+)\b")
    for rel in ("lib/theme/material_symbols.dart", "test/app_icon_test.dart"):
        text = (REPO_ROOT / rel).read_text(encoding="utf-8")
        names.update(pattern.findall(text))
    return names


def parse_upstream_symbols(pkg_dir: Path) -> Dict[str, Tuple[int, bool]]:
    """Parse Symbols.<name> -> (codepoint, matchTextDirection) from material_symbols_icons."""
    source = (pkg_dir / "lib/symbols.dart").read_text(encoding="utf-8")
    # Match declarations like:
    # static const IconData foo_rounded = IconData(0xe123, fontFamily: 'MaterialSymbolsRounded', fontPackage: 'material_symbols_icons', matchTextDirection: true);
    decl_re = re.compile(
        r"static\s+const\s+IconData\s+([a-z0-9_]+)\s*=\s*IconData\(\s*0x([0-9a-fA-F]+)\s*,([^;]*)\);",
        re.MULTILINE | re.DOTALL,
    )
    table: Dict[str, Tuple[int, bool]] = {}
    for m in decl_re.finditer(source):
        name = m.group(1)
        cp = int(m.group(2), 16)
        rest = m.group(3)
        rtl = "matchTextDirection: true" in rest
        table[name] = (cp, rtl)
    return table


def build_mornye_symbols(pkg_dir: Path) -> None:
    used = sorted(collect_used_symbol_names())
    upstream = parse_upstream_symbols(pkg_dir)
    missing = [name for name in used if name not in upstream]
    if missing:
        raise RuntimeError(f"Unknown Material Symbols: {missing}")

    out_dir = REPO_ROOT / "third_party/mornye_symbols"
    fonts_dir = out_dir / "fonts"
    lib_dir = out_dir / "lib"
    fonts_dir.mkdir(parents=True, exist_ok=True)
    lib_dir.mkdir(parents=True, exist_ok=True)

    # Generate lib/symbols.dart with @staticIconProvider so Flutter's
    # --tree-shake-icons continues to work cleanly.
    lines = [
        "// GENERATED BY scripts/optimize_fonts.py. Do not edit by hand.",
        "// Subset of Material Symbols Rounded (Apache-2.0) used by Mornye.",
        "// ignore_for_file: constant_identifier_names",
        "",
        "import 'package:flutter/widgets.dart';",
        "",
        "@staticIconProvider",
        "abstract final class Symbols {",
        "  static const String _fontFamily = 'MornyeSymbolsRounded';",
        "  static const String _fontPackage = 'mornye_symbols';",
        "",
    ]
    codepoints: Set[int] = set()
    for name in used:
        cp, rtl = upstream[name]
        codepoints.add(cp)
        rtl_arg = ", matchTextDirection: true" if rtl else ""
        lines.append(
            f"  static const IconData {name} = IconData("
            f"0x{cp:04x}, fontFamily: _fontFamily, fontPackage: _fontPackage{rtl_arg});"
        )
    lines.append("}")
    lines.append("")
    (lib_dir / "symbols.dart").write_text("\n".join(lines), encoding="utf-8")

    # Subset and pre-instance MaterialSymbolsRounded.ttf:
    # AppIcon varies FILL (0..1) and opsz (20..48), while GRAD stays 0 and wght stays 400.
    src_ttf = pkg_dir / "lib/fonts/MaterialSymbolsRounded.ttf"
    dst_ttf = fonts_dir / "MornyeSymbolsRounded.ttf"
    font = TTFont(str(src_ttf))
    options = ft_subset.Options()
    options.layout_features = ["*"]
    options.notdef_outline = True
    options.drop_tables += ["DSIG", "GSUB"]
    subsetter = ft_subset.Subsetter(options=options)
    subsetter.populate(unicodes=codepoints)
    subsetter.subset(font)
    font = _reload_font(font)

    instancer.instantiateVariableFont(
        font,
        {"GRAD": 0, "wght": 400, "FILL": (0, 1), "opsz": (20, 48)},
        inplace=True,
    )
    font.save(str(dst_ttf))
    print(
        f"MornyeSymbolsRounded.ttf: {len(used)} symbols ({len(codepoints)} unique codepoints), "
        f"{dst_ttf.stat().st_size:,} bytes"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--symbols-pkg-dir", default=None)
    parser.add_argument(
        "--only",
        choices=("all", "text", "symbols"),
        default="all",
    )
    args = parser.parse_args()

    if args.only in ("all", "text"):
        optimize_google_sans_flex()
        optimize_inter()
    if args.only in ("all", "symbols"):
        pkg_dir = find_material_symbols_pkg(args.symbols_pkg_dir)
        build_mornye_symbols(pkg_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
