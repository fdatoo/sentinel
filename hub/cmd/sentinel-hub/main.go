// Command sentinel-hub is the Sentinel server. On the tailnet it runs as its
// own tsnet node and serves HTTPS; with --dev it serves HTTP on loopback.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"tailscale.com/tsnet"

	"fdatoo.dev/sentinel/hub/internal/api"
	"fdatoo.dev/sentinel/hub/internal/hub"
	"fdatoo.dev/sentinel/hub/internal/identity"
	"fdatoo.dev/sentinel/hub/internal/push"
	"fdatoo.dev/sentinel/hub/internal/store"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "sentinel-hub:", err)
		os.Exit(1)
	}
}

func defaultStateDir() string {
	if d, err := os.UserConfigDir(); err == nil {
		return filepath.Join(d, "sentinel-hub")
	}
	return "sentinel-hub-state"
}

func run() error {
	var (
		debug     = flag.Bool("debug", false, "log every Mac presence report")
		dev       = flag.Bool("dev", false, "serve plain HTTP on --addr with header identity (never on the tailnet)")
		addr      = flag.String("addr", "127.0.0.1:7878", "listen address in --dev mode")
		hostname  = flag.String("hostname", "sentinel", "tailnet machine name")
		stateDir  = flag.String("state-dir", defaultStateDir(), "directory for the database and tsnet state")
		owner     = flag.String("owner", "", "tailnet login allowed to register devices, or \"any\" (required on the tailnet)")
		apnsKey   = flag.String("apns-key", "", "path to the APNs .p8 auth key")
		apnsKeyID = flag.String("apns-key-id", "", "APNs key id")
		apnsTeam  = flag.String("apns-team-id", "", "Apple developer team id")
		apnsTopic = flag.String("apns-topic", "", "app bundle id (required with --apns-key)")
		t         = hub.DefaultTimings
	)
	flag.DurationVar(&t.IdleThreshold, "idle-threshold", t.IdleThreshold, "a Mac idle this long is not active")
	flag.DurationVar(&t.HeartbeatTimeout, "heartbeat-timeout", t.HeartbeatTimeout, "a Mac silent this long is not active")
	flag.DurationVar(&t.FallbackNormal, "fallback-normal", t.FallbackNormal, "escalate normal requests from an unanswering Mac after")
	flag.DurationVar(&t.FallbackHigh, "fallback-high", t.FallbackHigh, "escalate high requests from an unanswering Mac after")
	flag.DurationVar(&t.RealertHigh, "realert-high", t.RealertHigh, "re-alert the phone for high requests every")
	flag.Parse()

	level := slog.LevelInfo
	if *debug {
		level = slog.LevelDebug
	}
	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: level}))
	if err := os.MkdirAll(*stateDir, 0o700); err != nil {
		return err
	}
	dbName := "sentinel.db"
	if *dev {
		dbName = "sentinel-dev.db"
	}
	st, err := store.Open(filepath.Join(*stateDir, dbName))
	if err != nil {
		return err
	}
	defer st.Close()

	var pusher push.Pusher = push.Log{L: log}
	if *apnsKey != "" {
		if *apnsKeyID == "" || *apnsTeam == "" || *apnsTopic == "" {
			return errors.New("--apns-key needs --apns-key-id, --apns-team-id and --apns-topic")
		}
		a, err := push.NewAPNs(*apnsKey, *apnsKeyID, *apnsTeam, *apnsTopic, log)
		if err != nil {
			return err
		}
		pusher = a
	} else {
		log.Warn("APNs not configured: escalations are logged, not pushed")
	}

	switch {
	case *owner == "any":
		*owner = ""
	case *owner == "" && !*dev:
		return errors.New("--owner is required: your tailnet login, or \"any\" to let every node register devices")
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	var callbacks *http.Client

	var ln net.Listener
	var resolver identity.Resolver
	if *dev {
		host, _, err := net.SplitHostPort(*addr)
		if err != nil {
			return err
		}
		if ip := net.ParseIP(host); host != "localhost" && (ip == nil || !ip.IsLoopback()) {
			return errors.New("--dev only listens on loopback")
		}
		ln, err = net.Listen("tcp", *addr)
		if err != nil {
			return err
		}
		resolver = identity.Dev{}
		log.Info("dev mode", "url", "http://"+ln.Addr().String())
	} else {
		ts := &tsnet.Server{
			Hostname: *hostname,
			Dir:      filepath.Join(*stateDir, "tsnet"),
			AuthKey:  os.Getenv("TS_AUTHKEY"),
			UserLogf: func(format string, args ...any) { log.Info(fmt.Sprintf(format, args...)) },
		}
		defer ts.Close()
		upCtx, cancel := context.WithTimeout(ctx, 5*time.Minute)
		_, err := ts.Up(upCtx)
		cancel()
		if err != nil {
			return fmt.Errorf("join tailnet: %w", err)
		}
		lc, err := ts.LocalClient()
		if err != nil {
			return err
		}
		ln, err = ts.ListenTLS("tcp", ":443")
		if err != nil {
			return err
		}
		resolver = identity.Tailscale{Client: lc}
		// Callback URLs are usually tailnet names, which only tsnet can reach.
		callbacks = ts.HTTPClient()
		callbacks.Timeout = 15 * time.Second
		if doms := ts.CertDomains(); len(doms) > 0 {
			log.Info("serving on the tailnet", "url", "https://"+doms[0])
		}
	}

	// Start after the tailnet join, so the warm-up window for reloaded requests
	// covers the time Macs need to reconnect rather than the join itself.
	h := hub.New(hub.Config{Store: st, Pusher: pusher, Log: log, Timings: t, Owner: *owner, HTTPClient: callbacks})
	if err := h.Start(ctx); err != nil {
		return err
	}
	defer h.Close()

	stopping := make(chan struct{})
	srv := &http.Server{
		Handler:           (&api.Server{Hub: h, Identity: resolver, Log: log, Stopping: stopping}).Handler(),
		ReadHeaderTimeout: 10 * time.Second,
	}
	srv.RegisterOnShutdown(func() { close(stopping) })
	drained := make(chan struct{})
	go func() {
		defer close(drained)
		<-ctx.Done()
		sctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := srv.Shutdown(sctx); err != nil {
			log.Warn("shutdown", "err", err)
		}
	}()
	if err := srv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	// Serve returns as soon as Shutdown starts; let in-flight requests finish.
	<-drained
	log.Info("stopped")
	return nil
}
