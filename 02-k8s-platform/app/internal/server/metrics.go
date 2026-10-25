package server

import (
	"net/http"
	"strconv"
	"time"

	"github.com/prometheus/client_golang/prometheus"
)

// Metrics follow the RED method: Rate, Errors, Duration — the inputs to the SLOs in project 06.
type Metrics struct {
	requests *prometheus.CounterVec
	duration *prometheus.HistogramVec
	inflight prometheus.Gauge
}

func NewMetrics(reg prometheus.Registerer, version string) *Metrics {
	m := &Metrics{
		requests: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "HTTP requests by route, method and status code.",
		}, []string{"route", "method", "code"}),
		duration: prometheus.NewHistogramVec(prometheus.HistogramOpts{
			Name: "http_request_duration_seconds",
			Help: "HTTP request latency by route.",
			// Buckets chosen around the 300ms latency SLO so burn-rate maths is precise there.
			Buckets: []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.2, 0.3, 0.5, 1, 2.5, 5},
		}, []string{"route", "method"}),
		inflight: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "http_requests_in_flight",
			Help: "Requests currently being served.",
		}),
	}
	buildInfo := prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "pulse_build_info",
		Help: "Always 1; labels carry the build version.",
	}, []string{"version"})
	buildInfo.WithLabelValues(version).Set(1)

	reg.MustRegister(m.requests, m.duration, m.inflight, buildInfo)
	return m
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

// Instrument wraps a handler. route must be the *pattern* ("/api/v1/notes/{id}"), never the raw
// path — raw paths with IDs in them explode metric cardinality and can take Prometheus down.
func (m *Metrics) Instrument(route string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		m.inflight.Inc()
		defer m.inflight.Dec()
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		m.duration.WithLabelValues(route, r.Method).Observe(time.Since(start).Seconds())
		m.requests.WithLabelValues(route, r.Method, strconv.Itoa(rec.status)).Inc()
	})
}
