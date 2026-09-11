# Current host integration contract

Council requires Minerva's TurnRock catalog and bulk snapshot changes for the
full workflow. Feature detection keeps the legacy 64 KiB control route usable
for small records; larger exchanges refuse explicitly on old hosts.

- Document exchanges use `request_bulk` when advertised, with UTF-8 byte counts.
- Documents and protocol commands are bounded at 1 MiB, with room reserved for
  interruption records. The host bulk envelope is 8 MiB; the backend line reader
  permits 16 MiB for nested JSON wrappers and escaping. Per-field limits stay
  32 KiB. No successful change may make the document impossible to reopen.
- Model choices persist the host's opaque `model_spec`. Legacy `model_hint`
  remains readable; explicit structured identity wins over it. Run overrides
  accept either a legacy string or a structured spec. Missing identities refuse
  before a run is created. No service-name tie-break substitutes another model.
- Optional member `generation_options` carries `temperature` and `max_tokens`
  through the host's canonical option resolver; explicit zero is preserved.
- MCP waits are 1–25 seconds, default 20. A timeout of this bounded observation
  does not cancel a running model; subsequent awaits observe the same run.
- An empty, unowned panel may adopt a tool-created document after an atomic
  identity-guarded read. A panel holding another document never adopts it.
- Dispatch commits record the model and time a seat takes its concurrency slot.
  The panel shows queued/running/finished states, elapsed allowance, usage once
  reported, and a Cancel control. A green tab indicator marks active work.

Real-provider and live UX acceptance remain necessary before stable publication.
