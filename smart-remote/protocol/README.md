# Device <-> plugin protocol

The single authoritative definition of the messages between the remote firmware and the Minerva plugin: JSON control frames plus binary audio frames with a 4-byte header. Both the firmware and plugin tests validate against what lives here.

- `protocol.md` — behaviour: transport, session, audio framing, push-to-talk, replies, picker, choices, error and close codes.
- `provisioning.md` — Bluetooth setup: WiFi credentials, Minerva address and pairing token over Espressif Security 2.
- `schema/` — one JSON Schema (draft 2020-12) per message; `device/` is device→plugin, `plugin/` is plugin→device. Message fields are defined only here.
- `examples/` — JSONL frame sequences. `examples/invalid/` each break one rule and must be rejected.

Check after any change:

```sh
python3 tools/check_examples.py
```

Needs `jsonschema` 4.18 or later. Design: Docket `smart-remote:01a12de97992`; tracking item `smart-remote:01a1322ec02a`.
