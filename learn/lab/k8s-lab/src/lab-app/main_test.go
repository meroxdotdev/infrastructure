package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func get(t *testing.T, h http.Handler, path string) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
	return rec
}

func TestReadinessFollowsState(t *testing.T) {
	a := newApp()
	h := a.handler()

	if got := get(t, h, "/readyz").Code; got != http.StatusServiceUnavailable {
		t.Fatalf("before start: /readyz = %d, want 503", got)
	}
	a.ready.Store(true)
	if got := get(t, h, "/readyz").Code; got != http.StatusOK {
		t.Fatalf("running: /readyz = %d, want 200", got)
	}
	a.ready.Store(false)
	if got := get(t, h, "/healthz").Code; got != http.StatusOK {
		t.Fatalf("shutting down: /healthz = %d, want 200 (liveness must not fail on shutdown)", got)
	}
}

func TestMetricsCountRequestsNotProbes(t *testing.T) {
	a := newApp()
	h := a.handler()
	for range 3 {
		get(t, h, "/")
	}
	get(t, h, "/healthz")
	get(t, h, "/readyz")

	body := get(t, h, "/metrics").Body.String()
	if !strings.Contains(body, "lab_app_requests_total 3\n") {
		t.Fatalf("want 3 counted requests, got:\n%s", body)
	}
}

func TestIndexReportsVersionAndMessage(t *testing.T) {
	t.Setenv("MESSAGE", "test")
	a := newApp()
	rec := get(t, a.handler(), "/")

	var out map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	if out["message"] != "test" || out["version"] != version {
		t.Fatalf("unexpected body: %v", out)
	}
}

func TestUnknownPathIs404(t *testing.T) {
	if got := get(t, newApp().handler(), "/nope").Code; got != http.StatusNotFound {
		t.Fatalf("/nope = %d, want 404", got)
	}
}
