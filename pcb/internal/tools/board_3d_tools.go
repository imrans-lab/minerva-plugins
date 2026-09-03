// board_3d_tools.go — the 3D export's TWO agent-facing verbs.
//
// WHY TWO ENTRIES AND NOT ONE. Every exporter in this plugin runs
// synchronously and there is no progress channel, so a single verb that both
// fetched vendor models and wrote the file would hold the caller — the panel's
// Export menu included — through ~86 network requests with nothing on screen.
// The network half is therefore its own verb. That also splits two reds that
// were being reported as one: "the supplier does not have this model" and "the
// geometry could not be built" are different problems with different fixes,
// and warming is independently useful to the orientation work, which needs the
// same vendor documents to measure against.
//
// ONE REGISTRY ENTRY PER VERB, TWO CALLERS EACH — the same arrangement
// minerva_pcb_order_package has. The panel's exporter chooser sends on these
// tools' OWN names as panel-IPC channels rather than getting dotted twins, so
// the owner (GUI only, cannot call a tool) and an agent (tools only, cannot
// click) reach one implementation and are told the same name for one fault.
package tools

import (
	"context"
	"encoding/json"

	"github.com/imrans-lab/minerva-plugins/shared/bridge"
)

// The board-source half of both schemas. Identical to the order package's,
// deliberately: a caller that can hand a board to one export can hand it to
// the other without learning a second vocabulary.
const board3DSourceSchema = `
			"yaml": {"type": "string", "description": "Canonical board YAML source."},
			"board": {"type": "object", "description": "Canonical board object (alternative to yaml)."},
			"board_path": {"type": "string", "description": "Path to a board file, read only when yaml and board are both absent and only with board_digest."},
			"board_digest": {"type": "string", "description": "sha256 hex of the board_path file's bytes. Mandatory with board_path — an unverified file read is refused, never trusted."},
			"profile": {"type": "string", "description": "Service profile id whose position-file walk names the catalogue numbers (default \"jlc\")."}`

var fetchPartModelsDescription = "WARM the vendor 3D-model cache for one board — the SLOW HALF of the 3D " +
	"export, split off deliberately. This is the only verb here that reaches the network: it walks the " +
	"board for every catalogue number its populated parts name, and fetches BOTH documents each part " +
	"needs (the component payload and the mesh it points at) into the per-user cache, at most once per part " +
	"and concurrently. IT REFUSES ALMOST NOTHING: only a board that will not compile, and a profile nobody " +
	"publishes, stop it. It deliberately does NOT walk the position file — designator uniqueness, row limits, " +
	"placement spacing and the part-identity contract are all promises about a document a manufacturer reads, " +
	"and none of them bear on whether a model can be downloaded; a verb whose job is \"fetch what you can, " +
	"report what you cannot\" must not refuse forty-six parts because of the forty-seventh. " +
	"minerva_pcb_export_3d then reads that cache and never fetches, so the file write stays " +
	"fast and deterministic and a supplier outage cannot be mistaken for a geometry fault. Args {yaml|board|" +
	"board_path+board_digest, profile?}. Returns {profile, cache_dir, requested, ready:[{part, refs, " +
	"model_uuid, from_cache, bytes, sha256}], missing:[{part, refs, reason, detail}], refs_without_part, " +
	"counts:{requested, ready, fetched, already_cached, missing}, summary}. `missing` NEVER refuses — a part " +
	"the supplier has no model for is a placeholder prism at export time, not a failure — and its `reason` is " +
	"the stable name (no_part_number, not_found, no_network, malformed, no_model, identity_mismatch). " +
	"`refs_without_part` names placements the board gave no catalogue number for, which is a board fact and " +
	"not a fetch failure. An EMPTY cache_dir means this host stated no cache directory: everything fetched " +
	"was discarded, and an export will still find the cache cold. Nothing but the cache is written. " +
	"Holding an editor? The panel's Export menu runs this over the LIVE board through the same entry."

var fetchPartModelsSchema = json.RawMessage(`{
		"type": "object",
		"properties": {` + board3DSourceSchema + `
		}
	}`)

var FetchPartModels = ToolSpec{
	Name:        "minerva_pcb_fetch_part_models",
	Description: fetchPartModelsDescription,
	InputSchema: fetchPartModelsSchema,
}

// HandleFetchPartModels serves the agent call and the panel channel alike.
// withLibraryChain is required, not decorative: the walk strict-compiles the
// board, so without the host's live layer chain a board whose footprints come
// from the user or blessed-WIP layers refuses with footprint_unresolved.
func HandleFetchPartModels(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "fetch_part_models", withLibraryChain(params))
}

var export3DDescription = "Write the board as ONE .glb file: the textured slab with its holes cut, and every " +
	"ordered part seated at the position file's own transform in the vendor's colours. SYNCHRONOUS AND " +
	"OFFLINE — it reads only vendor models already cached and NEVER fetches, so it cannot stall behind a " +
	"supplier. Run minerva_pcb_fetch_part_models first to warm the cache. Args {yaml|board|" +
	"board_path+board_digest, out_dir?, name?, profile?, overwrite?, scale_px_per_mm?, max_px?}. " +
	"WITHOUT out_dir nothing is written and the reply is the size, the digest and the whole report — the " +
	"same optional-destination rule minerva_pcb_order_package uses, and useful for the same reason: " +
	"\"which parts have no model, how tall is the board, is the cache cold\" is worth answering without " +
	"picking a directory and cleaning up a file afterwards. WITH out_dir the .glb is published there. The " +
	"BYTES are never returned either way; the sha256 is what a caller can check. " +
	"Returns {path, filename, out_dir, written, bytes, sha256, profile, scale_px_per_mm, " +
	"missing_models, unverified, tallest, unknown_height_refs, advisories, excluded, cache_cold, " +
	"cache_cold_hint?, notes, report, viewer_note, summary}. THE REPORTS ARE THE POINT: `missing_models` " +
	"names every part drawn as a magenta placeholder prism and why, `unverified` every part whose ORIENTATION " +
	"was never measured (each carries an orange post in the file), `tallest` the tallest measured part per " +
	"side and `unknown_height_refs` the parts whose height nothing knows — so a render is never mistaken for " +
	"a measurement. `cache_cold` is the subset of missing_models that are missing ONLY because nobody warmed " +
	"the cache, and cache_cold_hint names the verb that fixes it. A part the board gives no catalogue " +
	"number for is a placeholder prism and a report line, NOT a refusal: the purchasing identity contract " +
	"(assembly_missing_identity) governs a document a house reads, and this draws a picture on your own " +
	"machine — a mid-layout board nobody has entered part numbers for is exactly when somebody wants to " +
	"look at it. The same report travels INSIDE the file, in " +
	"asset.extras, plus per-part facts on each node, so a person handed the .glb and nothing else can read " +
	"all of it. IT OPENS IN BLENDER or any glTF 2.0 viewer — Minerva's own CAD panel has no file loader and " +
	"cannot show it. " +
	"THE FILE IS IN METRES, the unit glTF defines: the whole scene hangs under one root node that scales board millimetres by 0.001, so the board imports at its real size instead of a thousand times too big. Node coordinates and every *_mm field are still board millimetres, and report.units names which frame is which. " +
	"Refusals are named and write nothing: board_3d_exists (the " +
	"destination is occupied and overwrite was not set — it may already have been sent to somebody), " +
	"board_3d_bad_parameter, board_3d_write_failed, board_3d_placement_mismatch (the emission and the board " +
	"are not the same board), and assembly_not_compilable for a board that does not compile. " +
	"Holding an editor? The panel's Export menu runs this over the LIVE board through the same entry, and " +
	"offers to open the written file in the desktop handler."

var export3DSchema = json.RawMessage(`{
		"type": "object",
		"properties": {` + board3DSourceSchema + `,
			"out_dir": {"type": "string", "description": "Directory to publish the .glb into. Omit to build the model and get its size, digest and full report without writing anything — the same optional-destination rule minerva_pcb_order_package uses. The bytes are never returned either way."},
			"name": {"type": "string", "description": "File name stem; defaults to the board's own name. A .glb suffix is added and never doubled."},
			"overwrite": {"type": "boolean", "description": "Replace an existing file of the same name (default false — it may already have been sent to somebody)."},
			"scale_px_per_mm": {"type": "number", "description": "Texture resolution for the two baked board pictures (default 20). Higher is sharper and larger; the long side is capped by max_px."},
			"max_px": {"type": "integer", "description": "Cap on the baked texture's long side in pixels. The scale is reduced to fit rather than the board being cropped."}
		}
	}`)

var Export3D = ToolSpec{
	Name:        "minerva_pcb_export_3d",
	Description: export3DDescription,
	InputSchema: export3DSchema,
}

// HandleExport3D serves the agent call and the panel channel alike. Writing is
// the WORKER's job here, as it is for the order package: the bytes are built
// there and shipping megabytes back over the bridge so Go could write them
// would be a copy for nothing.
func HandleExport3D(ctx context.Context, w *bridge.Worker, params json.RawMessage) (json.RawMessage, error) {
	return w.Call(ctx, "board_3d_export", withLibraryChain(params))
}
