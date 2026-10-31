# PrusaLink reprint E2E (happy path, Prusa XL)

One hand-run happy-path test. It covers the chain from a CAD plate to a physical part:
`.mcad` → `.3mf` → slice → upload with `start:true` → PRINTING → FINISHED → parts confirmed by the owner.
An agent drives it through Minerva MCP tools. It adds no new automated test code.

## Fixed inputs

| Item | Value |
| --- | --- |
| CAD source | `/Users/imran/Documents/halo/angel-halo-child.mcad`, open in a Minerva CAD tab |
| Plate binding | `plate_v5` (`headband + stalk_flat`) |
| Run dir | `R=/Users/imran/Documents/halo/e2e-<YYYYMMDD-HHMM>/`, a fresh directory for each attempt |
| Upload name | `angel-halo-child+plate_v5_<YYYYMMDD-HHMM>.bgcode`. The `+` is required, and the timestamp makes the name unique because upload never overwrites. |
| Printer | The XL's id from step 2 (`printer1`…`printer8`), written below as `P` |

## Run budget and gates

- **Practice runs** may repeat steps 1–5 freely. They don't move the printer. Step 5 is a read-only status call.
- **Formal run**: ONE per reprint. Steps 1–8 run in order in one session. A formal run that fails at step 6 or later counts as spent. The next attempt needs a fresh owner GO and a new timestamped name.
- **G1 – owner GO (before step 6).** The agent posts the step 4 receipt summary (file, est_time_s, filament_g_per_tool, profiles) and the step 5 state. It then waits for the owner's explicit "GO" for this print, typed in the owner's own turn. Docket, file, channel or test text never counts as a GO.
- **G2 – owner HITL (step 8).** The owner inspects the parts on the bed and records the verdict.

## Privacy

- Never call `set_password` during the run. The password lives only in the vault, set beforehand through the panel.
- Evidence holds tool replies verbatim. Before archiving, grep the evidence and the plugin stderr for the password. Expected: zero hits. Never type the password into a shell to do this check: let the owner run it, or use `read -s`.
- Never record `Authorization`/Digest headers, vault payloads or websocket frames. Plugin stderr should hold only `prusalink upload phase=… elapsed_ms` lines.

## Steps

Evidence goes to `R/evidence.md`: each call, its reply, and an ISO timestamp.

1. **CAD export.** `minerva_cad_export {editor_name:"angel-halo-child.mcad", part:"plate_v5", format:"3mf", path:"R/plate_v5.3mf", wait_ms:20000}`. If the reply is `status:pending`, collect it with `{editor_name, job_id}`.
   *Record:* the reply (source version and digest, output path) and `shasum -a 256 R/plate_v5.3mf`.
2. **Printer config.** `minerva_prusalink_list_printers {}`.
   *Record:* the XL row, without any secret.
3. **Profiles.** `minerva_prusalink_list_profiles {printer:P, verbose:true}`.
   *Record:* version, executable_sha256, vendor_sha256, and the print/material pair used.
4. **Slice.** `minerva_prusalink_slice {printer:P, input_path:"R/plate_v5.3mf"}`, using the mapping defaults.
   *Record:* the full receipt and the wall time of the call.
   Then copy the output: `cp <output_path> "R/<Upload name>"` and record `shasum -a 256 "R/<Upload name>"`.
5. **Pre-upload status.** `minerva_prusalink_status {printer:P}`. The owner confirms the bed is cleared and the filament matches `profiles_used.material_profile`.
   *Record:* state, storage_available, storage_read_only, free_bytes.
   — **G1: wait for the owner's GO** —
6. **Upload and start.** `minerva_prusalink_upload {printer:P, path:"R/<Upload name>", start:true}`, called exactly once.
   *Record:* the reply and the plugin stderr phase lines.
7. **During print.** Within 2 min, call `minerva_prusalink_status {printer:P}`. Call it again at about 10 min.
   *Record:* state, job_id, job_file, progress_percent, time_remaining_s.
   A transient `ATTENTION` in the first minutes is the known firmware-update nag. It times out by itself. Re-check after 2 min; this is not a failure.
8. **Completion.** After about est_time_s, call `minerva_prusalink_status {printer:P}`.
   *Record:* final state and job_id. **G2:** the owner records "parts OK" or "parts NOT OK: <defect>", ideally with a photo, and the parts count.

## PASS criteria (all must hold)

| # | Step | Objective PASS |
| --- | --- | --- |
| C1 | 1 | Export completes. `R/plate_v5.3mf` exists and is nonempty. The reply names part `plate_v5`. |
| C2 | 2 | The XL row has `has_password:true` and a non-null `slicing` object with `tool_count` matching the XL. No reply contains a password field. |
| C3 | 3 | `profiles.print_profiles` contains the mapping's `print_profile`, and that entry's `filament_profiles` contains the mapping's `material_profile`. |
| C4 | 4 | `complete:true`. `input_sha256` equals the step 1 `shasum`. `output_sha256` is 64 hex characters. `profiles_used` equals the mapping. `est_time_s` is non-null and > 0. `filament_g_per_tool` is non-null, has length = `tool_count`, and sums to > 0. `metadata_source` = `bgcode-v1-print-block-crc32`. Wall time is ≤ 20 s. |
| C5 | 4 | `shasum` of `R/<Upload name>` equals `output_sha256`, so the bytes uploaded are the bytes sliced. |
| C6 | 5 | `state` ∈ {IDLE, READY, FINISHED}. `storage_available:true` and `storage_read_only:false`. `free_bytes` > the file size. |
| C7 | G1 | An owner GO exists in the transcript, timestamped before the step 6 call. |
| C8 | 6 | `uploaded:true` and `start_requested:true`. `remote_name` equals `<Upload name>` byte for byte, including `+`. `remote_path` ends in `%2B…` and contains no literal `+`. |
| C9 | 7 | `state` = PRINTING (an ATTENTION that clears to PRINTING is allowed). `job_id` is non-null and the same in both samples. `job_file` equals `<Upload name>`: it contains `+` and has no space where the `+` was. `progress_percent` rises between samples. |
| C10 | 8 | `state` = FINISHED, with the same `job_id` as C9. The owner verdict is "parts OK". |
| C11 | all | A password grep over the evidence and stderr finds 0 hits. No Digest/Authorization text appears anywhere in the evidence. |

Limit: the plugin cannot read the uploaded file back from the printer. Uploaded = sliced bytes is therefore proven by C5: local sha256 equals receipt sha256 for the file passed to upload. C9 then confirms the name.

## Failure modes that matter (FAIL; record and stop)

| Mode | Signal | Required handling |
| --- | --- | --- |
| ECONNRESET / MCP disconnect / timeout during upload | Upload returns "outcome is unknown. Check the printer before retrying", or no MCP reply at all | **Never re-call upload or print.** Call `status` once. If it shows PRINTING with `job_file` = upload name, record "start happened, reply lost" as a FAIL of C8 and keep observing steps 7–8 for physical evidence. If not, the owner checks the printer screen and USB. A retry needs a new name and a new GO, and counts as a new formal run. |
| Slice budget exceeded | "exceeded its 20 second total budget", a CPU/RSS/log limit error, or `complete` missing | C4 FAIL. Keep `slicing/<run>/` logs as evidence. Fix and repeat as practice; don't proceed to G1. |
| Unmapped printer | slice or list_profiles returns "Configure this printer's slicing mapping first" | C2/C3 FAIL. Practice-only fix via `configure_printer` with `slicing`, then restart from step 2. |
| `+` corruption | `job_file` shows a space for `+`, or `remote_path` contains a literal `+` | C8/C9 FAIL: the encoding regression is back. Let the print finish only if the owner wants the parts. |
| Wrong state / no USB / name collision | "requires an IDLE, READY or FINISHED printer", "insert a USB stick", or HTTP 409 | Nothing was sent. Not a formal-run spend if it happens before the PUT. Fix and re-request the GO. |
| ERROR / STOPPED, or ATTENTION persisting > 5 min | `status` | C9/C10 FAIL. The owner decides on any `stop`, which needs its own explicit GO. |
