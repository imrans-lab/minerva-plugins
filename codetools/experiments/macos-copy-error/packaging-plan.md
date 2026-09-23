# CodeTools macOS Copy Error capture

The live prototype captured 20 distinct warnings from Minerva's Godot 4.6.2 debugger, matching the observed Errors (20) tab. Clipboard contents (all materialized pasteboard formats) and prior application focus were restored. No application restart, probe installation, or source edits were needed. This is a laptop-calibrated prototype, not an installed CodeTools feature.

## Integration

- Keep the existing minerva_codetools_inspect operation capture-debugger. Add capture_method: macos to codetools/manifest.json and the Go schema in internal/tools/sightline.go. Do not make auto unexpectedly seize the mouse: require explicit interaction confirmation.
- Add a Python macOS backend alongside worker/codetools_worker/godot_debugger_capture.py. Reuse diagnostics normalization and the existing JSON/text artifact schema. Move common capture logic out of capture_x11 only where both backends need it.
- Keep a small Swift helper's source in codetools. Build it with Apple's SDK in the macOS CI job for arm64/amd64 and include it in each embedded runtime bundle, next to bundled executables. No checked-in helper binary or Swift compiler requirement on user machines.
- Expose permission status before starting. Permission attribution must be verified from the actual Minerva-launched plugin; this trial used Terminal's Accessibility permission. Use stable helper identity/signing for repeat installs. Screen capture permission is needed for screenshot artifacts.
- Add a host confirmation/countdown before UI control, a bounded capture interval, cancellation, and an explicit completion notice. Save and restore clipboard and app focus in a finally path. Abort on focus loss or changed target window. Never restore over unrelated new user clipboard data after cancellation.
- Store this laptop's debugger region calibration in plugin data, keyed to window/display geometry; invalidate after layout/scale changes. Use window coordinates in macOS points, not Retina screenshot pixels. This trial used window 1728x1001 points and screenshots 3456x2002 pixels.
- Identify the active context-menu window and choose Copy Error relative to its actual bounds. Menus shift near the display edge. Wait for menu appearance and a pasteboard change count, rather than relying only on fixed sleeps.
- Scroll the debugger region with an explicitly positioned wheel event: Copy Error selection opens the source script, so PageDown/End can unexpectedly target the script editor. Do not infer the end from repeated warning text; preserve duplicates and report limits.

## Validation before release

Live test from the packaged plugin: permission denied/granted, one warning and one error with a stack trace, a multi-page list, clipboard/focus restoration, and user cancellation. Reuse captured diagnostic text as a parser fixture. The current trial covered 20 warnings; no E-severity entries were present in that Debugger list. Other panels or sessions may contain additional diagnostics.

Prototype sources and captured text are saved beside this plan. Original screenshots remain with the local Minerva capture artifacts. The Python trial scripts contain this laptop's paths and coordinates and require the Swift helper to be compiled; they are evidence/prototype material, not ready-to-ship tools.
