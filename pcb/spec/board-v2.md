# Canonical board schema — shared validation boundary (v1 / v2)

This is the human spec for the canonical PCB board source that the Go codec
(`internal/board`) and the Python compiler (`worker/pcb_worker`) BOTH enforce.
It exists because K3 (DRC/routing) must not consume a v2 board through two
independently drifting validators (item `019f802ca3af`, comment 629). The
executable form of this spec is the committed vector suite in
[`vectors/`](vectors/) — every rule below is pinned by at least one vector that
is asserted **identically** on both sides:

- Go: `internal/board/vectors_test.go` (`UnmarshalYAML` + `board.Validate`)
- Python: `worker/tests/test_board_v2_vectors.py` (`board_validate.validate_board_v2`)

Both suites parametrize over the same directory and both enforce a committed
floor count, so a lost vector or a one-sided rule change turns one suite red.

## Schema versions

| Version | Identity | Notes |
|---|---|---|
| **1** | none | The ordinal-bridge era. Entities have no persistent id; the compiler derives ordinal ids and emits an `ordinal_ids` INFO. Safe only while the result is private to a fabrication emitter, never for identity-dependent consumers (DRC/routing). |
| **2** | mint-once opaque ids | Board + every trace/via/hole carry a persistent `id`. Required before any identity-dependent consumer switches onto the ResolvedBoard IR. |

`version` MUST be the integer `1` or `2`. Any other value — `0`, `3`, a float,
a quoted string, a boolean, or missing — is `unsupported_schema_version`. (The Go
codec additionally rejects a non-integer `version` at unmarshal.)

## Persistent identity (v2)

A minted id is exactly `"<kind>:<32 lowercase hex>"` — a 128-bit crypto-random
mint, **not** a content hash (a trace's geometry mutates under editing; its
identity must survive the edit). The kinds are `board`, `trace`, `via`, `hole`.

On a **v2** board, the board `id` and the `id` of every trace, via, and mounting
hole MUST be a well-formed minted id. Anything else — absent, empty, a legacy
ordinal shape like `trace_1` carried in from a `.minpcb` import, uppercase hex,
or a foreign shape — is `unminted_persistent_id` and fails closed. v1 boards have
no id requirement.

The one-time v1→v2 mint-and-write migration (`board.MigrateV1toV2`, run at
`pcb.deserialize`) assigns these ids and bumps the version; it is idempotent and
re-mints any non-minted id. See `internal/board/migrate.go`.

## Pin geometry authority

The locked footprint is authoritative for a pad's fabrication geometry. A typed
per-pin `override` (`drill_mm`, `annulus_diameter_mm`, `pad_width_mm`,
`pad_height_mm` as numbers; `plated` as a boolean) is the ONLY sanctioned way to
express an intentional deviation. A malformed override field type is
`invalid_pin_override` — the Go codec rejects it structurally at unmarshal (the
fields are typed pointers), and the Python validator, parsing an untyped dict,
re-checks the field types so the same vector is rejected on both sides.

Legacy inline pin fabrication geometry (the same keys on the pin itself, schema
v1) is deprecated. The compiler folds it per-compile: values that match the
footprint are dropped silently; values that diverge raise a deprecation warning
to migrate them into an `override`. Applying a validated override to emitted pad
geometry is deferred emitter work (`019f88a0c84f`) — at this boundary the
override is validated and recorded, and the footprint stays authoritative for
emission.

## Boundary scope (what the vectors can and cannot pin)

The shared boundary is the INTERSECTION of rules both sides enforce:
schema-version dispatch, persistent-id validity, and pin-override field types.
Vectors live in that intersection.

Outside it, the two implementations legitimately differ and no vector may
straddle the difference:

- **Go's codec is a strict superset.** `UnmarshalYAML` rejects a source whose
  field TYPES don't decode (`width_mm: twenty`, `x_mm: 'one'`) — the Python
  schema validator doesn't inspect those fields, so it would call them valid. A
  malformed field type is a Go error and simply is not expressed as a vector.
- **Parser-level differences are documented, not vectored.** A whole-float
  version (`2.0`) coerces to int in yaml.v3, so the Go codec rejects it
  explicitly (see above) to match Python. A duplicate mapping key errors in
  yaml.v3 but is last-wins in PyYAML; a `null` list item is dropped by yaml.v3
  and is skipped by the Python validator to match. These are properties of the
  parsers, kept aligned in code, not asserted as vectors.

## Adding a vector

Create `vectors/<NNN-name>/` with `input.yaml` (a board source) and `expect.json`
(`{"valid": true}` or `{"valid": false, "code": "<shared code>"}`). It runs on
both sides automatically. Bump the `minVectors` / `_MIN_VECTORS` floor in both
test files when you add one.
