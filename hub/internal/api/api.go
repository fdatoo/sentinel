// Package api serves the HTTP surface in docs/api.md on top of the hub.
package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"mime"
	"net/http"
	"strconv"
	"sync"
	"time"

	"github.com/coder/websocket"

	"fdatoo.dev/sentinel/hub/internal/hub"
	"fdatoo.dev/sentinel/hub/internal/identity"
	"fdatoo.dev/sentinel/hub/internal/model"
)

type Server struct {
	Hub      *hub.Hub
	Identity identity.Resolver
	Log      *slog.Logger
	// Stopping, when closed, ends long-polls early with the current state and
	// closes event streams, so a graceful shutdown doesn't wait them out.
	Stopping <-chan struct{}
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "ok\n") })
	mux.HandleFunc("POST /v1/requests", s.with(s.create))
	mux.HandleFunc("GET /v1/requests", s.with(s.list))
	mux.HandleFunc("GET /v1/requests/{id}", s.with(s.get))
	mux.HandleFunc("GET /v1/requests/{id}/events", s.with(s.events))
	mux.HandleFunc("DELETE /v1/requests/{id}", s.with(s.cancel))
	mux.HandleFunc("POST /v1/requests/{id}/response", s.with(s.answer))
	mux.HandleFunc("POST /v1/devices", s.with(s.register))
	mux.HandleFunc("GET /v1/devices", s.with(s.devices))
	mux.HandleFunc("GET /v1/devices/ws", s.with(s.socket))
	return mux
}

type handler func(w http.ResponseWriter, r *http.Request, who identity.Identity) error

func (s *Server) with(h handler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		who, err := s.Identity.Resolve(r)
		if err != nil {
			s.Log.Warn("identify caller", "remote", r.RemoteAddr, "err", err)
			writeError(w, &hub.Error{Status: http.StatusForbidden, Code: "forbidden", Message: "caller is not on the tailnet"})
			return
		}
		if err := h(w, r, who); err != nil {
			var he *hub.Error
			if !errors.As(err, &he) {
				if errors.Is(err, context.Canceled) {
					return
				}
				s.Log.Error("request failed", "method", r.Method, "path", r.URL.Path, "err", err)
				he = &hub.Error{Status: http.StatusInternalServerError, Code: "internal", Message: "internal error"}
			}
			writeError(w, he)
		}
	}
}

func writeError(w http.ResponseWriter, e *hub.Error) {
	var body model.ErrorBody
	body.Error.Code, body.Error.Message = e.Code, e.Message
	writeJSON(w, e.Status, body)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// decode insists on a JSON content type. Browsers can only send one
// cross-origin after a CORS preflight, which the hub never grants, so a web
// page open on a registered device can't forge an answer.
func decode(r *http.Request, v any) error {
	if mt, _, _ := mime.ParseMediaType(r.Header.Get("Content-Type")); mt != "application/json" {
		return &hub.Error{Status: http.StatusUnsupportedMediaType, Code: "invalid_request", Message: "Content-Type must be application/json"}
	}
	dec := json.NewDecoder(io.LimitReader(r.Body, 1<<20))
	if err := dec.Decode(v); err != nil {
		return &hub.Error{Status: http.StatusBadRequest, Code: "invalid_request", Message: "malformed JSON: " + err.Error()}
	}
	return nil
}

func (s *Server) create(w http.ResponseWriter, r *http.Request, who identity.Identity) error {
	var in model.CreateRequest
	if err := decode(r, &in); err != nil {
		return err
	}
	req, err := s.Hub.Create(r.Context(), who, in)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusCreated, req)
	return nil
}

func (s *Server) list(w http.ResponseWriter, r *http.Request, _ identity.Identity) error {
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	reqs, err := s.Hub.List(r.Context(), model.State(r.URL.Query().Get("state")), limit)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]any{"requests": reqs})
	return nil
}

func (s *Server) get(w http.ResponseWriter, r *http.Request, _ identity.Identity) error {
	id := r.PathValue("id")
	var req *model.Request
	var err error
	if v := r.URL.Query().Get("wait"); v != "" {
		secs, perr := strconv.Atoi(v)
		if perr != nil || secs < 0 {
			return &hub.Error{Status: http.StatusBadRequest, Code: "invalid_request", Message: "wait must be a number of seconds"}
		}
		ctx, cancel := context.WithCancel(r.Context())
		defer cancel()
		go func() {
			select {
			case <-s.Stopping:
				cancel()
			case <-ctx.Done():
			}
		}()
		req, err = s.Hub.Wait(ctx, id, time.Duration(min(secs, 300))*time.Second)
		if err != nil && ctx.Err() != nil && r.Context().Err() == nil {
			// Shutting down: answer with where things stand; clients poll again.
			req, err = s.Hub.Get(r.Context(), id)
		}
	} else {
		req, err = s.Hub.Get(r.Context(), id)
	}
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, req)
	return nil
}

func (s *Server) events(w http.ResponseWriter, r *http.Request, _ identity.Identity) error {
	id := r.PathValue("id")
	ch, unsub := s.Hub.Subscribe(id)
	defer unsub()
	req, err := s.Hub.Get(r.Context(), id)
	if err != nil {
		return err
	}
	flusher, _ := w.(http.Flusher)
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.WriteHeader(http.StatusOK)
	send := func(req *model.Request) error {
		b, _ := json.Marshal(req)
		if _, err := fmt.Fprintf(w, "event: request\ndata: %s\n\n", b); err != nil {
			return err
		}
		if flusher != nil {
			flusher.Flush()
		}
		return nil
	}
	if err := send(req); err != nil || req.State != model.StatePending {
		return nil
	}
	keepalive := time.NewTicker(25 * time.Second)
	defer keepalive.Stop()
	for {
		select {
		case req := <-ch:
			if err := send(req); err != nil || req.State != model.StatePending {
				return nil
			}
		case <-keepalive.C:
			if _, err := io.WriteString(w, ": keepalive\n\n"); err != nil {
				return nil
			}
			if flusher != nil {
				flusher.Flush()
			}
		case <-r.Context().Done():
			return nil
		case <-s.Stopping:
			return nil
		}
	}
}

func (s *Server) cancel(w http.ResponseWriter, r *http.Request, who identity.Identity) error {
	req, err := s.Hub.Cancel(r.Context(), who, r.PathValue("id"))
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, req)
	return nil
}

func (s *Server) answer(w http.ResponseWriter, r *http.Request, who identity.Identity) error {
	var in model.Answer
	if err := decode(r, &in); err != nil {
		return err
	}
	req, err := s.Hub.Answer(r.Context(), who, r.PathValue("id"), in)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, req)
	return nil
}

func (s *Server) register(w http.ResponseWriter, r *http.Request, who identity.Identity) error {
	var in model.RegisterDevice
	if err := decode(r, &in); err != nil {
		return err
	}
	dev, err := s.Hub.RegisterDevice(r.Context(), who, in)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, dev)
	return nil
}

func (s *Server) devices(w http.ResponseWriter, r *http.Request, _ identity.Identity) error {
	devs, err := s.Hub.Devices(r.Context())
	if err != nil {
		return err
	}
	if devs == nil {
		devs = []model.Device{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"devices": devs})
	return nil
}

// wsConn queues frames for one Mac socket so the hub never blocks on a slow
// network. If the queue fills, the socket is dropped and the Mac reconnects to
// a fresh sync.
type wsConn struct {
	out       chan []byte
	closeOnce sync.Once
	done      chan struct{}
}

func (c *wsConn) Send(frame []byte) {
	select {
	case c.out <- frame:
	case <-c.done:
	default:
		c.close()
	}
}

func (c *wsConn) close() { c.closeOnce.Do(func() { close(c.done) }) }

func (s *Server) socket(w http.ResponseWriter, r *http.Request, who identity.Identity) error {
	dev, err := s.Hub.DeviceForMac(r.Context(), who)
	if err != nil {
		return err
	}
	// The default origin check rejects browser pages; the native app sends no Origin.
	ws, err := websocket.Accept(w, r, nil)
	if err != nil {
		return nil // Accept already wrote the response
	}
	defer ws.CloseNow()
	ws.SetReadLimit(64 << 10)

	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	conn := &wsConn{out: make(chan []byte, 256), done: make(chan struct{})}
	s.Hub.MacConnected(dev, conn)
	defer s.Hub.MacDisconnected(dev.ID, conn)

	// Writer: queued frames plus a ping every 20s so dead sockets surface.
	go func() {
		defer cancel()
		ping := time.NewTicker(20 * time.Second)
		defer ping.Stop()
		for {
			select {
			case b := <-conn.out:
				wctx, wcancel := context.WithTimeout(ctx, 10*time.Second)
				err := ws.Write(wctx, websocket.MessageText, b)
				wcancel()
				if err != nil {
					return
				}
			case <-ping.C:
				pctx, pcancel := context.WithTimeout(ctx, 10*time.Second)
				err := ws.Ping(pctx)
				pcancel()
				if err != nil {
					return
				}
			case <-conn.done:
				ws.Close(websocket.StatusTryAgainLater, "send queue full")
				return
			case <-ctx.Done():
				return
			}
		}
	}()

	for {
		_, b, err := ws.Read(ctx)
		if err != nil {
			conn.close()
			return nil
		}
		var f model.MacFrame
		if err := json.Unmarshal(b, &f); err != nil {
			s.Log.Warn("bad frame from mac", "device", dev.Name, "err", err)
			continue
		}
		if f.Type == "presence" {
			s.Hub.MacPresence(dev.ID, conn, f.Presence)
		}
	}
}
