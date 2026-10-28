// Package hook turns a Claude Code PermissionRequest hook payload into a
// Sentinel request, and a resolved request back into the hook's decision
// (docs/spec.md, ADR-0003).
package hook

import (
	"bytes"
	"encoding/json"
	"fmt"
	"path/filepath"
	"strconv"
	"strings"

	"fdatoo.dev/sentinel/hub/internal/model"
)

type Input struct {
	SessionID             string            `json:"session_id"`
	Cwd                   string            `json:"cwd"`
	HookEventName         string            `json:"hook_event_name"`
	ToolName              string            `json:"tool_name"`
	ToolInput             json.RawMessage   `json:"tool_input"`
	PermissionSuggestions []json.RawMessage `json:"permission_suggestions"`
}

const (
	ExpiresSeconds = 3600
	maxTitle       = 200
)

func str(m map[string]any, key string) string {
	s, _ := m[key].(string)
	return s
}

func oneLine(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = strings.TrimSpace(s[:i]) + " …"
	}
	return s
}

func truncate(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n-1]) + "…"
}

func relPath(cwd, p string) string {
	if cwd != "" && filepath.IsAbs(p) {
		if rel, err := filepath.Rel(cwd, p); err == nil && !strings.HasPrefix(rel, "..") {
			return rel
		}
	}
	return p
}

// Title is the tool plus its main argument, such as "Bash: mkdir build".
func Title(in Input) string {
	var args map[string]any
	_ = json.Unmarshal(in.ToolInput, &args)
	var arg string
	switch in.ToolName {
	case "Bash":
		arg = oneLine(str(args, "command"))
	case "Edit", "MultiEdit", "Write", "Read", "NotebookEdit":
		p := str(args, "file_path")
		if p == "" {
			p = str(args, "notebook_path")
		}
		arg = relPath(in.Cwd, p)
	case "WebFetch":
		arg = str(args, "url")
	case "WebSearch":
		arg = str(args, "query")
	case "Glob", "Grep":
		arg = str(args, "pattern")
	case "Task", "Agent":
		arg = str(args, "description")
	}
	name := in.ToolName
	if name == "" {
		name = "Tool"
	}
	if arg == "" {
		return truncate(name, maxTitle)
	}
	return truncate(name+": "+arg, maxTitle)
}

// Body shows where the agent is and the full tool input.
func Body(in Input) string {
	var b strings.Builder
	if in.Cwd != "" {
		fmt.Fprintf(&b, "In %s\n\n", in.Cwd)
	}
	var args map[string]any
	if json.Unmarshal(in.ToolInput, &args) == nil {
		if d := str(args, "description"); d != "" && in.ToolName == "Bash" {
			fmt.Fprintf(&b, "%s\n\n", d)
		}
	}
	var pretty bytes.Buffer
	if json.Indent(&pretty, in.ToolInput, "", "  ") == nil {
		fmt.Fprintf(&b, "```json\n%s\n```\n", pretty.String())
	}
	s := b.String()
	if len(s) > 60<<10 {
		s = s[:60<<10] + "\n…(truncated)"
	}
	return s
}

const (
	toolAskUserQuestion = "AskUserQuestion"
	toolExitPlanMode    = "ExitPlanMode"
)

type question struct {
	Question    string `json:"question"`
	Header      string `json:"header"`
	MultiSelect bool   `json:"multiSelect"`
	Options     []struct {
		Label       string `json:"label"`
		Description string `json:"description"`
	} `json:"options"`
}

func questions(in Input) []question {
	var ti struct {
		Questions []question `json:"questions"`
	}
	if json.Unmarshal(in.ToolInput, &ti) != nil {
		return nil
	}
	return ti.Questions
}

// Requests builds the Sentinel requests for one hook call. Permission prompts
// are a single authorize request. AskUserQuestion is one decision request per
// question, and ExitPlanMode is a decision on the plan, so neither is dressed
// up as a permission.
func Requests(in Input) []model.CreateRequest {
	switch in.ToolName {
	case toolAskUserQuestion:
		if qs := questions(in); len(qs) > 0 {
			out := make([]model.CreateRequest, len(qs))
			for i, q := range qs {
				out[i] = questionRequest(in, q)
			}
			return out
		}
	case toolExitPlanMode:
		return []model.CreateRequest{planRequest(in)}
	}
	return []model.CreateRequest{Request(in)}
}

func base(in Input, kind model.Kind) model.CreateRequest {
	r := model.CreateRequest{Kind: kind, AllowText: true, ExpiresInSeconds: ExpiresSeconds}
	r.Agent.Label = "claude-code"
	r.Agent.Session = in.SessionID
	return r
}

func questionRequest(in Input, q question) model.CreateRequest {
	r := base(in, model.KindDecision)
	r.Title = truncate(q.Question, maxTitle)
	var b strings.Builder
	if in.Cwd != "" {
		fmt.Fprintf(&b, "In %s\n\n", in.Cwd)
	}
	for i, o := range q.Options {
		r.Options = append(r.Options, model.Option{ID: strconv.Itoa(i), Label: o.Label, Style: model.StyleDefault})
		if o.Description != "" {
			fmt.Fprintf(&b, "- %s: %s\n", o.Label, o.Description)
		}
	}
	if q.MultiSelect {
		b.WriteString("\nPick one, or type several separated by commas.\n")
	}
	r.Body = b.String()
	return r
}

func planRequest(in Input) model.CreateRequest {
	r := base(in, model.KindDecision)
	r.Title = "Approve this plan?"
	var args map[string]any
	_ = json.Unmarshal(in.ToolInput, &args)
	body := str(args, "plan")
	if in.Cwd != "" {
		body = "In " + in.Cwd + "\n\n" + body
	}
	if len(body) > 60<<10 {
		body = body[:60<<10] + "\n…(truncated)"
	}
	r.Body = body
	r.Options = []model.Option{
		{ID: "approve", Label: "Approve", Style: model.StyleDefault},
		{ID: "revise", Label: "Keep planning", Style: model.StyleDefault, Negative: true},
	}
	return r
}

// Request is the authorize request for a plain permission prompt.
func Request(in Input) model.CreateRequest {
	opts := []model.Option{{ID: "allow", Label: "Allow", Style: model.StyleDefault}}
	if len(in.PermissionSuggestions) > 0 {
		opts = append(opts, model.Option{ID: "always", Label: "Always allow", Style: model.StyleDefault})
	}
	opts = append(opts, model.Option{ID: "deny", Label: "Deny", Style: model.StyleDestructive, Negative: true})
	r := base(in, model.KindAuthorize)
	r.Title = Title(in)
	r.Body = Body(in)
	r.Options = opts
	return r
}

type decision struct {
	Behavior           string            `json:"behavior"`
	Message            string            `json:"message,omitempty"`
	UpdatedInput       json.RawMessage   `json:"updatedInput,omitempty"`
	UpdatedPermissions []json.RawMessage `json:"updatedPermissions,omitempty"`
}

type output struct {
	HookSpecificOutput struct {
		HookEventName string   `json:"hookEventName"`
		Decision      decision `json:"decision"`
	} `json:"hookSpecificOutput"`
}

func marshal(d decision) []byte {
	var o output
	o.HookSpecificOutput.HookEventName = "PermissionRequest"
	o.HookSpecificOutput.Decision = d
	b, _ := json.Marshal(o)
	return b
}

// Output is the hook's stdout for the resolved requests (one per entry of
// Requests), or nil when the hook should stay silent and leave the terminal
// prompt in charge.
func Output(in Input, reqs []*model.Request) []byte {
	for _, r := range reqs {
		if r.State != model.StateAnswered || r.Response == nil {
			return nil
		}
	}
	if len(reqs) == 0 {
		return nil
	}
	switch in.ToolName {
	case toolAskUserQuestion:
		if qs := questions(in); len(qs) == len(reqs) && len(qs) > 0 {
			return answerQuestions(in, qs, reqs)
		}
	case toolExitPlanMode:
		return planOutput(reqs[0])
	}
	return permissionOutput(in, reqs[0])
}

func answerQuestions(in Input, qs []question, reqs []*model.Request) []byte {
	var input map[string]json.RawMessage
	if json.Unmarshal(in.ToolInput, &input) != nil {
		return nil
	}
	answers := make(map[string]string, len(qs))
	for i, q := range qs {
		resp := reqs[i].Response
		switch {
		case resp.OptionID != nil:
			idx, err := strconv.Atoi(*resp.OptionID)
			if err != nil || idx < 0 || idx >= len(q.Options) {
				return nil
			}
			answers[q.Question] = q.Options[idx].Label
		case resp.Text != nil && *resp.Text != "":
			answers[q.Question] = *resp.Text
		default:
			return nil
		}
	}
	input["answers"], _ = json.Marshal(answers)
	updated, _ := json.Marshal(input)
	return marshal(decision{Behavior: "allow", UpdatedInput: updated})
}

func planOutput(req *model.Request) []byte {
	resp := req.Response
	if resp.OptionID != nil && *resp.OptionID == "approve" {
		return marshal(decision{Behavior: "allow"})
	}
	msg := "Keep planning: not approved from " + resp.DeviceName + " via Sentinel"
	if resp.Text != nil && *resp.Text != "" {
		msg = *resp.Text
	}
	return marshal(decision{Behavior: "deny", Message: msg})
}

func permissionOutput(in Input, req *model.Request) []byte {
	var d decision
	resp := req.Response
	opt := ""
	if resp.OptionID != nil {
		opt = *resp.OptionID
	}
	switch opt {
	case "allow":
		d.Behavior = "allow"
	case "always":
		d.Behavior = "allow"
		if len(in.PermissionSuggestions) > 0 {
			d.UpdatedPermissions = in.PermissionSuggestions[:1]
		}
	default:
		// Deny, or a text-only reply, which is a denial with instructions.
		d.Behavior = "deny"
		if resp.Text != nil && *resp.Text != "" {
			d.Message = *resp.Text
		} else {
			d.Message = "Denied from " + resp.DeviceName + " via Sentinel"
		}
	}
	return marshal(d)
}

// Titles are the titles of the requests Requests builds for in, which is how a
// later PostToolUse call finds the requests belonging to a finished tool call.
func Titles(in Input) []string {
	rs := Requests(in)
	out := make([]string, len(rs))
	for i, r := range rs {
		out[i] = r.Title
	}
	return out
}
