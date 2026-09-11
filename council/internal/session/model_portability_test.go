package session

import (
	"context"
	"testing"
)

type portabilityCatalog []HostModel

func (c portabilityCatalog) Models(context.Context) ([]HostModel, error) { return c, nil }

func TestModelSelectionAcrossInstallations(t *testing.T) {
	for _, kind := range []string{"builtin", "dynamic"} {
		t.Run(kind, func(t *testing.T) {
			s := &Store{}
			catalog := portabilityCatalog{{ProviderKey: "provider-a", ModelName: "model-a", ModelSpec: map[string]any{"kind": kind, "model_id": 10003}}}
			s.SetModelCatalog(catalog)
			if err := s.RefreshModels(context.Background()); err != nil {
				t.Fatal(err)
			}
			saved := s.models[0].ModelSpec
			if f := s.checkModelSelection(saved, "member"); f != nil {
				t.Fatal(f)
			}
			if f := s.checkModelSelection(map[string]any{"kind": kind, "model_id": 10003}, "unguarded old selection"); f == nil {
				t.Fatal("unguarded installation-local ID accepted")
			}
			catalog[0].ModelName = "different-model"
			if err := s.RefreshModels(context.Background()); err != nil {
				t.Fatal(err)
			}
			if f := s.checkModelSelection(saved, "imported member"); f == nil {
				t.Fatal("same numeric ID silently substituted another model")
			}
			catalog[0].ModelName = "model-a"
			catalog[0].ProviderKey = "provider-b"
			if err := s.RefreshModels(context.Background()); err != nil {
				t.Fatal(err)
			}
			if f := s.checkModelSelection(saved, "imported member"); f == nil {
				t.Fatal("same name silently substituted another provider")
			}
		})
	}
}
