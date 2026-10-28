// Package hub owns every request: validation, the routing state machine
// (docs/spec.md, ADR-0002), presence, timers, waiters and callbacks.
package hub

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"slices"
	"sync"
	"time"

	"github.com/oklog/ulid/v2"

	"fdatoo.dev/sentinel/hub/internal/identity"
	"fdatoo.dev/sentinel/hub/internal/model"
	"fdatoo.dev/sentinel/hub/internal/push"
	"fdatoo.dev/sentinel/hub/internal/store"
)

// Timings are the routing knobs from the spec's defaults table.
type Timings struct {
	IdleThreshold    time.Duration
	HeartbeatTimeout time.Duration
	FallbackNormal   time.Duration
	FallbackHigh     time.Duration
	RealertHigh      time.Duration
	PresenceTick     time.Duration
}

const (
	// MaxPending bounds the requests held in memory and walked on every tick.
	MaxPending = 500
	// MaxSync and MaxSyncBytes bound a Mac's sync frame. URLSessionWebSocketTask
	// drops messages over 1 MiB, and raising its limit stalls the handshake on
	// current macOS, so the hub stays under it.
	MaxSync      = 50
	MaxSyncBytes = 768 << 10
)

var DefaultTimings = Timings{
	IdleThreshold:    120 * time.Second,
	HeartbeatTimeout: 45 * time.Second,
	FallbackNormal:   3 * time.Minute,
	FallbackHigh:     time.Minute,
	RealertHigh:      5 * time.Minute,
	PresenceTick:     5 * time.Second,
}

type Config struct {
	Store   *store.Store
	Pusher  push.Pusher
	Clock   Clock
	Log     *slog.Logger
	Timings Timings
	// Owner, when set, is the only tailnet login allowed to register devices.
	Owner string
	// Dispatch runs network side effects (pushes, callbacks). It defaults to
	// starting a goroutine; tests run them inline.
	Dispatch func(func())
	// HTTPClient is used for webhook callbacks.
	HTTPClient *http.Client
}

// Error is an API error with the code and status from docs/api.md.
type Error struct {
	Status  int
	Code    string
	Message string
}

func (e *Error) Error() string { return e.Code + ": " + e.Message }

func invalid(format string, a ...any) *Error {
	return &Error{http.StatusBadRequest, "invalid_request", fmt.Sprintf(format, a...)}
}

var (
	errNotFound  = &Error{http.StatusNotFound, "not_found", "no such request"}
	errForbidden = func(msg string) *Error { return &Error{http.StatusForbidden, "forbidden", msg} }
)

// MacConn is the send side of a Mac's WebSocket. Send must not block.
type MacConn interface {
	Send(frame []byte)
}

type mac struct {
	device     model.Device
	conn       MacConn
	presence   model.Presence
	receivedAt time.Time
	reported   bool
}

type Hub struct {
	cfg Config
	log *slog.Logger

	mu      sync.Mutex
	pending map[string]*store.Record
	timers  map[string]Timer
	macs    map[string]*mac // by device id, connected only
	subs    map[string]map[chan *model.Request]struct{}
	tick    Timer
	closed  bool
	// Until warmUntil after a start, a missing Mac may just be reconnecting,
	// so requests reloaded from the store don't escalate for lack of one.
	warmUntil time.Time
	reloaded  map[string]bool
}

func New(cfg Config) *Hub {
	if cfg.Clock == nil {
		cfg.Clock = RealClock
	}
	if cfg.Log == nil {
		cfg.Log = slog.Default()
	}
	if cfg.Timings == (Timings{}) {
		cfg.Timings = DefaultTimings
	}
	if cfg.Dispatch == nil {
		cfg.Dispatch = func(f func()) { go f() }
	}
	if cfg.HTTPClient == nil {
		cfg.HTTPClient = &http.Client{Timeout: 15 * time.Second}
	}
	if cfg.Pusher == nil {
		cfg.Pusher = push.Log{L: cfg.Log}
	}
	return &Hub{
		cfg:      cfg,
		log:      cfg.Log,
		pending:  map[string]*store.Record{},
		timers:   map[string]Timer{},
		macs:     map[string]*mac{},
		subs:     map[string]map[chan *model.Request]struct{}{},
		reloaded: map[string]bool{},
	}
}

// Start reloads pending requests, re-arms their deadlines and starts the
// presence tick.
func (h *Hub) Start(ctx context.Context) error {
	recs, err := h.cfg.Store.ListRequests(ctx, model.StatePending, 100000)
	if err != nil {
		return err
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	h.warmUntil = h.cfg.Clock.Now().Add(h.cfg.Timings.HeartbeatTimeout)
	for _, rec := range recs {
		rec := rec
		h.pending[rec.Request.ID] = &rec
		h.reloaded[rec.Request.ID] = true
	}
	h.stepAllLocked()
	h.scheduleTickLocked()
	h.log.Info("hub started", "pending", len(recs))
	return nil
}

func (h *Hub) Close() {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.closed = true
	for _, t := range h.timers {
		t.Stop()
	}
	if h.tick != nil {
		h.tick.Stop()
	}
}

func (h *Hub) scheduleTickLocked() {
	if h.closed {
		return
	}
	h.tick = h.cfg.Clock.AfterFunc(h.cfg.Timings.PresenceTick, func() {
		h.mu.Lock()
		defer h.mu.Unlock()
		h.stepAllLocked()
		h.scheduleTickLocked()
	})
}

// ---- requests ----

func defaultOptions(kind model.Kind) []model.Option {
	switch kind {
	case model.KindAuthorize:
		return []model.Option{
			{ID: "approve", Label: "Approve", Style: model.StyleDefault},
			{ID: "deny", Label: "Deny", Style: model.StyleDestructive, Negative: true},
		}
	case model.KindAction:
		return []model.Option{
			{ID: "done", Label: "Done", Style: model.StyleDefault},
			{ID: "cant", Label: "Can't", Style: model.StyleDefault, Negative: true},
		}
	}
	return nil
}

func (h *Hub) Create(ctx context.Context, who identity.Identity, in model.CreateRequest) (*model.Request, error) {
	switch in.Kind {
	case model.KindDecision, model.KindAuthorize, model.KindAction:
	default:
		return nil, invalid("kind must be decision, authorize or action")
	}
	if in.Title == "" || len([]rune(in.Title)) > 200 {
		return nil, invalid("title is required and at most 200 characters")
	}
	if len(in.Body) > 64<<10 {
		return nil, invalid("body exceeds 64 KiB")
	}
	if len(in.Options) > 8 {
		return nil, invalid("at most 8 options")
	}
	seen := map[string]bool{}
	opts := make([]model.Option, 0, len(in.Options))
	for _, o := range in.Options {
		if o.ID == "" || len(o.ID) > 64 || seen[o.ID] {
			return nil, invalid("option ids must be unique, non-empty and at most 64 characters")
		}
		seen[o.ID] = true
		if o.Label == "" {
			o.Label = o.ID
		}
		switch o.Style {
		case "":
			o.Style = model.StyleDefault
		case model.StyleDefault, model.StyleDestructive:
		default:
			return nil, invalid("option style must be default or destructive")
		}
		opts = append(opts, o)
	}
	if len(opts) == 0 {
		opts = defaultOptions(in.Kind)
		if in.Kind == model.KindDecision && !in.AllowText {
			return nil, invalid("a decision needs options or allow_text")
		}
	}
	switch in.Urgency {
	case "":
		in.Urgency = model.UrgencyNormal
	case model.UrgencyLow, model.UrgencyNormal, model.UrgencyHigh:
	default:
		return nil, invalid("urgency must be low, normal or high")
	}
	if in.GraceSeconds < 0 || in.GraceSeconds > 300 {
		return nil, invalid("grace_seconds must be between 0 and 300")
	}
	if in.ExpiresInSeconds == 0 {
		in.ExpiresInSeconds = 86400
	}
	if in.ExpiresInSeconds < 60 || in.ExpiresInSeconds > 604800 {
		return nil, invalid("expires_in_seconds must be between 60 and 604800")
	}
	if in.CallbackURL != nil && *in.CallbackURL == "" {
		in.CallbackURL = nil
	}

	now := h.cfg.Clock.Now()
	req := &model.Request{
		ID:           ulid.Make().String(),
		Agent:        model.Agent{Host: who.Host, Node: who.Node, Label: in.Agent.Label, Session: in.Agent.Session},
		Kind:         in.Kind,
		Title:        in.Title,
		Body:         in.Body,
		Options:      opts,
		AllowText:    in.AllowText,
		Urgency:      in.Urgency,
		Sensitive:    in.Sensitive,
		GraceSeconds: in.GraceSeconds,
		CreatedAt:    now,
		ExpiresAt:    now.Add(time.Duration(in.ExpiresInSeconds) * time.Second),
		CallbackURL:  in.CallbackURL,
		State:        model.StatePending,
		Stage:        model.StageGrace,
	}
	if req.Agent.Label == "" {
		req.Agent.Label = "agent"
	}

	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.pending) >= MaxPending {
		return nil, &Error{Status: http.StatusTooManyRequests, Code: "too_many_pending", Message: fmt.Sprintf("%d requests are already pending", len(h.pending))}
	}
	rec := &store.Record{Request: req}
	// Persist before routing so no device hears about a request the store lacks.
	if err := h.saveLocked(ctx, rec); err != nil {
		return nil, err
	}
	h.pending[req.ID] = rec
	before := snapshot(rec)
	h.stepLocked(rec, now)
	if snapshot(rec) != before {
		if err := h.saveLocked(context.WithoutCancel(ctx), rec); err != nil {
			h.log.Error("save request", "id", req.ID, "err", err)
		}
	}
	h.log.Info("request created", "id", req.ID, "kind", req.Kind, "agent", req.Agent.Label, "host", req.Agent.Host, "stage", req.Stage)
	return clone(req), nil
}

func (h *Hub) Get(ctx context.Context, id string) (*model.Request, error) {
	h.mu.Lock()
	if rec, ok := h.pending[id]; ok {
		defer h.mu.Unlock()
		return clone(rec.Request), nil
	}
	h.mu.Unlock()
	rec, err := h.cfg.Store.GetRequest(ctx, id)
	if errors.Is(err, store.ErrNotFound) {
		return nil, errNotFound
	}
	if err != nil {
		return nil, err
	}
	return rec.Request, nil
}

func (h *Hub) List(ctx context.Context, state model.State, limit int) ([]*model.Request, error) {
	if limit <= 0 || limit > 500 {
		limit = 50
	}
	recs, err := h.cfg.Store.ListRequests(ctx, state, limit)
	if err != nil {
		return nil, err
	}
	out := make([]*model.Request, 0, len(recs))
	for _, r := range recs {
		out = append(out, r.Request)
	}
	return out, nil
}

// Subscribe returns a channel that receives the request after every change.
// The returned function unsubscribes.
func (h *Hub) Subscribe(id string) (<-chan *model.Request, func()) {
	ch := make(chan *model.Request, 8)
	h.mu.Lock()
	if h.subs[id] == nil {
		h.subs[id] = map[chan *model.Request]struct{}{}
	}
	h.subs[id][ch] = struct{}{}
	h.mu.Unlock()
	return ch, func() {
		h.mu.Lock()
		delete(h.subs[id], ch)
		if len(h.subs[id]) == 0 {
			delete(h.subs, id)
		}
		h.mu.Unlock()
	}
}

func (h *Hub) publishLocked(req *model.Request) {
	for ch := range h.subs[req.ID] {
		// A slow subscriber may miss an intermediate state, never the latest:
		// drop its oldest queued state to make room.
		for sent := false; !sent; {
			select {
			case ch <- clone(req):
				sent = true
			default:
				select {
				case <-ch:
				default:
				}
			}
		}
	}
}

// Wait returns once the request leaves pending, the timeout passes or ctx ends.
func (h *Hub) Wait(ctx context.Context, id string, timeout time.Duration) (*model.Request, error) {
	ch, unsub := h.Subscribe(id)
	defer unsub()
	req, err := h.Get(ctx, id)
	if err != nil || req.State != model.StatePending {
		return req, err
	}
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	for {
		select {
		case r := <-ch:
			if r.State != model.StatePending {
				return r, nil
			}
		case <-timer.C:
			return h.Get(ctx, id)
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
}

func outcome(req *model.Request) string {
	switch req.State {
	case model.StateAnswered:
		if req.Response != nil {
			return "answered on " + req.Response.DeviceName
		}
		return "answered"
	case model.StateExpired:
		return "expired"
	case model.StateCancelled:
		return "cancelled"
	}
	return string(req.State)
}

func alreadyResolved(req *model.Request) *Error {
	return &Error{http.StatusConflict, "already_resolved", outcome(req)}
}

// lookupLocked finds a request for mutation. Resolved requests return a 409.
func (h *Hub) lookupLocked(ctx context.Context, id string) (*store.Record, error) {
	if rec, ok := h.pending[id]; ok {
		return rec, nil
	}
	rec, err := h.cfg.Store.GetRequest(ctx, id)
	if errors.Is(err, store.ErrNotFound) {
		return nil, errNotFound
	}
	if err != nil {
		return nil, err
	}
	return nil, alreadyResolved(rec.Request)
}

func (h *Hub) Cancel(ctx context.Context, who identity.Identity, id string) (*model.Request, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	rec, err := h.lookupLocked(ctx, id)
	if err != nil {
		return nil, err
	}
	if rec.Request.Agent.Node != who.Node {
		return nil, errForbidden("only the node that created a request may cancel it")
	}
	if err := h.resolveLocked(ctx, rec, model.StateCancelled, nil); err != nil {
		return nil, err
	}
	h.log.Info("request cancelled", "id", id)
	return clone(rec.Request), nil
}

func (h *Hub) Answer(ctx context.Context, who identity.Identity, id string, a model.Answer) (*model.Request, error) {
	dev, err := h.cfg.Store.DeviceByNode(ctx, who.Node)
	if errors.Is(err, store.ErrNotFound) {
		return nil, errForbidden("only registered devices may answer")
	}
	if err != nil {
		return nil, err
	}
	if a.Text != nil && *a.Text == "" {
		a.Text = nil
	}
	if a.OptionID != nil && *a.OptionID == "" {
		a.OptionID = nil
	}

	h.mu.Lock()
	defer h.mu.Unlock()
	rec, err := h.lookupLocked(ctx, id)
	if err != nil {
		return nil, err
	}
	req := rec.Request
	if a.OptionID == nil && a.Text == nil {
		return nil, invalid("option_id or text is required")
	}
	if a.OptionID != nil {
		if _, ok := req.Option(*a.OptionID); !ok {
			return nil, invalid("unknown option %q", *a.OptionID)
		}
	}
	if a.Text != nil && !req.AllowText {
		return nil, invalid("this request does not accept text")
	}
	resp := &model.Response{
		OptionID:   a.OptionID,
		Text:       a.Text,
		DeviceID:   dev.ID,
		DeviceName: dev.Name,
		AnsweredAt: h.cfg.Clock.Now(),
	}
	// During grace no device has been shown the request yet, so an approval
	// can only come from something reading the API, such as the agent itself.
	// Refusals are harmless and stay allowed.
	if req.Stage == model.StageGrace && !resp.NegativeFor(req) {
		return nil, &Error{Status: http.StatusConflict, Code: "too_early", Message: "this request hasn't been delivered yet"}
	}
	if err := h.resolveLocked(ctx, rec, model.StateAnswered, resp); err != nil {
		return nil, err
	}
	h.log.Info("request answered", "id", id, "device", dev.Name)
	return clone(req), nil
}

// ---- devices ----

func (h *Hub) RegisterDevice(ctx context.Context, who identity.Identity, in model.RegisterDevice) (model.Device, error) {
	if h.cfg.Owner != "" && who.User != h.cfg.Owner {
		return model.Device{}, errForbidden("only the hub owner's devices may register")
	}
	switch in.Kind {
	case model.DeviceMac, model.DeviceIPhone, model.DeviceCLI:
	default:
		return model.Device{}, invalid("kind must be mac, iphone or cli")
	}
	if in.Name == "" {
		in.Name = who.Host
	}
	if in.Kind == model.DeviceIPhone {
		if in.APNsEnvironment == "" {
			in.APNsEnvironment = "production"
		}
		if in.APNsEnvironment != "sandbox" && in.APNsEnvironment != "production" {
			return model.Device{}, invalid("apns_environment must be sandbox or production")
		}
	} else {
		in.APNsToken, in.APNsEnvironment = "", ""
	}
	now := h.cfg.Clock.Now()
	dev, err := h.cfg.Store.DeviceByNode(ctx, who.Node)
	switch {
	case errors.Is(err, store.ErrNotFound):
		dev = model.Device{ID: ulid.Make().String(), Node: who.Node, CreatedAt: now}
	case err != nil:
		return model.Device{}, err
	case in.Kind == model.DeviceCLI && dev.Kind != model.DeviceCLI:
		// A Mac or iPhone can already answer; turning it into a cli device would
		// cut the app off. Keep it as it is.
		dev.LastSeenAt = now
		if err := h.cfg.Store.PutDevice(ctx, dev); err != nil {
			return model.Device{}, err
		}
		return dev, nil
	}
	dev.Kind, dev.Name, dev.APNsToken, dev.APNsEnvironment, dev.LastSeenAt = in.Kind, in.Name, in.APNsToken, in.APNsEnvironment, now
	if err := h.cfg.Store.PutDevice(ctx, dev); err != nil {
		return model.Device{}, err
	}
	h.log.Info("device registered", "id", dev.ID, "kind", dev.Kind, "name", dev.Name)
	return dev, nil
}

func (h *Hub) Devices(ctx context.Context) ([]model.Device, error) {
	return h.cfg.Store.Devices(ctx)
}

// DeviceForMac returns the caller's registered Mac device.
func (h *Hub) DeviceForMac(ctx context.Context, who identity.Identity) (model.Device, error) {
	dev, err := h.cfg.Store.DeviceByNode(ctx, who.Node)
	if errors.Is(err, store.ErrNotFound) || (err == nil && dev.Kind != model.DeviceMac) {
		return model.Device{}, errForbidden("register this node as a mac first")
	}
	return dev, err
}

// MacConnected attaches a socket and sends the sync frame.
func (h *Hub) MacConnected(dev model.Device, conn MacConn) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if old, ok := h.macs[dev.ID]; ok && old.conn != conn {
		h.log.Info("mac reconnected, replacing socket", "device", dev.Name)
	}
	h.macs[dev.ID] = &mac{device: dev, conn: conn}
	var recs []*store.Record
	for _, rec := range h.sortedPendingLocked() {
		r := rec.Request
		if (r.Stage == model.StageMac && r.RoutedTo != nil && *r.RoutedTo == dev.ID) || r.Stage == model.StagePhone {
			recs = append(recs, rec)
		}
	}
	// Keep the frame well under a WebSocket client's message limit: the newest
	// requests win, and older ones stay answerable from the phone.
	size, first := 0, len(recs)
	for first > 0 && len(recs)-first < MaxSync {
		b, _ := json.Marshal(recs[first-1].Request)
		if size+len(b) > MaxSyncBytes {
			break
		}
		size += len(b)
		first--
	}
	var reqs []*model.Request
	for _, rec := range recs[first:] {
		reqs = append(reqs, rec.Request)
		if !slices.Contains(rec.Routing.DeliveredTo, dev.ID) {
			rec.Routing.DeliveredTo = append(rec.Routing.DeliveredTo, dev.ID)
		}
	}
	h.sendLocked(dev.ID, model.HubFrame{Type: "sync", Requests: nonNil(reqs)})
	h.log.Info("mac connected", "device", dev.Name)
}

func nonNil(r []*model.Request) []*model.Request {
	if r == nil {
		return []*model.Request{}
	}
	return r
}

func (h *Hub) MacPresence(devID string, conn MacConn, p model.Presence) {
	h.mu.Lock()
	defer h.mu.Unlock()
	m, ok := h.macs[devID]
	if !ok || m.conn != conn {
		return
	}
	m.presence, m.receivedAt, m.reported = p, h.cfg.Clock.Now(), true
	h.log.Debug("mac presence", "device", m.device.Name, "idle", p.IdleSeconds, "locked", p.Locked,
		"asleep", p.Asleep, "display_asleep", p.DisplayAsleep, "session_active", p.SessionActive)
	h.stepAllLocked()
}

func (h *Hub) MacDisconnected(devID string, conn MacConn) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if m, ok := h.macs[devID]; ok && m.conn == conn {
		delete(h.macs, devID)
		h.log.Info("mac disconnected", "device", m.device.Name)
		h.stepAllLocked()
	}
}

// ---- routing ----

func (h *Hub) activeLocked(m *mac, now time.Time) bool {
	t := h.cfg.Timings
	if m == nil || !m.reported {
		return false
	}
	p := m.presence
	if p.Locked || p.Asleep || p.DisplayAsleep || !p.SessionActive {
		return false
	}
	since := now.Sub(m.receivedAt)
	idle := time.Duration(p.IdleSeconds*float64(time.Second)) + since
	return since < t.HeartbeatTimeout && idle < t.IdleThreshold
}

// currentMacLocked is the active Mac with the most recent input.
func (h *Hub) currentMacLocked(now time.Time) *mac {
	var best *mac
	var bestInput time.Time
	for _, m := range h.macs {
		if !h.activeLocked(m, now) {
			continue
		}
		input := m.receivedAt.Add(-time.Duration(m.presence.IdleSeconds * float64(time.Second)))
		if best == nil || input.After(bestInput) || (input.Equal(bestInput) && m.device.ID < best.device.ID) {
			best, bestInput = m, input
		}
	}
	return best
}

func (h *Hub) sortedPendingLocked() []*store.Record {
	recs := make([]*store.Record, 0, len(h.pending))
	for _, r := range h.pending {
		recs = append(recs, r)
	}
	slices.SortFunc(recs, func(a, b *store.Record) int { return a.Request.CreatedAt.Compare(b.Request.CreatedAt) })
	return recs
}

func (h *Hub) stepAllLocked() {
	now := h.cfg.Clock.Now()
	for _, rec := range h.sortedPendingLocked() {
		before := snapshot(rec)
		h.stepLocked(rec, now)
		if snapshot(rec) != before {
			if err := h.saveLocked(context.Background(), rec); err != nil {
				h.log.Error("save request", "id", rec.Request.ID, "err", err)
			}
		}
	}
}

// snapshot captures what stepLocked can change, to decide whether to save.
func snapshot(rec *store.Record) string {
	r := rec.Request
	b, _ := json.Marshal(struct {
		State    model.State
		Stage    model.Stage
		RoutedTo *string
		Routing  store.Routing
	}{r.State, r.Stage, r.RoutedTo, rec.Routing})
	return string(b)
}

// stepLocked advances one pending request's routing to match the current time
// and presence, then re-arms its timer.
func (h *Hub) stepLocked(rec *store.Record, now time.Time) {
	req := rec.Request
	if req.State != model.StatePending {
		return
	}
	if !now.Before(req.ExpiresAt) {
		if err := h.resolveLocked(context.Background(), rec, model.StateExpired, nil); err != nil {
			// The presence tick retries.
			h.log.Error("expire request", "id", req.ID, "err", err)
			return
		}
		h.log.Info("request expired", "id", req.ID)
		return
	}
	graceEnd := req.CreatedAt.Add(time.Duration(req.GraceSeconds) * time.Second)
	if now.Before(graceEnd) {
		req.Stage = model.StageGrace
		h.armLocked(rec)
		return
	}
	cur := h.currentMacLocked(now)
	warming := h.reloaded[req.ID] && now.Before(h.warmUntil)
	switch req.Stage {
	case model.StageGrace, "":
		switch {
		case cur != nil:
			h.toMacLocked(rec, cur, now)
		case !warming:
			h.toPhoneLocked(rec, now)
		}
	case model.StageMac:
		routed := h.macs[deref(req.RoutedTo)]
		switch {
		case warming && (routed == nil || !routed.reported):
		case cur != nil && cur != routed:
			// Follow the user to the Mac they are using, including when the old
			// one just locked or slept; the fallback timer keeps running.
			old := deref(req.RoutedTo)
			h.sendLocked(old, model.HubFrame{Type: "retract", Request: req})
			rec.Routing.DeliveredTo = slices.DeleteFunc(rec.Routing.DeliveredTo, func(id string) bool { return id == old })
			req.RoutedTo = ptr(cur.device.ID)
			h.deliverLocked(rec, cur.device.ID)
		case !h.activeLocked(routed, now):
			h.toPhoneLocked(rec, now)
		case rec.Routing.EscalateAt != nil && !now.Before(*rec.Routing.EscalateAt):
			h.toPhoneLocked(rec, now)
		}
	case model.StagePhone:
		if cur != nil && !slices.Contains(rec.Routing.DeliveredTo, cur.device.ID) {
			h.deliverLocked(rec, cur.device.ID)
		}
		if rec.Routing.RealertAt != nil && !now.Before(*rec.Routing.RealertAt) {
			h.pushAlertsLocked(rec)
			rec.Routing.RealertAt = ptr(now.Add(h.cfg.Timings.RealertHigh))
		}
	}
	h.armLocked(rec)
}

func (h *Hub) toMacLocked(rec *store.Record, m *mac, now time.Time) {
	req := rec.Request
	req.Stage = model.StageMac
	req.RoutedTo = ptr(m.device.ID)
	rec.Routing.EscalateAt = nil
	switch req.Urgency {
	case model.UrgencyNormal:
		rec.Routing.EscalateAt = ptr(now.Add(h.cfg.Timings.FallbackNormal))
	case model.UrgencyHigh:
		rec.Routing.EscalateAt = ptr(now.Add(h.cfg.Timings.FallbackHigh))
	}
	h.deliverLocked(rec, m.device.ID)
}

func (h *Hub) toPhoneLocked(rec *store.Record, now time.Time) {
	req := rec.Request
	req.Stage = model.StagePhone
	req.RoutedTo = nil
	rec.Routing.EscalateAt = nil
	h.pushAlertsLocked(rec)
	if req.Urgency == model.UrgencyHigh {
		rec.Routing.RealertAt = ptr(now.Add(h.cfg.Timings.RealertHigh))
	}
	h.log.Info("request escalated to phone", "id", req.ID)
}

func (h *Hub) deliverLocked(rec *store.Record, devID string) {
	h.sendLocked(devID, model.HubFrame{Type: "deliver", Request: rec.Request})
	if !slices.Contains(rec.Routing.DeliveredTo, devID) {
		rec.Routing.DeliveredTo = append(rec.Routing.DeliveredTo, devID)
	}
}

func (h *Hub) iphonesLocked() []model.Device {
	devs, err := h.cfg.Store.Devices(context.Background())
	if err != nil {
		h.log.Error("list devices", "err", err)
		return nil
	}
	var out []model.Device
	for _, d := range devs {
		if d.Kind == model.DeviceIPhone && d.APNsToken != "" {
			out = append(out, d)
		}
	}
	return out
}

func (h *Hub) pushAlertsLocked(rec *store.Record) {
	phones := h.iphonesLocked()
	if len(phones) == 0 {
		h.log.Warn("no iPhone registered, request stays where it is", "id", rec.Request.ID)
		return
	}
	rec.Routing.Pushed = true
	req := clone(rec.Request)
	for _, d := range phones {
		d := d
		h.cfg.Dispatch(func() {
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()
			if err := h.cfg.Pusher.Alert(ctx, d, req); err != nil {
				h.log.Error("push alert", "device", d.Name, "request", req.ID, "err", err)
			}
		})
	}
}

// resolveLocked moves a request to a terminal state, persists it, and only
// then retracts it everywhere and tells waiters. If the save fails the request
// stays pending, untouched.
func (h *Hub) resolveLocked(ctx context.Context, rec *store.Record, state model.State, resp *model.Response) error {
	req := rec.Request
	prevReq, prevRouting := *req, rec.Routing
	now := h.cfg.Clock.Now()
	req.State = state
	req.Stage = model.StageDone
	req.Response = resp
	req.ResolvedAt = &now
	rec.Routing.EscalateAt, rec.Routing.RealertAt = nil, nil
	// The caller going away must not abandon a resolution halfway.
	sctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 10*time.Second)
	defer cancel()
	if err := h.saveLocked(sctx, rec); err != nil {
		*req, rec.Routing = prevReq, prevRouting
		return err
	}
	if t, ok := h.timers[req.ID]; ok {
		t.Stop()
		delete(h.timers, req.ID)
	}
	delete(h.pending, req.ID)
	delete(h.reloaded, req.ID)

	for _, devID := range rec.Routing.DeliveredTo {
		h.sendLocked(devID, model.HubFrame{Type: "retract", Request: req})
	}
	if rec.Routing.Pushed {
		phones := h.iphonesLocked()
		for _, d := range phones {
			d := d
			h.cfg.Dispatch(func() {
				ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
				defer cancel()
				if err := h.cfg.Pusher.Retract(ctx, d, req.ID); err != nil {
					h.log.Error("push retract", "device", d.Name, "request", req.ID, "err", err)
				}
			})
		}
	}
	h.publishLocked(req)
	if req.CallbackURL != nil {
		body, _ := json.Marshal(req)
		url := *req.CallbackURL
		h.cfg.Dispatch(func() { h.callback(url, req.ID, body) })
	}
	return nil
}

// callback POSTs the resolved request, retrying with backoff for up to an hour.
func (h *Hub) callback(url, id string, body []byte) {
	deadline := time.Now().Add(time.Hour)
	backoff := time.Second
	for {
		req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(body))
		if err != nil {
			h.log.Error("callback url", "request", id, "err", err)
			return
		}
		req.Header.Set("Content-Type", "application/json")
		res, err := h.cfg.HTTPClient.Do(req)
		if err == nil {
			res.Body.Close()
			if res.StatusCode < 300 {
				return
			}
			err = fmt.Errorf("status %d", res.StatusCode)
		}
		if time.Now().Add(backoff).After(deadline) {
			h.log.Error("callback gave up", "request", id, "url", url, "err", err)
			return
		}
		h.log.Warn("callback failed, retrying", "request", id, "err", err, "in", backoff)
		time.Sleep(backoff)
		backoff = min(backoff*2, 5*time.Minute)
	}
}

// armLocked schedules the next deadline: grace end, escalation, re-alert or expiry.
func (h *Hub) armLocked(rec *store.Record) {
	req := rec.Request
	if t, ok := h.timers[req.ID]; ok {
		t.Stop()
		delete(h.timers, req.ID)
	}
	if h.closed || req.State != model.StatePending {
		return
	}
	// Deadlines already passed (held back by warm-up) are left to the presence
	// tick; re-arming them would fire in a loop.
	now := h.cfg.Clock.Now()
	next := req.ExpiresAt
	consider := func(t *time.Time) {
		if t != nil && t.After(now) && t.Before(next) {
			next = *t
		}
	}
	if req.Stage == model.StageGrace {
		consider(ptr(req.CreatedAt.Add(time.Duration(req.GraceSeconds) * time.Second)))
	}
	consider(rec.Routing.EscalateAt)
	consider(rec.Routing.RealertAt)
	id := req.ID
	d := max(next.Sub(now), 0)
	h.timers[id] = h.cfg.Clock.AfterFunc(d, func() {
		h.mu.Lock()
		defer h.mu.Unlock()
		rec, ok := h.pending[id]
		if !ok {
			return
		}
		delete(h.timers, id)
		h.stepLocked(rec, h.cfg.Clock.Now())
		if err := h.saveLocked(context.Background(), rec); err != nil {
			h.log.Error("save request", "id", id, "err", err)
		}
	})
}

func (h *Hub) sendLocked(devID string, f model.HubFrame) {
	m, ok := h.macs[devID]
	if !ok {
		return
	}
	b, err := json.Marshal(f)
	if err != nil {
		h.log.Error("marshal frame", "err", err)
		return
	}
	m.conn.Send(b)
}

func (h *Hub) saveLocked(ctx context.Context, rec *store.Record) error {
	if err := h.cfg.Store.PutRequest(ctx, *rec); err != nil {
		return err
	}
	if rec.Request.State == model.StatePending {
		h.publishLocked(rec.Request)
	}
	return nil
}

func clone(r *model.Request) *model.Request {
	b, _ := json.Marshal(r)
	var c model.Request
	_ = json.Unmarshal(b, &c)
	return &c
}

func ptr[T any](v T) *T { return &v }

func deref(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}
