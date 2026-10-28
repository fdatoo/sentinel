package hub

import (
	"sort"
	"sync"
	"time"
)

type Timer interface{ Stop() bool }

// Clock lets tests drive routing deadlines without sleeping.
type Clock interface {
	Now() time.Time
	AfterFunc(d time.Duration, f func()) Timer
}

type realClock struct{}

func (realClock) Now() time.Time                            { return time.Now().UTC() }
func (realClock) AfterFunc(d time.Duration, f func()) Timer { return time.AfterFunc(d, f) }

// RealClock is the wall clock.
var RealClock Clock = realClock{}

// FakeClock fires timers synchronously from Advance.
type FakeClock struct {
	mu     sync.Mutex
	now    time.Time
	timers []*fakeTimer
}

type fakeTimer struct {
	c       *FakeClock
	at      time.Time
	f       func()
	stopped bool
}

func NewFakeClock(start time.Time) *FakeClock { return &FakeClock{now: start.UTC()} }

func (c *FakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *FakeClock) AfterFunc(d time.Duration, f func()) Timer {
	c.mu.Lock()
	defer c.mu.Unlock()
	t := &fakeTimer{c: c, at: c.now.Add(d), f: f}
	c.timers = append(c.timers, t)
	return t
}

func (t *fakeTimer) Stop() bool {
	t.c.mu.Lock()
	defer t.c.mu.Unlock()
	was := !t.stopped
	t.stopped = true
	return was
}

// Advance moves time forward, firing due timers in deadline order. Timers
// scheduled by a firing callback also fire if they fall within the window.
func (c *FakeClock) Advance(d time.Duration) {
	c.mu.Lock()
	end := c.now.Add(d)
	c.mu.Unlock()
	for {
		c.mu.Lock()
		sort.SliceStable(c.timers, func(i, j int) bool { return c.timers[i].at.Before(c.timers[j].at) })
		var next *fakeTimer
		for i, t := range c.timers {
			if t.stopped {
				continue
			}
			if !t.at.After(end) {
				next = t
				c.timers = append(c.timers[:i], c.timers[i+1:]...)
			}
			break
		}
		if next == nil {
			c.now = end
			live := c.timers[:0]
			for _, t := range c.timers {
				if !t.stopped {
					live = append(live, t)
				}
			}
			c.timers = live
			c.mu.Unlock()
			return
		}
		next.stopped = true
		if next.at.After(c.now) {
			c.now = next.at
		}
		c.mu.Unlock()
		next.f()
	}
}
