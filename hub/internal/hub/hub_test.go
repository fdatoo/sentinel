package hub

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"fdatoo.dev/sentinel/hub/internal/identity"
	"fdatoo.dev/sentinel/hub/internal/model"
	"fdatoo.dev/sentinel/hub/internal/push"
	"fdatoo.dev/sentinel/hub/internal/store"
)

type fakeConn struct {
	mu     sync.Mutex
	frames []model.HubFrame
}

func (c *fakeConn) Send(b []byte) {
	var f model.HubFrame
	if err := json.Unmarshal(b, &f); err != nil {
		panic(err)
	}
	c.mu.Lock()
	c.frames = append(c.frames, f)
	c.mu.Unlock()
}

// kinds returns "type:id" for each frame since the last call.
func (c *fakeConn) take() []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	var out []string
	for _, f := range c.frames {
		switch {
		case f.Request != nil:
			out = append(out, f.Type+":"+f.Request.ID)
		default:
			s := f.Type + ":"
			for _, r := range f.Requests {
				s += r.ID + ","
			}
			out = append(out, s)
		}
	}
	c.frames = nil
	return out
}

type env struct {
	t     *testing.T
	st    *store.Store
	path  string
	clock *FakeClock
	push  *push.Recorder
	hub   *Hub
}

var agent = identity.Identity{Node: "agent-node", Host: "devbox", User: "fynn"}

func newEnv(t *testing.T) *env {
	t.Helper()
	path := filepath.Join(t.TempDir(), "s.db")
	e := &env{t: t, path: path, clock: NewFakeClock(time.Date(2026, 10, 1, 9, 0, 0, 0, time.UTC)), push: &push.Recorder{}}
	e.open()
	return e
}

func (e *env) open() {
	st, err := store.Open(e.path)
	if err != nil {
		e.t.Fatal(err)
	}
	e.st = st
	e.hub = New(Config{
		Store:    st,
		Pusher:   e.push,
		Clock:    e.clock,
		Log:      slog.New(slog.NewTextHandler(io.Discard, nil)),
		Dispatch: func(f func()) { f() },
	})
	if err := e.hub.Start(context.Background()); err != nil {
		e.t.Fatal(err)
	}
	e.t.Cleanup(func() { e.hub.Close(); st.Close() })
}

func (e *env) restart() {
	e.hub.Close()
	e.st.Close()
	e.open()
}

func (e *env) register(node string, kind model.DeviceKind) model.Device {
	e.t.Helper()
	in := model.RegisterDevice{Kind: kind, Name: node}
	if kind == model.DeviceIPhone {
		in.APNsToken, in.APNsEnvironment = "abcd", "sandbox"
	}
	d, err := e.hub.RegisterDevice(context.Background(), identity.Identity{Node: node, Host: node}, in)
	if err != nil {
		e.t.Fatal(err)
	}
	return d
}

func (e *env) mac(name string, idle float64) (model.Device, *fakeConn) {
	d := e.register(name, model.DeviceMac)
	c := &fakeConn{}
	e.hub.MacConnected(d, c)
	e.hub.MacPresence(d.ID, c, model.Presence{IdleSeconds: idle, SessionActive: true})
	c.take()
	return d, c
}

func (e *env) create(in model.CreateRequest) *model.Request {
	e.t.Helper()
	if in.Kind == "" {
		in.Kind = model.KindAuthorize
	}
	if in.Title == "" {
		in.Title = "Deploy?"
	}
	r, err := e.hub.Create(context.Background(), agent, in)
	if err != nil {
		e.t.Fatal(err)
	}
	return r
}

func (e *env) get(id string) *model.Request {
	r, err := e.hub.Get(context.Background(), id)
	if err != nil {
		e.t.Fatal(err)
	}
	return r
}

func eq(t *testing.T, got, want any) {
	t.Helper()
	gb, _ := json.Marshal(got)
	wb, _ := json.Marshal(want)
	if string(gb) != string(wb) {
		t.Fatalf("got %s, want %s", gb, wb)
	}
}

func TestRoutesToActiveMacThenEscalates(t *testing.T) {
	e := newEnv(t)
	e.register("phone", model.DeviceIPhone)
	m, c := e.mac("mbp", 3)
	r := e.create(model.CreateRequest{})
	eq(t, r.Stage, model.StageMac)
	eq(t, *r.RoutedTo, m.ID)
	eq(t, c.take(), []string{"deliver:" + r.ID})

	// Keep the Mac active but unanswered: presence every 15s.
	for range 11 {
		e.clock.Advance(15 * time.Second)
		e.hub.MacPresence(m.ID, c, model.Presence{IdleSeconds: 1, SessionActive: true})
	}
	eq(t, e.get(r.ID).Stage, model.StageMac)
	eq(t, len(e.push.Alerts()), 0)
	e.clock.Advance(20 * time.Second) // passes 3m
	e.hub.MacPresence(m.ID, c, model.Presence{IdleSeconds: 1, SessionActive: true})
	eq(t, e.get(r.ID).Stage, model.StagePhone)
	eq(t, e.push.Alerts(), []string{r.ID})
}

func TestNoActiveMacGoesStraightToPhone(t *testing.T) {
	e := newEnv(t)
	e.register("phone", model.DeviceIPhone)
	_, c := e.mac("mbp", 500) // idle past threshold
	r := e.create(model.CreateRequest{})
	eq(t, r.Stage, model.StagePhone)
	eq(t, e.push.Alerts(), []string{r.ID})
	eq(t, c.take(), []string(nil))
}

func TestLockingTheMacEscalatesImmediately(t *testing.T) {
	e := newEnv(t)
	e.register("phone", model.DeviceIPhone)
	m, c := e.mac("mbp", 0)
	r := e.create(model.CreateRequest{})
	e.hub.MacPresence(m.ID, c, model.Presence{Locked: true, SessionActive: true})
	eq(t, e.get(r.ID).Stage, model.StagePhone)
	eq(t, len(e.push.Alerts()), 1)
}

func TestHeartbeatTimeoutEscalates(t *testing.T) {
	e := newEnv(t)
	e.register("phone", model.DeviceIPhone)
	e.mac("mbp", 0)
	r := e.create(model.CreateRequest{Urgency: model.UrgencyLow})
	e.clock.Advance(50 * time.Second) // presence tick notices the silent Mac
	eq(t, e.get(r.ID).Stage, model.StagePhone)
}

func TestLowUrgencyStaysOnActiveMac(t *testing.T) {
	e := newEnv(t)
	e.register("phone", model.DeviceIPhone)
	m, c := e.mac("mbp", 0)
	r := e.create(model.CreateRequest{Urgency: model.UrgencyLow})
	for range 40 {
		e.clock.Advance(15 * time.Second)
		e.hub.MacPresence(m.ID, c, model.Presence{IdleSeconds: 1, SessionActive: true})
	}
	eq(t, e.get(r.ID).Stage, model.StageMac)
	eq(t, len(e.push.Alerts()), 0)
}

func TestHighUrgencyFallsBackFasterAndRealerts(t *testing.T) {
	e := newEnv(t)
	e.register("phone", model.DeviceIPhone)
	m, c := e.mac("mbp", 0)
	r := e.create(model.CreateRequest{Urgency: model.UrgencyHigh})
	for range 4 {
		e.clock.Advance(15 * time.Second)
		e.hub.MacPresence(m.ID, c, model.Presence{IdleSeconds: 1, SessionActive: true})
	}
	eq(t, e.get(r.ID).Stage, model.StagePhone)
	e.hub.MacDisconnected(m.ID, c)
	e.clock.Advance(5 * time.Minute)
	e.clock.Advance(5 * time.Minute)
	eq(t, e.push.Alerts(), []string{r.ID, r.ID, r.ID})
}

func TestFollowsUserToAnotherMac(t *testing.T) {
	e := newEnv(t)
	e.register("phone", model.DeviceIPhone)
	a, ca := e.mac("mbp", 0)
	r := e.create(model.CreateRequest{})
	eq(t, ca.take(), []string{"deliver:" + r.ID})
	e.clock.Advance(10 * time.Second)
	b, cb := e.mac("studio", 0) // more recent input
	eq(t, *e.get(r.ID).RoutedTo, b.ID)
	eq(t, ca.take(), []string{"retract:" + r.ID})
	eq(t, cb.take(), []string(nil)) // delivered before take() in mac()
	_ = a
}

func TestPhoneStageAlsoDeliversToMacThatWakes(t *testing.T) {
	e := newEnv(t)
	e.register("phone", model.DeviceIPhone)
	r := e.create(model.CreateRequest{})
	eq(t, r.Stage, model.StagePhone)
	m := e.register("mbp", model.DeviceMac)
	c := &fakeConn{}
	e.hub.MacConnected(m, c)
	eq(t, c.take(), []string{"sync:" + r.ID + ","})
	e.hub.MacPresence(m.ID, c, model.Presence{SessionActive: true})
	eq(t, c.take(), []string(nil)) // sync already counted as delivery
	_, err := e.hub.Answer(context.Background(), identity.Identity{Node: "mbp"}, r.ID, model.Answer{OptionID: ptr("approve")})
	if err != nil {
		t.Fatal(err)
	}
	eq(t, c.take(), []string{"retract:" + r.ID})
	eq(t, e.push.Retracts(), []string{r.ID})
}

func TestGraceDelaysRouting(t *testing.T) {
	e := newEnv(t)
	e.register("phone", model.DeviceIPhone)
	r := e.create(model.CreateRequest{GraceSeconds: 10})
	eq(t, r.Stage, model.StageGrace)
	e.clock.Advance(9 * time.Second)
	eq(t, len(e.push.Alerts()), 0)
	e.clock.Advance(time.Second)
	eq(t, e.get(r.ID).Stage, model.StagePhone)
	eq(t, len(e.push.Alerts()), 1)
}

func TestCancelDuringGraceNeverNotifies(t *testing.T) {
	e := newEnv(t)
	e.register("phone", model.DeviceIPhone)
	r := e.create(model.CreateRequest{GraceSeconds: 10})
	if _, err := e.hub.Cancel(context.Background(), agent, r.ID); err != nil {
		t.Fatal(err)
	}
	e.clock.Advance(time.Minute)
	eq(t, len(e.push.Alerts()), 0)
	eq(t, len(e.push.Retracts()), 0)
	eq(t, e.get(r.ID).State, model.StateCancelled)
}

func TestFirstAnswerWins(t *testing.T) {
	e := newEnv(t)
	e.register("phone", model.DeviceIPhone)
	e.register("cli", model.DeviceCLI)
	r := e.create(model.CreateRequest{})
	got, err := e.hub.Answer(context.Background(), identity.Identity{Node: "phone"}, r.ID, model.Answer{OptionID: ptr("deny")})
	if err != nil {
		t.Fatal(err)
	}
	eq(t, got.State, model.StateAnswered)
	if !got.Negative() {
		t.Fatal("deny should be negative")
	}
	_, err = e.hub.Answer(context.Background(), identity.Identity{Node: "cli"}, r.ID, model.Answer{OptionID: ptr("approve")})
	var he *Error
	if !errors.As(err, &he) || he.Code != "already_resolved" || he.Message != "answered on phone" {
		t.Fatalf("got %v", err)
	}
}

func TestAnswerValidation(t *testing.T) {
	e := newEnv(t)
	e.register("phone", model.DeviceIPhone)
	r := e.create(model.CreateRequest{})
	cases := []struct {
		who  string
		a    model.Answer
		code string
	}{
		{"stranger", model.Answer{OptionID: ptr("approve")}, "forbidden"},
		{"phone", model.Answer{}, "invalid_request"},
		{"phone", model.Answer{OptionID: ptr("maybe")}, "invalid_request"},
		{"phone", model.Answer{Text: ptr("hi")}, "invalid_request"},
	}
	for _, c := range cases {
		_, err := e.hub.Answer(context.Background(), identity.Identity{Node: c.who}, r.ID, c.a)
		var he *Error
		if !errors.As(err, &he) || he.Code != c.code {
			t.Errorf("%+v: got %v, want %s", c, err, c.code)
		}
	}
	if _, err := e.hub.Cancel(context.Background(), identity.Identity{Node: "other"}, r.ID); err == nil {
		t.Error("non-creator cancelled")
	}
}

func TestCreateValidation(t *testing.T) {
	e := newEnv(t)
	bad := []model.CreateRequest{
		{Kind: "nope", Title: "x"},
		{Kind: model.KindDecision, Title: "x"},
		{Kind: model.KindAuthorize},
		{Kind: model.KindAuthorize, Title: "x", GraceSeconds: 301},
		{Kind: model.KindAuthorize, Title: "x", ExpiresInSeconds: 10},
		{Kind: model.KindAuthorize, Title: "x", Options: []model.Option{{ID: "a"}, {ID: "a"}}},
	}
	for _, in := range bad {
		if _, err := e.hub.Create(context.Background(), agent, in); err == nil {
			t.Errorf("%+v accepted", in)
		}
	}
	r := e.create(model.CreateRequest{Kind: model.KindAction})
	eq(t, r.Options, defaultOptions(model.KindAction))
	eq(t, r.Agent.Host, "devbox")
	eq(t, r.Agent.Label, "agent")
}

func TestExpiry(t *testing.T) {
	e := newEnv(t)
	r := e.create(model.CreateRequest{ExpiresInSeconds: 60})
	e.clock.Advance(time.Minute)
	eq(t, e.get(r.ID).State, model.StateExpired)
}

func TestWaitReturnsOnAnswer(t *testing.T) {
	e := newEnv(t)
	e.register("phone", model.DeviceIPhone)
	r := e.create(model.CreateRequest{})
	done := make(chan *model.Request)
	go func() {
		got, _ := e.hub.Wait(context.Background(), r.ID, 5*time.Second)
		done <- got
	}()
	time.Sleep(20 * time.Millisecond)
	e.hub.Answer(context.Background(), identity.Identity{Node: "phone"}, r.ID, model.Answer{OptionID: ptr("approve")})
	select {
	case got := <-done:
		eq(t, got.State, model.StateAnswered)
	case <-time.After(2 * time.Second):
		t.Fatal("wait did not return")
	}
}

func TestRestartKeepsEscalationDeadline(t *testing.T) {
	e := newEnv(t)
	e.register("phone", model.DeviceIPhone)
	m, c := e.mac("mbp", 0)
	r := e.create(model.CreateRequest{})
	for range 2 {
		e.clock.Advance(30 * time.Second)
		e.hub.MacPresence(m.ID, c, model.Presence{SessionActive: true})
	}

	e.restart()
	// The Mac reconnects within the warm-up window, so nothing escalates early.
	c2 := &fakeConn{}
	e.hub.MacConnected(m, c2)
	eq(t, c2.take(), []string{"sync:" + r.ID + ","})
	for range 7 {
		e.clock.Advance(15 * time.Second)
		e.hub.MacPresence(m.ID, c2, model.Presence{SessionActive: true})
	}
	eq(t, e.get(r.ID).Stage, model.StageMac)
	eq(t, len(e.push.Alerts()), 0)
	e.clock.Advance(16 * time.Second) // 3m after routing
	e.hub.MacPresence(m.ID, c2, model.Presence{SessionActive: true})
	eq(t, e.get(r.ID).Stage, model.StagePhone)
}

func TestRestartWithoutMacEscalatesAfterWarmup(t *testing.T) {
	e := newEnv(t)
	e.register("phone", model.DeviceIPhone)
	e.mac("mbp", 0)
	r := e.create(model.CreateRequest{Urgency: model.UrgencyLow})
	e.restart()
	e.clock.Advance(40 * time.Second)
	eq(t, e.get(r.ID).Stage, model.StageMac)
	e.clock.Advance(10 * time.Second)
	eq(t, e.get(r.ID).Stage, model.StagePhone)
}

func answerAs(e *env, node, id string, a model.Answer) (*model.Request, error) {
	return e.hub.Answer(context.Background(), identity.Identity{Node: node}, id, a)
}

func TestNoApprovalsDuringGrace(t *testing.T) {
	e := newEnv(t)
	e.register("phone", model.DeviceIPhone)
	r := e.create(model.CreateRequest{GraceSeconds: 10})
	_, err := answerAs(e, "phone", r.ID, model.Answer{OptionID: ptr("approve")})
	var he *Error
	if !errors.As(err, &he) || he.Code != "too_early" {
		t.Fatalf("approval during grace: %v", err)
	}
	if _, err := answerAs(e, "phone", r.ID, model.Answer{OptionID: ptr("deny")}); err != nil {
		t.Fatalf("deny during grace: %v", err)
	}
	eq(t, len(e.push.Alerts()), 0)
}

func TestFailedSaveLeavesRequestPending(t *testing.T) {
	e := newEnv(t)
	e.register("phone", model.DeviceIPhone)
	_, c := e.mac("mbp", 0)
	r := e.create(model.CreateRequest{})
	c.take()
	ch, unsub := e.hub.Subscribe(r.ID)
	defer unsub()
	e.st.Close()
	if _, err := answerAs(e, "phone", r.ID, model.Answer{OptionID: ptr("approve")}); err == nil {
		t.Fatal("answer succeeded with a closed store")
	}
	select {
	case got := <-ch:
		t.Fatalf("waiter heard %s", got.State)
	default:
	}
	eq(t, c.take(), []string(nil))
	eq(t, len(e.push.Retracts()), 0)
	eq(t, e.get(r.ID).State, model.StatePending)
	eq(t, e.get(r.ID).Response, (*model.Response)(nil))
}

func TestFollowsInsteadOfEscalatingWhenOtherMacIsActive(t *testing.T) {
	e := newEnv(t)
	e.register("phone", model.DeviceIPhone)
	a, ca := e.mac("mbp", 0)
	b, cb := e.mac("studio", 20) // active, but A had more recent input
	r := e.create(model.CreateRequest{})
	eq(t, *r.RoutedTo, a.ID)
	ca.take()
	e.hub.MacPresence(a.ID, ca, model.Presence{Locked: true, SessionActive: true})
	got := e.get(r.ID)
	eq(t, got.Stage, model.StageMac)
	eq(t, *got.RoutedTo, b.ID)
	eq(t, ca.take(), []string{"retract:" + r.ID})
	eq(t, cb.take(), []string{"deliver:" + r.ID})
	eq(t, len(e.push.Alerts()), 0)
}

func TestPhoneStageRedeliversToMacThatFollowMeLeft(t *testing.T) {
	e := newEnv(t)
	e.register("phone", model.DeviceIPhone)
	a, ca := e.mac("mbp", 0)
	r := e.create(model.CreateRequest{})
	e.clock.Advance(10 * time.Second)
	b, cb := e.mac("studio", 0)
	eq(t, ca.take(), []string{"deliver:" + r.ID, "retract:" + r.ID})
	// The user stays at B without answering until the fallback fires.
	for range 12 {
		e.clock.Advance(15 * time.Second)
		e.hub.MacPresence(b.ID, cb, model.Presence{IdleSeconds: 1, SessionActive: true})
		e.hub.MacPresence(a.ID, ca, model.Presence{IdleSeconds: 500, SessionActive: true})
	}
	eq(t, e.get(r.ID).Stage, model.StagePhone)
	// Back at A.
	e.hub.MacPresence(a.ID, ca, model.Presence{IdleSeconds: 0, SessionActive: true})
	eq(t, ca.take(), []string{"deliver:" + r.ID})
}

func TestCLIRegistrationKeepsMac(t *testing.T) {
	e := newEnv(t)
	m := e.register("mbp", model.DeviceMac)
	d := e.register("mbp", model.DeviceCLI)
	eq(t, d.ID, m.ID)
	eq(t, d.Kind, model.DeviceMac)
	if _, err := e.hub.DeviceForMac(context.Background(), identity.Identity{Node: "mbp"}); err != nil {
		t.Fatal(err)
	}
}

func TestSyncIsCapped(t *testing.T) {
	e := newEnv(t)
	e.register("phone", model.DeviceIPhone)
	var last string
	for range MaxSync + 5 {
		last = e.create(model.CreateRequest{}).ID
		e.clock.Advance(time.Millisecond)
	}
	m := e.register("mbp", model.DeviceMac)
	c := &fakeConn{}
	e.hub.MacConnected(m, c)
	c.mu.Lock()
	reqs := c.frames[0].Requests
	c.mu.Unlock()
	eq(t, len(reqs), MaxSync)
	eq(t, reqs[len(reqs)-1].ID, last)
}

func TestPendingIsCapped(t *testing.T) {
	e := newEnv(t)
	for range MaxPending {
		e.create(model.CreateRequest{Urgency: model.UrgencyLow})
	}
	_, err := e.hub.Create(context.Background(), agent, model.CreateRequest{Kind: model.KindAuthorize, Title: "one more"})
	var he *Error
	if !errors.As(err, &he) || he.Status != 429 {
		t.Fatalf("got %v", err)
	}
}

func TestTextOnlyRefusesAuthorizeButAnswersDecision(t *testing.T) {
	text := "not until Monday"
	auth := &model.Request{Kind: model.KindAuthorize, Response: &model.Response{Text: &text}}
	dec := &model.Request{Kind: model.KindDecision, Response: &model.Response{Text: &text}}
	eq(t, auth.Negative(), true)
	eq(t, dec.Negative(), false)
}

func TestSyncStaysUnderMessageLimit(t *testing.T) {
	e := newEnv(t)
	e.register("phone", model.DeviceIPhone)
	body := strings.Repeat("x", 60_000)
	for range 20 {
		e.create(model.CreateRequest{Body: body})
		e.clock.Advance(time.Millisecond)
	}
	m := e.register("mbp", model.DeviceMac)
	c := &fakeConn{}
	e.hub.MacConnected(m, c)
	c.mu.Lock()
	reqs := c.frames[0].Requests
	c.mu.Unlock()
	b, _ := json.Marshal(model.HubFrame{Type: "sync", Requests: reqs})
	if len(reqs) == 0 || len(reqs) == 20 || len(b) > 1<<20 {
		t.Fatalf("%d requests, %d bytes", len(reqs), len(b))
	}
}
