# Device <-> plugin protocol

Owned here in minerva-plugins at `smart-remote/protocol/`. The ccsandbox copy is a retained migration snapshot, not a second protocol owner. Run `../scripts/check-protocol-sync.sh /path/to/ccsandbox/smart-remote-v2/protocol` after changes; synchronize the snapshot before firmware integration. The check compares every contract file, ignores only this repository ownership README and generated Python caches, and explicitly verifies the exact pinned owner-approved STT/TTS wording amendment in `../scripts/protocol-owner-amendment.json`.

The single authoritative definition of the messages between the remote firmware and the Minerva plugin: JSON control frames plus binary audio frames with a 4-byte header. Both the firmware and plugin tests validate against what lives here.

- `protocol.md` — behaviour: transport, session, audio framing, push-to-talk, replies, picker, choices, error and close codes.
- `provisioning.md` — Bluetooth setup: WiFi credentials, Minerva address and pairing token over Espressif Security 2.
- `schema/` — one JSON Schema (draft 2020-12) per message; `device/` is device→plugin, `plugin/` is plugin→device. Message fields are defined only here.
- `examples/` — JSONL frame sequences. `examples/invalid/` each break one rule that a conforming **sender** never breaks; `tools/check_examples.py` must reject every one. A receiver still follows `protocol.md`, which is tolerant in places (an early `ptt_up` counts as EOS; an unannounced audio stream is dropped).

Check after any change:

```sh
python3 tools/check_examples.py
```

Needs `jsonschema` 4.18 or later. Design: Docket `smart-remote:01a12de97992`; tracking item `smart-remote:01a1322ec02a`.
