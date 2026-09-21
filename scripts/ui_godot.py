#!/usr/bin/env python3
"""Keep the Godot CLI transport machine-readable despite engine banner output."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(json.dumps({"success": False, "errors": [{"code": "LAUNCHER_USAGE", "message": "ui_godot.py <godot_binary> <ui_args...>"}]}))
        return 2
    godot_binary = argv[0]
    project_dir = Path(__file__).resolve().parents[1]
    try:
        import_process = subprocess.run(
            [godot_binary, "--headless", "--editor", "--path", str(project_dir), "--quit"],
            capture_output=True,
            text=True,
            timeout=120,
        )
    except subprocess.TimeoutExpired:
        print(json.dumps({
            "success": False,
            "errors": [{
                "code": "GODOT_IMPORT_TIMEOUT",
                "message": "Godot did not finish project initialization/import within 120 seconds.",
            }],
        }, indent="\t"))
        return 124
    if import_process.returncode != 0:
        print(json.dumps({
            "success": False,
            "errors": [{
                "code": "GODOT_IMPORT_FAILED",
                "message": "Godot could not initialize/import the project before the CLI command.",
                "stderr": import_process.stderr.strip()[-4000:],
            }],
        }, indent="\t"))
        return import_process.returncode
    render_with_virtual_display = argv[1] == "render" and not os.environ.get("DISPLAY") and shutil.which("xvfb-run")
    command = ([shutil.which("xvfb-run"), "-a", godot_binary] if render_with_virtual_display else [godot_binary, "--headless"])
    command.extend([
        "--path",
        str(project_dir),
        "--script",
        "res://addons/aether_ui/cli/cli_main.gd",
        "--",
        *argv[1:],
    ])
    process = subprocess.run(command, capture_output=True, text=True)
    decoder = json.JSONDecoder()
    payload = None
    for index, character in enumerate(process.stdout):
        if character != "{":
            continue
        try:
            candidate, _end = decoder.raw_decode(process.stdout[index:])
            if isinstance(candidate, dict) and "success" in candidate:
                payload = candidate
                break
        except json.JSONDecodeError:
            continue
    if payload is None:
        payload = {
            "success": False,
            "errors": [{
                "code": "GODOT_CLI_NO_JSON",
                "message": "Godot did not return a structured CLI result.",
                "stderr": process.stderr.strip()[-2000:],
                "stdout": process.stdout.strip()[-4000:],
            }],
        }
    print(json.dumps(payload, indent="\t", ensure_ascii=False))
    return process.returncode


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
