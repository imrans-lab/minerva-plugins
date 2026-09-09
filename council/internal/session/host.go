package session

import (
	"context"
	"errors"
)

// ChatHost is the whole of Council's dependency on somebody else's models.
//
// It is one method on purpose. The engine decides who is consulted, what they
// are told, how long they get and what is recorded; the host adapter only
// carries one assembled call to a model and brings back what it said. That line
// is what lets a deterministic fake stand in for a live model in tests without
// standing in for anything else: the store, the commands, the schemas and the
// protocol are the real ones on both sides of it.
//
// An implementation must honour ctx. The engine cancels it when the user
// cancels the run, when the per-member timeout expires, and when the whole run
// exhausts its budget, and it relies on Generate returning promptly so a run
// reaches a resting state instead of hanging.
type ChatHost interface {
	Generate(ctx context.Context, call ModelCall) (ModelReply, error)
}

// ModelCall is one assembled consultation. The prompt is already built: the
// engine owns what a member is told, so an adapter cannot quietly add context
// one member should not have seen.
type ModelCall struct {
	// Routing. These identify the contribution the reply belongs to; an adapter
	// may log them and must not otherwise act on them.
	RunID          string
	ContributionID string
	SeatID         string
	MemberID       string
	MemberRevision int

	// Role is "advisor" for a member contribution and "chair" for the
	// synthesis. It exists so an adapter can pick a different endpoint for the
	// two if it ever needs to; the prompts already differ.
	Role string

	// Model is the host model name to ask for, resolved against the host's
	// enabled-model catalogue where one could be read (models.go). Empty means
	// Council could not see a catalogue and expressed no preference, which is
	// the adapter's cue to fall back to the host's default route.
	Model string

	// Provider disambiguates a model_name two enabled providers both offer. It
	// is the provider's DISPLAY name lowercased by the host before comparison,
	// not the stable key host.models.list_providers returns beside it. Empty
	// when the model is unambiguous or unresolved.
	Provider string

	// System and User are the assembled prompt. An initial member call carries
	// no other member's answer in either of them — that is the independence
	// rule, and it is enforced where the prompt is built rather than trusted to
	// an adapter.
	System string
	User   string
}

// ModelReply is what a model said, plus what it cost.
//
// ModelID is what actually answered, which is not necessarily what was asked
// for: a council may name a model the user does not have enabled, and the
// record must attribute the answer to the model that produced it.
type ModelReply struct {
	ModelID          string
	Text             string
	PromptTokens     int
	CompletionTokens int
	// UsageReported distinguishes "the host said nothing about cost" from "the
	// call cost nothing". Only a reported figure is written into the record.
	UsageReported bool
}

// unavailableChatHost is the default: it refuses every call and says why.
//
// A Store built without a host is not broken, it is a Store that cannot consult
// anybody — the state in which the engine runs under `go test` for the parts of
// the protocol that never reach a model, and the state a backend is in before
// its stdio transport has been bound. Refusing with model_unavailable puts that
// in front of the user as a visible, retryable failure instead of a hang.
type unavailableChatHost struct{}

func (unavailableChatHost) Generate(context.Context, ModelCall) (ModelReply, error) {
	return ModelReply{}, HostFailure(CodeModelUnavailable,
		"this Council backend has no route to a host model, so nobody could be consulted")
}

// SetChatHost installs the adapter the engine consults through. It replaces the
// refusing default; production binds the host's capability transport, and a
// test binds a fake whose replies it controls.
func (s *Store) SetChatHost(host ChatHost) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if host == nil {
		host = unavailableChatHost{}
	}
	s.chat = host
}

// ConcurrencyLimiter lets an adapter say how many calls it can carry at once.
// An adapter that does not implement it is taken to carry as many as the
// council allows.
//
// The engine clamps its own semaphore to this rather than letting members queue
// inside the adapter, because a member's timeout is armed when it takes a slot:
// one that waited inside the adapter would spend its allowance queueing and
// expire without ever having been asked.
type ConcurrencyLimiter interface {
	Concurrency() int
}

// FailureCoder lets a host adapter say which of Council's visible failure
// states its error belongs in. The failure enum is the record's, not the
// transport's, so the mapping from "the broker refused this" to
// model_unavailable belongs with the adapter that read the refusal.
//
// An error that does not implement it is recorded as model_error, which is the
// honest default: something went wrong at the model, and the message says what.
type FailureCoder interface {
	CouncilFailureCode() string
}

type codedError struct {
	code    string
	message string
}

func (e codedError) Error() string              { return e.message }
func (e codedError) CouncilFailureCode() string { return e.code }

// HostFailure builds an error carrying one of the record's failure codes. An
// adapter uses it so a refusal reaches the user as the state it actually is.
func HostFailure(code, message string) error {
	return codedError{code: code, message: message}
}

// failureCodeOf reads the code an error carries, defaulting to model_error.
func failureCodeOf(err error) string {
	var coded FailureCoder
	if errors.As(err, &coded) {
		return coded.CouncilFailureCode()
	}
	switch {
	case errors.Is(err, context.Canceled):
		return CodeCancelled
	case errors.Is(err, context.DeadlineExceeded):
		return CodeTimeout
	}
	return CodeModelError
}

// generate enforces the combined system/user budget before contacting a model.
// An empty user prompt means its required sections could not fit.
func (s *Store) generate(ctx context.Context, call ModelCall, maxBytes int) (ModelReply, error) {
	if call.User == "" || len(call.System)+len(call.User) > maxBytes {
		return ModelReply{}, HostFailure(CodePayloadTooLarge, "Required prompt material exceeds this council's per-call byte limit; shorten the question or increase the limit.")
	}
	return s.chatHost().Generate(ctx, call)
}
