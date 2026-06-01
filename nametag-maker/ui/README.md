# nametag-maker UI panel

`nametag_panel.html` is a **single self-contained HTML file** (inline CSS + JS, no
sibling assets) — per the Minerva Plugin Developer Guide §2.5. The host probes
`ui/<panel_name>.html` then `ui/panel.html` and ignores the manifest `entry`, so the
file is named to match the panel `name` (`nametag_panel`).

## Vendored PDF.js (provenance)

The PDF preview uses Mozilla **PDF.js**, vendored **inline** as JavaScript source
(no compiled binary committed):

- **Version:** 3.11.174
- **Build:** legacy UMD distribution (`legacy/build/pdf.min.js` +
  `legacy/build/pdf.worker.min.js`)
- **Source:** `https://cdn.jsdelivr.net/npm/pdfjs-dist@3.11.174/legacy/build/`
  (npm package `pdfjs-dist`)
- **License:** Apache-2.0 (Copyright Mozilla Foundation)

### Why legacy UMD + a Blob-URL worker

- The **legacy UMD** build exposes `window.pdfjsLib` as a global and avoids ESM /
  top-level-await features that misbehave under WebKit — the panel must render under
  BOTH godot-cef (Chromium) and godot_wry (WebKit). It does not rely on native
  `<embed>` PDF rendering; every page is drawn to a stacked `<canvas>`.
- Because the panel is one file with no served siblings, the worker cannot be loaded
  from a path. The worker source is parked in a
  `<script type="text/plain" id="pdfWorkerSource">` island (raw, not executed) and
  wired at init via:
  `GlobalWorkerOptions.workerSrc = URL.createObjectURL(new Blob([source], {type:'application/javascript'}))`.
- No runtime network access: the worker has no `importScripts`, the PDFs embed their
  own fonts (host generator bundles DejaVuSans), so no CMap/font fetching occurs.

### Regenerating

Re-download the two files from the source URL above and splice them into the HTML in
place of the `/*__PDFJS_MAIN_SOURCE__*/` and `/*__PDFJS_WORKER_SOURCE__*/` markers
(the build splice asserts neither file contains a `</script` sequence that would break
the inline island).
