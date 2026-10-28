// Package identity resolves who is calling the hub. On the tailnet that is the
// caller's Tailscale node; in dev mode it comes from request headers.
package identity

import (
	"context"
	"fmt"
	"net/http"
	"strings"

	"tailscale.com/client/local"
)

type Identity struct {
	Node string // stable node id
	Host string // short machine name
	User string // tailnet login name
}

type Resolver interface {
	Resolve(r *http.Request) (Identity, error)
}

// Dev trusts the X-Sentinel-Node and X-Sentinel-Host headers. It is only
// used by --dev, which listens on loopback.
type Dev struct{}

func (Dev) Resolve(r *http.Request) (Identity, error) {
	id := Identity{
		Node: r.Header.Get("X-Sentinel-Node"),
		Host: r.Header.Get("X-Sentinel-Host"),
		User: "dev",
	}
	if id.Node == "" {
		id.Node = "dev-node"
	}
	if id.Host == "" {
		id.Host = "localhost"
	}
	return id, nil
}

// Tailscale asks the local tailscaled (or tsnet server) who owns the remote
// address.
type Tailscale struct {
	Client *local.Client
}

func (t Tailscale) Resolve(r *http.Request) (Identity, error) {
	return t.whois(r.Context(), r.RemoteAddr)
}

func (t Tailscale) whois(ctx context.Context, addr string) (Identity, error) {
	who, err := t.Client.WhoIs(ctx, addr)
	if err != nil {
		return Identity{}, fmt.Errorf("whois %s: %w", addr, err)
	}
	if who.Node == nil {
		return Identity{}, fmt.Errorf("whois %s: no node", addr)
	}
	host := who.Node.ComputedName
	if host == "" {
		host, _, _ = strings.Cut(who.Node.Name, ".")
	}
	id := Identity{Node: string(who.Node.StableID), Host: host}
	if who.UserProfile != nil {
		id.User = who.UserProfile.LoginName
	}
	return id, nil
}
