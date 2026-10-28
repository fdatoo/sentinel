package api

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"fdatoo.dev/sentinel/hub/internal/client"
	"fdatoo.dev/sentinel/hub/internal/hub"
	"fdatoo.dev/sentinel/hub/internal/identity"
	"fdatoo.dev/sentinel/hub/internal/model"
	"fdatoo.dev/sentinel/hub/internal/push"
	"fdatoo.dev/sentinel/hub/internal/store"
)

func server(t *testing.T) (*httptest.Server, *push.Recorder) {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "s.db"))
	if err != nil {
		t.Fatal(err)
	}
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	rec := &push.Recorder{}
	h := hub.New(hub.Config{Store: st, Pusher: rec, Log: log, Dispatch: func(f func()) { f() }})
	if err := h.Start(context.Background()); err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer((&Server{Hub: h, Identity: identity.Dev{}, Log: log}).Handler())
	t.Cleanup(func() { srv.Close(); h.Close(); st.Close() })
	return srv, rec
}

func as(srv *httptest.Server, node string) *client.Client {
	return client.New(client.Config{URL: srv.URL, Node: node, Host: node})
}

func code(err error) string {
	var e *client.APIError
	if errors.As(err, &e) {
		return e.Code
	}
	return ""
}

func TestAskAnswerWait(t *testing.T) {
	srv, rec := server(t)
	ctx := context.Background()
	agent, phone, cli := as(srv, "agent"), as(srv, "phone"), as(srv, "cli")
	if _, err := phone.Register(ctx, model.RegisterDevice{Kind: model.DeviceIPhone, Name: "iPhone", APNsToken: "aa", APNsEnvironment: "sandbox"}); err != nil {
		t.Fatal(err)
	}
	cli.Register(ctx, model.RegisterDevice{Kind: model.DeviceCLI, Name: "term"})

	r, err := agent.Create(ctx, model.CreateRequest{Kind: model.KindAction, Title: "Plug in the YubiKey"})
	if err != nil {
		t.Fatal(err)
	}
	if r.Stage != model.StagePhone || r.Agent.Host != "agent" {
		t.Fatalf("got %+v", r)
	}
	if got := rec.Alerts(); len(got) != 1 {
		t.Fatalf("alerts %v", got)
	}

	done := make(chan *model.Request, 1)
	go func() {
		res, err := agent.Wait(ctx, r.ID)
		if err != nil {
			t.Error(err)
		}
		done <- res
	}()
	time.Sleep(50 * time.Millisecond)

	if _, err := agent.Answer(ctx, r.ID, model.Answer{OptionID: ptr("done")}); code(err) != "forbidden" {
		t.Fatalf("unregistered answer: %v", err)
	}
	if _, err := phone.Answer(ctx, r.ID, model.Answer{OptionID: ptr("cant")}); err != nil {
		t.Fatal(err)
	}
	select {
	case res := <-done:
		if res.State != model.StateAnswered || !res.Negative() || res.Response.DeviceName != "iPhone" {
			t.Fatalf("got %+v", res)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("wait did not return")
	}
	if _, err := cli.Answer(ctx, r.ID, model.Answer{OptionID: ptr("done")}); code(err) != "already_resolved" {
		t.Fatalf("second answer: %v", err)
	}
	if _, err := agent.Cancel(ctx, r.ID); code(err) != "already_resolved" {
		t.Fatalf("cancel after answer: %v", err)
	}
	if got := rec.Retracts(); len(got) != 1 {
		t.Fatalf("retracts %v", got)
	}
	list, err := agent.List(ctx, "answered", 10)
	if err != nil || len(list) != 1 {
		t.Fatalf("list %v %v", list, err)
	}
}

func ptr[T any](v T) *T { return &v }

func TestRejectsNonJSONBodies(t *testing.T) {
	srv, _ := server(t)
	res, err := http.Post(srv.URL+"/v1/requests", "text/plain", strings.NewReader(`{"kind":"action","title":"x"}`))
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != http.StatusUnsupportedMediaType {
		t.Fatalf("status %d", res.StatusCode)
	}
}

func TestEventsStream(t *testing.T) {
	srv, _ := server(t)
	ctx := context.Background()
	agent := as(srv, "agent")
	r, err := agent.Create(ctx, model.CreateRequest{Kind: model.KindAuthorize, Title: "x"})
	if err != nil {
		t.Fatal(err)
	}
	req, _ := http.NewRequest("GET", srv.URL+"/v1/requests/"+r.ID+"/events", nil)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	sc := bufio.NewScanner(res.Body)
	sc.Buffer(nil, 1<<20)
	states := make(chan string, 4)
	go func() {
		for sc.Scan() {
			if d, ok := strings.CutPrefix(sc.Text(), "data: "); ok {
				var r model.Request
				json.Unmarshal([]byte(d), &r)
				states <- string(r.State)
			}
		}
		close(states)
	}()
	if s := <-states; s != "pending" {
		t.Fatalf("first event %s", s)
	}
	// The creating node cancels; dev identity defaults to the agent header.
	if _, err := agent.Cancel(ctx, r.ID); err != nil {
		t.Fatal(err)
	}
	if s := <-states; s != "cancelled" {
		t.Fatalf("second event %s", s)
	}
	if _, ok := <-states; ok {
		t.Fatal("stream should close after resolution")
	}
}

func TestMacSocket(t *testing.T) {
	srv, _ := server(t)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	mac := as(srv, "mbp")
	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http") + "/v1/devices/ws"
	hdr := http.Header{"X-Sentinel-Node": {"mbp"}, "X-Sentinel-Host": {"mbp"}}

	if _, _, err := websocket.Dial(ctx, wsURL, &websocket.DialOptions{HTTPHeader: hdr}); err == nil {
		t.Fatal("unregistered mac connected")
	}
	if _, err := mac.Register(ctx, model.RegisterDevice{Kind: model.DeviceMac, Name: "MacBook"}); err != nil {
		t.Fatal(err)
	}
	ws, _, err := websocket.Dial(ctx, wsURL, &websocket.DialOptions{HTTPHeader: hdr})
	if err != nil {
		t.Fatal(err)
	}
	defer ws.CloseNow()
	read := func() model.HubFrame {
		_, b, err := ws.Read(ctx)
		if err != nil {
			t.Fatal(err)
		}
		var f model.HubFrame
		json.Unmarshal(b, &f)
		return f
	}
	if f := read(); f.Type != "sync" {
		t.Fatalf("first frame %+v", f)
	}
	p, _ := json.Marshal(map[string]any{"type": "presence", "idle_seconds": 1, "session_active": true})
	if err := ws.Write(ctx, websocket.MessageText, p); err != nil {
		t.Fatal(err)
	}
	time.Sleep(50 * time.Millisecond)
	r, err := as(srv, "agent").Create(ctx, model.CreateRequest{Kind: model.KindAuthorize, Title: "Ship it?"})
	if err != nil {
		t.Fatal(err)
	}
	if f := read(); f.Type != "deliver" || f.Request.ID != r.ID {
		t.Fatalf("got %+v", f)
	}
	if _, err := mac.Answer(ctx, r.ID, model.Answer{OptionID: ptr("approve")}); err != nil {
		t.Fatal(err)
	}
	if f := read(); f.Type != "retract" || f.Request.State != model.StateAnswered || f.Request.Response.DeviceName != "MacBook" {
		t.Fatalf("got %+v", f)
	}
}

func TestBrowserOriginRejected(t *testing.T) {
	srv, _ := server(t)
	ctx := context.Background()
	as(srv, "mbp").Register(ctx, model.RegisterDevice{Kind: model.DeviceMac})
	hdr := http.Header{"X-Sentinel-Node": {"mbp"}, "Origin": {"https://evil.example"}}
	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http") + "/v1/devices/ws"
	if _, _, err := websocket.Dial(ctx, wsURL, &websocket.DialOptions{HTTPHeader: hdr}); err == nil {
		t.Fatal("cross-origin socket accepted")
	}
}
