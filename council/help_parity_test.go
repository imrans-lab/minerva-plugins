package main

import (
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"strings"
	"testing"

	"github.com/ipeerbhai/plugins/council/internal/session"
	"github.com/ipeerbhai/plugins/council/presets"
)

// What the user is told, held against what the plugin does.
//
// The failure this file exists to catch is the cheapest one to make and the
// most expensive one to ship: help, a skill or a preset that names a tool, a
// command or a chat directive which was renamed, or never existed. A user
// following it gets an error they cannot act on, and an agent following the
// skill spends a turn discovering the same thing.
//
// The oracles are the live tables, never a second list:
//
//   - tools        newRegistry(store).specs() — what the backend answers, which
//                  TestManifestAdvertisesExactlyTheToolsTheBackendAnswers has
//                  already tied to the manifest the host offers.
//   - commands     session.CommandNames() — the dispatch table itself.
//   - directives   session.Directives() — the turn reader's own prefixes.
//   - presets      a real session.Store, running a real definition.import.
//
// The scanning convention, which the prose has to keep: a command or directive
// is named in BACKTICKS. Bare prose is not scanned, because "council_definition
// .schema.json" and "definition.import" are indistinguishable to a regex and
// only one of them is a claim.

// Everything that tells a user or an agent what Council can do.
func helpSources(t *testing.T) map[string]string {
	t.Helper()
	out := map[string]string{}
	for _, path := range []string{"README.md"} {
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("%s is shipped help and must be readable: %v", path, err)
		}
		out[path] = string(raw)
	}
	out["manifest.json skills[]"] = skillProse(t)
	return out
}

// skillProse is every string the seeded skill puts in front of an agent. They
// are concatenated because a claim is a claim wherever in the record it sits.
func skillProse(t *testing.T) string {
	t.Helper()
	var m struct {
		Skills []struct {
			ID            string   `json:"id"`
			Title         string   `json:"title"`
			Summary       string   `json:"summary"`
			SystemPrompt  string   `json:"system_prompt"`
			Preconditions string   `json:"preconditions"`
			Outcome       string   `json:"outcome"`
			Steps         string   `json:"steps"`
			ToolDeps      []string `json:"tool_deps"`
			Target        string   `json:"target"`
		} `json:"skills"`
	}
	raw, err := os.ReadFile("manifest.json")
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatal(err)
	}
	if len(m.Skills) != 1 {
		t.Fatalf("expected exactly one seeded skill, got %d", len(m.Skills))
	}
	skill := m.Skills[0]

	// The host validates these at install: a skill missing one of them, or with
	// an id that does not match ^minerva_council_[a-z0-9_]+$, fails the seeding
	// rather than arriving half-formed.
	if !regexp.MustCompile(`^minerva_council_[a-z0-9_]+$`).MatchString(skill.ID) {
		t.Errorf("skill id %q does not match the host's required shape", skill.ID)
	}
	for name, value := range map[string]string{
		"title": skill.Title, "summary": skill.Summary, "system_prompt": skill.SystemPrompt,
		"preconditions": skill.Preconditions, "outcome": skill.Outcome, "steps": skill.Steps,
		"target": skill.Target,
	} {
		if strings.TrimSpace(value) == "" {
			t.Errorf("skill field %q is required by the host and is empty", name)
		}
	}
	if len(skill.ToolDeps) == 0 {
		t.Error("skill tool_deps is empty; the host resolves it at install and an empty list claims nothing")
	}
	return strings.Join(append(skill.ToolDeps,
		skill.Title, skill.Summary, skill.SystemPrompt,
		skill.Preconditions, skill.Outcome, skill.Steps), "\n")
}

var (
	toolToken     = regexp.MustCompile(`minerva_council_[a-z0-9_]+`)
	backtickToken = regexp.MustCompile("`([^`\n]+)`")
	commandShape  = regexp.MustCompile(`^(snapshot|definition|source|member|session|run|outcome)\.[a-z_]+$`)
	// Every directive shape the reader answers to, so a new one is covered by
	// this sweep from the moment it is documented. A pattern narrower than the
	// directive table is a directive that can be named in the help without
	// anything checking it exists.
	directiveShape = regexp.MustCompile(`^/(council[a-z-]*|ask|bench)(\s|$)`)
)

func TestShippedHelpNamesOnlyThingsThatExist(t *testing.T) {
	store, err := session.New()
	if err != nil {
		t.Fatal(err)
	}
	tools := map[string]bool{}
	for _, spec := range newRegistry(store).specs() {
		tools[spec.Name] = true
	}
	commands := map[string]bool{}
	for _, name := range session.CommandNames() {
		commands[name] = true
	}
	directives := map[string]bool{}
	for _, directive := range session.Directives() {
		directives[strings.TrimSpace(directive)] = true
	}

	// A tool the skill lists as a dependency but that no plugin answers is a
	// HOST tool — the guide's own example does this — so only the plugin's own
	// namespace is checkable here, and that is the namespace a rename breaks.
	for path, text := range helpSources(t) {
		for _, name := range toolToken.FindAllString(text, -1) {
			if !tools[name] {
				t.Errorf("%s names the tool %q, which this backend does not answer", path, name)
			}
		}
		for _, match := range backtickToken.FindAllStringSubmatch(text, -1) {
			token := strings.TrimSpace(match[1])
			switch {
			case commandShape.MatchString(token) && !commands[token]:
				t.Errorf("%s names the command `%s`, which is not in the dispatch table", path, token)
			case directiveShape.MatchString(token):
				// A directive is named with its argument: `/council <id>`.
				word := strings.Fields(token)[0]
				if !directives[word] {
					t.Errorf("%s names the chat directive %q, which the turn reader does not read", path, word)
				}
			}
		}
	}

	// The other direction, for the tools only: a tool nobody documents is a tool
	// nobody finds. Commands are deliberately NOT swept this way — the help is
	// meant to be short, and naming all seventeen would make it a reference.
	documented := map[string]bool{}
	for _, text := range helpSources(t) {
		for _, name := range toolToken.FindAllString(text, -1) {
			documented[name] = true
		}
	}
	for name := range tools {
		if !documented[name] {
			t.Errorf("the backend answers %q and no shipped help or skill mentions it", name)
		}
	}

	checkToolTable(t, len(tools))
}

var (
	toolRow    = regexp.MustCompile("(?m)^\\| `(minerva_council_[a-z0-9_]+)` \\|")
	toolCounts = regexp.MustCompile(`(?m)^([A-Z][a-z]+) tools\. ([A-Z][a-z]+) answer a caller`)
	numberWord = map[string]int{
		"One": 1, "Two": 2, "Three": 3, "Four": 4, "Five": 5, "Six": 6,
		"Seven": 7, "Eight": 8, "Nine": 9, "Ten": 10, "Eleven": 11, "Twelve": 12,
	}
)

// The README's tool table, held to the registry.
//
// A count written in prose is the one claim that rots silently: adding a tool
// leaves the sentence reading "eight" and the table one row short, and nothing
// else in the build notices. So both the row count and the two numerals in the
// sentence above it are derived from the same list the backend answers from.
func checkToolTable(t *testing.T, answered int) {
	t.Helper()
	raw, err := os.ReadFile("README.md")
	if err != nil {
		t.Fatal(err)
	}
	rows := map[string]bool{}
	for _, match := range toolRow.FindAllStringSubmatch(string(raw), -1) {
		if rows[match[1]] {
			t.Errorf("README.md lists %q twice in the tool table", match[1])
		}
		rows[match[1]] = true
	}
	if len(rows) != answered {
		t.Errorf("README.md's tool table has %d rows and the backend answers %d tools; every tool gets a row of its own",
			len(rows), answered)
	}

	counts := toolCounts.FindStringSubmatch(string(raw))
	if counts == nil {
		t.Fatal("README.md's tool surface no longer opens with \"<N> tools. <M> answer a caller\"; the count assertion has nothing to read")
	}
	if numberWord[counts[1]] != answered {
		t.Errorf("README.md says %q tools and the backend answers %d", counts[1], answered)
	}
	// The rest belong to the host (the two chat tools) and to the panel (the two
	// snapshot hooks). Neither is a tool a caller invokes, and the sentence
	// promises exactly that split.
	if want := answered - 4; numberWord[counts[2]] != want {
		t.Errorf("README.md says %q tools answer a caller; %d do, once the host's two chat tools and the panel's two snapshot hooks are set aside",
			counts[2], want)
	}
}

// The shipped councils are ordinary records, and this is what "ordinary" has to
// mean: the real store, the real schema validation, the real invariants and the
// real definition.import — the same path an exported council from another
// project takes. A preset that only worked because the page was lenient would
// pass a hand-written check and fail on the user's first click.
func TestShippedPresetsAreImportableCouncils(t *testing.T) {
	shipped, err := presets.All()
	if err != nil {
		t.Fatal(err)
	}
	if len(shipped) < 3 {
		t.Fatalf("v0.1 ships a business council, a general-purpose council and a grounded example; found %d", len(shipped))
	}

	store, err := session.New()
	if err != nil {
		t.Fatal(err)
	}
	grounded := 0
	for i, preset := range shipped {
		var record map[string]any
		if err := json.Unmarshal(preset.Definition, &record); err != nil {
			t.Fatalf("%s: %v", preset.File, err)
		}
		if strings.TrimSpace(preset.Name) == "" || strings.TrimSpace(preset.Purpose) == "" {
			t.Errorf("%s: a shipped council needs a name and a purpose; they are what the offer shows", preset.File)
		}
		for _, member := range record["members"].([]any) {
			m := member.(map[string]any)
			if m["kind"] == "simulant" {
				grounded++
			}
		}

		// Each import is given a fresh definition_id, exactly as the panel and
		// the skill do it, because the shipped id is a NAME and import refuses
		// one the project already holds.
		record["definition_id"] = fmt.Sprintf("def-import-%d", i)
		reply := dispatch(t, store, map[string]any{
			"request_id":    fmt.Sprintf("req-preset-%d", i),
			"command":       "definition.import",
			"base_revision": store.Revision(),
			"payload":       map[string]any{"definition": record},
		})
		if !reply.OK {
			t.Errorf("%s does not import through the real backend: %s", preset.File, reply.Error.Message)
			continue
		}
		// An import names what did not travel. A shipped preset either carries
		// its material or ships none, so this list is always empty — a preset
		// that referenced material it does not hold would offer a member that
		// looks grounded and is not.
		if missing, _ := reply.Payload["sources_without_content"].([]any); len(missing) > 0 {
			t.Errorf("%s imports with %d source(s) whose material did not travel", preset.File, len(missing))
		}
	}
	if grounded == 0 {
		t.Error("no shipped preset demonstrates a source-grounded simulant, which is the one mechanism a user cannot infer from the others")
	}

	// The presets tool and the page are fed from the same files. The page holds
	// each record's exact BYTES (ui/build.mjs inlines them, and JSON is a JS
	// expression), so a preset the backend serves and the page does not offer —
	// or a page rebuilt from a stale copy — is a drift this catches without
	// running a browser.
	page, err := os.ReadFile("ui/panel.html")
	if err != nil {
		t.Fatal(err)
	}
	for _, preset := range shipped {
		body := strings.TrimRight(string(preset.Definition), "\n")
		if !strings.Contains(string(page), body) {
			t.Errorf("ui/panel.html does not carry %s verbatim; run: node ui/build.mjs", preset.File)
		}
	}
}

// dispatch runs one envelope through the real store and decodes the reply.
func dispatch(t *testing.T, store *session.Store, envelope map[string]any) session.Reply {
	t.Helper()
	if _, ok := envelope["schema_version"]; !ok {
		envelope["schema_version"] = session.SchemaVersion
	}
	if _, ok := envelope["envelope"]; !ok {
		envelope["envelope"] = "request"
	}
	raw, err := json.Marshal(envelope)
	if err != nil {
		t.Fatal(err)
	}
	reply, err := store.Dispatch(raw)
	if err != nil {
		t.Fatalf("dispatch %v: %v", envelope["command"], err)
	}
	return reply
}
