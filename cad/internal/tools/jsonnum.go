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
	"math/big"
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
	// A 64-bit mantissa represents every int64 exactly. Retain the parse
	// accuracy too: rounding a fraction to an integer must not accept it.
	f, _, err := big.ParseFloat(num.String(), 10, 64, big.ToZero)
	if err != nil {
		return 0, errNotANumber
	}
	if f.Cmp(new(big.Float).SetInt64(math.MinInt64)) < 0 || f.Cmp(new(big.Float).SetInt64(math.MaxInt64)) > 0 {
		return 0, errOutOfRange
	}
	i, accuracy := f.Int64()
	if f.Acc() != big.Exact || accuracy != big.Exact {
		return 0, errNotAWholeNumber
	}
	return i, nil
}
