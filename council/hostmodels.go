package main

import (
	"context"
	"encoding/json"

	"github.com/ipeerbhai/plugins/council/internal/session"
)

// hostModelCatalog reads Minerva's enabled-model list over the same stdio
// capability transport the chat calls use.
//
// It is two capabilities, not one: host.models.list_providers answers with the
// enabled providers, and host.models.list_models answers with one provider's
// models (CapabilityBroker.gd:565-576). Both grants are declared in
// manifest.json; an undeclared one is refused by the policy gate before it is
// dispatched (CapabilityBroker.gd:271-285), so a build that forgot one gets a
// clear refusal rather than an empty list that looks like "no models". A host
// with no policy engine at all refuses everything the same way (:286-293).
type hostModelCatalog struct {
	host *stdioChatHost
}

// providerListing is host.models.list_providers' result body. "key" is the
// stable lowercase provider name; "display" is what the user sees — and, as
// host.providers.chat compares its own "provider" argument against the display
// name lowercased, it is also the disambiguator a call has to carry.
type providerListing struct {
	Providers []struct {
		Key     string `json:"key"`
		Display string `json:"display"`
	} `json:"providers"`
}

// modelListing is host.models.list_models' result body for one provider.
//
// model_spec is present only for a provider whose models are not a static list.
// Minerva sends it for the "turnrock" key, whose models are the live service
// actions of the running Core node, and the dictionary is what
// host.providers.chat must be handed back to reach that action — the action
// name alone does not say which service it belongs to. Council never reads
// inside it.
type modelListing struct {
	Provider string `json:"provider"`
	Models   []struct {
		ModelName string         `json:"model_name"`
		Display   string         `json:"display"`
		ModelSpec map[string]any `json:"model_spec"`
	} `json:"models"`
}

// Models assembles the flat catalogue the engine reasons about.
//
// A provider that answers with nothing is skipped rather than reported: the
// host already omits providers with no models from the provider list, so an
// empty model list is a provider that was disabled between the two calls, and
// there is nothing for a user to do about it.
func (c *hostModelCatalog) Models(ctx context.Context) ([]session.HostModel, error) {
	raw, err := c.host.exchange(ctx, "host.models.list_providers", map[string]any{})
	if err != nil {
		return nil, err
	}
	var providers providerListing
	if err := json.Unmarshal(raw, &providers); err != nil {
		return nil, session.HostFailure(session.CodeInternal,
			"the host's provider list could not be read: "+err.Error())
	}

	catalogue := []session.HostModel{}
	for _, provider := range providers.Providers {
		if provider.Key == "" {
			continue
		}
		body, err := c.host.exchange(ctx, "host.models.list_models",
			map[string]any{"provider": provider.Key})
		if err != nil {
			return nil, err
		}
		var models modelListing
		if err := json.Unmarshal(body, &models); err != nil {
			return nil, session.HostFailure(session.CodeInternal,
				"the host's model list for "+provider.Key+" could not be read: "+err.Error())
		}
		for _, model := range models.Models {
			if model.ModelName == "" {
				continue
			}
			entry := session.HostModel{
				ProviderKey:     provider.Key,
				ProviderDisplay: provider.Display,
				ModelName:       model.ModelName,
				ModelDisplay:    model.Display,
			}
			// An empty object is dropped rather than carried: the broker
			// refuses a model_spec with no kind, so sending one back would turn
			// a callable model into a refusal.
			if len(model.ModelSpec) > 0 {
				entry.ModelSpec = model.ModelSpec
			}
			catalogue = append(catalogue, entry)
		}
	}
	return catalogue, nil
}
