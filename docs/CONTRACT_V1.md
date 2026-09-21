# UIForge V1 Contract

This document describes the shared validity contract implemented by:

- `schemas/uiforge.schema.json`
- `addons/uiforge/validation/uiforge_validator.gd`
- `scripts/ui_fallback.py`

JSON Schema, runtime validation, and CLI behavior are kept aligned through the shared corpus in `tests/conformance/manifest.json`.

## Stable IDs

Node IDs must match:

```text
^[A-Za-z][A-Za-z0-9_-]*$
```

Document names must match:

```text
^[A-Za-z0-9_-]+$
```

Invalid IDs and document names are rejected before persistence. Valid IDs must survive Godot `validate_node_name()` unchanged.

## Semantic properties

`properties` objects reject unknown keys with `UNSUPPORTED_PROPERTY`. Native Godot properties belong under `properties.godot_overrides`.

`properties.columns` must be a positive integer (`>= 1`), not a float.

Node and layout objects reject unknown keys with `UNKNOWN_NODE_KEY` and `UNKNOWN_LAYOUT_KEY`.

## Transactional CLI commands

`new`, `set`, `add`, `delete`, `move`, and `duplicate` follow:

```text
create or load → clone → mutate or assemble → validate → save → committed=true
```

Failure at any stage leaves the source document untouched and returns:

```json
{"success": false, "committed": false}
```

Save failure also forces `success: false` and a non-zero exit status. Filesystem failures must return structured JSON, never a traceback.

## Conformance vectors

Adversarial fixtures live under `tests/conformance/fixtures/`.

- Portable CI runs `tests/test_conformance.py` against `scripts/ui_fallback.py`.
- Native CI runs `tests/conformance_runner.gd`, which validates the same manifest through both `UIForgeValidator` and `scripts/ui validate`.

## Known intentional differences

- Resource existence checks (`RESOURCE_NOT_FOUND`) require Godot resource loading or filesystem access and may differ when assets are absent in a bare checkout.
- PNG rendering is native-only; the fallback returns `GODOT_UNAVAILABLE`.
