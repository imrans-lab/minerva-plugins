package libraries

// Status reports what fraction of the lock manifest is present + verified
// under destDir, without fetching anything.
type Status struct {
	Present         bool     `json:"present"`
	VersionTag      string   `json:"version_tag"`
	EntriesVerified int      `json:"entries_verified"`
	TotalEntries    int      `json:"total_entries"`
	Missing         []string `json:"missing"`
}

// GetStatus loads the lock manifest at lockPath and checks, for every entry,
// whether destDir already has a verified (sha256-matching) copy. Present is
// true only when every entry verifies — a partial/corrupt fetch reports
// Present:false with the specific missing names, so a caller can decide
// whether to re-run pcb_fetch_libraries.
func GetStatus(lockPath, destDir string) (Status, error) {
	lock, err := LoadLock(lockPath)
	if err != nil {
		return Status{}, err
	}

	st := Status{VersionTag: lock.Tag, TotalEntries: len(lock.Entries), Missing: []string{}}
	for _, e := range lock.Entries {
		if verifyFileSHA256(e.DestPath(destDir), e.SHA256) {
			st.EntriesVerified++
		} else {
			st.Missing = append(st.Missing, e.Name)
		}
	}
	st.Present = st.TotalEntries > 0 && st.EntriesVerified == st.TotalEntries
	return st, nil
}
