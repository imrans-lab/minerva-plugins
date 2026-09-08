// Package tools — shared decoding for numeric tool arguments.
//
// The Minerva host re-serializes tool arguments after parsing them, and its
// JSON parser carries every number as a float. An argument a caller wrote as
// `0` can therefore reach the plugin spelled `0` or `0.0`, and both mean the
// same integer. Tools that need a whole number decode it through jsonInt
// rather than a Go `int` field, which accepts only the first spelling.
package tools

import (
	"bytes"
	"encoding/json"
	"errors"
	"math"
)

// errNotAWholeNumber says the value was a number but had a fractional part,
// which is a caller mistake rather than a host spelling artefact.
var errNotAWholeNumber = errors.New("must be a whole number")

// errNotANumber says the value was not a JSON number at all (a string, bool,
// object, or malformed text). A quoted numeric string is deliberately refused.
var errNotANumber = errors.New("must be a number")

// errOutOfRange says the value was a whole number too large to be one, which
// is a different mistake from writing a fraction and reads as one.
var errOutOfRange = errors.New("is out of range")

// jsonAbsent reports whether a raw argument is missing or the literal null,
// both of which mean "the caller did not pass this".
func jsonAbsent(raw json.RawMessage) bool {
	trimmed := bytes.TrimSpace(raw)
	return len(trimmed) == 0 || bytes.Equal(trimmed, []byte("null"))
}

// jsonInt decodes a raw JSON value that must be an integral number, accepting
// either the integer or the float spelling of the same value (0 and 0.0), and
// refusing anything with a fractional part. Values int64 cannot hold are
// refused as well, so a caller cannot wrap a bound check by overflowing it.
func jsonInt(raw json.RawMessage) (int64, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		return 0, errNotANumber
	}
	// A number TOKEN, not merely something json.Number can hold: decoding a
	// bare value leaves a quoted "0" as a string, which is not a number here.
	num, ok := v.(json.Number)
	if !ok {
		return 0, errNotANumber
	}
	if i, err := num.Int64(); err == nil {
		return i, nil
	}
	f, err := num.Float64()
	if err != nil {
		return 0, errNotANumber
	}
	if math.IsNaN(f) {
		return 0, errNotANumber
	}
	// The upper bound is 2^63 written out, not math.MaxInt64: MaxInt64 has no
	// exact float64, and converting it ROUNDS UP to 2^63 — so comparing
	// against it would admit the one value whose int64(f) overflows. MinInt64
	// is exactly representable, so its own comparison is already right.
	if math.IsInf(f, 0) || f < math.MinInt64 || f >= 9223372036854775808.0 {
		return 0, errOutOfRange
	}
	if f != math.Trunc(f) {
		return 0, errNotAWholeNumber
	}
	return int64(f), nil
}
