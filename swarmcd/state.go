package swarmcd

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path"
	"sync"
	"time"
)

// deployRecord is what SwarmCD remembers about the last successful deploy of a stack
type deployRecord struct {
	Hash       string    `json:"hash"`
	Revision   string    `json:"revision"`
	DeployedAt time.Time `json:"deployed_at"`
}

// deployState holds the last deployed hash per stack. With a file path it
// is persisted, so a restart of SwarmCD does not redeploy every stack.
type deployState struct {
	lock    sync.Mutex
	path    string
	records map[string]deployRecord
}

// loadDeployState reads the state file. A missing file yields an empty
// state; a corrupt one yields an empty state and an error to log, so that
// SwarmCD deploys everything once instead of refusing to start.
func loadDeployState(filePath string) (*deployState, error) {
	state := &deployState{path: filePath, records: map[string]deployRecord{}}
	if filePath == "" {
		return state, nil
	}
	data, err := os.ReadFile(filePath)
	if errors.Is(err, fs.ErrNotExist) {
		return state, nil
	}
	if err != nil {
		return state, fmt.Errorf("could not read state file %s: %w", filePath, err)
	}
	if err = json.Unmarshal(data, &state.records); err != nil {
		state.records = map[string]deployRecord{}
		return state, fmt.Errorf("could not parse state file %s: %w", filePath, err)
	}
	return state, nil
}

func (state *deployState) unchanged(stack string, hash string) bool {
	state.lock.Lock()
	defer state.lock.Unlock()
	record, ok := state.records[stack]
	return ok && record.Hash == hash
}

func (state *deployState) deployed(stack string) deployRecord {
	state.lock.Lock()
	defer state.lock.Unlock()
	return state.records[stack]
}

// record stores a successful deploy and writes the state file atomically
func (state *deployState) record(stack string, hash string, revision string) error {
	state.lock.Lock()
	defer state.lock.Unlock()
	state.records[stack] = deployRecord{Hash: hash, Revision: revision, DeployedAt: time.Now().UTC()}
	if state.path == "" {
		return nil
	}
	data, err := json.MarshalIndent(state.records, "", "  ")
	if err != nil {
		return fmt.Errorf("could not encode state: %w", err)
	}
	if err = os.MkdirAll(path.Dir(state.path), 0o755); err != nil {
		return fmt.Errorf("could not create directory for state file %s: %w", state.path, err)
	}
	tmp := state.path + ".tmp"
	if err = os.WriteFile(tmp, data, 0o600); err != nil {
		return fmt.Errorf("could not write state file %s: %w", tmp, err)
	}
	if err = os.Rename(tmp, state.path); err != nil {
		return fmt.Errorf("could not replace state file %s: %w", state.path, err)
	}
	return nil
}
