// Command sentinel asks a human for a decision, an authorization or an action
// through the Sentinel hub, and doubles as a Claude Code PermissionRequest hook.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"text/tabwriter"
	"time"

	"fdatoo.dev/sentinel/hub/internal/client"
	"fdatoo.dev/sentinel/hub/internal/hook"
	"fdatoo.dev/sentinel/hub/internal/model"
)

// Exit codes from docs/spec.md.
const (
	exitPositive  = 0
	exitNegative  = 1
	exitExpired   = 2
	exitCancelled = 3
	exitError     = 4
	exitPending   = 5
)

const usage = `usage: sentinel <command> [flags]

  ask       create a request (--wait to block for the answer)
  wait      block until a request resolves
  get       print a request
  list      list requests
  cancel    cancel a request this machine created
  answer    answer a request from the terminal
  register  register this machine as a CLI device so it can answer
  devices   list registered devices
  hook      Claude Code PermissionRequest hook (reads stdin)
  hook-done Claude Code PostToolUse, PostToolUseFailure, UserPromptSubmit and Stop
            hook: withdraws prompts that were answered outside Sentinel

Exit codes: 0 answered positively, 1 denied or can't, 2 expired,
3 cancelled, 4 error or hub unreachable, 5 still pending after --timeout.
`

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(args []string) int {
	if len(args) == 0 || args[0] == "-h" || args[0] == "--help" || args[0] == "help" {
		fmt.Fprint(os.Stderr, usage)
		if len(args) == 0 {
			return exitError
		}
		return 0
	}
	cmd, args := args[0], args[1:]
	if cmd == "hook" {
		return runHook(os.Stdin, os.Stdout)
	}
	if cmd == "hook-done" {
		return runHookDone(os.Stdin)
	}
	cmds := map[string]func(*client.Client, []string) (int, error){
		"ask": cmdAsk, "wait": cmdWait, "get": cmdGet, "list": cmdList, "cancel": cmdCancel,
		"answer": cmdAnswer, "register": cmdRegister, "devices": cmdDevices,
	}
	f, ok := cmds[cmd]
	if !ok {
		fmt.Fprintf(os.Stderr, "sentinel: unknown command %q\n\n%s", cmd, usage)
		return exitError
	}
	cfg, err := client.LoadConfig()
	if err != nil {
		fmt.Fprintln(os.Stderr, "sentinel:", err)
		return exitError
	}
	code, err := f(client.New(cfg), args)
	if err != nil {
		if !errors.Is(err, flag.ErrHelp) {
			fmt.Fprintln(os.Stderr, "sentinel:", err)
		}
		return exitError
	}
	return code
}

// parse lets flags follow positional arguments, as in "wait <id> --timeout 5m".
func parse(fs *flag.FlagSet, args []string, positional int) ([]string, error) {
	fs.SetOutput(os.Stderr)
	var pos []string
	for {
		if err := fs.Parse(args); err != nil {
			return nil, err
		}
		args = fs.Args()
		if len(args) == 0 {
			break
		}
		pos = append(pos, args[0])
		args = args[1:]
	}
	if len(pos) != positional {
		fs.Usage()
		return nil, fmt.Errorf("%s takes %d argument(s)", fs.Name(), positional)
	}
	return pos, nil
}

type options []model.Option

func (o *options) String() string { return "" }
func (o *options) Set(v string) error {
	id, label, ok := strings.Cut(v, "=")
	if !ok {
		label = id
	}
	if id == "" {
		return errors.New("option needs an id")
	}
	*o = append(*o, model.Option{ID: id, Label: label})
	return nil
}

type stringList []string

func (s *stringList) String() string     { return strings.Join(*s, ",") }
func (s *stringList) Set(v string) error { *s = append(*s, v); return nil }

func printJSON(v any) {
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	_ = enc.Encode(v)
}

func exitFor(r *model.Request) int {
	switch r.State {
	case model.StateAnswered:
		if r.Negative() {
			return exitNegative
		}
		return exitPositive
	case model.StateExpired:
		return exitExpired
	case model.StateCancelled:
		return exitCancelled
	}
	return exitPending
}

func signalContext(timeout time.Duration) (context.Context, context.CancelFunc) {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	if timeout <= 0 {
		return ctx, stop
	}
	tctx, cancel := context.WithTimeout(ctx, timeout)
	return tctx, func() { cancel(); stop() }
}

// condition is an --until check: a shell command that exits 0 once the thing
// being waited for has happened without me answering, such as a PR review.
type condition struct {
	cmd   string
	every time.Duration
}

func (cond condition) met(ctx context.Context) bool {
	cctx, cancel := context.WithTimeout(ctx, max(cond.every, 30*time.Second))
	defer cancel()
	c := exec.CommandContext(cctx, "/bin/sh", "-c", cond.cmd)
	c.Stdout, c.Stderr = io.Discard, os.Stderr
	return c.Run() == nil
}

// wait blocks for the outcome. On timeout it prints the still-pending request.
// With an --until check, the check passing withdraws the request and counts as
// a positive outcome.
func wait(c *client.Client, id string, timeout time.Duration, cond condition) (int, error) {
	ctx, cancel := signalContext(timeout)
	type result struct {
		r   *model.Request
		err error
	}
	done := make(chan result, 1)
	wctx, stopWait := context.WithCancel(ctx)
	go func() {
		r, err := c.Wait(wctx, id)
		done <- result{r, err}
	}()
	var tick <-chan time.Time
	if cond.cmd != "" {
		if cond.every <= 0 {
			stopWait()
			cancel()
			return exitError, errors.New("--every must be positive")
		}
		t := time.NewTicker(cond.every)
		defer t.Stop()
		tick = t.C
	}
	var res result
	metCond := false
loop:
	for {
		select {
		case res = <-done:
			break loop
		case <-tick:
			if cond.met(ctx) {
				metCond = true
				stopWait()
				<-done
				break loop
			}
		}
	}
	stopWait()
	// Release the signal handlers before the final read, so ^C still works.
	cancel()
	r, err := res.r, res.err
	if metCond {
		fmt.Fprintln(os.Stderr, "sentinel: --until check passed, withdrawing the request")
		cctx, ccancel := context.WithTimeout(context.Background(), 10*time.Second)
		r, err = c.Cancel(cctx, id)
		ccancel()
		var apiErr *client.APIError
		if errors.As(err, &apiErr) {
			// Answered or expired in the meantime: report that instead.
			gctx, gcancel := context.WithTimeout(context.Background(), 10*time.Second)
			r, err = c.Get(gctx, id)
			gcancel()
			if err == nil && r.State != model.StateCancelled {
				printJSON(r)
				return exitFor(r), nil
			}
		}
		if err != nil {
			return exitError, err
		}
		printJSON(r)
		return exitPositive, nil
	}
	if errors.Is(err, context.DeadlineExceeded) {
		gctx, gcancel := context.WithTimeout(context.Background(), 10*time.Second)
		r, err = c.Get(gctx, id)
		gcancel()
	}
	if err != nil {
		return exitError, err
	}
	printJSON(r)
	return exitFor(r), nil
}

func cmdAsk(c *client.Client, args []string) (int, error) {
	fs := flag.NewFlagSet("ask", flag.ContinueOnError)
	var (
		in        model.CreateRequest
		opts      options
		negatives stringList
		destruct  stringList
		kind      = fs.String("kind", "decision", "decision, authorize or action")
		title     = fs.String("title", "", "one-line question (required)")
		body      = fs.String("body", "", "markdown details")
		bodyFile  = fs.String("body-file", "", "read the body from a file, or - for stdin")
		urgency   = fs.String("urgency", "normal", "low, normal or high")
		expires   = fs.Duration("expires", 24*time.Hour, "give up after this long")
		callback  = fs.String("callback", "", "URL to POST the resolved request to")
		doWait    = fs.Bool("wait", false, "block until resolved and exit with the outcome")
		timeout   = fs.Duration("timeout", 0, "with --wait, stop waiting after this long (exit 5)")
		cond      condition
	)
	fs.StringVar(&cond.cmd, "until", "", "with --wait, shell check that exits 0 once the request is moot; withdraws it and exits 0")
	fs.DurationVar(&cond.every, "every", time.Minute, "how often to run the --until check")
	fs.Var(&opts, "option", "an answer as id=Label (repeatable)")
	fs.Var(&negatives, "negative", "option id that counts as a no, for the exit code (repeatable)")
	fs.Var(&destruct, "destructive", "option id to style as destructive (repeatable)")
	fs.BoolVar(&in.AllowText, "text", false, "allow a free-text reply")
	fs.BoolVar(&in.Sensitive, "sensitive", false, "keep details off the lock screen")
	fs.IntVar(&in.GraceSeconds, "grace", 0, "seconds to wait before notifying, so a quick cancel is silent")
	fs.StringVar(&in.Agent.Label, "label", envOr("SENTINEL_LABEL", "agent"), "who is asking")
	fs.StringVar(&in.Agent.Session, "session", os.Getenv("SENTINEL_SESSION"), "agent session id")
	if _, err := parse(fs, args, 0); err != nil {
		return exitError, err
	}
	if *title == "" {
		return exitError, errors.New("--title is required")
	}
	if cond.cmd != "" && !*doWait {
		return exitError, errors.New("--until needs --wait")
	}
	in.Kind, in.Title, in.Body, in.Urgency = model.Kind(*kind), *title, *body, model.Urgency(*urgency)
	if *bodyFile != "" {
		var b []byte
		var err error
		if *bodyFile == "-" {
			b, err = io.ReadAll(os.Stdin)
		} else {
			b, err = os.ReadFile(*bodyFile)
		}
		if err != nil {
			return exitError, err
		}
		in.Body = string(b)
	}
	for i := range opts {
		for _, n := range negatives {
			opts[i].Negative = opts[i].Negative || n == opts[i].ID
		}
		for _, d := range destruct {
			if d == opts[i].ID {
				opts[i].Style = model.StyleDestructive
			}
		}
	}
	in.Options = opts
	in.ExpiresInSeconds = int(expires.Seconds())
	if *callback != "" {
		in.CallbackURL = callback
	}
	r, err := c.Create(context.Background(), in)
	if err != nil {
		return exitError, err
	}
	if !*doWait {
		printJSON(r)
		return 0, nil
	}
	fmt.Fprintf(os.Stderr, "sentinel: waiting on %s\n", r.ID)
	return wait(c, r.ID, *timeout, cond)
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func cmdWait(c *client.Client, args []string) (int, error) {
	fs := flag.NewFlagSet("wait", flag.ContinueOnError)
	timeout := fs.Duration("timeout", 0, "stop waiting after this long (exit 5)")
	var cond condition
	fs.StringVar(&cond.cmd, "until", "", "shell check that exits 0 once the request is moot; withdraws it and exits 0")
	fs.DurationVar(&cond.every, "every", time.Minute, "how often to run the --until check")
	pos, err := parse(fs, args, 1)
	if err != nil {
		return exitError, err
	}
	return wait(c, pos[0], *timeout, cond)
}

func cmdGet(c *client.Client, args []string) (int, error) {
	pos, err := parse(flag.NewFlagSet("get", flag.ContinueOnError), args, 1)
	if err != nil {
		return exitError, err
	}
	r, err := c.Get(context.Background(), pos[0])
	if err != nil {
		return exitError, err
	}
	printJSON(r)
	return exitFor(r), nil
}

func cmdList(c *client.Client, args []string) (int, error) {
	fs := flag.NewFlagSet("list", flag.ContinueOnError)
	state := fs.String("state", "pending", "pending, answered, expired, cancelled, or all")
	limit := fs.Int("limit", 50, "maximum requests")
	asJSON := fs.Bool("json", false, "print JSON")
	if _, err := parse(fs, args, 0); err != nil {
		return exitError, err
	}
	if *state == "all" {
		*state = ""
	}
	reqs, err := c.List(context.Background(), *state, *limit)
	if err != nil {
		return exitError, err
	}
	if *asJSON {
		printJSON(map[string]any{"requests": reqs})
		return 0, nil
	}
	tw := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintln(tw, "ID\tSTATE\tSTAGE\tFROM\tTITLE\tOPTIONS")
	for _, r := range reqs {
		ids := make([]string, len(r.Options))
		for i, o := range r.Options {
			ids[i] = o.ID
		}
		fmt.Fprintf(tw, "%s\t%s\t%s\t%s@%s\t%s\t%s\n", r.ID, r.State, r.Stage, r.Agent.Label, r.Agent.Host,
			strings.ReplaceAll(r.Title, "\t", " "), strings.Join(ids, ","))
	}
	return 0, tw.Flush()
}

func cmdCancel(c *client.Client, args []string) (int, error) {
	pos, err := parse(flag.NewFlagSet("cancel", flag.ContinueOnError), args, 1)
	if err != nil {
		return exitError, err
	}
	r, err := c.Cancel(context.Background(), pos[0])
	if err != nil {
		return exitError, err
	}
	printJSON(r)
	return 0, nil
}

func cmdAnswer(c *client.Client, args []string) (int, error) {
	fs := flag.NewFlagSet("answer", flag.ContinueOnError)
	text := fs.String("text", "", "free-text reply")
	fs.Usage = func() { fmt.Fprintln(os.Stderr, "usage: sentinel answer <id> [option] [--text reply]") }
	if err := fs.Parse(args); err != nil {
		return exitError, err
	}
	var pos []string
	rest := fs.Args()
	for len(rest) > 0 {
		pos, rest = append(pos, rest[0]), rest[1:]
		if err := fs.Parse(rest); err != nil {
			return exitError, err
		}
		rest = fs.Args()
	}
	if len(pos) < 1 || len(pos) > 2 || (len(pos) == 1 && *text == "") {
		fs.Usage()
		return exitError, errors.New("need a request id and an option or --text")
	}
	var a model.Answer
	if len(pos) == 2 {
		a.OptionID = &pos[1]
	}
	if *text != "" {
		a.Text = text
	}
	r, err := c.Answer(context.Background(), pos[0], a)
	if err != nil {
		return exitError, err
	}
	printJSON(r)
	return 0, nil
}

func cmdRegister(c *client.Client, args []string) (int, error) {
	fs := flag.NewFlagSet("register", flag.ContinueOnError)
	host, _ := os.Hostname()
	name := fs.String("name", host+" (CLI)", "device name shown as the answerer")
	if _, err := parse(fs, args, 0); err != nil {
		return exitError, err
	}
	d, err := c.Register(context.Background(), model.RegisterDevice{Kind: model.DeviceCLI, Name: *name})
	if err != nil {
		return exitError, err
	}
	printJSON(d)
	return 0, nil
}

func cmdDevices(c *client.Client, args []string) (int, error) {
	if _, err := parse(flag.NewFlagSet("devices", flag.ContinueOnError), args, 0); err != nil {
		return exitError, err
	}
	devs, err := c.Devices(context.Background())
	if err != nil {
		return exitError, err
	}
	tw := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintln(tw, "ID\tKIND\tNAME\tLAST SEEN")
	for _, d := range devs {
		fmt.Fprintf(tw, "%s\t%s\t%s\t%s\n", d.ID, d.Kind, d.Name, d.LastSeenAt.Local().Format(time.DateTime))
	}
	return 0, tw.Flush()
}

// runHook never fails loudly: any problem leaves the terminal prompt in charge.
func runHook(stdin io.Reader, stdout io.Writer) int {
	logf := func(format string, a ...any) { fmt.Fprintf(os.Stderr, "sentinel hook: "+format+"\n", a...) }
	var in hook.Input
	if err := json.NewDecoder(stdin).Decode(&in); err != nil {
		logf("bad input: %v", err)
		return 0
	}
	cfg, err := client.LoadConfig()
	if err != nil {
		logf("%v", err)
		return 0
	}
	c := client.New(cfg)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	defer stop()
	// Claude Code answered some other way (terminal prompt, app) and signals us,
	// or the session died and we were reparented: either way, stop waiting.
	ppid := os.Getppid()
	go func() {
		for t := time.NewTicker(2 * time.Second); ; {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				if os.Getppid() != ppid {
					stop()
					return
				}
			}
		}
	}()

	var ids []string
	withdraw := func() {
		dctx, dcancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer dcancel()
		for _, id := range ids {
			// Already answered or expired is fine; only log real failures.
			var apiErr *client.APIError
			if _, cerr := c.Cancel(dctx, id); cerr != nil && !errors.As(cerr, &apiErr) {
				logf("cancel %s: %v", id, cerr)
			}
		}
	}

	for _, cr := range hook.Requests(in) {
		cctx, cancel := context.WithTimeout(ctx, 10*time.Second)
		r, err := c.Create(cctx, cr)
		cancel()
		if err != nil {
			logf("%v", err)
			withdraw()
			return 0
		}
		ids = append(ids, r.ID)
	}

	wctx, cancel := context.WithTimeout(ctx, (hook.ExpiresSeconds+60)*time.Second)
	defer cancel()
	results := make([]*model.Request, len(ids))
	errs := make([]error, len(ids))
	var wg sync.WaitGroup
	for i, id := range ids {
		wg.Add(1)
		go func() {
			defer wg.Done()
			results[i], errs[i] = c.Wait(wctx, id)
			if errs[i] != nil {
				cancel() // stop waiting on the sibling questions too
			}
		}()
	}
	wg.Wait()
	if err := errors.Join(errs...); err != nil {
		// Answered elsewhere (signal) or gave up: withdraw what is still open.
		withdraw()
		return 0
	}
	if out := hook.Output(in, results); out != nil {
		stdout.Write(append(out, '\n'))
	}
	return 0
}

// doneInput is the part of a PostToolUse, PostToolUseFailure, UserPromptSubmit
// or Stop payload that hook-done needs.
type doneInput struct {
	hook.Input
}

// runHookDone withdraws this session's pending Claude Code requests once
// Claude Code has moved past them. Claude Code does not reliably signal a
// PermissionRequest hook that was answered in the terminal or the desktop app,
// so the next lifecycle event does the cleanup. A finished tool call withdraws
// only its own requests; a new prompt or the end of a turn withdraws them all.
func runHookDone(stdin io.Reader) int {
	var in doneInput
	if json.NewDecoder(stdin).Decode(&in) != nil || in.SessionID == "" {
		return 0
	}
	cfg, err := client.LoadConfig()
	if err != nil {
		return 0
	}
	c := client.New(cfg)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	var titles map[string]bool
	switch in.HookEventName {
	case "PostToolUse", "PostToolUseFailure":
		titles = map[string]bool{}
		for _, t := range hook.Titles(in.Input) {
			titles[t] = true
		}
	}
	reqs, err := c.List(ctx, string(model.StatePending), 200)
	if err != nil {
		return 0
	}
	for _, r := range reqs {
		if r.Agent.Label != "claude-code" || r.Agent.Session != in.SessionID {
			continue
		}
		if titles != nil && !titles[r.Title] {
			continue
		}
		_, _ = c.Cancel(ctx, r.ID)
	}
	return 0
}
