// Package chaos injects failures into live traffic so you can practise
// incident response (project 06) against real alerts instead of slides.
package chaos

import (
	"math/rand/v2"
	"net/http"
	"sync"
	"time"
)

// Config is safe to read and update concurrently.
type Config struct {
	mu        sync.RWMutex
	ErrorRate float64 `json:"error_rate"` // 0.0–1.0 fraction of requests that return 500
	LatencyMS int     `json:"latency_ms"` // added to every affected request
}

type Snapshot struct {
	ErrorRate float64 `json:"error_rate"`
	LatencyMS int     `json:"latency_ms"`
}

func (c *Config) Get() Snapshot {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return Snapshot{ErrorRate: c.ErrorRate, LatencyMS: c.LatencyMS}
}

func (c *Config) Set(s Snapshot) {
	if s.ErrorRate < 0 {
		s.ErrorRate = 0
	}
	if s.ErrorRate > 1 {
		s.ErrorRate = 1
	}
	if s.LatencyMS < 0 {
		s.LatencyMS = 0
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.ErrorRate, c.LatencyMS = s.ErrorRate, s.LatencyMS
}

// Middleware applies the current fault configuration. rnd is injectable for tests.
func (c *Config) Middleware(next http.Handler, rnd func() float64) http.Handler {
	if rnd == nil {
		rnd = rand.Float64
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s := c.Get()
		if s.LatencyMS > 0 {
			select {
			case <-time.After(time.Duration(s.LatencyMS) * time.Millisecond):
			case <-r.Context().Done():
				return
			}
		}
		if s.ErrorRate > 0 && rnd() < s.ErrorRate {
			http.Error(w, `{"error":"chaos: injected failure"}`, http.StatusInternalServerError)
			return
		}
		next.ServeHTTP(w, r)
	})
}
