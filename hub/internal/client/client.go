// Package client talks to the hub for the sentinel CLI.
package client

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"fdatoo.dev/sentinel/hub/internal/model"
)

// Config is read from ~/.config/sentinel/config.json; SENTINEL_URL, and in dev
// mode SENTINEL_NODE and SENTINEL_HOST, override it.
type Config struct {
	URL string `json:"url"`
	// Node and Host become the dev-mode identity headers. Ignored on the tailnet.
	Node string `json:"node,omitempty"`
	Host string `json:"host,omitempty"`
}

func ConfigPath() string {
	dir := os.Getenv("XDG_CONFIG_HOME")
	if dir == "" {
		home, _ := os.UserHomeDir()
		dir = filepath.Join(home, ".config")
	}
	return filepath.Join(dir, "sentinel", "config.json")
}

func LoadConfig() (Config, error) {
	var c Config
	b, err := os.ReadFile(ConfigPath())
	switch {
	case err == nil:
		if err := json.Unmarshal(b, &c); err != nil {
			return c, fmt.Errorf("%s: %w", ConfigPath(), err)
		}
	case !errors.Is(err, os.ErrNotExist):
		return c, err
	}
	if v := os.Getenv("SENTINEL_URL"); v != "" {
		c.URL = v
	}
	if v := os.Getenv("SENTINEL_NODE"); v != "" {
		c.Node = v
	}
	if v := os.Getenv("SENTINEL_HOST"); v != "" {
		c.Host = v
	}
	if c.URL == "" {
		return c, fmt.Errorf("no hub configured: set SENTINEL_URL or write %s", ConfigPath())
	}
	c.URL = strings.TrimRight(c.URL, "/")
	return c, nil
}

type Client struct {
	cfg  Config
	http *http.Client
}

func New(cfg Config) *Client {
	return &Client{cfg: cfg, http: &http.Client{}}
}

// APIError is a non-2xx response from the hub.
type APIError struct {
	Status  int
	Code    string
	Message string
}

func (e *APIError) Error() string { return fmt.Sprintf("%s: %s", e.Code, e.Message) }

// Unreachable wraps transport failures, as opposed to the hub saying no.
type Unreachable struct{ Err error }

func (e *Unreachable) Error() string { return "hub unreachable: " + e.Err.Error() }
func (e *Unreachable) Unwrap() error { return e.Err }

func (c *Client) do(ctx context.Context, method, path string, in, out any) error {
	var body io.Reader
	if in != nil {
		b, err := json.Marshal(in)
		if err != nil {
			return err
		}
		body = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.cfg.URL+path, body)
	if err != nil {
		return err
	}
	if in != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if c.cfg.Node != "" {
		req.Header.Set("X-Sentinel-Node", c.cfg.Node)
	}
	if c.cfg.Host != "" {
		req.Header.Set("X-Sentinel-Host", c.cfg.Host)
	}
	res, err := c.http.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return &Unreachable{err}
	}
	defer res.Body.Close()
	b, err := io.ReadAll(res.Body)
	if err != nil {
		return &Unreachable{err}
	}
	if res.StatusCode >= 300 {
		var e model.ErrorBody
		if json.Unmarshal(b, &e) == nil && e.Error.Code != "" {
			return &APIError{res.StatusCode, e.Error.Code, e.Error.Message}
		}
		return &APIError{res.StatusCode, "http", strings.TrimSpace(string(b))}
	}
	if out != nil {
		return json.Unmarshal(b, out)
	}
	return nil
}

func (c *Client) Create(ctx context.Context, in model.CreateRequest) (*model.Request, error) {
	var r model.Request
	return &r, c.do(ctx, http.MethodPost, "/v1/requests", in, &r)
}

func (c *Client) Get(ctx context.Context, id string) (*model.Request, error) {
	var r model.Request
	return &r, c.do(ctx, http.MethodGet, "/v1/requests/"+url.PathEscape(id), nil, &r)
}

// Wait long-polls until the request leaves pending or ctx ends. Transport
// errors are retried with backoff, so a hub restart doesn't end the wait.
func (c *Client) Wait(ctx context.Context, id string) (*model.Request, error) {
	backoff := time.Second
	for {
		var r model.Request
		err := c.do(ctx, http.MethodGet, "/v1/requests/"+url.PathEscape(id)+"?wait=300", nil, &r)
		var un *Unreachable
		switch {
		case err == nil:
			if r.State != model.StatePending {
				return &r, nil
			}
			backoff = time.Second
			continue
		case errors.As(err, &un):
			select {
			case <-time.After(backoff):
			case <-ctx.Done():
				return nil, ctx.Err()
			}
			backoff = min(backoff*2, 30*time.Second)
		default:
			return nil, err
		}
	}
}

func (c *Client) List(ctx context.Context, state string, limit int) ([]*model.Request, error) {
	q := url.Values{}
	if state != "" {
		q.Set("state", state)
	}
	if limit > 0 {
		q.Set("limit", fmt.Sprint(limit))
	}
	var out struct {
		Requests []*model.Request `json:"requests"`
	}
	return out.Requests, c.do(ctx, http.MethodGet, "/v1/requests?"+q.Encode(), nil, &out)
}

func (c *Client) Cancel(ctx context.Context, id string) (*model.Request, error) {
	var r model.Request
	return &r, c.do(ctx, http.MethodDelete, "/v1/requests/"+url.PathEscape(id), nil, &r)
}

func (c *Client) Answer(ctx context.Context, id string, a model.Answer) (*model.Request, error) {
	var r model.Request
	return &r, c.do(ctx, http.MethodPost, "/v1/requests/"+url.PathEscape(id)+"/response", a, &r)
}

func (c *Client) Register(ctx context.Context, in model.RegisterDevice) (model.Device, error) {
	var d model.Device
	return d, c.do(ctx, http.MethodPost, "/v1/devices", in, &d)
}

func (c *Client) Devices(ctx context.Context) ([]model.Device, error) {
	var out struct {
		Devices []model.Device `json:"devices"`
	}
	return out.Devices, c.do(ctx, http.MethodGet, "/v1/devices", nil, &out)
}
