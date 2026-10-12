# smart-remote-v2 ↔ Minerva plugin protocol, version 1

Design: Docket `smart-remote:01a12de97992`; tracking item `smart-remote:01a1322ec02a`.
Message fields are defined only in `schema/`; this document defines behaviour. `examples/` are checked against the schemas by `tools/check_examples.py`.

## Transport

- WebSocket (RFC 6455), plain `ws://` on the local network. Path `/remote/v1`.
- The plugin advertises mDNS service `_minerva-remote._tcp` with TXT `proto=1`. The device connects to the address stored at BLE provisioning first and falls back to mDNS.
- **Text frames** carry exactly one JSON control message (UTF-8 object with a `type` field). Device→plugin text frames are at most 4 KiB; plugin→device at most 8 KiB.
- No JSON string or property name may contain U+0000, raw or escaped as `\u0000`. Embedded C parsers cannot represent it and the OLED cannot render it, so the plugin removes it from any text it sends (draft, reply, chat names, choices) and a receiver rejects a message containing it as `bad_message`.
- JSON nesting depth is at most 8.
- **Binary frames** carry audio (below). Nothing else is sent as binary.
- Keepalive: the plugin sends a WebSocket ping every 15 s. Either side treats 45 s without any frame as a dead link and closes.

## Session

1. Device connects and sends `hello` within 5 s. Anything else first closes with 4002.
2. Plugin replies `welcome` (then `target`) or closes:
   - 4001 bad or unknown token, after sending `error{code:"auth"}`;
   - 4003 unsupported `proto`, after sending `error{code:"proto_version"}`.
3. One live connection per `device_id`; a newer `hello` from the same device closes the older socket with 4004.
4. Switching to Mouse mode: device sends `mode{mode:"mouse"}` and closes with 1000. The plugin cancels any in-flight transcription and drops pending speech; replies stay in Minerva.
5. After deep sleep the device reconnects and repeats `hello`. The plugin keeps the last target and draft for that `device_id`, so the device needs no local copy beyond the OLED.

Any message that fails its schema closes with 4002 after `error{code:"bad_message"}`. Unknown `type` values are protocol violations, not ignorable.

## Audio frames (owner ruling: 4-byte header)

Every binary frame is a 4-byte header followed by PCM:

| Byte | Meaning |
|---|---|
| 0 | bits 0–3: kind (`1` = mic, device→plugin; `2` = speaker, plugin→device). bits 4–6: reserved, must be 0. bit 7: end-of-stream (EOS). |
| 1 | stream id, `u8`. Mic: chosen by the device and announced in `ptt_down`. Speaker: chosen by the plugin and announced in `speak`. |
| 2–3 | sequence, `u16` little-endian, `0` for the first frame of a stream, +1 per frame, wraps at 65535. |

- Payload: signed 16-bit little-endian mono PCM at 16 000 Hz. Length is even and at most 4096 bytes (128 ms). 20–100 ms per frame is recommended.
- The last frame of every stream has EOS set; its payload may be empty.
- A receiver drops frames whose stream id is not the current stream for that kind. A sequence gap is reported as `error{code:"audio_gap"}` (device→plugin direction only) and the stream continues; WebSocket is reliable, so a gap means a sender bug.
- A frame with a reserved bit set or an unknown kind is a protocol violation (close 4002).

## Push-to-talk (Stream Deck semantics)

1. Device sends `ptt_down{stream}`, starts the mic, and streams mic frames on that stream id.
2. Plugin locks the current target for this turn and its reply, opens speech-to-text, and sends `mic_state{state:"recording"}`.
3. On release the device sends the final mic frame with EOS, then `ptt_up{stream}`. The plugin finalises on EOS; if `ptt_up` arrives first, it treats it as EOS.
4. Plugin sends `mic_state{state:"transcribing"}`, then appends the transcript to the draft, sends `draft{text}` with the whole draft, and `mic_state{state:"idle"}`. On failure: `mic_state{state:"error", detail}`, draft unchanged.
5. Each PTT appends; `clear` empties the draft (`draft{text:""}` echoes it); `send` submits the draft to the target chat.
   - `send` with an empty draft is refused with `error{code:"empty_draft"}`.
   - If the target changed since the turn locked it, the plugin refuses with `error{code:"target_changed"}` and keeps the draft, rather than posting to the wrong chat.
6. Recording longer than 300 s is cut by the plugin: it stops reading frames, sends `mic_state{state:"error", detail:"too_long"}`, and transcribes nothing.

`ptt_down` while a previous stream is still transcribing is refused with `error{code:"busy"}`.

## Replies and speech

- When the assistant finishes a turn the remote sent, the plugin sends `reply{chat_id, text, outcome}`, then `speak{stream, chat_id}` followed by speaker frames ending in EOS. Replies to turns the remote did not send are never spoken.
- The plugin paces speaker frames at real time with at most 1 s lead, so the device needs no flow control beyond its playback buffer.
- **Half duplex:** the device mutes the mic while playing. `ptt_down` during playback stops playback immediately on the device. On `ptt_down` the plugin ends the current speaker stream with an empty EOS frame and never resumes it.

## Target and chat picker

- Phase 1 follows focus: the plugin sends `target` whenever Minerva's visible chat changes and no turn is locked, and once after `welcome`. `target{chat_id:null}` means no chat is open; `send` is then refused with `error{code:"no_target"}`.
- Opening the picker: the device sends `picker_open`. The firmware recognises the long press (600 ms on the Send/confirm button) and **never sends `send` for a press that became a long press**. Plugin replies `chat_list{level:"groups"}`.
- Choosing a group: the device sends `picker_list{group_id}`; the plugin replies `chat_list{level:"chats"}`, most recent first.
- Choosing a chat: the device sends `target_set{chat_id}`; the plugin replies `target`. It fails with `error{code:"unknown_chat"}` if the chat is gone.
- **Back is local:** Back (chats → groups → close) is handled entirely on the device from the lists it already has; it sends nothing. Closing the picker without choosing sends nothing either.
- Lists are capped at 50 entries; `truncated:true` marks a cut list.

## Agent choices

- `choices{choice_id, prompt, items}` asks the remote to show a pick-one list; joystick moves, the confirm button picks.
- The device answers `choice_pick{choice_id, index}`. The plugin then sends `choices_closed{choice_id, reason:"picked"}`; on timeout or cancellation from the agent side it sends `reason:"timeout"` or `"cancelled"` and the device dismisses the list.
- Only one choice is open at a time; a new `choices` replaces the old one, and the plugin closes the old one with `reason:"replaced"`.

## Display

- `draft{text}` is always the whole draft, never a delta.
- `status{text}` is a short transient line (for example "Sent"), shown until the next status or draft.
- `reply` text is shown scrollable; the device wraps it to the OLED.

## Error codes

`auth`, `proto_version`, `bad_message`, `busy`, `empty_draft`, `no_target`, `target_changed`, `unknown_chat`, `stt_failed`, `tts_failed`, `send_failed`, `audio_gap`, `internal`. `error.message` is human-readable and may be shown on the OLED.

## Close codes

| Code | Meaning |
|---|---|
| 1000 | normal (Mouse mode, sleep) |
| 4001 | authentication failed |
| 4002 | protocol violation |
| 4003 | unsupported protocol version |
| 4004 | replaced by a newer connection from the same device |
