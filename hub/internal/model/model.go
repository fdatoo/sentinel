// Package model holds the wire types from docs/api.md, shared by the hub and the CLI.
package model

import "time"

type Kind string

const (
	KindDecision  Kind = "decision"
	KindAuthorize Kind = "authorize"
	KindAction    Kind = "action"
)

type Urgency string

const (
	UrgencyLow    Urgency = "low"
	UrgencyNormal Urgency = "normal"
	UrgencyHigh   Urgency = "high"
)

type State string

const (
	StatePending   State = "pending"
	StateAnswered  State = "answered"
	StateExpired   State = "expired"
	StateCancelled State = "cancelled"
)

type Stage string

const (
	StageGrace Stage = "grace"
	StageMac   Stage = "mac"
	StagePhone Stage = "phone"
	StageDone  Stage = "done"
)

type Style string

const (
	StyleDefault     Style = "default"
	StyleDestructive Style = "destructive"
)

type Option struct {
	ID       string `json:"id"`
	Label    string `json:"label"`
	Style    Style  `json:"style"`
	Negative bool   `json:"negative"`
}

type Agent struct {
	Host    string `json:"host"`
	Node    string `json:"node"`
	Label   string `json:"label"`
	Session string `json:"session,omitempty"`
}

type Response struct {
	OptionID   *string   `json:"option_id"`
	Text       *string   `json:"text"`
	DeviceID   string    `json:"device_id"`
	DeviceName string    `json:"device_name"`
	AnsweredAt time.Time `json:"answered_at"`
}

type Request struct {
	ID           string     `json:"id"`
	Agent        Agent      `json:"agent"`
	Kind         Kind       `json:"kind"`
	Title        string     `json:"title"`
	Body         string     `json:"body"`
	Options      []Option   `json:"options"`
	AllowText    bool       `json:"allow_text"`
	Urgency      Urgency    `json:"urgency"`
	Sensitive    bool       `json:"sensitive"`
	GraceSeconds int        `json:"grace_seconds"`
	CreatedAt    time.Time  `json:"created_at"`
	ExpiresAt    time.Time  `json:"expires_at"`
	CallbackURL  *string    `json:"callback_url"`
	State        State      `json:"state"`
	Stage        Stage      `json:"stage"`
	RoutedTo     *string    `json:"routed_to"`
	Response     *Response  `json:"response"`
	ResolvedAt   *time.Time `json:"resolved_at"`
}

// Option returns the option with the given id.
func (r *Request) Option(id string) (Option, bool) {
	for _, o := range r.Options {
		if o.ID == id {
			return o, true
		}
	}
	return Option{}, false
}

// Negative reports whether the answer is a deny or can't outcome.
func (r *Request) Negative() bool {
	return r.Response != nil && r.Response.NegativeFor(r)
}

// NegativeFor reports whether this response refuses req: a negative option,
// or a text-only reply to an authorize or action request, which is an
// instruction rather than an approval (the hook and apps read it the same way).
func (resp *Response) NegativeFor(req *Request) bool {
	if resp.OptionID == nil {
		return req.Kind != KindDecision
	}
	o, ok := req.Option(*resp.OptionID)
	return ok && o.Negative
}

type CreateRequest struct {
	Kind             Kind     `json:"kind"`
	Title            string   `json:"title"`
	Body             string   `json:"body,omitempty"`
	Options          []Option `json:"options,omitempty"`
	AllowText        bool     `json:"allow_text"`
	Urgency          Urgency  `json:"urgency,omitempty"`
	Sensitive        bool     `json:"sensitive"`
	GraceSeconds     int      `json:"grace_seconds"`
	ExpiresInSeconds int      `json:"expires_in_seconds,omitempty"`
	CallbackURL      *string  `json:"callback_url,omitempty"`
	Agent            struct {
		Label   string `json:"label"`
		Session string `json:"session,omitempty"`
	} `json:"agent"`
}

type Answer struct {
	OptionID *string `json:"option_id"`
	Text     *string `json:"text"`
}

type DeviceKind string

const (
	DeviceMac    DeviceKind = "mac"
	DeviceIPhone DeviceKind = "iphone"
	DeviceCLI    DeviceKind = "cli"
)

type Device struct {
	ID              string     `json:"id"`
	Kind            DeviceKind `json:"kind"`
	Name            string     `json:"name"`
	Node            string     `json:"node"`
	APNsToken       string     `json:"-"`
	APNsEnvironment string     `json:"-"`
	CreatedAt       time.Time  `json:"created_at"`
	LastSeenAt      time.Time  `json:"last_seen_at"`
}

type RegisterDevice struct {
	Kind            DeviceKind `json:"kind"`
	Name            string     `json:"name"`
	APNsToken       string     `json:"apns_token,omitempty"`
	APNsEnvironment string     `json:"apns_environment,omitempty"`
}

type Presence struct {
	IdleSeconds   float64 `json:"idle_seconds"`
	Locked        bool    `json:"locked"`
	Asleep        bool    `json:"asleep"`
	DisplayAsleep bool    `json:"display_asleep"`
	SessionActive bool    `json:"session_active"`
}

// HubFrame is a hub-to-Mac WebSocket message: sync, deliver or retract.
type HubFrame struct {
	Type     string     `json:"type"`
	Request  *Request   `json:"request,omitempty"`
	Requests []*Request `json:"requests,omitempty"`
}

// MacFrame is a Mac-to-hub WebSocket message. Only "presence" is defined.
type MacFrame struct {
	Type string `json:"type"`
	Presence
}

type ErrorBody struct {
	Error struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
}
