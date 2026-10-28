// Package push builds APNs payloads (docs/api.md) and sends them.
package push

import (
	"context"
	"fmt"
	"log/slog"
	"slices"
	"sync"

	"github.com/sideshow/apns2"
	"github.com/sideshow/apns2/token"

	"fdatoo.dev/sentinel/hub/internal/model"
)

// Pusher delivers alerts and retractions to iPhones.
type Pusher interface {
	Alert(ctx context.Context, dev model.Device, req *model.Request) error
	Retract(ctx context.Context, dev model.Device, requestID string) error
}

type optShape struct{ id, label string }

func matches(req *model.Request, kind model.Kind, allowText bool, shape ...optShape) bool {
	if req.Kind != kind || req.AllowText != allowText || len(req.Options) != len(shape) {
		return false
	}
	for i, o := range req.Options {
		if o.ID != shape[i].id || o.Label != shape[i].label {
			return false
		}
	}
	return true
}

// Category picks the notification category for a request, per the table in
// docs/api.md. The Swift clients implement the same rule.
func Category(req *model.Request) string {
	switch {
	case req.Sensitive:
		return "sentinel.open"
	case matches(req, model.KindAuthorize, false, optShape{"approve", "Approve"}, optShape{"deny", "Deny"}):
		return "sentinel.authorize.2"
	case matches(req, model.KindAuthorize, true, optShape{"allow", "Allow"}, optShape{"always", "Always allow"}, optShape{"deny", "Deny"}):
		return "sentinel.authorize.hook"
	case matches(req, model.KindAction, false, optShape{"done", "Done"}, optShape{"cant", "Can't"}):
		return "sentinel.action.2"
	}
	return "sentinel.open"
}

// AlertPayload is the JSON body of an escalation push.
func AlertPayload(req *model.Request) map[string]any {
	title := req.Agent.Label
	if title == "" {
		title = "agent"
	}
	body := req.Title
	if req.Sensitive {
		body = "needs you"
	} else if req.Agent.Host != "" {
		title += " on " + req.Agent.Host
	}
	aps := map[string]any{
		"alert":              map[string]string{"title": title, "body": body},
		"category":           Category(req),
		"thread-id":          "sentinel",
		"mutable-content":    1,
		"interruption-level": "time-sensitive",
		"sound":              "default",
	}
	if req.Urgency == model.UrgencyLow {
		aps["interruption-level"] = "passive"
		delete(aps, "sound")
	}
	return map[string]any{"aps": aps, "request_id": req.ID}
}

// RetractPayload is the JSON body of the background push that removes a
// delivered notification.
func RetractPayload(requestID string) map[string]any {
	return map[string]any{"aps": map[string]any{"content-available": 1}, "retract": requestID}
}

// APNs sends through Apple's push service with token (.p8) authentication.
type APNs struct {
	sandbox, production *apns2.Client
	topic               string
	log                 *slog.Logger
}

func NewAPNs(keyPath, keyID, teamID, topic string, log *slog.Logger) (*APNs, error) {
	key, err := token.AuthKeyFromFile(keyPath)
	if err != nil {
		return nil, fmt.Errorf("apns key: %w", err)
	}
	tok := &token.Token{AuthKey: key, KeyID: keyID, TeamID: teamID}
	return &APNs{
		sandbox:    apns2.NewTokenClient(tok).Development(),
		production: apns2.NewTokenClient(tok).Production(),
		topic:      topic,
		log:        log,
	}, nil
}

func (a *APNs) client(dev model.Device) *apns2.Client {
	if dev.APNsEnvironment == "production" {
		return a.production
	}
	return a.sandbox
}

func (a *APNs) send(ctx context.Context, dev model.Device, n *apns2.Notification) error {
	if dev.APNsToken == "" {
		return fmt.Errorf("device %s has no APNs token", dev.ID)
	}
	n.DeviceToken = dev.APNsToken
	n.Topic = a.topic
	res, err := a.client(dev).PushWithContext(ctx, n)
	if err != nil {
		return err
	}
	if !res.Sent() {
		return fmt.Errorf("apns %d %s", res.StatusCode, res.Reason)
	}
	return nil
}

func (a *APNs) Alert(ctx context.Context, dev model.Device, req *model.Request) error {
	return a.send(ctx, dev, &apns2.Notification{
		CollapseID: req.ID,
		Priority:   apns2.PriorityHigh,
		PushType:   apns2.PushTypeAlert,
		Expiration: req.ExpiresAt,
		Payload:    AlertPayload(req),
	})
}

func (a *APNs) Retract(ctx context.Context, dev model.Device, requestID string) error {
	return a.send(ctx, dev, &apns2.Notification{
		Priority: apns2.PriorityLow,
		PushType: apns2.PushTypeBackground,
		Payload:  RetractPayload(requestID),
	})
}

// Log records pushes instead of sending them, for dev mode or a hub without
// APNs credentials.
type Log struct{ L *slog.Logger }

func (l Log) Alert(_ context.Context, dev model.Device, req *model.Request) error {
	l.L.Info("push alert (not sent, APNs unconfigured)", "device", dev.Name, "request", req.ID, "category", Category(req))
	return nil
}

func (l Log) Retract(_ context.Context, dev model.Device, id string) error {
	l.L.Info("push retract (not sent, APNs unconfigured)", "device", dev.Name, "request", id)
	return nil
}

// Recorder captures pushes for tests.
type Recorder struct {
	mu       sync.Mutex
	alerts   []string
	retracts []string
}

func (r *Recorder) Alert(_ context.Context, _ model.Device, req *model.Request) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.alerts = append(r.alerts, req.ID)
	return nil
}

func (r *Recorder) Retract(_ context.Context, _ model.Device, id string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.retracts = append(r.retracts, id)
	return nil
}

// Alerts returns the request ids alerted so far, in order.
func (r *Recorder) Alerts() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return slices.Clone(r.alerts)
}

// Retracts returns the request ids retracted so far, in order.
func (r *Recorder) Retracts() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return slices.Clone(r.retracts)
}
