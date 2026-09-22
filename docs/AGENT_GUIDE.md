# UIForge Agent Guide

This guide describes the recommended workflow for AI agents working with UIForge through the machine protocol.

## Why use the persistent server

For multi-step editing sessions, prefer:

```bash
ui serve --stdio
```

One native Godot process handles many requests. This is substantially faster than spawning Godot for every command.

## Recommended workflow

1. Call `capabilities` and read command schemas, batch support, revision policy, and limits.
2. `inspect` the target document and capture `revision`.
3. Build a `batch` request with `expected_revision`.
4. Run `batch` with `"dry_run": true`.
5. Inspect diagnostics from the dry run.
6. Commit with the same `expected_revision`.
7. `build` generated scenes when needed.
8. Optionally `render` previews on Linux or a GPU-capable host.

## Example persistent request

```json
{
  "protocol": "uiforge.machine",
  "protocol_version": 1,
  "request_id": "req-001",
  "method": "validate",
  "params": {
    "document": "res://examples/specs/inventory.ui.json"
  }
}
```

## Example atomic batch

```json
{
  "protocol": "uiforge.machine",
  "protocol_version": 1,
  "request_id": "req-002",
  "method": "batch",
  "params": {
    "document": "res://examples/specs/inventory.ui.json",
    "expected_revision": "sha256:…",
    "dry_run": false,
    "operations": [
      {"op": "set", "node": "inventory_title", "property": "properties.text", "value": "\"Inventory\""},
      {"op": "set", "node": "inventory_grid", "property": "properties.columns", "value": 10}
    ]
  }
}
```

## One-shot machine mode

```bash
ui --machine capabilities
ui --machine validate --params /path/to/params.json
```

Human commands such as `ui validate foo.ui.json` remain available and unchanged.
