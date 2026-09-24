package main

import (
	"encoding/json"
	"fmt"
)

// callCapability asks the host for a capability and waits on stdin for the
// matching reply. Safe only from inside a tools/call handler: the host sends
// no other request while one is in flight, so the next stdin line is ours.
func (s *server) callCapability(capability string, args map[string]interface{}) (json.RawMessage, error) {
	s.capSeq++
	id := fmt.Sprintf(`"cap-%d"`, s.capSeq)
	s.send(map[string]interface{}{
		"jsonrpc": "2.0", "id": json.RawMessage(id), "method": "minerva/capability",
		"params": map[string]interface{}{"capability": capability, "args": args},
	})
	for s.in.Scan() {
		var resp struct {
			ID     json.RawMessage `json:"id"`
			Result json.RawMessage `json:"result"`
			Error  *rpcError       `json:"error"`
		}
		if err := json.Unmarshal(s.in.Bytes(), &resp); err != nil || string(resp.ID) != id {
			continue
		}
		if resp.Error != nil {
			return nil, fmt.Errorf("%s: %s", capability, resp.Error.Message)
		}
		return resp.Result, nil
	}
	return nil, fmt.Errorf("stdin closed waiting for %s", capability)
}

// pickSavePath pops the host save dialog. Empty path means the user cancelled.
func (s *server) pickSavePath(title, initial string) (string, error) {
	raw, err := s.callCapability("host.dialogs.file_picker", map[string]interface{}{
		"mode": "save", "title": title, "initial_path": initial, "filters": []string{"*.csv"},
	})
	if err != nil {
		return "", err
	}
	var pick struct {
		Success      bool   `json:"success"`
		ErrorMessage string `json:"error_message"`
		Result       struct {
			Cancelled bool   `json:"cancelled"`
			Path      string `json:"path"`
		} `json:"result"`
	}
	if err := json.Unmarshal(raw, &pick); err != nil {
		return "", err
	}
	if !pick.Success {
		return "", fmt.Errorf("file picker: %s", pick.ErrorMessage)
	}
	if pick.Result.Cancelled {
		return "", nil
	}
	return pick.Result.Path, nil
}
