// Command server runs the Course Planner backend API.
//
//	Usage: DATABASE_URL=... JWT_SECRET=... go run ./cmd/server
//
// Endpoints are served under /api/v1 (including the MCP streamable-HTTP
// endpoint at /api/v1/mcp), plus /healthz and the browser sign-in page at
// /mcp/connect. The backend is designed to sit behind an HTTPS edge
// (Cloudflare Tunnel / reverse proxy) and must not be exposed publicly
// in plain HTTP (docs/architecture.md §7).
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
	// Zoneinfo is embedded as a fallback: the app resolves user timezones with
	// time.LoadLocation, and minimal server images (scratch, distroless, slim
	// images without tzdata) have no /usr/share/zoneinfo. Without this a
	// deployment would fail registration with INVALID_TIMEZONE. The system
	// database still wins when it exists.
	_ "time/tzdata"

	"github.com/carryingon/courseplanner/server/internal/app"
	"github.com/carryingon/courseplanner/server/internal/platform/config"
)

func main() {
	if err := run(); err != nil {
		slog.Error("server exited with error", "error", err)
		os.Exit(1)
	}
}

func run() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	setupLogger(cfg.LogLevel)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	server, err := app.New(ctx, cfg)
	if err != nil {
		return err
	}
	defer server.Close()

	httpSrv := &http.Server{
		Addr:              ":" + cfg.Port,
		Handler:           server.Router,
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	errCh := make(chan error, 1)
	go func() {
		slog.Info("listening", "addr", httpSrv.Addr, "health", "/healthz")
		if err := httpSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	select {
	case err := <-errCh:
		return err
	case <-stop:
		slog.Info("shutting down")
		shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer shutdownCancel()
		return httpSrv.Shutdown(shutdownCtx)
	}
}

func setupLogger(level string) {
	var lvl slog.Level
	switch level {
	case "debug":
		lvl = slog.LevelDebug
	case "warn":
		lvl = slog.LevelWarn
	case "error":
		lvl = slog.LevelError
	default:
		lvl = slog.LevelInfo
	}
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: lvl})))
}
