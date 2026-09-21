# UIForge V1 Contract

This document defines the single validity contract shared by:

- `schemas/uiforge.schema.json`
- `addons/uiforge/validation/uiforge_validator.gd`
- `scripts/ui_fallback.py`

## Stable IDs

Node IDs must match:

```text
^[A-Za-z][A-Za-z0-9_-]*$
```

Invalid IDs are rejected before mutation commit. Valid IDs must survive Godot `validate_node_name()` unchanged.

## Semantic properties

`properties` objects reject unknown keys with `UNSUPPORTED_PROPERTY`. Native Godot properties belong under `properties.godot_overrides`.

`properties.columns` must be an integer `>= 1`.

## Transactional CLI mutations

All native and fallback mutation commands follow:

```text
load → clone → mutate → validate → save → committed=true
```

Failure at any stage leaves the source document untouched and returns:

```json
{"success": false, "committed": false}
```

Save failure also forces `success: false` and a non-zero exit status.

## Conformance vectors

Adversarial fixtures live under `tests/conformance/`. Python runs them always; Godot-native parity runs the same corpus in CI when Godot is available.
