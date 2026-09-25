# Oscilloscope: Hantek 6022BE

Start with `minerva_oscilloscope_status`. Open the panel with
`minerva_plugin_open_panel plugin_id=oscilloscope`.

Ask which channel is connected and the physical 1×/10× probe switch position.
Set `configure` probe_ch1/probe_ch2 only when confirmed. Defaults display 1×,
explicitly marked unconfirmed. Probe contact and physical attenuation cannot
be detected automatically. For the ESP32 example, CH1 tip goes to the signal
GPIO and its ground clip to board GND.

`run` starts repeated finite captures; `stop` freezes the last capture.
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
