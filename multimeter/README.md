# MultiMeter plugin

Reads an OWON B41T+ digital multimeter over Bluetooth Low Energy and exposes it to
Minerva as tools (`minerva_multimeter_*`), a `multimeter.reading` event stream, and
plugin state. Pure Go on `tinygo.org/x/bluetooth`: one static binary, no runtime.

## Docs for agents

`help.md` is the complete diagnose flow for an agent that knows nothing but
Minerva's tool list; Minerva returns it verbatim from
`minerva_plugin_help id=multimeter`, and every tool description points there.
The `minerva_multimeter_diagnose` skill in `manifest.json` carries the same
flow for Minerva's own chats. Change them together.

## Protocol

Service `0xFFF0`. `0xFFF4` notifies one 6-byte packet per reading; `0xFFF3` takes
button presses as a little-endian uint16 (`0x0100|code` tap, bare `code` hold).
The decode is in `decode.go`, with live captures in `decode_test.go`.

## Build and test

```
go build -o multimeter-plugin .
go test ./...
MULTIMETER_NO_BLE=1 python3 ../scripts/smoke/mcp_smoke.py ./multimeter-plugin
```

macOS builds need cgo (CoreBluetooth). The packaged Minerva app must declare
Bluetooth usage in its Info.plist; the Godot editor prompts on its own.
