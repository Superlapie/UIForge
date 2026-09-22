# UIForge Machine Protocol

## Protocol identifier

- `protocol`: `uiforge.machine`
- `protocol_version`: `1` (also accepts JSON `1.0`; must be a finite integer-valued JSON number matching a supported version)
- `command_contract_version`: `1`

Document schema version remains independent (`schema_version` in `.ui.json` files).

## Request envelope

```json
{
  "protocol": "uiforge.machine",
  "protocol_version": 1,
  "request_id": "req-123",
  "method": "validate",
  "params": {}
}
```

## Response envelope

Success:

```json
{
  "protocol": "uiforge.machine",
  "protocol_version": 1,
  "request_id": "req-123",
  "success": true,
  "result": {},
  "diagnostics": [],
  "meta": {
    "backend": "godot-native",
    "schema_version": 1,
    "command_contract_version": 1
  }
}
```

Failure uses the same envelope with `success: false` and an `error` object `{ "code", "message" }`.

## Transports

| Transport | Entry | Output |
|---|---|---|
| Human CLI | `ui validate doc.ui.json` | Legacy indented JSON |
| One-shot machine | `ui --machine validate` | Single JSON object |
| Native framed | Godot emits `UIFORGE_MACHINE_V1\t{...}` | Wrapper extracts one frame |
| Persistent stdio | `ui serve --stdio` | JSONL, one response per line |

Diagnostics and logs belong on stderr. Public machine stdout is response-only.

## Methods

Core methods: `capabilities`, `validate`, `inspect`, `get`, `set`, `add`, `delete`, `move`, `duplicate`, `batch`, `build`, `build-all`, `render`, `shutdown`.

## Batch semantics

- Load once, clone once, apply operations sequentially.
- Stop on first failed operation.
- Validate full document before commit.
- Commit once through existing optimistic source transactions.
- `dry_run: true` performs all checks without writing.
- Failed batches leave zero partial writes.

## Optimistic concurrency

Read methods include `revision`. Mutations and batches accept `expected_revision`. Mismatch returns `REVISION_CONFLICT`.

## Exit codes

| Code | Meaning |
|---:|---|
| 0 | Success |
| 2 | CLI usage / malformed protocol request |
| 3 | Validation / semantic command failure |
| 4 | Optimistic concurrency / write conflict |
| 5 | Filesystem / trust / IO failure |
| 70 | Internal UIForge failure |

Persistent mode keeps serving after a failed request.

## Request limits

Maximum request size: `1048576` bytes (`max_request_bytes` in capabilities).

## Compatibility

Machine protocol changes require explicit protocol version consideration. Human CLI syntax remains backward compatible.
