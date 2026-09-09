package session

import (
	"log"

	"github.com/ipeerbhai/plugins/council/internal/contract"
)

// terminalResultFailure is also used by the snapshot budget check, reserving
// the exact state needed to explain a rejected asynchronous result.
func terminalResultFailure(session, run map[string]any) {
	failure := func() map[string]any {
		return map[string]any{"code": CodeInternal, "message": "Council could not store a model result. Reduce this document or retry.", "retryable": true}
	}
	for _, x := range arr(run["contributions"]) {
		contribution := obj(x)
		if status := str(contribution["status"]); status == "pending" || status == "running" {
			contribution["status"] = "failed"
			contribution["failure"] = failure()
		}
	}
	run["status"] = "failed"
	run["failure"] = failure()
	session["status"] = contract.DeriveSessionStatus(session)
	bumpSession(session)
}

// The caller holds the store lock. Accepted answers survive a rejected result;
// the run reaches a visible, retryable failure instead of losing its handle
// while the record still says it is running.
func (s *Store) failResult(sessionID, runID string, reason *Failure) {
	log.Printf("Council result rejected session=%s run=%s: %s", sessionID, runID, reason.Message)
	if f := s.commit(func(snap map[string]any) *Failure {
		session, _ := findByID(snap["sessions"], "session_id", sessionID)
		if session == nil {
			return unchanged
		}
		run, _ := findByID(session["runs"], "run_id", runID)
		if run == nil || (str(run["status"]) != "pending" && str(run["status"]) != "running") {
			return unchanged
		}
		terminalResultFailure(session, run)
		return nil
	}); f != nil && f != unchanged {
		log.Printf("Council could not record reserved result failure: %s", f.Message)
	}
	if control := s.live[runKey(sessionID, runID)]; control != nil {
		control.cancel()
	}
}
