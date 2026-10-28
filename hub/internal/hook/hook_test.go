package hook

import (
	"encoding/json"
	"strings"
	"testing"

	"fdatoo.dev/sentinel/hub/internal/model"
	"fdatoo.dev/sentinel/hub/internal/push"
)

const bashInput = `{
  "session_id": "s1", "cwd": "/Users/fynn/proj", "hook_event_name": "PermissionRequest",
  "tool_name": "Bash",
  "tool_input": {"command": "mkdir build\necho done", "description": "Make build dir"},
  "permission_suggestions": [{"type": "addRules", "rules": [{"toolName": "Bash", "ruleContent": "mkdir:*"}], "behavior": "allow", "destination": "localSettings"}]
}`

func input(t *testing.T, s string) Input {
	t.Helper()
	var in Input
	if err := json.Unmarshal([]byte(s), &in); err != nil {
		t.Fatal(err)
	}
	return in
}

func TestTitles(t *testing.T) {
	cases := map[string]string{
		bashInput: "Bash: mkdir build …",
		`{"cwd":"/p","tool_name":"Edit","tool_input":{"file_path":"/p/src/a.go"}}`: "Edit: src/a.go",
		`{"cwd":"/p","tool_name":"Write","tool_input":{"file_path":"/etc/hosts"}}`: "Write: /etc/hosts",
		`{"tool_name":"WebFetch","tool_input":{"url":"https://x.dev"}}`:            "WebFetch: https://x.dev",
		`{"tool_name":"mcp__github__create_issue","tool_input":{"title":"x"}}`:     "mcp__github__create_issue",
	}
	for in, want := range cases {
		if got := Title(input(t, in)); got != want {
			t.Errorf("Title = %q, want %q", got, want)
		}
	}
}

func TestRequestShape(t *testing.T) {
	r := Request(input(t, bashInput))
	if r.Kind != model.KindAuthorize || r.GraceSeconds != 0 || r.ExpiresInSeconds != 3600 || !r.AllowText {
		t.Fatalf("unexpected %+v", r)
	}
	if r.Agent.Label != "claude-code" || r.Agent.Session != "s1" {
		t.Fatalf("agent %+v", r.Agent)
	}
	// The hook's three options must match the sentinel.authorize.hook category.
	req := &model.Request{Kind: r.Kind, Options: r.Options, AllowText: r.AllowText}
	if got := push.Category(req); got != "sentinel.authorize.hook" {
		t.Fatalf("category %s", got)
	}
	noSuggest := Request(input(t, `{"tool_name":"Bash","tool_input":{"command":"ls"}}`))
	if len(noSuggest.Options) != 2 {
		t.Fatalf("options %+v", noSuggest.Options)
	}
}

func answered(opt, text string) *model.Request {
	r := &model.Request{State: model.StateAnswered, Response: &model.Response{DeviceName: "Sam's iPhone"}}
	if opt != "" {
		r.Response.OptionID = &opt
	}
	if text != "" {
		r.Response.Text = &text
	}
	return r
}

func TestOutput(t *testing.T) {
	in := input(t, bashInput)
	cases := []struct {
		req  *model.Request
		want string
	}{
		{answered("allow", ""), `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`},
		{answered("always", ""), `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","updatedPermissions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"mkdir:*"}],"behavior":"allow","destination":"localSettings"}]}}}`},
		{answered("deny", "use make instead"), `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"use make instead"}}}`},
		{answered("deny", ""), `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from Sam's iPhone via Sentinel"}}}`},
		{answered("", "not now"), `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"not now"}}}`},
		{&model.Request{State: model.StateExpired}, ``},
		{&model.Request{State: model.StateCancelled}, ``},
	}
	for _, c := range cases {
		if got := string(Output(in, []*model.Request{c.req})); got != c.want {
			t.Errorf("got  %s\nwant %s", got, c.want)
		}
	}
}

const askInput = `{
  "session_id": "s1", "cwd": "/p", "tool_name": "AskUserQuestion",
  "tool_input": {"questions": [
    {"question": "Which framework?", "header": "Framework", "multiSelect": false,
     "options": [{"label": "React", "description": "Components"}, {"label": "Vue", "description": "Progressive"}]},
    {"question": "Which db?", "header": "DB", "multiSelect": true,
     "options": [{"label": "pg", "description": ""}, {"label": "sqlite", "description": ""}]}
  ]}
}`

func TestAskUserQuestionIsDecisions(t *testing.T) {
	in := input(t, askInput)
	rs := Requests(in)
	if len(rs) != 2 || rs[0].Kind != model.KindDecision || rs[0].Title != "Which framework?" {
		t.Fatalf("requests %+v", rs)
	}
	if len(rs[0].Options) != 2 || rs[0].Options[1].ID != "1" || rs[0].Options[1].Label != "Vue" || !rs[0].AllowText {
		t.Fatalf("options %+v", rs[0].Options)
	}
	out := Output(in, []*model.Request{answered("1", ""), answered("", "pg, sqlite")})
	want := `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","updatedInput":`
	if !strings.HasPrefix(string(out), want) {
		t.Fatalf("got %s", out)
	}
	var o struct {
		HookSpecificOutput struct {
			Decision struct {
				UpdatedInput struct {
					Questions []json.RawMessage `json:"questions"`
					Answers   map[string]string `json:"answers"`
				} `json:"updatedInput"`
			} `json:"decision"`
		} `json:"hookSpecificOutput"`
	}
	if err := json.Unmarshal(out, &o); err != nil {
		t.Fatal(err)
	}
	ui := o.HookSpecificOutput.Decision.UpdatedInput
	if len(ui.Questions) != 2 || ui.Answers["Which framework?"] != "Vue" || ui.Answers["Which db?"] != "pg, sqlite" {
		t.Fatalf("updatedInput %+v", ui)
	}
	// One unanswered question leaves the terminal in charge.
	if out := Output(in, []*model.Request{answered("0", ""), {State: model.StateExpired}}); out != nil {
		t.Fatalf("expected silence, got %s", out)
	}
}

func TestExitPlanMode(t *testing.T) {
	in := input(t, `{"tool_name":"ExitPlanMode","tool_input":{"plan":"1. do it"}}`)
	rs := Requests(in)
	if len(rs) != 1 || rs[0].Kind != model.KindDecision || !strings.Contains(rs[0].Body, "1. do it") {
		t.Fatalf("requests %+v", rs)
	}
	if got := string(Output(in, []*model.Request{answered("approve", "")})); got != `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}` {
		t.Fatalf("approve: %s", got)
	}
	if got := string(Output(in, []*model.Request{answered("revise", "split step 2")})); !strings.Contains(got, `"deny","message":"split step 2"`) {
		t.Fatalf("revise: %s", got)
	}
}

func TestPlainPermissionStaysAuthorize(t *testing.T) {
	rs := Requests(input(t, bashInput))
	if len(rs) != 1 || rs[0].Kind != model.KindAuthorize {
		t.Fatalf("requests %+v", rs)
	}
}
