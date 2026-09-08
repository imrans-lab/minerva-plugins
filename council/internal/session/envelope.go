// Package session is Council's command engine: it holds the one snapshot the
// backend is currently working on and applies the protocol commands to it.
//
// The engine is deliberately not a second place where state lives. It holds a
// working copy that was handed to it by the native wrapper (or starts empty),
// applies one command at a time, and hands the acknowledged revision back in
// every reply. Nothing here is durable; the wrapper writes the snapshot into
// the project and into a .mcouncil file, and a snapshot that never reached the
// wrapper is lost when the process ends. That is why a run left in flight is
// demoted on load rather than resumed.
package session

import "github.com/ipeerbhai/plugins/council/internal/contract"

// SchemaVersion is the one wire/record format version this build speaks. A
// record or envelope carrying anything else is refused rather than guessed at.
const SchemaVersion = 1

// MaxEnvelopeBytes is the largest single protocol message the engine accepts.
// It is the host's pluginIPC request cap, of which contract.InlineLimit is
// deliberately half so that a maximal inline payload still fits inside its
// envelope. Deriving it here keeps one definition of the transport budget.
const MaxEnvelopeBytes = 2 * contract.InlineLimit

// Failure codes, the closed enum from session.schema.json. A caller error that
// is none of the specific cases lands on CodeInternal, which is the only
// catch-all the enum offers.
const (
	CodeModelUnavailable = "model_unavailable"
	CodeModelError       = "model_error"
	CodeTimeout          = "timeout"
	CodeCancelled        = "cancelled"
	CodeInterrupted      = "interrupted"
	CodeMissingSource    = "missing_source"
	CodeMissingChat      = "missing_chat"
	CodeStaleRevision    = "stale_revision"
	CodePayloadTooLarge  = "payload_too_large"
	CodeInternal         = "internal"
)

// Request is one inbound protocol envelope. base_revision is a pointer because
// its absence is meaningful: a read command must not carry one and a mutating
// command must.
type Request struct {
	SchemaVersion int            `json:"schema_version"`
	Envelope      string         `json:"envelope"`
	RequestID     string         `json:"request_id"`
	Command       string         `json:"command"`
	BaseRevision  *int           `json:"base_revision,omitempty"`
	Payload       map[string]any `json:"payload"`
}

// Reply is one outbound protocol envelope. Every reply carries the
// snapshot_revision it was produced against, so a view that applies replies out
// of order can notice and re-read instead of rendering a mixture.
type Reply struct {
	SchemaVersion    int            `json:"schema_version"`
	Envelope         string         `json:"envelope"`
	RequestID        string         `json:"request_id"`
	OK               bool           `json:"ok"`
	SnapshotRevision int            `json:"snapshot_revision"`
	Replayed         bool           `json:"replayed,omitempty"`
	Payload          map[string]any `json:"payload,omitempty"`
	Error            *Failure       `json:"error,omitempty"`
}

// Failure is a visible failure state. retryable drives whether a view offers an
// explicit retry; nothing in Council retries on its own.
type Failure struct {
	Code      string `json:"code"`
	Message   string `json:"message"`
	Retryable bool   `json:"retryable"`
}

func fail(code, message string, retryable bool) *Failure {
	return &Failure{Code: code, Message: message, Retryable: retryable}
}

// okReply and errReply build the two reply shapes. They exist so the "a
// successful reply carries no error, a failed one carries nothing else"
// invariant is expressed once rather than at every return site.
func okReply(requestID string, revision int, payload map[string]any) Reply {
	return Reply{
		SchemaVersion:    SchemaVersion,
		Envelope:         "reply",
		RequestID:        requestID,
		OK:               true,
		SnapshotRevision: revision,
		Payload:          payload,
	}
}

func errReply(requestID string, revision int, f *Failure) Reply {
	return Reply{
		SchemaVersion:    SchemaVersion,
		Envelope:         "reply",
		RequestID:        requestID,
		OK:               false,
		SnapshotRevision: revision,
		Error:            f,
	}
}
