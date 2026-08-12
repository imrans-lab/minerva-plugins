package main

import (
	"encoding/json"
	"os"
	"reflect"
	"sort"
	"strings"
	"testing"
)

// manifestTool mirrors the shape of one pcb/manifest.json "tools[]" entry —
// only the fields this test needs.
type manifestTool struct {
	Name        string          `json:"name"`
	Description string          `json:"description"`
	Executor    string          `json:"executor"`
	InputSchema json.RawMessage `json:"input_schema"`
}

type manifestFile struct {
	Tools []manifestTool `json:"tools"`
}

// loadManifestBackendTools parses pcb/manifest.json (relative to this package
// dir, which is pcb/ — `go test` runs with cwd = the package directory, the
// same convention TestPCBWorkerStdioSmoke already relies on for
// "spikes/gerber/board.yaml") and returns the subset of tools[] whose
// EFFECTIVE executor is "backend". Per PluginDefinition._from_dict_internal
// and PluginToolRegistry.register_plugin_tools (Minerva host), an absent
// "executor" field defaults to "backend" — this mirrors that default so an
// entry that omits the field (as every backend tool in this manifest does,
// matching every other plugin's manifest in this monorepo) is still counted.
func loadManifestBackendTools(t *testing.T) map[string]manifestTool {
	t.Helper()
	data, err := os.ReadFile("manifest.json")
	if err != nil {
		t.Fatalf("read manifest.json: %v", err)
	}
	var mf manifestFile
	if err := json.Unmarshal(data, &mf); err != nil {
		t.Fatalf("parse manifest.json: %v", err)
	}
	out := map[string]manifestTool{}
	for _, tool := range mf.Tools {
		executor := tool.Executor
		if executor == "" {
			executor = "backend"
		}
		if executor != "backend" {
			continue
		}
		out[tool.Name] = tool
	}
	return out
}

// agentFacingBrokerSpecs returns every registered broker ToolSpec whose Name
// begins with "minerva_pcb_" — the definition of "agent-facing" pinned by
// docket 019fa486b408 comment 832 (the cold-review premise correction).
// Without this filter, "the broker's tools" would also include "ping" and the
// dotted pcb.serialize/pcb.deserialize/pcb.collect_export/pcb.apply_export/
// pcb.route/pcb.draft_check panel-IPC channels — none of which begin with
// minerva_pcb_ (ping has no prefix at all; the dotted channels use a "pcb."
// prefix, not "minerva_pcb_"), so this filter naturally excludes them without
// an explicit denylist.
func agentFacingBrokerSpecs(t *testing.T) map[string]ToolSpecLike {
	t.Helper()
	initRegistry()
	out := map[string]ToolSpecLike{}
	for _, s := range registry.Specs() {
		if !strings.HasPrefix(s.Name, "minerva_pcb_") {
			continue
		}
		out[s.Name] = ToolSpecLike{Description: s.Description, InputSchema: s.InputSchema}
	}
	return out
}

// ToolSpecLike is a local copy of the two fields this test compares, so this
// file does not need to import the tools package's ToolSpec type by name
// (registry.Specs() already returns tools.ToolSpec; this struct just carries
// the two fields we read out of it into a local, package-neutral shape).
type ToolSpecLike struct {
	Description string
	InputSchema json.RawMessage
}

// TestManifestBrokerParity is the round D0-expose parity gate (docket
// 019fa486b408, acceptance criterion 2 as amended by comment 832): the
// manifest's backend-executor tool names and the broker's agent-facing
// (minerva_pcb_*) registry entries must be the SAME SET, checked in BOTH
// directions. A one-directional containment check would pass a half-done
// rename (e.g. broker renamed but manifest only carries 6 of the 11, or vice
// versa) — this test fails loudly on either gap.
func TestManifestBrokerParity(t *testing.T) {
	manifestTools := loadManifestBackendTools(t)
	brokerSpecs := agentFacingBrokerSpecs(t)

	var inManifestNotBroker, inBrokerNotManifest []string
	for name := range manifestTools {
		if _, ok := brokerSpecs[name]; !ok {
			inManifestNotBroker = append(inManifestNotBroker, name)
		}
	}
	for name := range brokerSpecs {
		if _, ok := manifestTools[name]; !ok {
			inBrokerNotManifest = append(inBrokerNotManifest, name)
		}
	}
	sort.Strings(inManifestNotBroker)
	sort.Strings(inBrokerNotManifest)

	if len(inManifestNotBroker) > 0 {
		t.Errorf("manifest declares backend tool(s) the broker does not register: %v", inManifestNotBroker)
	}
	if len(inBrokerNotManifest) > 0 {
		t.Errorf("broker registers agent-facing tool(s) the manifest does not declare: %v", inBrokerNotManifest)
	}
	// 11 (the D0-expose set) + 1: minerva_pcb_export_assembly (D0-5, docket
	// 019fc2f8b903) — a SEPARATE unstaged bump from this same round's manifest
	// addition, per the same "reviewed as its own diff" convention the GD
	// registration-count pin (pcb/tests/gd/test_manifest_tool_registration.gd)
	// documents; this count is a hard gate (not discretionary), so it moves in
	// lockstep with the manifest/broker entry rather than trailing it.
	if len(manifestTools) != 17 {
		t.Errorf("manifest backend-executor tool count = %d, want 17 (the D0-expose 11 + D0-5's minerva_pcb_export_assembly + LIB1 B2's stage/report/bless trio + LIB1 B3's minerva_pcb_acquire_footprint + LIB2 B7's minerva_pcb_footprint_promote)", len(manifestTools))
	}
	if len(brokerSpecs) != 17 {
		t.Errorf("broker agent-facing (minerva_pcb_*) tool count = %d, want 17", len(brokerSpecs))
	}
}

// TestManifestInputSchemaMatchesBroker is acceptance criterion 3 (input_schema)
// PLUS a description-parity check added on cold review (F1, docket
// 019fa486b408): each manifest entry's input_schema must EQUAL the broker
// spec's InputSchema for that tool, compared as PARSED JSON (so key
// order/whitespace differences don't fail the test, but a semantically
// different schema does) — this is the criterion a lazy fix fails, since 11
// manifest entries all carrying {"type":"object"} would satisfy
// TestManifestBrokerParity (same names) and even a live tools/call (the
// broker doesn't consult the manifest schema at dispatch time) without
// satisfying this.
//
// The manifest's descriptions were copy-pasted verbatim from the Go
// ToolSpec.Description strings at authoring time (compared=11, diffs=0), but
// nothing enforces that going forward: an edit to a Go description ships a
// silently stale install-time surface (the manifest is what an agent reads
// before the plugin ever starts) unless something pins the two together. This
// test is that pin — string-equal, not parsed, since Description is prose,
// not JSON.
func TestManifestInputSchemaMatchesBroker(t *testing.T) {
	manifestTools := loadManifestBackendTools(t)
	brokerSpecs := agentFacingBrokerSpecs(t)

	for name, spec := range brokerSpecs {
		mt, ok := manifestTools[name]
		if !ok {
			// Already reported by TestManifestBrokerParity; don't double-fail here.
			continue
		}
		var manifestSchema, brokerSchema interface{}
		if err := json.Unmarshal(mt.InputSchema, &manifestSchema); err != nil {
			t.Errorf("%s: manifest input_schema is not valid JSON: %v", name, err)
			continue
		}
		if err := json.Unmarshal(spec.InputSchema, &brokerSchema); err != nil {
			t.Errorf("%s: broker InputSchema is not valid JSON: %v", name, err)
			continue
		}
		if !reflect.DeepEqual(manifestSchema, brokerSchema) {
			t.Errorf("%s: manifest input_schema != broker InputSchema\nmanifest: %s\nbroker:   %s",
				name, string(mt.InputSchema), string(spec.InputSchema))
		}
		if mt.Description != spec.Description {
			t.Errorf("%s: manifest description != broker Description\nmanifest: %s\nbroker:   %s",
				name, mt.Description, spec.Description)
		}
	}
}

// TestCutoutDescriptionsMatchCompiledSupport pins the agent-facing contract
// that drifted after CPN1: cutouts are no longer schema-only. These panel tools
// do not have a duplicate Go ToolSpec, so the backend description-parity test
// above cannot protect them.
func TestCutoutDescriptionsMatchCompiledSupport(t *testing.T) {
	data, err := os.ReadFile("manifest.json")
	if err != nil {
		t.Fatalf("read manifest.json: %v", err)
	}
	var mf manifestFile
	if err := json.Unmarshal(data, &mf); err != nil {
		t.Fatalf("parse manifest.json: %v", err)
	}

	descriptions := map[string]string{}
	for _, tool := range mf.Tools {
		descriptions[tool.Name] = tool.Description
	}
	for _, name := range []string{
		"minerva_pcb_list_cutouts",
		"minerva_pcb_create_cutout",
		"minerva_pcb_propose_cutout",
	} {
		description, ok := descriptions[name]
		if !ok {
			t.Errorf("manifest missing %s", name)
			continue
		}
		for _, claim := range []string{"routing", "DRC", "zone fill", "Edge.Cuts"} {
			if !strings.Contains(description, claim) {
				t.Errorf("%s description omits compiled cutout consumer %q: %s", name, claim, description)
			}
		}
		for _, obsolete := range []string{"NOT YET COMPILED", "not compilable", "do not see it"} {
			if strings.Contains(description, obsolete) {
				t.Errorf("%s description retains obsolete claim %q: %s", name, obsolete, description)
			}
		}
	}
}

// toolIdentityKeyword is a HEURISTIC, not a content-quality check (cold
// review S2, docket 019fa486b408): a keyword string that appears in this
// tool's OWN description and, verified below, in NO OTHER tool's description.
// It pins NAME-TO-DESCRIPTION PAIRING — that minerva_pcb_drc's description is
// actually ABOUT minerva_pcb_drc — not whether the description is well
// written. Swapping two tools' descriptions between otherwise-correct specs
// (e.g. minerva_pcb_gerbers reading minerva_pcb_drc's prose) is invisible to
// every other test in this file: TestManifestInputSchemaMatchesBroker
// compares manifest.Description to broker.Description, and a swap moves both
// sides together, so they still match EACH OTHER. Only a check tied to the
// tool's OWN identity catches it.
var toolIdentityKeyword = map[string]string{
	"minerva_pcb_validate":      "Structurally validate",
	"minerva_pcb_generate":      "Generate KiCad files",
	"minerva_pcb_gerbers":       "Gerber RS-274X",
	"minerva_pcb_drc":           "CONNECTIVITY/topology",
	"minerva_pcb_drc_geometric": "ResolvedBoard IR",
	// WAS "silkscreen" until CP2. GC9 gave drc_geometric a legitimate reason to
	// say the word, so a keyword naming a LAYER could no longer pin a TOOL: silk
	// is discussed anywhere the fab surface is discussed, which made every future
	// description edit a tripwire on an unrelated tool's identity. "coincidence
	// guard" names the one behaviour only resolve has — the fail-closed refusal
	// when a declared pin position disagrees with the footprint pad it resolves
	// to — in words the copper/fab surface has no reason to reuse.
	"minerva_pcb_resolve":         "coincidence guard",
	"minerva_pcb_normalize":       "normalized v2 shape",
	"minerva_pcb_check_libraries": "footprint-library data",
	"minerva_pcb_check_bom":       "bill of materials",
	"minerva_pcb_fetch_libraries": "curated KiCAD symbol/footprint library subset",
	"minerva_pcb_library_status":  "fetched and verified",
	"minerva_pcb_export_assembly": "pre-assembly order package",
	// LIB1 B2 (rendered bless): keywords verified unique across all 15
	// descriptions at authoring time.
	"minerva_pcb_footprint_stage":  "sha256-pinned and UNBLESSED",
	"minerva_pcb_footprint_report": "a FACT TABLE and a self-contained SVG",
	"minerva_pcb_footprint_bless":  "AUTO-BLESSES on provenance",
	// LIB1 B3 (acquisition). The keyword names the one thing ONLY this tool does
	// — reach the network — in the exact words its description uses to disclose
	// it. Verified unique across all 16 manifest descriptions at authoring time,
	// and it is a claim no sibling can pick up without becoming a fetcher itself:
	// minerva_pcb_fetch_libraries is the only other tool that touches the network
	// and it says "Requires network access", never naming the host.
	"minerva_pcb_acquire_footprint": "outbound HTTPS to gitlab.com",
	// LIB2 B7 (promotion). Names the one transition ONLY this tool performs —
	// WIP staging → durable user layer. Siblings mention the layers but never
	// this exact movement phrase; verified unique across all 17 manifest
	// descriptions at authoring time.
	"minerva_pcb_footprint_promote": "out of the WIP staging layer into the durable USER library layer",
}

// TestDescriptionKeywordPinsToolIdentity is the S2 fix: for each of the 12
// tools (the D0-expose 11 + D0-5's minerva_pcb_export_assembly), assert its
// MANIFEST description contains its distinctive keyword, and — the part that
// actually catches a swap — that NO OTHER tool's description contains that
// same keyword. A pure "keyword present" check alone would not catch two
// tools swapping wholesale, since each swapped description would just be
// missing FROM THE WRONG ENTRY without anything checking that other entries
// didn't pick it up; checking uniqueness across all 12 is what makes this a
// pairing pin rather than a presence check.
func TestDescriptionKeywordPinsToolIdentity(t *testing.T) {
	manifestTools := loadManifestBackendTools(t)

	for name, keyword := range toolIdentityKeyword {
		mt, ok := manifestTools[name]
		if !ok {
			t.Errorf("%s: not found in manifest backend tools (checked separately by TestManifestBrokerParity)", name)
			continue
		}
		if !strings.Contains(mt.Description, keyword) {
			t.Errorf("%s: manifest description does not contain its identity keyword %q: %s", name, keyword, mt.Description)
		}
	}

	for name, keyword := range toolIdentityKeyword {
		for otherName, otherTool := range manifestTools {
			if otherName == name {
				continue
			}
			if strings.Contains(otherTool.Description, keyword) {
				t.Errorf("%s's identity keyword %q also appears in %s's description — "+
					"no longer distinctive, so it can't pin pairing (descriptions may have been swapped): %s",
					name, keyword, otherName, otherTool.Description)
			}
		}
	}
}
