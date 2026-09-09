#!/usr/bin/env python3
"""Check the source snapshot using only the Python standard library."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import sys


def main():
    root = Path(__file__).resolve().parent
    manifest = json.loads((root / "MANIFEST.json").read_text(encoding="utf-8"))
    failures = []
    for name, expected in manifest["files"].items():
        relative = PurePosixPath(name)
        if relative.is_absolute() or ".." in relative.parts or "\\" in name:
            failures.append(f"Invalid manifest path: {name}")
            continue
        path = root.joinpath(*relative.parts)
        if path.is_symlink() or not path.is_file():
            failures.append(f"Missing file or symlink: {name}")
            continue
        data = path.read_bytes()
        if len(data) != expected["bytes"] or hashlib.sha256(data).hexdigest() != expected["sha256"]:
            failures.append(f"Changed: {name}")
    if failures:
        print("\n".join(failures))
        return 1
    print(f"PACKAGE_PASS {len(manifest['files'])} files match SHA-256 manifest")
    print("Unlisted files, including new build outputs, are not checked.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
