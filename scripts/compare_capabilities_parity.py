#!/usr/bin/env python3
"""Compare native and fallback machine capabilities for portable contract parity."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from contract_snapshots import (  # noqa: E402
    component_definitions,
    diff_paths,
    normalize_capabilities_for_parity,
    property_groups,
    semantic_property_schemas,
)
from ui_fallback import capabilities  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fallback-only", action="store_true")
    parser.add_argument("--output", default="")
    args = parser.parse_args()
    if args.fallback_only:
        payload = normalize_capabilities_for_parity(capabilities())
        if args.output:
            Path(args.output).write_text(json.dumps(payload, sort_keys=True), encoding="utf-8")
        else:
            print(json.dumps(payload, sort_keys=True))
        return 0
    native_payload = json.loads(sys.stdin.read())
    native_caps = native_payload.get("capabilities", native_payload)
    failures = diff_paths(
        normalize_capabilities_for_parity(native_caps),
        normalize_capabilities_for_parity(capabilities()),
    )
    if failures:
        print(json.dumps({"success": False, "failures": failures}, indent=2))
        return 1
    print(json.dumps({"success": True}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
