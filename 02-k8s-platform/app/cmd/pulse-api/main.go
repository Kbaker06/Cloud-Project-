// Command pulse-api is a small, production-shaped HTTP service: structured logs, RED metrics,
// liveness/readiness probes, graceful shutdown and runtime fault injection.
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/kbaker06/cloud-project/pulse-api/internal/server"
)

// version is set at build time: -ldflags "-X main.version=1.2.3"
var version = "dev"

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	if err := run(logger); err != nil {
		logger.Error("fatal", "err", err)
		os.Exit(1)
	}
}

func run(logger *slog.Logger) error {
	addr := ":" + env("PORT", "8080")
	// How long to keep serving after SIGTERM while endpoints controllers / target groups
	// deregister us. Must be < terminationGracePeriodSeconds (k8s) / stopTimeout (ECS).
	drainDelay := envDuration("SHUTDOWN_DRAIN_SECONDS", 5)

	srv := server.New(server.Options{
		Version:    version,
		AdminToken: os.Getenv("ADMIN_TOKEN"),
		Logger:     logger,
	})

	httpServer := &http.Server{
		Addr:              addr,
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 5 * time.Second, // Slowloris protection
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	errCh := make(chan error, 1)
	go func() {
		logger.Info("listening", "addr", addr, "version", version)
		errCh <- httpServer.ListenAndServe()
	}()

	select {
	case err := <-errCh:
		return err
	case <-ctx.Done():
	}

	logger.Info("shutdown signal received; draining", "drain", drainDelay.String())
	srv.SetReady(false)
	time.Sleep(drainDelay)

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if err := httpServer.Shutdown(shutdownCtx); err != nil {
		return err
	}
	if err := <-errCh; err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	logger.Info("shutdown complete")
	return nil
}

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func envDuration(key string, fallbackSeconds int) time.Duration {
	if n, err := strconv.Atoi(os.Getenv(key)); err == nil && n >= 0 {
		return time.Duration(n) * time.Second
	}
	return time.Duration(fallbackSeconds) * time.Second
}
