# Oscilloscope: Hantek 6022BE

Start with `minerva_oscilloscope_status`. Open the panel with
`minerva_plugin_open_panel plugin_id=oscilloscope`.

Ask which channel is connected and the physical 1×/10× probe switch position.
Set `configure` probe_ch1/probe_ch2 only when confirmed. Defaults display 1×,
explicitly marked unconfirmed. Probe contact and physical attenuation cannot
be detected automatically. For the ESP32 example, CH1 tip goes to the signal
GPIO and its ground clip to board GND.

`run` starts repeated finite captures; `stop` freezes the last capture.
The panel has Scope, Measurements and Settings tabs with a shared LIVE/FROZEN
indicator. Scope keeps frequency and duty cycle above the trace and fills the
available panel height without scrolling. Measurements includes all readings,
quality explanations, capture identity and Save Capture. Settings contains
sampling, trigger, probe factors and Hantek connection information. Switching
tabs preserves acquisition and capture state.
The panel labels this Run / Freeze and retains the waveform and measurement
cards together. Single capture acquires once and leaves the panel frozen.
Click Frequency or Period to mark a measured cycle; click Duty cycle to shade
samples above its midpoint threshold. Cards average all complete cycles, while
the highlight reports one actual cycle. If no complete cycle fits in the preview,
the panel explains why it cannot highlight one. Fit Signal changes display scales
only and stays within the available preview. CH1/CH2 checkboxes control trace and
Scope readout visibility, not acquisition. Measurements still lists both channels.

Measurements include period_us and an optional visible_cycle with zero-based
start_sample/end_sample indices in the full capture and threshold_v. Subtract
preview_start_sample to locate that evidence in preview_v; end_sample marks the
next rising edge. Flat or unreliable timing returns null, with quality reasons.
`capture` acquires once without changing run state. `read` returns measurements
and a capture ID; use preview=true for at most 4096 consecutive samples per
channel, raw=true for full base64 interleaved CH1/CH2 bytes. An id pins a retained
capture (last 16 in memory); expired IDs return errors. `save` writes that capture
to the plugin's user-data directory as JSON and CSV and returns both paths.
CSV includes time, calibrated volts and raw ADC codes. JSON includes settings,
factory zero offsets, conversion scale, raw bytes and quality metadata.

Sampling options: 100000, 200000 (default), 500000, 1000000 samples/s per channel.
Both channels are always acquired, 8192 samples each. BNC range stays ±5 V;
vertical display zoom changes no hardware gain. DC coupling only.

Frequency and duty require at least three consistent rising edges, at least
10 samples per cycle, and a discernible voltage swing. Null is unknown, never
zero. Quality flags identify clipping, irregular/insufficient cycles and
unconfirmed probe factors. Gain is nominal; factory EEPROM zero offsets are
used when valid. No EEPROM writes. 512 settling pairs are discarded after each
ADC restart. Software-triggered alignment and separate captures have gaps;
watches guaranteeing every transient is caught are not supported.

Firmware is loaded into volatile RAM after connection when required. An unknown
already-loaded firmware is rejected: unplug/replug before using this plugin.
Close other scope software to release exclusive USB access. On Linux use the
upstream USB access rules if access is denied.

The panel and tools use the same acquisition state. Status settings describe
future captures; each retained capture keeps the settings actually used for it.
