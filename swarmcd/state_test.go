package swarmcd

import (
	"os"
	"path"
	"sync"
	"testing"

	"github.com/m-adawi/swarm-cd/util"
)

// An unknown stack is never unchanged, so it gets deployed once
func TestDeployStateUnknownStack(t *testing.T) {
	state, err := loadDeployState("")
	if err != nil {
		t.Fatalf("unexpected error: %s", err)
	}
	if state.unchanged("app", "abc") {
		t.Errorf("unknown stack reported as unchanged")
	}
}

func TestDeployStateRecord(t *testing.T) {
	state, _ := loadDeployState("")
	if err := state.record("app", "abc", "1234abcd"); err != nil {
		t.Fatalf("unexpected error: %s", err)
	}
	if !state.unchanged("app", "abc") {
		t.Errorf("recorded hash not reported as unchanged")
	}
	if state.unchanged("app", "def") {
		t.Errorf("different hash reported as unchanged")
	}
	if state.unchanged("other", "abc") {
		t.Errorf("hash of one stack applied to another")
	}
}

// The state survives a restart when a state file is configured
func TestDeployStatePersisted(t *testing.T) {
	file := path.Join(t.TempDir(), "sub", "state.json")
	state, err := loadDeployState(file)
	if err != nil {
		t.Fatalf("unexpected error on missing file: %s", err)
	}
	if err := state.record("app", "abc", "1234abcd"); err != nil {
		t.Fatalf("unexpected error: %s", err)
	}

	reloaded, err := loadDeployState(file)
	if err != nil {
		t.Fatalf("unexpected error: %s", err)
	}
	if !reloaded.unchanged("app", "abc") {
		t.Errorf("hash lost after reload")
	}
	if got := reloaded.deployed("app").Revision; got != "1234abcd" {
		t.Errorf("revision after reload = %q, want %q", got, "1234abcd")
	}
}

// A broken state file must not stop SwarmCD; it deploys everything once
func TestDeployStateCorruptFile(t *testing.T) {
	file := path.Join(t.TempDir(), "state.json")
	os.WriteFile(file, []byte("{not json"), 0o600)
	state, err := loadDeployState(file)
	if err == nil {
		t.Errorf("expected an error for a corrupt state file")
	}
	if state == nil || state.unchanged("app", "abc") {
		t.Errorf("corrupt state file must yield an empty, usable state")
	}
}

func TestDeployHash(t *testing.T) {
	originalConfig := config
	config = &util.Config{AlwaysPullContainers: false}
	t.Cleanup(func() { config = originalConfig })

	repo := &stackRepo{name: "test", path: "test", lock: &sync.Mutex{}}
	stack := newSwarmStack("test", repo, "main", "compose.yaml", nil, "", false, nil)
	compose := []byte("services:\n  app:\n    image: app:1\n")

	base := stack.deployHash(compose)
	if base != stack.deployHash(compose) {
		t.Errorf("hash is not deterministic")
	}
	if base == stack.deployHash([]byte("services:\n  app:\n    image: app:2\n")) {
		t.Errorf("hash ignores the compose content")
	}

	// options that change the deploy command count as a change, too
	stack.prune = true
	if base == stack.deployHash(compose) {
		t.Errorf("hash ignores prune")
	}
	stack.prune = false
	stack.alwaysPullContainers = boolPtr(true)
	if base == stack.deployHash(compose) {
		t.Errorf("hash ignores the resolve image mode")
	}
}

// The marshalled compose file is what gets hashed, so it must not depend on map order
func TestMarshalStackDeterministic(t *testing.T) {
	repo := &stackRepo{name: "test", path: "test", lock: &sync.Mutex{}}
	stack := newSwarmStack("test", repo, "main", "compose.yaml", nil, "", false, nil)
	composeMap, err := stack.parseStackString([]byte(`services:
  b: {image: b}
  a: {image: a}
  c: {image: c}
configs:
  z: {file: ./z}
  y: {file: ./y}
`))
	if err != nil {
		t.Fatalf("unexpected error: %s", err)
	}
	first, err := marshalStack(composeMap)
	if err != nil {
		t.Fatalf("unexpected error: %s", err)
	}
	for i := 0; i < 20; i++ {
		again, _ := marshalStack(composeMap)
		if string(again) != string(first) {
			t.Fatalf("marshalled stack differs between runs:\n%s\n---\n%s", first, again)
		}
	}
}
