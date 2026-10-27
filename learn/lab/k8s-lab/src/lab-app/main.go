// lab-app is the smallest service that still behaves like a real one:
// readiness separate from liveness, a graceful shutdown that does not drop
// requests, Prometheus metrics, configuration from the environment.
// Standard library only, so the image is one static binary.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"
	"time"
)

// version is set at build time: go build -ldflags "-X main.version=<sha>".
var version = "dev"

type app struct {
	hostname string
	message  string
	started  time.Time
	ready    atomic.Bool
	requests atomic.Uint64
}

func newApp() *app {
	host, _ := os.Hostname()
	return &app{hostname: host, message: getenv("MESSAGE", "salut din lab"), started: time.Now()}
}

func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func (a *app) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", a.index)
	// Liveness: the process can answer at all. Nothing else — a liveness
	// probe that checks a dependency restarts every pod when that dependency
	// blips, which turns one outage into two.
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprintln(w, "ok")
	})
	// Readiness: send me traffic. False before start-up and from SIGTERM on.
	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, _ *http.Request) {
		if !a.ready.Load() {
			http.Error(w, "not ready", http.StatusServiceUnavailable)
			return
		}
		fmt.Fprintln(w, "ready")
	})
	mux.HandleFunc("GET /metrics", a.metrics)
	return a.countRequests(mux)
}

func (a *app) countRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/healthz", "/readyz", "/metrics":
		default:
			a.requests.Add(1)
		}
		next.ServeHTTP(w, r)
	})
}

func (a *app) index(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]string{
		"message":  a.message,
		"hostname": a.hostname,
		"version":  version,
		"uptime":   time.Since(a.started).Round(time.Second).String(),
	})
}

// metrics writes the Prometheus text format by hand: three series do not
// justify a client library, and the format is worth seeing once.
func (a *app) metrics(w http.ResponseWriter, _ *http.Request) {
	ready := 0
	if a.ready.Load() {
		ready = 1
	}
	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	fmt.Fprintf(w, "# HELP lab_app_requests_total Requests served, probes excluded.\n")
	fmt.Fprintf(w, "# TYPE lab_app_requests_total counter\n")
	fmt.Fprintf(w, "lab_app_requests_total %d\n", a.requests.Load())
	fmt.Fprintf(w, "# HELP lab_app_ready 1 while this pod accepts traffic.\n")
	fmt.Fprintf(w, "# TYPE lab_app_ready gauge\n")
	fmt.Fprintf(w, "lab_app_ready %d\n", ready)
	fmt.Fprintf(w, "# HELP lab_app_info Build information.\n")
	fmt.Fprintf(w, "# TYPE lab_app_info gauge\n")
	fmt.Fprintf(w, "lab_app_info{version=%q} 1\n", version)
}

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	a := newApp()

	srv := &http.Server{
		Addr:              ":" + getenv("PORT", "8080"),
		Handler:           a.handler(),
		ReadHeaderTimeout: 5 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()

	go func() {
		log.Info("listening", "addr", srv.Addr, "version", version)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error("server failed", "err", err)
			os.Exit(1)
		}
	}()
	a.ready.Store(true)

	<-ctx.Done()

	// SIGTERM and "remove me from the Service" happen at the same time, not
	// in order: for a few seconds Envoy and every node may still send traffic
	// here. Fail readiness, keep serving for SHUTDOWN_DELAY, then drain.
	a.ready.Store(false)
	delay, err := time.ParseDuration(getenv("SHUTDOWN_DELAY", "5s"))
	if err != nil {
		delay = 5 * time.Second
	}
	log.Info("SIGTERM: not ready, still serving", "delay", delay.String())
	time.Sleep(delay)

	shutdown, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdown); err != nil {
		log.Error("shutdown", "err", err)
	}
	log.Info("stopped")
}
