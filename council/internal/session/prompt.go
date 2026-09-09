package session

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/ipeerbhai/plugins/council/internal/contract"
)

// This file assembles what a member is told and reads back what it said.
//
// It is deliberately the only place either happens. The independence rule —
// an initial member sees the shared context and its own grounding, and nothing
// of the other members' answers — is a property of how a prompt is built, so
// it is enforced by there being exactly one builder and by that builder never
// being handed the other contributions on an initial call.

// replyContract is the shape every member is asked to answer in. Council reads
// the answer structurally rather than parsing prose, because the distinction
// between "a source said this", "I concluded this" and "the material does not
// establish this" is the whole point of the record and cannot be recovered from
// a paragraph afterwards.
//
// A reply that is not in this shape is still kept: the text becomes the answer
// with no claims, and the chair still reads it. Losing the labels is bad;
// losing the answer would be worse.
const replyContract = `Answer as a single JSON object and nothing else:

{"answer": "<your answer, in prose>",
 "claims": [
   {"support": "source", "text": "<one assertion>",
    "citations": [{"source_id": "...", "source_revision": 1, "anchor_id": "..."}]},
   {"support": "inference", "text": "<an assertion you reached yourself>"},
   {"support": "unknown", "text": "<something the material does not establish>"}
 ]}

"source" means the assertion is quoted or paraphrased from an excerpt you were
given, and it must cite at least one of the anchor ids listed above; a citation
to anything else is dropped and the claim is recorded as unestablished.
"inference" is your own application of that material to this question.
"unknown" is a position the material does not settle. State those plainly
rather than filling the gap. Do not soften a disagreement with another member
into agreement; if you think a position is wrong, say which and why.`

// section is one labelled block of a prompt. droppable marks the material the
// assembler may shed to stay inside the byte budget; the question, the identity
// and the reply contract are never droppable, because a call without them is
// not a smaller version of the same consultation.
type section struct {
	label     string
	body      string
	droppable bool
}

// assemble renders the sections and brings the result inside budget by dropping
// droppable material from the tail, newest first, each replaced by a line
// saying what is missing. Truncation is visible in the prompt itself: a member
// that was not given everything must be able to say so.
func assemble(sections []section, maxBytes int) string {
	render := func(keep int) string {
		var b strings.Builder
		dropped := 0
		for i, s := range sections {
			if s.droppable && i >= keep {
				dropped++
				continue
			}
			b.WriteString("## ")
			b.WriteString(s.label)
			b.WriteString("\n")
			b.WriteString(s.body)
			b.WriteString("\n\n")
		}
		if dropped > 0 {
			fmt.Fprintf(&b, "## Omitted\n%d block(s) of material were left out to stay inside this council's per-call size limit. Say so if the question cannot be answered without them.\n", dropped)
		}
		return strings.TrimRight(b.String(), "\n") + "\n"
	}

	out := render(len(sections))
	if len(out) <= maxBytes {
		return out
	}
	// Drop droppable sections one at a time from the end. Everything
	// non-droppable is kept whatever happens: a prompt that no longer names the
	// question would be a different consultation, not a cheaper one.
	for keep := len(sections) - 1; keep >= 0; keep-- {
		out = render(keep)
		if len(out) <= maxBytes {
			return out
		}
	}
	return out
}

// memberSystem states who this member is and what it is answerable for. It is
// the seat's responsibility plus the identity's own scope and stated gaps, so a
// member cannot be quietly asked to speak outside what the record says it can.
func memberSystem(member, seat map[string]any) string {
	var b strings.Builder
	fmt.Fprintf(&b, "You are %q on a council, seated as: %s\n", str(member["display_name"]), str(seat["responsibility"]))
	switch str(member["kind"]) {
	case "simulant":
		fmt.Fprintf(&b, "You interpret %s from the captured material below, and only from it. You are an interpretation of that material, not that person, and you must not claim to be.\n", str(member["represents"]))
	case "assistant":
		b.WriteString("You are an assistant member: a functional advisor speaking to your stated scope, representing nobody.\n")
	case "human":
		b.WriteString("You are standing in for the local user's own observations. Answer only from what the context below records as observed.\n")
	}
	if scope := strings.TrimSpace(str(member["scope"])); scope != "" {
		fmt.Fprintf(&b, "Your scope: %s\n", scope)
	}
	if gaps := strings.TrimSpace(str(member["limitations"])); gaps != "" {
		fmt.Fprintf(&b, "What your grounding does NOT establish: %s\n", gaps)
	}
	b.WriteString("You are answering independently. You have not been shown what any other member said, and you must not invent it.")
	return b.String()
}

// groundingSections renders the exact source revisions this member is grounded
// in, and returns the anchor ids it is therefore allowed to cite.
//
// Only the pinned revisions are rendered. A newer capture of the same source
// sitting beside it in the council is not this member's material until somebody
// adopts it, and handing it over here would make member_revision a lie.
func groundingSections(def, member map[string]any) ([]section, map[string]bool) {
	allowed := map[string]bool{}
	var out []section
	for _, g := range arr(member["grounding"]) {
		ref := obj(g)
		id, revision := str(ref["source_id"]), int(num(ref["source_revision"]))
		src := findSourceRevision(def, id, revision)
		if src == nil {
			// The definition invariants refuse a grounding reference that does
			// not resolve, so this is unreachable for a validated record; the
			// member is told rather than silently given less material.
			out = append(out, section{
				label:     fmt.Sprintf("Source %s@%d — missing", id, revision),
				body:      "This council no longer holds that capture. Treat anything that depended on it as unestablished.",
				droppable: true,
			})
			continue
		}
		var b strings.Builder
		fmt.Fprintf(&b, "Title: %s\n", str(src["title"]))
		if author := str(src["author"]); author != "" {
			fmt.Fprintf(&b, "Author: %s\n", author)
		}
		if locator := str(src["locator"]); locator != "" {
			fmt.Fprintf(&b, "Where it came from: %s\n", locator)
		}
		if inline := str(obj(src["payload"])["inline"]); inline != "" {
			b.WriteString("\nThe captured material:\n")
			b.WriteString(inline)
			b.WriteString("\n")
		} else {
			b.WriteString("\nThe material itself is not held in this project; only the excerpts below were kept.\n")
		}
		b.WriteString("\nExcerpts you may cite:\n")
		for _, a := range arr(src["anchors"]) {
			anchor := obj(a)
			anchorID := str(anchor["anchor_id"])
			allowed[citationKey(id, revision, anchorID)] = true
			fmt.Fprintf(&b, "  [%s] %q\n", anchorID, str(anchor["quote"]))
		}
		out = append(out, section{
			label:     fmt.Sprintf("Source %s, capture %d", id, revision),
			body:      strings.TrimRight(b.String(), "\n"),
			droppable: true,
		})
	}
	return out, allowed
}

// allAnchors is the chair's citation set. The chair has no grounding of its own
// and reads the members' answers, so what it may cite is every anchor the
// session's own definition snapshot holds — which is exactly the union of what
// the members could cite.
func allAnchors(def map[string]any) map[string]bool {
	allowed := map[string]bool{}
	for _, s := range arr(def["sources"]) {
		src := obj(s)
		id, revision := str(src["source_id"]), int(num(src["source_revision"]))
		for _, a := range arr(src["anchors"]) {
			allowed[citationKey(id, revision, str(obj(a)["anchor_id"]))] = true
		}
	}
	return allowed
}

func citationKey(sourceID string, revision int, anchorID string) string {
	return fmt.Sprintf("%s@%d#%s", sourceID, revision, anchorID)
}

func findSourceRevision(def map[string]any, id string, revision int) map[string]any {
	for _, s := range arr(def["sources"]) {
		src := obj(s)
		if str(src["source_id"]) == id && int(num(src["source_revision"])) == revision {
			return src
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// reading the reply
// ---------------------------------------------------------------------------

// rawReply is the shape replyContract asks for. Every field is optional here:
// a model that answers with prose, or with half the structure, still gets its
// answer recorded.
type rawReply struct {
	Answer string `json:"answer"`
	Claims []struct {
		Support   string `json:"support"`
		Text      string `json:"text"`
		Citations []struct {
			SourceID string `json:"source_id"`
			Revision int    `json:"source_revision"`
			AnchorID string `json:"anchor_id"`
		} `json:"citations"`
	} `json:"claims"`
}

// parseReply reads a member's answer. A model that wrapped the object in a
// fenced code block, or put a sentence in front of it, is still understood;
// anything else is taken as prose and returned as the answer with no claims.
func parseReply(text string) rawReply {
	candidate := strings.TrimSpace(text)
	if fenced := extractFenced(candidate); fenced != "" {
		candidate = fenced
	} else if start := strings.Index(candidate, "{"); start > 0 {
		candidate = strings.TrimSpace(candidate[start:])
	}
	var parsed rawReply
	if err := json.Unmarshal([]byte(candidate), &parsed); err == nil && strings.TrimSpace(parsed.Answer) != "" {
		return parsed
	}
	return rawReply{Answer: strings.TrimSpace(text)}
}

// extractFenced returns the body of the first ``` block, which is how most
// models return JSON when asked for JSON.
func extractFenced(text string) string {
	open := strings.Index(text, "```")
	if open < 0 {
		return ""
	}
	rest := text[open+3:]
	if nl := strings.IndexByte(rest, '\n'); nl >= 0 {
		rest = rest[nl+1:]
	}
	end := strings.Index(rest, "```")
	if end < 0 {
		return ""
	}
	return strings.TrimSpace(rest[:end])
}

// buildClaims turns a parsed reply's claims into contribution records.
//
// The support label is checked against what the claim actually cites, because
// the label is what a reader trusts. A "source" claim whose citations do not
// all resolve to material this member was given keeps only the ones that do;
// if none does, the claim is recorded as "unknown" with no citations. An
// interpretation is never displayed as something a source said — dropping the
// label is the only way to keep that true without dropping the assertion.
func buildClaims(parsed rawReply, allowed map[string]bool, mint func() string) []any {
	claims := []any{}
	for _, raw := range parsed.Claims {
		text := strings.TrimSpace(raw.Text)
		if text == "" {
			continue
		}
		if len(text) > contract.ClaimTextLimit {
			text = text[:contract.ClaimTextLimit]
		}
		support := raw.Support
		citations := []any{}
		if support == "source" {
			for _, c := range raw.Citations {
				if !allowed[citationKey(c.SourceID, c.Revision, c.AnchorID)] {
					continue
				}
				citations = append(citations, map[string]any{
					"source_id":       c.SourceID,
					"source_revision": float64(c.Revision),
					"anchor_id":       c.AnchorID,
				})
			}
			if len(citations) == 0 {
				support = "unknown"
			}
		}
		if support != "source" && support != "inference" && support != "unknown" {
			support = "unknown"
		}
		claims = append(claims, map[string]any{
			"claim_id":  mint(),
			"support":   support,
			"text":      text,
			"citations": citations,
		})
	}
	return claims
}

// answerText is the contribution's own text, capped at the schema's ceiling so
// a long answer is stored truncated rather than refused after it was paid for.
func answerText(parsed rawReply, fallback string) string {
	text := strings.TrimSpace(parsed.Answer)
	if text == "" {
		text = strings.TrimSpace(fallback)
	}
	if len(text) > contract.InlineLimit {
		text = text[:contract.InlineLimit-3] + "..."
	}
	return text
}
