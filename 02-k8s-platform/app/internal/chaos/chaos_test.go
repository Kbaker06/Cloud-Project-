package chaos

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestSetClamps(t *testing.T) {
	var c Config
	c.Set(Snapshot{ErrorRate: 7, LatencyMS: -5})
	got := c.Get()
	if got.ErrorRate != 1 || got.LatencyMS != 0 {
		t.Fatalf("got %+v, want error_rate=1 latency=0", got)
	}
}

func TestLatencyRespectsClientCancellation(t *testing.T) {
	var c Config
	c.Set(Snapshot{LatencyMS: 10_000})
	h := c.Middleware(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		t.Error("handler should not run after client cancelled")
	}), nil)

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	req := httptest.NewRequest("GET", "/", nil).WithContext(ctx)

	start := time.Now()
	h.ServeHTTP(httptest.NewRecorder(), req)
	if time.Since(start) > time.Second {
		t.Fatal("injected latency ignored request cancellation")
	}
}
