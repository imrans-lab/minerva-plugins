package session

import (
	"context"
	"fmt"
	"sort"
	"strings"
)

// Council's model choice is EXPLICIT. This file is why.
//
// The host resolves the model string "default" to its TurnRock/Core provider
// (CapabilityBroker.gd:2354-2361), and that provider is constructible with no
// service and no action — a degraded instance the chat picker itself refuses
// (ChatPane.gd:5244-5253). A council that leaned on it would fail at the model
// call, after a round had been planned and a user had waited. So the engine
// learns which models the host actually has, offers only those, and refuses a
// hint it cannot see before anything is spent.
//
// Two strings matter and they are not interchangeable. host.providers.chat
// matches its "model" argument against each enabled model's model_name
// (CapabilityBroker.gd:2402-2416), which is what host.models.list_models
// returns. When two providers offer the same model_name it disambiguates with
// "provider", compared against the provider's DISPLAY name lowercased
// (CapabilityBroker.gd:2427-2432) — not the "key" that
// host.models.list_providers returns beside it. Both are carried here so a call
// can be aimed unambiguously.

// HostModel is one entry of the host's enabled-model catalogue, assembled from
// host.models.list_providers and host.models.list_models.
type HostModel struct {
	// ProviderKey is list_providers' "key": the stable lowercase enum name
	// (singleton_object.gd:2044-2045). It identifies the provider to
	// list_models and is what a user-facing list should group by.
	ProviderKey string
	// ProviderDisplay is list_providers' "display". It is the value
	// host.providers.chat's "provider" argument is matched against.
	ProviderDisplay string
	// ModelName is list_models' "model_name" and the only string
	// host.providers.chat's "model" argument will match.
	ModelName string
	// ModelDisplay is what a chooser should show for this model.
	ModelDisplay string
}

// ModelCatalog is how the engine learns what the host has enabled. One method,
// for the same reason ChatHost has one: the engine decides what a refusal
// means, and the adapter only fetches.
//
// One known gap, and it is the host's: host.models.list_models enumerates the
// DYNAMIC provider map alone (singleton_object.gd:2079-2091), while
// host.providers.chat also matches the static built-in models
// (CapabilityBroker.gd:2374-2392). A built-in a user has enabled is therefore
// callable but absent from the catalogue, and the check below refuses it. The
// refusal names the models it can see, so the user is told what to pick rather
// than left guessing.
type ModelCatalog interface {
	Models(ctx context.Context) ([]HostModel, error)
}

// SetModelCatalog installs the source the enabled-model list is read from.
// Production binds the host's capability transport; a test binds a fixed list.
func (s *Store) SetModelCatalog(catalog ModelCatalog) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.catalog = catalog
}

// RefreshModels re-reads the host's enabled models and replaces the cached
// catalogue. It makes host calls, so it must be called with the engine lock
// RELEASED — the tool layer calls it at startup, when a document is loaded, and
// when a caller asks for the list.
//
// A failure leaves the previous catalogue in place and is reported. It is not
// fatal: a backend that cannot see the catalogue falls back to passing hints
// through unchecked, which is worse than refusing early and better than
// refusing everything.
func (s *Store) RefreshModels(ctx context.Context) error {
	s.mu.Lock()
	catalog := s.catalog
	s.mu.Unlock()
	if catalog == nil {
		return fmt.Errorf("this Council backend has no route to the host's model catalogue")
	}
	models, err := catalog.Models(ctx)
	if err != nil {
		return err
	}
	sort.Slice(models, func(i, j int) bool {
		if models[i].ProviderKey != models[j].ProviderKey {
			return models[i].ProviderKey < models[j].ProviderKey
		}
		return models[i].ModelName < models[j].ModelName
	})
	s.mu.Lock()
	defer s.mu.Unlock()
	s.models = models
	s.modelsKnown = true
	return nil
}

// Models reports the cached catalogue and whether one has ever been read. The
// second value is the difference between "the host has no models" and "Council
// has not been able to ask", and every refusal here turns on it.
func (s *Store) Models() ([]HostModel, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]HostModel{}, s.models...), s.modelsKnown
}

// findModel resolves a model hint against the cached catalogue. The caller
// holds the lock.
//
// Matching is case-insensitive because the host's own matching is — it compares
// both the static built-ins and the dynamic entries with .to_lower() on each
// side (CapabilityBroker.gd:2391, :2413) — so a hint that would work must not
// be refused here over its capitalisation.
func (s *Store) findModel(hint string) (HostModel, bool) {
	for _, model := range s.models {
		if strings.EqualFold(model.ModelName, hint) {
			return model, true
		}
	}
	return HostModel{}, false
}

// checkModelHint refuses a hint the host does not have. The caller holds the
// lock.
//
// It is silent when no catalogue has been read: absence of the list is not
// evidence the model is missing, and refusing every hint because Council could
// not ask would break a working council on a host that never answered.
func (s *Store) checkModelHint(hint, where string) *Failure {
	if hint == "" || !s.modelsKnown {
		return nil
	}
	if _, found := s.findModel(hint); found {
		return nil
	}
	return fail(CodeModelUnavailable, fmt.Sprintf(
		"%s names the model %q, which is not one this Minerva has enabled. Enabled models: %s. Enable it in Minerva's model settings, or pick one of these; if you have just enabled it, refresh the list with minerva_council_models.",
		where, hint, s.modelNames()), false)
}

// modelNames renders the catalogue for a refusal message, capped so a host with
// a long list cannot push a multi-kilobyte error through the transport.
func (s *Store) modelNames() string {
	if len(s.models) == 0 {
		return "none — this Minerva has no enabled model with a usable name"
	}
	const maxReported = 12
	names := make([]string, 0, len(s.models))
	for _, model := range s.models {
		names = append(names, model.ModelName)
	}
	if len(names) > maxReported {
		return strings.Join(names[:maxReported], ", ") + fmt.Sprintf(", and %d more", len(names)-maxReported)
	}
	return strings.Join(names, ", ")
}

// modelFor picks the model one seat is asked with, and the provider that
// disambiguates it. The run's own override wins, then the member's hint.
//
// An expressed hint is resolved against the catalogue so the call carries the
// provider too; an unknown one is passed through unchanged, because by the time
// a round is planned the refusal has already happened at member.upsert and
// run.start and passing it on is more honest than substituting a model nobody
// asked for.
//
// With no hint at all the engine takes the catalogue's FIRST model rather than
// sending "default": the host resolves "default" to a Core provider that may
// have no service or action behind it, and a council must not depend on that
// route. With no catalogue there is nothing to choose from and the empty string
// travels, which is the adapter's cue to fall back to "default".
//
// The caller holds the lock.
func (s *Store) modelFor(run map[string]any, seatID string, member map[string]any) (string, string) {
	hint := str(obj(run["model_overrides"])[seatID])
	if hint == "" {
		hint = str(member["model_hint"])
	}
	if hint != "" {
		if model, found := s.findModel(hint); found {
			return model.ModelName, model.ProviderDisplay
		}
		return hint, ""
	}
	if len(s.models) > 0 {
		return s.models[0].ModelName, s.models[0].ProviderDisplay
	}
	return "", ""
}

// checkRunModels refuses a run whose seats, or whose overrides, name a model
// the host does not have — before the run record is created, so nothing is
// spent and nothing has to be cancelled. The caller holds the lock.
func (s *Store) checkRunModels(session map[string]any, overrides map[string]any, seats []map[string]any) *Failure {
	if !s.modelsKnown {
		return nil
	}
	def := obj(session["definition_snapshot"])
	// Every override is checked, including one for a seat this round does not
	// consult: it is stored on the run and a retry reads it back.
	for seatID, value := range overrides {
		if f := s.checkModelHint(str(value), fmt.Sprintf("the model override for seat %q", seatID)); f != nil {
			return f
		}
	}
	// The chair answers every round, so its hint is checked alongside the
	// advisors' even though it is never in seats.
	checked := append(append([]map[string]any{}, seats...), chairSeatOf(def))
	for _, seat := range checked {
		if seat == nil {
			continue
		}
		seatID := str(seat["seat_id"])
		if str(overrides[seatID]) != "" {
			continue
		}
		member, _ := findByID(def["members"], "member_id", str(seat["member_id"]))
		if member == nil {
			continue
		}
		if f := s.checkModelHint(str(member["model_hint"]),
			fmt.Sprintf("the member in seat %q", seatID)); f != nil {
			return f
		}
	}
	return nil
}
