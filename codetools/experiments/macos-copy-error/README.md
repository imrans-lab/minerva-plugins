# WIP: macOS Godot Copy Error capture

Tracking: minerva-plugins Docket `01a0d052b56a7ff6b7f3e5c42bd13d60`.

Archived proof of concept from the September 23, 2026 live laptop trial. **Not integrated into CodeTools, included in runtime bundles, or ready for unattended use.** Extend this prototype under the existing `minerva_codetools_inspect` / `capture-debugger` operation; see [packaging-plan.md](packaging-plan.md).

## What worked

Godot 4.6.2 on an Apple Silicon Mac: copied 20 distinct warnings from the Debugger Errors (20) list, including exact source lines and available stack details. The captured list contained zero E-severity errors. Raw evidence is in [debugger-capture.txt](debugger-capture.txt); it is a point-in-time observation, not a current project health report. This does not claim coverage of other panels, filters, sessions, or subsequently generated entries.

## Sources

- `mac_capture.swift`: native permission check, foreground PID, input events, and clipboard save/read/restore. Clipboard snapshots retain all materialized formats, not only text.
- `windows.py`: read-only CoreGraphics window discovery using Python ctypes; no PyObjC dependency.
- `capture_rows.py`: archived calibrated row loop. Requires `--allow-ui-control`. **Still contains the trial's temporary helper path, PID, coordinates, timing, and menu-size assumptions.** Updating those is mandatory before another use.
- `scroll.py`: explicitly positioned wheel event from the successful paging experiment; requires `--allow-ui-control`.
- `packaging-plan.md`: integration, build, permissions, interaction, and validation follow-up.

## Interaction contract

Before any clicks, keys, scrolling, or window activation: explicitly warn the user, state the expected hands-off interval, and wait for readiness. Save clipboard and foreground application before capture. Restore them and explicitly announce completion, including on errors or cancellation. The row-loop prototype does NOT perform that orchestration; it was done separately during the trial. Do not run it standalone assuming it cleans up. Avoid restoring old clipboard data over unrelated user edits after interruption.

No UI automation is needed to review or syntax-check these files.

## Build the helper from source

With a matching installed Xcode compiler and SDK:

```sh
xcrun swiftc mac_capture.swift -o /tmp/mac_capture
/tmp/mac_capture status
python3 windows.py
```

The trial used the Swift compiler and MacOSX26.5 SDK inside `/Applications/Xcode.app`, explicitly selected with `-sdk`, because this laptop's default Command Line Tools SDK differed. Do not commit the compiled helper or clipboard snapshots. Accessibility access was granted to Terminal in this trial; permission attribution must be verified again when Minerva launches the packaged plugin.

The `focus` helper command did not reliably activate the application before the short-lived process exited. The successful trial used System Events to set the editor process frontmost and waited before clicking. Preserve this finding when replacing that temporary workaround.

## Calibration findings

Editor: 1728 × 1001 macOS points at (0, 33); screenshot: 3456 × 2002 pixels. Convert Retina pixels to points before sending events. These values are historical, not universal defaults.

Right-click selects the diagnostic and may switch the source script. Keyboard End/PageDown subsequently went to that script, so the trial scrolled using a CoreGraphics wheel event with its location explicitly inside the debugger region. The final page was checked visually before choosing the remaining rows.

Context menus can shift near screen edges. The prototype discovers the popup bounds instead of using a fixed desktop menu location. Short sleeps proved unreliable; production code should poll for the expected menu and clipboard change, abort on focus loss, and enforce a deadline.

## Next work

1. Extract a bounded Mac backend and parameterize project/window identification and laptop calibration.
2. Add permission preflight and the explicit hands-off/completion workflow, with cleanup and cancellation in one orchestrator.
3. Compile and embed the helper from source in macOS runtime bundles; update tool schemas and dispatch without making `auto` unexpectedly seize input.
4. Test through the actual installed plugin, including E-severity errors, stacks, multi-page lists, cancellation, and clipboard/focus restoration.

No plugin release has been produced from this WIP.
