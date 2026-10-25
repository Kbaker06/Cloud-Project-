package server

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func newTestServer(t *testing.T, opts Options) *httptest.Server {
	t.Helper()
	opts.Logger = slog.New(slog.NewTextHandler(io.Discard, nil))
	if opts.Version == "" {
		opts.Version = "test"
	}
	ts := httptest.NewServer(New(opts).Handler())
	t.Cleanup(ts.Close)
	return ts
}

func do(t *testing.T, method, url, body string, headers map[string]string) (*http.Response, string) {
	t.Helper()
	req, err := http.NewRequest(method, url, strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp, string(b)
}

func TestProbes(t *testing.T) {
	ts := newTestServer(t, Options{})
	for _, path := range []string{"/healthz", "/readyz"} {
		resp, _ := do(t, "GET", ts.URL+path, "", nil)
		if resp.StatusCode != http.StatusOK {
			t.Errorf("%s = %d, want 200", path, resp.StatusCode)
		}
	}
}

func TestReadinessFlipsDuringShutdown(t *testing.T) {
	s := New(Options{Logger: slog.New(slog.NewTextHandler(io.Discard, nil))})
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	s.SetReady(false)
	resp, _ := do(t, "GET", ts.URL+"/readyz", "", nil)
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("readyz while draining = %d, want 503", resp.StatusCode)
	}
	// Liveness must stay green while draining, or the kubelet restarts us mid-shutdown.
	resp, _ = do(t, "GET", ts.URL+"/healthz", "", nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("healthz while draining = %d, want 200", resp.StatusCode)
	}
}

func TestNotesCRUD(t *testing.T) {
	ts := newTestServer(t, Options{})

	resp, body := do(t, "POST", ts.URL+"/api/v1/notes", `{"text":"  hello cloud  "}`, nil)
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("create = %d %s", resp.StatusCode, body)
	}
	var created struct{ ID, Text string }
	if err := json.Unmarshal([]byte(body), &created); err != nil {
		t.Fatal(err)
	}
	if created.Text != "hello cloud" {
		t.Errorf("text not trimmed: %q", created.Text)
	}
	if loc := resp.Header.Get("Location"); loc != "/api/v1/notes/"+created.ID {
		t.Errorf("Location = %q", loc)
	}

	resp, body = do(t, "GET", ts.URL+"/api/v1/notes/"+created.ID, "", nil)
	if resp.StatusCode != http.StatusOK || !strings.Contains(body, "hello cloud") {
		t.Fatalf("get = %d %s", resp.StatusCode, body)
	}

	resp, body = do(t, "GET", ts.URL+"/api/v1/notes", "", nil)
	if resp.StatusCode != http.StatusOK || !strings.Contains(body, created.ID) {
		t.Fatalf("list = %d %s", resp.StatusCode, body)
	}

	resp, _ = do(t, "DELETE", ts.URL+"/api/v1/notes/"+created.ID, "", nil)
	if resp.StatusCode != http.StatusNoContent {
		t.Fatalf("delete = %d", resp.StatusCode)
	}
	resp, _ = do(t, "GET", ts.URL+"/api/v1/notes/"+created.ID, "", nil)
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("get after delete = %d, want 404", resp.StatusCode)
	}
}

func TestCreateNoteValidation(t *testing.T) {
	ts := newTestServer(t, Options{})
	cases := map[string]string{
		"not json":   `nope`,
		"empty text": `{"text":"   "}`,
		"too large":  `{"text":"` + strings.Repeat("a", 5000) + `"}`,
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			resp, _ := do(t, "POST", ts.URL+"/api/v1/notes", body, nil)
			if resp.StatusCode != http.StatusBadRequest {
				t.Errorf("status = %d, want 400", resp.StatusCode)
			}
		})
	}
}

func TestAdminDisabledWithoutToken(t *testing.T) {
	ts := newTestServer(t, Options{})
	resp, _ := do(t, "GET", ts.URL+"/admin/chaos", "", nil)
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("admin without configured token = %d, want 404", resp.StatusCode)
	}
}

func TestAdminRequiresToken(t *testing.T) {
	ts := newTestServer(t, Options{AdminToken: "s3cret"})
	resp, _ := do(t, "PUT", ts.URL+"/admin/chaos", `{"error_rate":1}`, map[string]string{"Authorization": "Bearer wrong"})
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("wrong token = %d, want 401", resp.StatusCode)
	}
}

func TestChaosInjectsErrorsButSparesProbes(t *testing.T) {
	ts := newTestServer(t, Options{AdminToken: "s3cret", Random: func() float64 { return 0.0 }})
	auth := map[string]string{"Authorization": "Bearer s3cret"}

	resp, body := do(t, "PUT", ts.URL+"/admin/chaos", `{"error_rate":0.5,"latency_ms":0}`, auth)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("set chaos = %d %s", resp.StatusCode, body)
	}

	resp, _ = do(t, "GET", ts.URL+"/api/v1/notes", "", nil)
	if resp.StatusCode != http.StatusInternalServerError {
		t.Fatalf("user path under chaos = %d, want 500", resp.StatusCode)
	}
	resp, _ = do(t, "GET", ts.URL+"/healthz", "", nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("healthz under chaos = %d, want 200", resp.StatusCode)
	}

	do(t, "PUT", ts.URL+"/admin/chaos", `{"error_rate":0}`, auth)
	resp, _ = do(t, "GET", ts.URL+"/api/v1/notes", "", nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("after clearing chaos = %d, want 200", resp.StatusCode)
	}
}

func TestMetricsUseRoutePatternNotRawPath(t *testing.T) {
	ts := newTestServer(t, Options{})
	do(t, "GET", ts.URL+"/api/v1/notes/12345", "", nil)
	do(t, "GET", ts.URL+"/api/v1/notes/67890", "", nil)

	_, body := do(t, "GET", ts.URL+"/metrics", "", nil)
	want := `http_requests_total{code="404",method="GET",route="/api/v1/notes/{id}"} 2`
	if !strings.Contains(body, want) {
		t.Fatalf("metrics missing %q", want)
	}
	if strings.Contains(body, "12345") {
		t.Fatal("raw path leaked into metric labels (cardinality bomb)")
	}
	if !strings.Contains(body, `pulse_build_info{version="test"} 1`) {
		t.Fatal("build info metric missing")
	}
}

func TestWorkIsCapped(t *testing.T) {
	ts := newTestServer(t, Options{})
	_, body := do(t, "GET", ts.URL+"/api/v1/work?ms=999999", "", nil)
	if !strings.Contains(body, `"burned_ms":2000`) {
		t.Fatalf("work not capped: %s", body)
	}
}
