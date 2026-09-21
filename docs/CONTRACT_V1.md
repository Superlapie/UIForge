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

Before save, the native and fallback engines compare the loaded document revision hash against the current source file. A mismatch returns `WRITE_CONFLICT` with `committed: false` and leaves the newer source untouched.

## Output policy

Machine-facing writes default to the project workspace:

| Command | Extension | Default destination |
|---------|-----------|---------------------|
| `new` | `.ui.json` | caller path inside project |
| `build` | `.tscn` | sibling of source unless overridden |
| `render` / diff | `.png` | `.uiforge/renders/` |

Relative paths such as `examples/scenes/foo.tscn` resolve under the project root. Paths outside the workspace return `OUTPUT_OUTSIDE_WORKSPACE` unless `--allow-outside-project` is supplied. Wrong extensions return `OUTPUT_EXTENSION_INVALID`.

## Generated artifact provenance

Generated `.tscn` files begin with a machine-readable header:

```text
; UIFORGE_GENERATED_V1
; uiforge_source: res://path/to/source.ui.json
; uiforge_source_hash: sha256:...
; uiforge_generator: uiforge/0.1.0
; uiforge_schema: 1
```

Build behavior:

- missing output → create
- existing UIForge artifact from the same source/hash → replace
- existing UIForge artifact from another source → `OUTPUT_SOURCE_MISMATCH`
- existing non-UIForge file → `OUTPUT_NOT_UIFORGE_GENERATED`
- `--force` overrides the replace protections

`ui new` is create-only by default; existing `.ui.json` files require `--force`.

Writes use sibling unique temp files, read-back verification for generated scenes, and atomic replacement. Source saves use pending/backup recovery for interrupted transactions.

## Theme and metadata safety

Unknown document themes return `THEME_NOT_FOUND`. Malformed `theme_overrides` and `components` shapes return structured errors instead of runtime/type failures.

Authored node metadata keys must be Godot-safe identifiers and cannot use the reserved `uiforge_*` or legacy `aether_*` namespaces. Generated scenes emit only `metadata/uiforge_*`.

## Conformance vectors

Adversarial fixtures live under `tests/conformance/fixtures/`.

- Portable CI runs `tests/test_conformance.py` against `scripts/ui_fallback.py`.
- Native CI runs `tests/conformance_runner.gd`, which validates the same manifest through both `UIForgeValidator` and `scripts/ui validate`.

## Known intentional differences

- Resource existence checks (`RESOURCE_NOT_FOUND`) require Godot resource loading or filesystem access and may differ when assets are absent in a bare checkout.
- PNG rendering is native-only; the fallback returns `GODOT_UNAVAILABLE`.
- Native/fallback compiler semantic snapshot parity is not yet enforced in CI; portable and native validators/build policy are shared.
- Runtime and editor code may still read legacy `aether_*` metadata or drag payloads for compatibility with scenes generated before the UIForge ABI migration.
