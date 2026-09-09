package session

import (
	"encoding/json"
	"reflect"
	"testing"
)

func TestChatSetupCannotCrossDocumentReplacement(t *testing.T) {
	s := reviewStore(t)
	scope := s.beginChat("chat-review", false)
	defer scope.close()
	raw, _ := json.Marshal(s.Export())
	if _, err := s.Load(raw); err != nil {
		t.Fatal(err)
	}
	before := s.Export()
	reply := scope.chatCommand("session.bind_chat", map[string]any{"session_id": "ses-recurring-order", "chat_id": "chat-review"}, true, nil)
	if reply.OK || reply.Error.Code != CodeStaleRevision {
		t.Fatalf("old turn crossed load: %+v", reply)
	}
	scope.rememberQuestion("chat-review", "old question")
	scope.rememberCouncil("chat-review", "old council")
	scope.noteChat("chat-review")
	if !reflect.DeepEqual(before, s.Export()) || len(s.chatPending) != 0 || len(s.chatCouncil) != 0 || s.chatProject["chat-review"] != "" {
		t.Fatal("old turn changed replacement document or its routing state")
	}
}

func TestChatCancelReachesSetupAndDoesNotPoisonNextTurn(t *testing.T) {
	for _, bound := range []bool{false, true} {
		s := reviewStore(t)
		scope := s.beginChat("chat-review", false)
		if bound {
			reply := scope.chatCommand("session.bind_chat", map[string]any{"session_id": "ses-recurring-order", "chat_id": "chat-review"}, true, nil)
			if !reply.OK {
				t.Fatalf("bind: %+v", reply)
			}
		}
		before := s.Export()
		s.ChatCancelFor("chat-review")
		command, payload := "session.create", map[string]any{"session_id": "ses-new", "definition_id": "def-unused", "question": "Question", "chat_id": "chat-review"}
		if bound {
			command, payload = "run.start", map[string]any{"session_id": "ses-recurring-order"}
		}
		reply := scope.chatCommand(command, payload, true, nil)
		if reply.OK || reply.Error.Code != CodeCancelled {
			t.Fatalf("setup survived cancel: %+v", reply)
		}
		if !reflect.DeepEqual(before, s.Export()) {
			t.Fatal("cancelled setup mutated document")
		}
		scope.close()
		next := s.beginChat("chat-review", false)
		reply = next.chatCommand("session.bind_chat", map[string]any{"session_id": "ses-recurring-order", "chat_id": "chat-review"}, true, nil)
		next.close()
		if !reply.OK || len(s.chatActive) != 0 {
			t.Fatalf("cancel poisoned next turn or retained scope: %+v", reply)
		}
	}
}

func TestChatCommitRefusesConcurrentRound(t *testing.T) {
	s := reviewStore(t)
	scope := s.beginChat("chat-review", false)
	defer scope.close()
	bound := scope.chatCommand("session.bind_chat", map[string]any{"session_id": "ses-recurring-order", "chat_id": "chat-review"}, true, nil)
	if !bound.OK {
		t.Fatalf("bind: %+v", bound)
	}
	// Commit the first run without executing its deferred model work. The second
	// turn must see it at the mutation boundary, even if it routed before commit.
	prepareReviewRun(t, s, nil)
	before := s.Export()
	reply := scope.chatCommand("run.start", map[string]any{"session_id": "ses-recurring-order"}, true, nil)
	if reply.OK || reply.Error.Code != CodeStaleRevision {
		t.Fatalf("second live round accepted: %+v", reply)
	}
	if !reflect.DeepEqual(before, s.Export()) {
		t.Fatal("duplicate round changed the record")
	}
}
