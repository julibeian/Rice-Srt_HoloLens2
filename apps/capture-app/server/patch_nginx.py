#!/usr/bin/env python3
"""Add one managed include to the existing rice-srt.cn TLS server only."""
import argparse
import difflib
import re
from pathlib import Path


INCLUDE = "    include /etc/nginx/snippets/hololens-capture.conf;"


def closing_brace(text, opening):
    depth, quoted, escaped, comment = 0, None, False, False
    for index in range(opening, len(text)):
        ch = text[index]
        if comment:
            if ch == "\n":
                comment = False
            continue
        if escaped:
            escaped = False
            continue
        if ch == "\\":
            escaped = True
            continue
        if quoted:
            if ch == quoted:
                quoted = None
            continue
        if ch in ("'", '"'):
            quoted = ch
        elif ch == "#":
            comment = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return index
    raise ValueError("Unbalanced Nginx server block")


def patch_config(text):
    matches = []
    for match in re.finditer(r"(?m)^\s*server\s*\{", text):
        opening = text.index("{", match.start())
        closing = closing_brace(text, opening)
        block = text[opening:closing + 1]
        if (re.search(r"(?m)^\s*listen\s+443\s+ssl\b", block)
                and re.search(r"(?m)^\s*server_name\s+[^;]*\brice-srt\.cn\b[^;]*;", block)):
            matches.append((opening, closing, block))
    if len(matches) != 1:
        raise ValueError("Expected exactly one rice-srt.cn TLS server block")
    opening, closing, block = matches[0]
    if INCLUDE.strip() in block:
        if text.count(INCLUDE.strip()) != 1:
            raise ValueError("Unexpected duplicate managed include")
        return text
    if re.search(r"(?m)^\s*location\s+[^\n{]*/hololens", block):
        raise ValueError("A non-managed HoloLens location already exists")
    return text[:opening + 1] + "\n    # Isolated HoloLens single-photo capture gateway\n" + INCLUDE + text[opening + 1:]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    path = Path(args.config)
    old = path.read_text(encoding="utf-8")
    new = patch_config(old)
    print("".join(difflib.unified_diff(old.splitlines(True), new.splitlines(True),
                                       fromfile=str(path), tofile=str(path) + " + HoloLens")), end="")
    if args.apply and old != new:
        path.write_text(new, encoding="utf-8")


if __name__ == "__main__":
    main()
