package contract

import (
	"encoding/json"
	"fmt"

	"github.com/ipeerbhai/plugins/council/schemas"
)

// schemaForKind maps a record kind onto the schema document that describes it.
// "council_envelope" is the one kind that is not stamped with a record_kind
// field, because an envelope is wire traffic rather than a stored record.
var schemaForKind = map[string]string{
	"council_definition":       schemas.CouncilDefinition,
	"council_session":          schemas.Session,
	"council_project_snapshot": schemas.ProjectSnapshot,
	"council_envelope":         schemas.Envelope,
}

// KindOf reports the record kind of a decoded document: the stored kinds carry
// a record_kind discriminator, wire envelopes carry an envelope field.
func KindOf(value any) (string, error) {
	m, ok := value.(map[string]any)
	if !ok {
		return "", fmt.Errorf("expected a JSON object")
	}
	if k, ok := m["record_kind"].(string); ok {
		if _, known := schemaForKind[k]; !known {
			return "", fmt.Errorf("unknown record_kind %q", k)
		}
		return k, nil
	}
	if _, ok := m["envelope"].(string); ok {
		return "council_envelope", nil
	}
	return "", fmt.Errorf("document carries neither record_kind nor envelope")
}

// ValidateRecord runs both halves of the contract against one JSON document:
// the shipped schema, then the cross-field invariants. Schema failures are
// returned on their own, because an invariant check on a structurally wrong
// document produces noise rather than information.
func (r *Registry) ValidateRecord(recordKind string, raw []byte) []string {
	var value any
	if err := json.Unmarshal(raw, &value); err != nil {
		return []string{fmt.Sprintf("(root): not valid JSON: %v", err)}
	}
	file, ok := schemaForKind[recordKind]
	if !ok {
		return []string{fmt.Sprintf("(root): unknown record kind %q", recordKind)}
	}
	if errs := r.Validate(file, value); len(errs) > 0 {
		return errs
	}
	return CheckInvariants(recordKind, value)
}
