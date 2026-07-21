#!/usr/bin/env bash
# Guards against user-facing string literals silently missing from
# Sources/AnglesiteApp/Localizable.xcstrings (#811).
#
# SWIFT_EMIT_LOC_STRINGS only performs the real String Catalog merge during an interactive
# Xcode IDE build; a CLI-only `xcodebuild build` (the only option for a headless/agent
# workflow) never merges new/removed keys into the catalog (see CONTRIBUTING.md's "Commit
# String Catalog updates" section). That leaves CLI-only contributors with no automated
# feedback when they add localizable text — every app-side PR merged since the CONTRIBUTING.md
# rule landed (#755) has silently missed it.
#
# This is a static, heuristic check (not a real extraction): it scans Sources/AnglesiteApp for
# common SwiftUI call sites whose first positional argument is a LocalizedStringKey-typed string
# literal (Text, Button, Label, Toggle, TextField, SecureField, Menu, Section, Picker, GroupBox,
# ContentUnavailableView) plus explicit String(localized:) and LocalizedStringKey(...) calls, and
# checks each literal is a key in Localizable.xcstrings. It does NOT type-check call sites (so a
# same-named local type/function would false-positive) and does NOT catch every extraction vector
# Xcode recognizes (e.g. a custom view whose init parameter happens to be typed
# LocalizedStringKey) - it only catches the shapes actually used in this codebase today. Treat a
# pass here as necessary, not sufficient: it complements, not replaces, the manual `.xcstrings`
# diff review CONTRIBUTING.md asks for.
#
# For a string literal containing interpolation (`\(expr)`), Xcode's real extractor turns each
# interpolation into a positional format specifier (%@, %lld, ...) chosen from the interpolated
# expression's type - this script can't type-check, so it matches any interpolation against a
# permissive `%<spec>` wildcard at that position instead of a specific specifier.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

sources_root="Sources/AnglesiteApp"
catalog="$sources_root/Localizable.xcstrings"

if [[ ! -f "$catalog" ]]; then
  echo "error: $catalog not found." >&2
  exit 1
fi

python3 - "$sources_root" "$catalog" <<'PY'
import json
import re
import sys
from pathlib import Path

sources_root, catalog_path = Path(sys.argv[1]), Path(sys.argv[2])

with open(catalog_path, encoding="utf-8") as f:
    catalog_keys = set(json.load(f)["strings"].keys())

# First-positional-argument call sites whose parameter is LocalizedStringKey in stock SwiftUI.
CALL_NAMES = [
    "Text", "Button", "Label", "Toggle", "TextField", "SecureField",
    "Menu", "Section", "Picker", "GroupBox", "ContentUnavailableView",
]
# These only match up to and including the opening quote - the scanner below (which
# understands nested string literals inside `\(...)` interpolations, e.g.
# `\(x.joined(separator: ", "))`) finds the true end of the literal.
CALL_PATTERN = re.compile(r'\b(?:' + "|".join(CALL_NAMES) + r')\(\s*"')
LOCALIZED_PATTERN = re.compile(r'String\(localized:\s*"')
KEY_PATTERN = re.compile(r'LocalizedStringKey\(\s*"')

# Any interpolation could extract to %@, %lld, %ld, %d, %f, %u, or a positional variant
# (%1$@ etc.) depending on the interpolated expression's type - match permissively.
FORMAT_SPEC = r"%(?:[0-9]+\$)?[a-zA-Z@]+"

ESCAPES = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\", "'": "'", "0": "\0"}


def scan_literal(text, start):
    """text[start] is the character right after a string literal's opening quote.
    Returns (tokens, end_index): end_index is the closing quote's index, and tokens
    alternates ('text', decoded_str) / ('interp', raw_expr_str). Recurses into nested
    string literals inside `\\(...)` interpolations so an embedded quote (e.g.
    `\\(x.joined(separator: ", "))`) doesn't end the outer literal early."""
    tokens, buf, i, n = [], [], start, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            tokens.append(("text", "".join(buf)))
            return tokens, i
        if c == "\\" and i + 1 < n:
            nc = text[i + 1]
            if nc == "(":
                tokens.append(("text", "".join(buf)))
                buf = []
                expr, after = scan_interpolation(text, i + 2)
                tokens.append(("interp", expr))
                i = after
                continue
            if nc == "u" and i + 2 < n and text[i + 2] == "{":
                close = text.find("}", i + 3)
                if close != -1:
                    try:
                        buf.append(chr(int(text[i + 3 : close], 16)))
                        i = close + 1
                        continue
                    except ValueError:
                        pass
            if nc in ESCAPES:
                buf.append(ESCAPES[nc])
                i += 2
                continue
            # Unrecognized escape - best effort, keep the backslash literally.
            buf.append(c)
            i += 1
            continue
        buf.append(c)
        i += 1
    # Unterminated literal (shouldn't happen in valid Swift) - return what we have.
    tokens.append(("text", "".join(buf)))
    return tokens, n


def scan_interpolation(text, start):
    """text[start] is the character right after `\\(`. Returns (raw_expr, index_after_close_paren)."""
    depth, i, n = 1, start, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            _tokens, end = scan_literal(text, i + 1)
            i = end + 1
            continue
        if c == "(":
            depth += 1
            i += 1
            continue
        if c == ")":
            depth -= 1
            i += 1
            if depth == 0:
                return text[start : i - 1], i
            continue
        if c == "\\" and i + 1 < n:
            i += 2
            continue
        i += 1
    return text[start:i], i


def render(tokens):
    """Best-effort human-readable reconstruction of a token list, for error messages."""
    return "".join(val if kind == "text" else f"\\({val})" for kind, val in tokens)


def literal_present(tokens):
    if not any(kind == "interp" for kind, _ in tokens):
        return "".join(val for _, val in tokens) in catalog_keys
    # A string with interpolation is extracted as a format string, so any literal `%`
    # in the text portions is escaped to `%%` in the catalog key.
    parts = []
    for kind, val in tokens:
        if kind == "text":
            parts.append(re.escape(val.replace("%", "%%")))
        else:
            parts.append(FORMAT_SPEC)
    pattern = re.compile("^" + "".join(parts) + "$")
    return any(pattern.match(key) for key in catalog_keys)


missing = []
for path in sorted(sources_root.rglob("*.swift")):
    text = path.read_text(encoding="utf-8")
    for pattern in (CALL_PATTERN, LOCALIZED_PATTERN, KEY_PATTERN):
        for m in pattern.finditer(text):
            tokens, _end = scan_literal(text, m.end())
            if not tokens or all(kind == "text" and not val for kind, val in tokens):
                continue
            if not literal_present(tokens):
                line = text.count("\n", 0, m.start()) + 1
                missing.append((str(path), line, render(tokens)))

if missing:
    missing.sort()
    print(
        f"error: {len(missing)} localizable string literal(s) in {sources_root} have no "
        f"matching key in {catalog_path}:",
        file=sys.stderr,
    )
    for path, line, raw in missing:
        print(f"  {path}:{line}: \"{raw}\"", file=sys.stderr)
    print(
        "\nSee CONTRIBUTING.md's \"Commit String Catalog updates\" section for how to "
        "regenerate the catalog locally, then review and commit the .xcstrings diff.",
        file=sys.stderr,
    )
    sys.exit(1)

print(f"✓ every scanned localizable literal in {sources_root} has a matching {catalog_path} key.")
PY
