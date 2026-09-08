package contract

// DeriveSessionStatus computes a session's status from its runs. It is the one
// derivation: nothing sets a session status directly, so starting a run,
// cancelling one, and demoting an interrupted one cannot disagree about what
// the session as a whole is doing.
//
// The rules follow the state model. A session with no runs is a draft. A
// session with any run still pending or running is running. Otherwise the last
// run decides, and a failed run is read as "partial" when members were actually
// dispatched — some member failed or was cancelled — and as "failed" only when
// the round never got as far as consulting anybody.
func DeriveSessionStatus(session map[string]any) string {
	runs := arr(session["runs"])
	if len(runs) == 0 {
		return "draft"
	}
	for _, r := range runs {
		switch str(obj(r)["status"]) {
		case "pending", "running":
			return "running"
		}
	}
	last := obj(runs[len(runs)-1])
	switch status := str(last["status"]); status {
	case "failed":
		if len(arr(last["contributions"])) > 0 {
			return "partial"
		}
		return "failed"
	case "complete", "partial", "cancelled":
		return status
	default:
		return "partial"
	}
}

// RehydrateOnLoad prepares a snapshot that has just come back from project
// restore for use by a freshly started backend.
//
// The rule it enforces is the one that costs money to get wrong: a run that was
// in flight when the panel closed, the plugin stopped, or Minerva exited is
// NOT resumed. The process that owned those model calls is gone, so the run is
// marked interrupted and its unfinished contributions with it. The user sees a
// visible failed state with a retry, and nothing spends tokens on its own.
//
// It returns the number of runs it demoted, so a caller can report the state
// change rather than silently rewriting the user's history.
func RehydrateOnLoad(snapshot map[string]any) int {
	demoted := 0
	for _, s := range arr(snapshot["sessions"]) {
		session := obj(s)
		for _, r := range arr(session["runs"]) {
			run := obj(r)
			status := str(run["status"])
			if status != "pending" && status != "running" {
				continue
			}
			for _, c := range arr(run["contributions"]) {
				contribution := obj(c)
				switch str(contribution["status"]) {
				case "pending", "running":
					contribution["status"] = "failed"
					contribution["failure"] = interruptedFailure()
				}
			}
			run["status"] = "failed"
			run["failure"] = interruptedFailure()
			demoted++
		}
		// The session status is re-derived whether or not a demotable run was
		// found: the status describes the run set, and a session left saying
		// "running" over runs that are all terminal would show the user work
		// that nothing is doing.
		session["status"] = DeriveSessionStatus(session)
	}
	return demoted
}

func interruptedFailure() map[string]any {
	return map[string]any{
		"code":      "interrupted",
		"message":   "The run was in flight when the session was last closed. It was not resumed; start it again to retry.",
		"retryable": true,
	}
}
