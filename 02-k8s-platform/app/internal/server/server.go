// Package server wires HTTP routes, health probes, metrics and chaos together.
package server

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"github.com/kbaker06/cloud-project/pulse-api/internal/chaos"
	"github.com/kbaker06/cloud-project/pulse-api/internal/store"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

type Options struct {
	Version    string
	AdminToken string // empty disables /admin endpoints entirely
	Logger     *slog.Logger
	Store      store.Store
	Registry   *prometheus.Registry
	Random     func() float64 // chaos randomness; nil = math/rand
}

type Server struct {
	opts    Options
	metrics *Metrics
	chaos   *chaos.Config
	ready   atomic.Bool
	mux     *http.ServeMux
}

func New(opts Options) *Server {
	if opts.Logger == nil {
		opts.Logger = slog.Default()
	}
	if opts.Store == nil {
		opts.Store = store.NewMemory()
	}
	if opts.Registry == nil {
		opts.Registry = prometheus.NewRegistry()
		opts.Registry.MustRegister(
			prometheus.NewGoCollector(),
			prometheus.NewProcessCollector(prometheus.ProcessCollectorOpts{}),
		)
	}
	s := &Server{
		opts:    opts,
		metrics: NewMetrics(opts.Registry, opts.Version),
		chaos:   &chaos.Config{},
		mux:     http.NewServeMux(),
	}
	s.ready.Store(true)
	s.routes()
	return s
}

func (s *Server) Handler() http.Handler { return s.mux }

// SetReady flips the readiness probe. main() sets it false on SIGTERM so the load balancer / kube-proxy
// stops sending new traffic *before* the server stops accepting connections.
func (s *Server) SetReady(v bool) { s.ready.Store(v) }

func (s *Server) routes() {
	// Probes and metrics bypass chaos: you want to break the user path, not the observability of it.
	s.mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	s.mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, _ *http.Request) {
		if !s.ready.Load() {
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "draining"})
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
	})
	s.mux.Handle("GET /metrics", promhttp.HandlerFor(s.opts.Registry, promhttp.HandlerOpts{}))

	s.handle("GET /", "/", s.handleRoot)
	s.handle("GET /api/v1/notes", "/api/v1/notes", s.handleListNotes)
	s.handle("POST /api/v1/notes", "/api/v1/notes", s.handleCreateNote)
	s.handle("GET /api/v1/notes/{id}", "/api/v1/notes/{id}", s.handleGetNote)
	s.handle("DELETE /api/v1/notes/{id}", "/api/v1/notes/{id}", s.handleDeleteNote)
	s.handle("GET /api/v1/work", "/api/v1/work", s.handleWork)

	s.mux.Handle("GET /admin/chaos", s.requireAdmin(http.HandlerFunc(s.handleGetChaos)))
	s.mux.Handle("PUT /admin/chaos", s.requireAdmin(http.HandlerFunc(s.handleSetChaos)))
}

func (s *Server) handle(pattern, route string, h http.HandlerFunc) {
	s.mux.Handle(pattern, s.metrics.Instrument(route, s.logRequests(s.chaos.Middleware(h, s.opts.Random))))
}

func (s *Server) logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		s.opts.Logger.Info("request",
			"method", r.Method, "path", r.URL.Path, "status", rec.status,
			"duration_ms", time.Since(start).Milliseconds(),
			"request_id", r.Header.Get("X-Request-Id"))
	})
}

func (s *Server) requireAdmin(next http.Handler) http.Handler {
	want := sha256.Sum256([]byte(s.opts.AdminToken))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if s.opts.AdminToken == "" {
			http.NotFound(w, r)
			return
		}
		got := sha256.Sum256([]byte(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")))
		// Constant-time compare so the token can't be recovered by timing responses.
		if subtle.ConstantTimeCompare(got[:], want[:]) != 1 {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *Server) handleRoot(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not found"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"service": "pulse-api", "version": s.opts.Version})
}

func (s *Server) handleListNotes(w http.ResponseWriter, _ *http.Request) {
	notes, err := s.opts.Store.List()
	if err != nil {
		s.internalError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"notes": notes})
}

const maxNoteBytes = 4 << 10

func (s *Server) handleCreateNote(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Text string `json:"text"`
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxNoteBytes)
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "body must be JSON {\"text\": \"...\"} under 4KiB"})
		return
	}
	body.Text = strings.TrimSpace(body.Text)
	if body.Text == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "text is required"})
		return
	}
	n, err := s.opts.Store.Create(body.Text)
	if err != nil {
		s.internalError(w, err)
		return
	}
	w.Header().Set("Location", "/api/v1/notes/"+n.ID)
	writeJSON(w, http.StatusCreated, n)
}

func (s *Server) handleGetNote(w http.ResponseWriter, r *http.Request) {
	n, err := s.opts.Store.Get(r.PathValue("id"))
	if errors.Is(err, store.ErrNotFound) {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "note not found"})
		return
	}
	if err != nil {
		s.internalError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, n)
}

func (s *Server) handleDeleteNote(w http.ResponseWriter, r *http.Request) {
	err := s.opts.Store.Delete(r.PathValue("id"))
	if errors.Is(err, store.ErrNotFound) {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "note not found"})
		return
	}
	if err != nil {
		s.internalError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// handleWork burns CPU for ?ms= milliseconds (max 2000) so you can watch an HPA scale out.
func (s *Server) handleWork(w http.ResponseWriter, r *http.Request) {
	ms, err := strconv.Atoi(r.URL.Query().Get("ms"))
	if err != nil || ms <= 0 {
		ms = 50
	}
	ms = min(ms, 2000)
	deadline := time.Now().Add(time.Duration(ms) * time.Millisecond)
	var x uint64
	for time.Now().Before(deadline) {
		for i := 0; i < 10_000; i++ {
			x += uint64(i) * 2654435761
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"burned_ms": ms, "checksum": x % 1000})
}

func (s *Server) handleGetChaos(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, s.chaos.Get())
}

func (s *Server) handleSetChaos(w http.ResponseWriter, r *http.Request) {
	var snap chaos.Snapshot
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<10)).Decode(&snap); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "body must be {\"error_rate\":0.1,\"latency_ms\":200}"})
		return
	}
	s.chaos.Set(snap)
	s.opts.Logger.Warn("chaos configuration changed", "error_rate", snap.ErrorRate, "latency_ms", snap.LatencyMS)
	writeJSON(w, http.StatusOK, s.chaos.Get())
}

func (s *Server) internalError(w http.ResponseWriter, err error) {
	s.opts.Logger.Error("internal error", "err", err)
	writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
