# Oscilloscope MCP 0.2 — Hantek 6022BE

Use `minerva_oscilloscope_capture {}` for a fresh, compact measurement. It waits
for acquisition and pins the result. Default summary has no waveform arrays.
Do not call run then read just to obtain one measurement. `run` is for continuous
acquisition and now returns only after a fresh capture succeeds.

## Evidence workflow

1. `capture {"channels":[1]}` → capture ID, named channel measurements, immutable
   settings, quality flags and retention. Both channels are physically acquired.
2. `evaluate {"id":"…","checks":[{"channel":1,"metric":"duty_percent",
   "target":50,"tolerance":{"kind":"absolute","value":5}}]}` → pass, fail or
   inconclusive with measured values and inclusive bounds. Duty tolerance is in
   percentage points; relative_percent is a percentage of the target magnitude.
3. `show_capture {"id":"…","channel":1,"highlight":"high"}` → stops live
   acquisition and selects this exact waveform on the shared Scope page.
4. `save {"id":"…"}` → JSON/CSV paths, or `retain {"id":"…","action":"release"}`
   when discussion of the evidence is complete. Saved files persist; pins do not.

At most 8 unique pinned captures survive live-ring eviction; the unpinned live
ring holds 16. A full pin set rejects capture before USB access. Use pin:false
for transient captures, and status(include:["retention"]) to list pins. Pins are
lost on backend restart. The displayed frozen capture has its own reference;
releasing a pin cannot remove it from the panel. No silent fallback for an
explicit unavailable ID. Capture IDs include a random backend-session prefix.

`read` is read-only; default is latest summary. detail:"preview" adds up to 4096
consecutive voltage samples per selected channel. detail:"raw" returns base 64
interleaved CH1/CH2 ADC bytes, irrespective of output channel filtering. Metadata
includes preview start/stride, sample rate/count, duration_us, zero offsets and
scale. Each channels[] record names its channel and measurement; period_us and
visible_cycle start_sample/end_sample/threshold_v provide timing evidence.
The cycle end marks the next rising edge. Subtract preview_start_sample to locate
these absolute sample indices in the preview. Legacy preview/raw boolean flags
remain supported on read, but cannot be combined with detail.

## State and configuration

`status` is compact and read-only. include:["capabilities","retention","display"]
adds device limits/identity, pin IDs and display/panel telemetry. display_revision
is exposed as display.revision. `panel_sync` is for the panel to report the capture,
revision, page and viewport it applied; telemetry is not proof a human saw it.
`show_capture` selects evidence even if the panel is closed. Open it via
`minerva_plugin_open_panel plugin_id=oscilloscope`; no tool claims confirmed
rendering. Highlight unavailable means no valid complete cycle in the preview.

`stop` means Freeze; repeated calls retain an already selected older capture.
`run` returns the display to live and clears the explicit selection. Single
capture preserves Run/Freeze state; while frozen, it selects the new capture.
Panel tabs share state. Measurements has independently collapsible CH1/CH2 cards
(CH1 initially open); Settings cards start closed. Scope fills available height.
Expanded card bodies may scroll when many cards are opened in a small viewport;
headers and page controls remain accessible.

`configure` changes persistent settings atomically. Sample rates are 100000,
200000, 500000, 1000000; software rising-edge trigger channel is 1 or 2. A capture's
optional settings:{sample_rate_hz,trigger_channel} affects only that acquisition.
Each capture records its actual settings and the base persistent revision.

Ask the user which channel and physical 1×/10× probe switch position they use.
`configure {"probes":[{"channel":1,"ratio":10,"confirmed":true}]}` records an
explicit confirmation. A ratio change clears confirmation unless explicitly
provided; confirmed:false clears it. Legacy probe_ch1/probe_ch2 set ratios only,
not confirmation. Never mark a switch confirmed based on the apparent voltage.
Frozen evidence keeps its original probe factor and confirmation.

## Limits, quality and errors

Hardware fixed range ±5 V at BNC, DC coupling, 8192 samples/channel. Both channels
are always acquired. 512 startup pairs are discarded. Display scales change no
hardware gain. Factory EEPROM zero offsets are used when available; gain remains
nominal. Captures have gaps: no guarantee of catching every glitch. Firmware is
loaded into volatile RAM only; no EEPROM writes. Only one program can own USB.
Linux may require upstream USB access rules. Tip→signal GPIO, ground→board GND.

Unknown timing is null with reasons (flat, too few cycles/samples, irregular
period), not 0 Hz. Evaluate treats invalid timing as inconclusive. Unconfirmed
attenuation or clipping makes voltage checks inconclusive, without invalidating
otherwise valid timing. Overall verdict is fail if any check fails, otherwise
inconclusive if any check is inconclusive, else pass. Bounds use six decimal
places; target magnitude/resolved bounds <=1e 12, tolerance 0..1e 6, 1..32 checks.
Relative tolerance around zero is rejected. Saved JSON preserves full evidence.

Failures have success:false, error:{code,message,retryable,suggested_action} and
MCP isError:true. Quality limitations on successful captures are not tool errors.
Codes include INVALID_ARGUMENT, DEVICE_NOT_FOUND, DEVICE_BUSY, PERMISSION_DENIED,
UNSUPPORTED_FIRMWARE, ACQUISITION_TIMEOUT, USB_DISCONNECTED, USB_ERROR, NO_CAPTURE,
CAPTURE_EXPIRED, PIN_LIMIT and SAVE_FAILED. Follow suggested_action; avoid blind
retries. Unknown loaded firmware requires unplug/replug.

Acquisition timeout_ms defaults 8000, allowed 100..15000. USB controls and reads
honor the remaining deadline; native USB discovery/close and waiting for an
in-flight operation can extend cleanup beyond it. A timed-out run stays stopped
and cannot start later. Read-only state access does not hold the USB lock.
