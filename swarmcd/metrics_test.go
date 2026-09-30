package swarmcd

import (
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus/testutil"
)

func TestMetricsCheckWithoutDeploy(t *testing.T) {
	m := newStackMetrics()
	m.initStack("app", deployRecord{})
	now := time.Unix(1000, 0)
	m.recordCheck("app", false, "1234abcd", nil, now)

	if got := testutil.ToFloat64(m.lastSuccess.WithLabelValues("app")); got != 1000 {
		t.Errorf("last success = %v, want 1000", got)
	}
	if got := testutil.ToFloat64(m.lastDeploy.WithLabelValues("app")); got != 0 {
		t.Errorf("last deploy = %v, want 0 (nothing deployed)", got)
	}
	if got := testutil.ToFloat64(m.deploys.WithLabelValues("app")); got != 0 {
		t.Errorf("deploys = %v, want 0", got)
	}
}

func TestMetricsDeployAndFailure(t *testing.T) {
	m := newStackMetrics()
	m.initStack("app", deployRecord{})

	m.recordCheck("app", true, "1234abcd", nil, time.Unix(1000, 0))
	m.recordCheck("app", false, "", errors.New("boom"), time.Unix(1100, 0))

	if got := testutil.ToFloat64(m.failing.WithLabelValues("app")); got != 1 {
		t.Errorf("failing = %v, want 1", got)
	}
	if got := testutil.ToFloat64(m.lastFailure.WithLabelValues("app")); got != 1100 {
		t.Errorf("last failure = %v, want 1100", got)
	}
	if got := testutil.ToFloat64(m.lastSuccess.WithLabelValues("app")); got != 1000 {
		t.Errorf("last success = %v, want 1000 (unchanged by the failure)", got)
	}
	if got := testutil.ToFloat64(m.lastCheck.WithLabelValues("app")); got != 1100 {
		t.Errorf("last check = %v, want 1100", got)
	}
	if got := testutil.ToFloat64(m.deploys.WithLabelValues("app")); got != 1 {
		t.Errorf("deploys = %v, want 1", got)
	}
	if got := testutil.ToFloat64(m.failures.WithLabelValues("app")); got != 1 {
		t.Errorf("failures = %v, want 1", got)
	}

	// the next good check clears the failure flag
	m.recordCheck("app", false, "1234abcd", nil, time.Unix(1200, 0))
	if got := testutil.ToFloat64(m.failing.WithLabelValues("app")); got != 0 {
		t.Errorf("failing after recovery = %v, want 0", got)
	}
}

// Exactly one info series per stack, carrying the deployed commit
func TestMetricsDeployedRevision(t *testing.T) {
	m := newStackMetrics()
	m.initStack("app", deployRecord{Revision: "aaaaaaaa", DeployedAt: time.Unix(900, 0)})
	if got := testutil.ToFloat64(m.lastDeploy.WithLabelValues("app")); got != 900 {
		t.Errorf("last deploy from state = %v, want 900", got)
	}

	m.recordCheck("app", true, "bbbbbbbb", nil, time.Unix(1000, 0))
	// a check without deploy must not move the deployed revision
	m.recordCheck("app", false, "cccccccc", nil, time.Unix(1100, 0))

	want := `
# HELP swarmcd_stack_deployed_info Commit of the last successful deploy of a stack.
# TYPE swarmcd_stack_deployed_info gauge
swarmcd_stack_deployed_info{revision="bbbbbbbb",stack="app"} 1
`
	if err := testutil.CollectAndCompare(m.deployedInfo, strings.NewReader(want)); err != nil {
		t.Error(err)
	}
}

// Stacks get their series at start, so a stack that never ran is visible
func TestMetricsInitStack(t *testing.T) {
	m := newStackMetrics()
	m.initStack("app", deployRecord{})
	if got := testutil.CollectAndCount(m.failing); got != 1 {
		t.Errorf("failing series = %d, want 1", got)
	}
	if got := testutil.CollectAndCount(m.deployedInfo); got != 0 {
		t.Errorf("deployed info without any deploy = %d series, want 0", got)
	}
}
