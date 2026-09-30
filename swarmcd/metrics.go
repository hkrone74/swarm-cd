package swarmcd

import (
	"net/http"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// stackMetrics are the per-stack metrics served on /metrics
type stackMetrics struct {
	registry     *prometheus.Registry
	lastCheck    *prometheus.GaugeVec
	lastSuccess  *prometheus.GaugeVec
	lastFailure  *prometheus.GaugeVec
	lastDeploy   *prometheus.GaugeVec
	failing      *prometheus.GaugeVec
	deployedInfo *prometheus.GaugeVec
	deploys      *prometheus.CounterVec
	failures     *prometheus.CounterVec
}

var metrics = newStackMetrics()

func newStackMetrics() *stackMetrics {
	gauge := func(name, help string, labels ...string) *prometheus.GaugeVec {
		return prometheus.NewGaugeVec(prometheus.GaugeOpts{Namespace: "swarmcd", Subsystem: "stack", Name: name, Help: help}, labels)
	}
	counter := func(name, help string) *prometheus.CounterVec {
		return prometheus.NewCounterVec(prometheus.CounterOpts{Namespace: "swarmcd", Subsystem: "stack", Name: name, Help: help}, []string{"stack"})
	}
	m := &stackMetrics{
		registry:     prometheus.NewRegistry(),
		lastCheck:    gauge("last_check_timestamp_seconds", "Time of the last update check of a stack, successful or not.", "stack"),
		lastSuccess:  gauge("last_success_timestamp_seconds", "Time of the last update check of a stack that ended without error.", "stack"),
		lastFailure:  gauge("last_failure_timestamp_seconds", "Time of the last update check of a stack that ended with an error.", "stack"),
		lastDeploy:   gauge("last_deploy_timestamp_seconds", "Time of the last successful deploy of a stack.", "stack"),
		failing:      gauge("failing", "1 if the last update check of a stack ended with an error.", "stack"),
		deployedInfo: gauge("deployed_info", "Commit of the last successful deploy of a stack.", "stack", "revision"),
		deploys:      counter("deploys_total", "Successful deploys of a stack."),
		failures:     counter("failures_total", "Update checks of a stack that ended with an error."),
	}
	m.registry.MustRegister(
		collectors.NewGoCollector(),
		collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
		m.lastCheck, m.lastSuccess, m.lastFailure, m.lastDeploy,
		m.failing, m.deployedInfo, m.deploys, m.failures,
	)
	return m
}

// initStack creates the series of a stack, taking the last deploy from the
// persisted state if there is one
func (m *stackMetrics) initStack(stack string, record deployRecord) {
	m.failing.WithLabelValues(stack).Set(0)
	m.deploys.WithLabelValues(stack)
	m.failures.WithLabelValues(stack)
	if record.Revision != "" {
		m.lastDeploy.WithLabelValues(stack).Set(float64(record.DeployedAt.Unix()))
		m.deployedInfo.WithLabelValues(stack, record.Revision).Set(1)
	}
}

func (m *stackMetrics) recordCheck(stack string, deployed bool, revision string, err error, now time.Time) {
	timestamp := float64(now.Unix())
	m.lastCheck.WithLabelValues(stack).Set(timestamp)
	if err != nil {
		m.failing.WithLabelValues(stack).Set(1)
		m.lastFailure.WithLabelValues(stack).Set(timestamp)
		m.failures.WithLabelValues(stack).Inc()
		return
	}
	m.failing.WithLabelValues(stack).Set(0)
	m.lastSuccess.WithLabelValues(stack).Set(timestamp)
	if deployed {
		m.lastDeploy.WithLabelValues(stack).Set(timestamp)
		m.deploys.WithLabelValues(stack).Inc()
		m.deployedInfo.DeletePartialMatch(prometheus.Labels{"stack": stack})
		m.deployedInfo.WithLabelValues(stack, revision).Set(1)
	}
}

// MetricsHandler serves the metrics in the Prometheus text format
func MetricsHandler() http.Handler {
	return promhttp.HandlerFor(metrics.registry, promhttp.HandlerOpts{})
}
