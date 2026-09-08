package contract

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
		// A session left "running" is demoted whether or not a demotable run
		// was found. The status describes the session, not the runs: a session
		// whose runs are all already terminal is still not running, and leaving
		// it saying so would show the user work that nothing is doing.
		if str(session["status"]) == "running" {
			session["status"] = "partial"
		}
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
