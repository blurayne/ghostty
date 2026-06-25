#!/usr/bin/env python3
"""Generate a VS Code snippets file from Ghostty's config.schema.json.

Usage:
    python3 gen_vscode_snippets.py config.schema.json > ghostty.code-snippets
"""

import json
import sys


def main() -> None:
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <config.schema.json>", file=sys.stderr)
        sys.exit(1)

    with open(sys.argv[1]) as fh:
        schema = json.load(fh)

    snippets = {
        entry["key"]: {
            "prefix": entry["key"],
            "body": [entry["key"] + " = ${1:" + (entry["default"] or "") + "}"],
            "description": (entry["description"].split("\n")[0] or "")[:80],
        }
        for entry in schema
    }

    print(json.dumps(snippets, indent=2))


if __name__ == "__main__":
    main()
