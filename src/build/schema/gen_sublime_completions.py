#!/usr/bin/env python3
"""Generate a .sublime-completions file from Ghostty's config.schema.json.

Usage:
    python3 gen_sublime_completions.py config.schema.json > ghostty.sublime-completions
"""

import json
import sys


def main() -> None:
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <config.schema.json>", file=sys.stderr)
        sys.exit(1)

    with open(sys.argv[1]) as fh:
        schema = json.load(fh)

    completions = {
        "scope": "source.ghostty",
        "completions": [
            {
                "trigger": entry["key"],
                "contents": entry["key"] + " = ${1:" + (entry["default"] or "") + "}",
                "description": (entry["description"].split("\n")[0] or "")[:80],
            }
            for entry in schema
        ],
    }

    print(json.dumps(completions, indent=2))


if __name__ == "__main__":
    main()
