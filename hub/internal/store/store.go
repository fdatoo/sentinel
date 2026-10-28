// Package store persists requests, their routing state and devices in SQLite.
package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	_ "modernc.org/sqlite"

	"fdatoo.dev/sentinel/hub/internal/model"
)

var ErrNotFound = errors.New("not found")

// Routing is the hub's private per-request routing state. It is persisted so
// that escalation deadlines survive a restart.
type Routing struct {
	EscalateAt *time.Time `json:"escalate_at,omitempty"`
	RealertAt  *time.Time `json:"realert_at,omitempty"`
	Pushed     bool       `json:"pushed,omitempty"`
	// Macs that have been shown this request, so they can be told to retract it.
	DeliveredTo []string `json:"delivered_to,omitempty"`
}

type Record struct {
	Request *model.Request
	Routing Routing
}

type Store struct {
	db *sql.DB
}

const schema = `
CREATE TABLE IF NOT EXISTS requests (
	id         TEXT PRIMARY KEY,
	state      TEXT NOT NULL,
	created_at TEXT NOT NULL,
	request    TEXT NOT NULL,
	routing    TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS requests_state ON requests(state, created_at);
CREATE TABLE IF NOT EXISTS devices (
	id           TEXT PRIMARY KEY,
	node         TEXT NOT NULL UNIQUE,
	kind         TEXT NOT NULL,
	name         TEXT NOT NULL,
	apns_token   TEXT NOT NULL DEFAULT '',
	apns_env     TEXT NOT NULL DEFAULT '',
	created_at   TEXT NOT NULL,
	last_seen_at TEXT NOT NULL
);
`

func Open(path string) (*Store, error) {
	db, err := sql.Open("sqlite", "file:"+path+"?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)&_pragma=foreign_keys(1)")
	if err != nil {
		return nil, err
	}
	// A single connection avoids SQLite write contention; the hub serializes
	// mutations anyway.
	db.SetMaxOpenConns(1)
	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, fmt.Errorf("migrate: %w", err)
	}
	return &Store{db: db}, nil
}

func (s *Store) Close() error { return s.db.Close() }

func (s *Store) PutRequest(ctx context.Context, rec Record) error {
	req, err := json.Marshal(rec.Request)
	if err != nil {
		return err
	}
	routing, err := json.Marshal(rec.Routing)
	if err != nil {
		return err
	}
	_, err = s.db.ExecContext(ctx, `
		INSERT INTO requests (id, state, created_at, request, routing) VALUES (?, ?, ?, ?, ?)
		ON CONFLICT(id) DO UPDATE SET state = excluded.state, request = excluded.request, routing = excluded.routing`,
		rec.Request.ID, rec.Request.State, rec.Request.CreatedAt.UTC().Format(time.RFC3339Nano), req, routing)
	return err
}

func scanRecord(row interface{ Scan(...any) error }) (Record, error) {
	var req, routing string
	if err := row.Scan(&req, &routing); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return Record{}, ErrNotFound
		}
		return Record{}, err
	}
	rec := Record{Request: &model.Request{}}
	if err := json.Unmarshal([]byte(req), rec.Request); err != nil {
		return Record{}, err
	}
	if err := json.Unmarshal([]byte(routing), &rec.Routing); err != nil {
		return Record{}, err
	}
	return rec, nil
}

func (s *Store) GetRequest(ctx context.Context, id string) (Record, error) {
	return scanRecord(s.db.QueryRowContext(ctx, `SELECT request, routing FROM requests WHERE id = ?`, id))
}

// ListRequests returns requests newest first. An empty state matches all.
func (s *Store) ListRequests(ctx context.Context, state model.State, limit int) ([]Record, error) {
	q := `SELECT request, routing FROM requests`
	var args []any
	if state != "" {
		q += ` WHERE state = ?`
		args = append(args, state)
	}
	q += ` ORDER BY created_at DESC, id DESC LIMIT ?`
	args = append(args, limit)
	rows, err := s.db.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Record
	for rows.Next() {
		rec, err := scanRecord(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, rec)
	}
	return out, rows.Err()
}

const deviceCols = `id, node, kind, name, apns_token, apns_env, created_at, last_seen_at`

func scanDevice(row interface{ Scan(...any) error }) (model.Device, error) {
	var d model.Device
	var created, seen string
	if err := row.Scan(&d.ID, &d.Node, &d.Kind, &d.Name, &d.APNsToken, &d.APNsEnvironment, &created, &seen); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return d, ErrNotFound
		}
		return d, err
	}
	d.CreatedAt, _ = time.Parse(time.RFC3339Nano, created)
	d.LastSeenAt, _ = time.Parse(time.RFC3339Nano, seen)
	return d, nil
}

func (s *Store) PutDevice(ctx context.Context, d model.Device) error {
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO devices (`+deviceCols+`) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(node) DO UPDATE SET kind = excluded.kind, name = excluded.name,
			apns_token = excluded.apns_token, apns_env = excluded.apns_env, last_seen_at = excluded.last_seen_at`,
		d.ID, d.Node, d.Kind, d.Name, d.APNsToken, d.APNsEnvironment,
		d.CreatedAt.UTC().Format(time.RFC3339Nano), d.LastSeenAt.UTC().Format(time.RFC3339Nano))
	return err
}

func (s *Store) DeviceByNode(ctx context.Context, node string) (model.Device, error) {
	return scanDevice(s.db.QueryRowContext(ctx, `SELECT `+deviceCols+` FROM devices WHERE node = ?`, node))
}

func (s *Store) Devices(ctx context.Context) ([]model.Device, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT `+deviceCols+` FROM devices ORDER BY created_at`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []model.Device
	for rows.Next() {
		d, err := scanDevice(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
}
