#!/usr/bin/env python3
"""Cross-platform UIForge launcher."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path


def main(argv: list[str]) -> int:
    project_dir = Path(__file__).resolve().parents[1]
    if not argv:
        argv = ["help"]
    godot_bin = os.environ.get("GODOT_BIN", "")
    if not godot_bin or not Path(godot_bin).exists():
        for candidate in ("godot", "godot4"):
            found = shutil.which(candidate)
            if found:
                godot_bin = found
                break
    if godot_bin and Path(godot_bin).exists():
        launcher = project_dir / "scripts" / "ui_godot.py"
        return subprocess.call([sys.executable, str(launcher), godot_bin, *argv])
    fallback = project_dir / "scripts" / "ui_fallback.py"
    return subprocess.call([sys.executable, str(fallback), *argv])


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
