# Oscilloscope

Hantek 6022BE USB oscilloscope for Minerva. Go/libusb acquisition backend,
HTML Canvas panel, and eleven MCP tools shared by people and agents.

Supported acquisition: two channels at 100/200/500 kS/s or 1 MS/s, ±5 V BNC range,
software rising-edge alignment, Run/Freeze/Single, probe factors, frequency,
duty cycle, period, clickable cycle/high-time annotations, voltage statistics, cursor inspection and capture JSON/CSV export.
Actual throughput is host-dependent. Acquisitions are separate, with gaps.

## Build and marketplace package

Prerequisites: Go 1.25+, C compiler, pkg-config, autoconf, automake, libtool,
make and SDCC. On macOS: `brew install go pkgconf autoconf automake libtool sdcc`.
On Linux install those development tools through the distribution package manager.

```
python3 scripts/package.py --target macos-universal
# or, on an x86-64 Linux build host:
python3 scripts/package.py --target linux-x86_64
```

The script builds pinned libusb and firmware sources, bundles dependencies and
corresponding sources/licenses, and produces `dist/oscilloscope-0.2.0-<target>.tar.gz`
with SHA256SUMS. Install this URL with `minerva_plugin_marketplace_install`,
then start `oscilloscope` and open `oscilloscope_panel`. A public registry entry
must only be generated after the corresponding release assets exist.
No developer tools or Python runtime are needed by the installed plugin.
Linux device access may require the USB rules in the bundled firmware sources.
Windows packaging is not provided in this increment.

## Development and verification

`GOWORK=off go test -race ./...` and `GOWORK=off go vet ./...` (libusb development
headers required). The package smoke test performs MCP initialization without
opening USB. Hardware opens only for Run or Capture. To run an unpackaged binary,
put source-built `firmware/dso6022be.hex` alongside it.

Acceptance: a real ESP32 signal on CH1; read capture measurements via MCP and
inspect the same waveform in the panel. Probe attenuation must be confirmed.
The device can be owned by only one acquisition process at a time.

Tracked work: plugins.dct `01a0d6e641f17f938f8bf94903a01076`.

## MCP 0.2

Capture defaults to compact named-channel measurements and pins the evidence
until release or backend restart (8-pin limit). `retain`, `evaluate` and
`show_capture` let agents keep evidence, check explicit tolerances and select
the same frozen trace for people. `panel_sync` reports panel state and viewport.
Run waits for a successful fresh capture. Errors have stable codes and recovery
actions. Probe scaling and physical-switch confirmation are separate.
See help.md for the complete contract and migration from 0.1.
