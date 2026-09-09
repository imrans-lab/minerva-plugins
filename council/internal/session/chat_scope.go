package session

// A chat turn spans commands and waits without holding the store lock. Its
// scope pins commands to the original document and lets cancel reach setup
// before a durable run exists.
type chatScope struct {
	*Store
	chatID     string
	generation uint64
	cancelled  bool // protected by Store.mu
}

func (s *Store) beginChat(chatID string, cancel bool) *chatScope {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.chatActive == nil {
		s.chatActive = make(map[*chatScope]struct{})
	}
	if cancel {
		for active := range s.chatActive {
			if active.chatID == chatID && active.generation == s.generation {
				active.cancelled = true
			}
		}
	}
	scope := &chatScope{Store: s, chatID: chatID, generation: s.generation}
	s.chatActive[scope] = struct{}{}
	return scope
}

func (s *chatScope) close() {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.chatActive, s)
}

// guard runs under the dispatcher lock before command application. Revision
// retries may follow panel edits, never document replacements.
func (s *chatScope) guard(req *Request) *Failure {
	if s.generation != s.Store.generation {
		return fail(CodeStaleRevision, "The Council document changed during this chat turn. Ask again in the intended document.", false)
	}
	if s.cancelled {
		return fail(CodeCancelled, "This chat turn was cancelled before its next command committed.", false)
	}
	if req.Command == "run.start" {
		record, _ := findByID(s.snapshot["sessions"], "session_id", str(req.Payload["session_id"]))
		if record != nil {
			binding := obj(record["chat_binding"])
			if str(binding["chat_id"]) != s.chatID || str(binding["project_id"]) != s.projectID() {
				return fail(CodeMissingChat, "The session's chat binding changed during this turn. Ask again.", false)
			}
			for _, value := range arr(record["runs"]) {
				if !restingStatus(str(obj(value)["status"])) {
					return fail(CodeStaleRevision, "This session already has a round running. Wait for it before asking again.", false)
				}
			}
		}
	}
	return nil
}
