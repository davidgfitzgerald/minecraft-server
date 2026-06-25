// Command setup is an interactive, idempotent first-run wizard for the Minecraft
// Bedrock server stack. It is launched by `just setup`.
//
// It does four things, none of which clobber existing state:
//  1. Detects required/optional tooling (Docker, python3, …) and prints OS-aware
//     install hints for anything missing.
//  2. Walks you through the .env settings one prompt at a time, PRE-FILLED from any
//     existing .env — accept (Enter) to keep what's there, or edit. Optional fields
//     can be left blank to skip.
//  3. Merges those values back into .env in place (preserving comments; only managed
//     keys are touched), or creates .env from .env.example on a fresh clone.
//  4. Offers to run the idempotent actions (start the stack, install the launchd
//     agents) — each is safe to re-run, and already-done steps are marked as such.
//
// CWD is forced to the project root (via MC_ROOT, set by the Justfile) so .env,
// `docker compose`, and `just` all resolve correctly.
package main

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// ───────────────────────────── styles ─────────────────────────────
var (
	cGold  = lipgloss.Color("220")
	cGreen = lipgloss.Color("42")
	cRed   = lipgloss.Color("203")
	cAmber = lipgloss.Color("214")
	cGray  = lipgloss.Color("245")
	cBlue  = lipgloss.Color("39")

	stTitle = lipgloss.NewStyle().Bold(true).Foreground(cGold)
	stSub   = lipgloss.NewStyle().Foreground(cGray)
	stOK    = lipgloss.NewStyle().Foreground(cGreen)
	stBad   = lipgloss.NewStyle().Foreground(cRed)
	stWarn  = lipgloss.NewStyle().Foreground(cAmber)
	stKey   = lipgloss.NewStyle().Bold(true)
	stLink  = lipgloss.NewStyle().Foreground(cBlue).Underline(true)
	stFoot  = lipgloss.NewStyle().Foreground(cGray).Italic(true)
	stSel   = lipgloss.NewStyle().Bold(true).Foreground(cGold)
)

// ───────────────────────────── data ─────────────────────────────
type step struct {
	key      string
	label    string
	help     string
	link     string
	def      string // default value if .env has none
	required bool
}

// the .env keys the wizard manages, in prompt order.
var steps = []step{
	{key: "SERVER_NAME", label: "Server name", help: "Shown in the server list.", def: "bedrock"},
	{key: "LEVEL_NAME", label: "World folder name", help: "Must match the folder under bedrock-data/worlds/.", def: "world"},
	{key: "PLAYIT_SECRET_KEY", label: "playit.gg secret key", help: "REQUIRED so friends/consoles can join. Shown once when you create the agent.", link: "https://playit.gg/account/agents/new-docker", required: true},
	{key: "NTFY_TOPIC", label: "ntfy push topic", help: "Optional phone push (the default notify channel). A PRIVATE random topic; treat like a password. Blank = skip.", link: "https://ntfy.sh"},
	{key: "DISCORD_WEBHOOK_PLAYER", label: "Discord webhook · #player-activity", help: "Optional. Edit Channel → Integrations → Webhooks → New Webhook. Blank = skip."},
	{key: "DISCORD_WEBHOOK_SERVER_STATUS", label: "Discord webhook · #server-status", help: "Optional. Crash / tunnel / up-down / resource alerts. Blank = skip."},
	{key: "DISCORD_WEBHOOK_MONITOR", label: "Discord webhook · #monitoring", help: "Optional. Daily digest + uptime graph. Blank = skip."},
	{key: "DISCORD_WEBHOOK_CHAT", label: "Discord webhook · #in-game-chat", help: "Optional. In-game chat is relayed here. Blank = skip."},
	{key: "GOBLIN_BOT_TOKEN", label: "Discord bot token (2-way chat)", help: "Optional. Lets Discord #in-game-chat post INTO the game. Enable MESSAGE CONTENT INTENT. Blank = skip.", link: "https://discord.com/developers/applications"},
	{key: "IN_GAME_CHAT_CHANNEL_ID", label: "#in-game-chat channel ID", help: "Optional, needed with the bot token. Developer Mode → right-click channel → Copy Channel ID."},
	{key: "HEALTHCHECK_URL", label: "healthchecks.io ping URL", help: "Optional. Powers the uptime graph + off-network down alerts. Blank = skip.", link: "https://healthchecks.io"},
	{key: "HEALTHCHECK_API_KEY", label: "healthchecks.io API key", help: "Optional, needed with the ping URL for the uptime graph's status strip."},
}

type req struct {
	name    string
	present bool
	detail  string
	hint    string
	hard    bool
}

type action struct {
	label    string
	cmd      []string
	selected bool
	note     string
	status   string // "", "ok", "fail", "skip"
	out      string
}

type stage int

const (
	stageReq stage = iota
	stageConfig
	stageActions
	stageRun
	stageDone
)

type doneMsg struct{ acts []action }

type model struct {
	root    string
	stage   stage
	reqs    []req
	ti      textinput.Model
	idx     int               // current step index
	values  map[string]string // collected values
	existing map[string]string
	acts    []action
	actIdx  int
	err     string
}

// ───────────────────────────── detection ─────────────────────────────
func have(bin string) (bool, string) {
	p, err := exec.LookPath(bin)
	if err != nil {
		return false, ""
	}
	return true, p
}

func installHint(bin string) string {
	switch runtime.GOOS {
	case "darwin":
		switch bin {
		case "docker":
			return "Install OrbStack (https://orbstack.dev) or Docker Desktop (https://docker.com/products/docker-desktop), then start it."
		case "python3":
			return "brew install python3   (or https://www.python.org/downloads/)"
		case "go":
			return "brew install go   (or https://go.dev/dl/)"
		case "terminal-notifier":
			return "brew install terminal-notifier"
		}
	case "linux":
		switch bin {
		case "docker":
			return "Install Docker Engine: https://docs.docker.com/engine/install/  (and the compose plugin)"
		case "python3":
			return "sudo apt install python3   (or your distro's package manager)"
		case "go":
			return "https://go.dev/dl/   (or your distro's golang package)"
		case "terminal-notifier":
			return "n/a on Linux — macOS only (the ntfy push works cross-platform)"
		}
	}
	return "See the project README for install instructions."
}

func detectReqs() []req {
	var rs []req
	// docker (+ daemon)
	if ok, p := have("docker"); ok {
		daemon := exec.Command("docker", "info").Run() == nil
		if daemon {
			rs = append(rs, req{"Docker", true, "found at " + p + " (daemon up)", "", true})
		} else {
			rs = append(rs, req{"Docker", false, "found, but the daemon isn't running", "Start OrbStack / Docker Desktop, then re-run.", true})
		}
	} else {
		rs = append(rs, req{"Docker", false, "not found", installHint("docker"), true})
	}
	// python3 (bot venv + uptime graph)
	if ok, p := have("python3"); ok {
		rs = append(rs, req{"python3", true, "found at " + p, "", false})
	} else {
		rs = append(rs, req{"python3", false, "not found (needed for the chat bot + uptime graph)", installHint("python3"), false})
	}
	// terminal-notifier (only relevant on macOS, for opt-in desktop alerts)
	if runtime.GOOS == "darwin" {
		if ok, _ := have("terminal-notifier"); ok {
			rs = append(rs, req{"terminal-notifier", true, "found (optional macOS desktop alerts)", "", false})
		} else {
			rs = append(rs, req{"terminal-notifier", false, "not found (optional — only for NOTIFY_MACOS=1)", installHint("terminal-notifier"), false})
		}
	}
	return rs
}

func dockerStackUp() bool {
	out, _ := exec.Command("docker", "ps", "--filter", "name=^/bedrock$", "-q").Output()
	return strings.TrimSpace(string(out)) != ""
}

func agentLoaded(label string) bool {
	out, _ := exec.Command("id", "-u").Output()
	uid := strings.TrimSpace(string(out))
	return exec.Command("launchctl", "print", "gui/"+uid+"/"+label).Run() == nil
}

// ───────────────────────────── .env I/O ─────────────────────────────
var reInlineComment = regexp.MustCompile(`\s+#`)

func parseEnv(root string) map[string]string {
	m := map[string]string{}
	b, err := os.ReadFile(filepath.Join(root, ".env"))
	if err != nil {
		return m
	}
	for _, ln := range strings.Split(string(b), "\n") {
		t := strings.TrimSpace(ln)
		if t == "" || strings.HasPrefix(t, "#") || !strings.Contains(t, "=") {
			continue
		}
		kv := strings.SplitN(t, "=", 2)
		k := strings.TrimSpace(kv[0])
		v := strings.TrimSpace(kv[1])
		if loc := reInlineComment.FindStringIndex(v); loc != nil {
			v = strings.TrimSpace(v[:loc[0]])
		}
		v = strings.Trim(v, `"'`)
		m[k] = v
	}
	return m
}

func envVal(v string) string {
	if strings.ContainsAny(v, " \t") {
		return `"` + v + `"`
	}
	return v
}

func setKV(lines []string, k, v string) []string {
	pre := k + "="
	for i, ln := range lines {
		if strings.HasPrefix(strings.TrimSpace(ln), pre) {
			lines[i] = k + "=" + envVal(v)
			return lines
		}
	}
	return append(lines, k+"="+envVal(v))
}

func writeEnv(root string, values, existing map[string]string) error {
	path := filepath.Join(root, ".env")
	var base string
	if b, err := os.ReadFile(path); err == nil {
		base = string(b)
	} else if b, err := os.ReadFile(filepath.Join(root, ".env.example")); err == nil {
		base = string(b)
	}
	lines := strings.Split(base, "\n")
	for _, s := range steps {
		v := values[s.key]
		_, present := existing[s.key]
		// skip writing empty optional keys that aren't already in the file (no clutter)
		if v == "" && !present {
			continue
		}
		lines = setKV(lines, s.key, v)
	}
	out := strings.Join(lines, "\n")
	if !strings.HasSuffix(out, "\n") {
		out += "\n"
	}
	return os.WriteFile(path, []byte(out), 0o600)
}

func randTopic() string {
	b := make([]byte, 5)
	_, _ = rand.Read(b)
	return "mc-" + hex.EncodeToString(b)
}

// ───────────────────────────── bubbletea ─────────────────────────────
func newTI() textinput.Model {
	t := textinput.New()
	t.CharLimit = 512
	t.Width = 60
	return t
}

func initialModel(root string) model {
	existing := parseEnv(root)
	m := model{
		root:     root,
		stage:    stageReq,
		reqs:     detectReqs(),
		ti:       newTI(),
		values:   map[string]string{},
		existing: existing,
	}
	return m
}

func (m model) Init() tea.Cmd { return nil }

// load the textinput for the current step (prefill from .env, else default).
func (m *model) loadStep() {
	s := steps[m.idx]
	cur := m.existing[s.key]
	if cur == "" {
		cur = s.def
		if s.key == "NTFY_TOPIC" && cur == "" {
			cur = randTopic()
		}
	}
	m.ti.SetValue(cur)
	m.ti.CursorEnd()
	m.ti.Focus()
}

func (m *model) buildActions() {
	stackUp := dockerStackUp()
	a := []action{
		{label: "Start the server stack  (docker compose up -d)", cmd: []string{"docker", "compose", "up", "-d"}, selected: !stackUp},
		{label: "Install player notifier agent  (just notify-install)", cmd: []string{"just", "notify-install"}, selected: !agentLoaded("com.mcserver.notify")},
		{label: "Install uptime-graph agent  (just uptime-install)", cmd: []string{"just", "uptime-install"}, selected: false},
	}
	if stackUp {
		a[0].note = "(stack already running — safe to re-run)"
	}
	if agentLoaded("com.mcserver.notify") {
		a[1].note = "(already installed)"
	}
	if agentLoaded("com.mcserver.uptime") {
		a[2].note = "(already installed)"
	} else {
		a[2].selected = m.values["HEALTHCHECK_URL"] != ""
	}
	if m.values["GOBLIN_BOT_TOKEN"] != "" {
		ba := action{label: "Install Discord→Minecraft chat bot  (just bot-install)", cmd: []string{"just", "bot-install"}, selected: !agentLoaded("com.mcserver.goblinbot")}
		if agentLoaded("com.mcserver.goblinbot") {
			ba.note = "(already installed)"
		}
		a = append(a, ba)
	}
	m.acts = a
}

func runActions(acts []action) tea.Cmd {
	return func() tea.Msg {
		for i := range acts {
			if !acts[i].selected {
				acts[i].status = "skip"
				continue
			}
			out, err := exec.Command(acts[i].cmd[0], acts[i].cmd[1:]...).CombinedOutput()
			acts[i].out = strings.TrimSpace(string(out))
			if err != nil {
				acts[i].status = "fail"
				if acts[i].out == "" {
					acts[i].out = err.Error()
				}
			} else {
				acts[i].status = "ok"
			}
		}
		return doneMsg{acts}
	}
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		if msg.Type == tea.KeyCtrlC {
			return m, tea.Quit
		}
		switch m.stage {
		case stageReq:
			if msg.Type == tea.KeyEnter {
				m.stage = stageConfig
				m.idx = 0
				m.loadStep()
			} else if msg.String() == "q" {
				return m, tea.Quit
			}
			return m, nil
		case stageConfig:
			if msg.Type == tea.KeyEnter {
				v := strings.TrimSpace(m.ti.Value())
				m.values[steps[m.idx].key] = v
				if m.idx < len(steps)-1 {
					m.idx++
					m.loadStep()
				} else {
					if err := writeEnv(m.root, m.values, m.existing); err != nil {
						m.err = "writing .env: " + err.Error()
					}
					m.buildActions()
					m.stage = stageActions
				}
				return m, nil
			}
			var cmd tea.Cmd
			m.ti, cmd = m.ti.Update(msg)
			return m, cmd
		case stageActions:
			switch msg.String() {
			case "up", "k":
				if m.actIdx > 0 {
					m.actIdx--
				}
			case "down", "j":
				if m.actIdx < len(m.acts)-1 {
					m.actIdx++
				}
			case " ":
				m.acts[m.actIdx].selected = !m.acts[m.actIdx].selected
			case "enter":
				m.stage = stageRun
				return m, runActions(m.acts)
			}
			return m, nil
		case stageDone:
			return m, tea.Quit
		}
	case doneMsg:
		m.acts = msg.acts
		m.stage = stageDone
		return m, nil
	case tea.WindowSizeMsg:
		if msg.Width > 20 {
			m.ti.Width = msg.Width - 12
		}
	}
	return m, nil
}

// ───────────────────────────── views ─────────────────────────────
func (m model) View() string {
	switch m.stage {
	case stageReq:
		return m.viewReq()
	case stageConfig:
		return m.viewConfig()
	case stageActions:
		return m.viewActions()
	case stageRun:
		return header() + "\n  Running selected steps… (this can take a few seconds)\n"
	case stageDone:
		return m.viewDone()
	}
	return ""
}

func header() string {
	return stTitle.Render("🐐 Cobblestone Goblins — server setup") + "\n"
}

func (m model) viewReq() string {
	var b strings.Builder
	b.WriteString(header() + "\n")
	b.WriteString(stSub.Render("Checking your machine for the tools this stack needs:") + "\n\n")
	blocking := false
	for _, r := range m.reqs {
		mark := stOK.Render("✓")
		if !r.present {
			if r.hard {
				mark = stBad.Render("✗")
				blocking = true
			} else {
				mark = stWarn.Render("•")
			}
		}
		b.WriteString(fmt.Sprintf("  %s %s — %s\n", mark, stKey.Render(r.name), r.detail))
		if !r.present && r.hint != "" {
			b.WriteString("      " + stSub.Render("→ "+r.hint) + "\n")
		}
	}
	b.WriteString("\n")
	if blocking {
		b.WriteString(stWarn.Render("  Docker is required and isn't ready. You can continue and fill in .env now,") + "\n")
		b.WriteString(stWarn.Render("  but install/start Docker before launching the stack.") + "\n\n")
	}
	b.WriteString(stFoot.Render("  Enter to continue · q or Ctrl-C to quit"))
	return b.String()
}

func (m model) viewConfig() string {
	s := steps[m.idx]
	var b strings.Builder
	b.WriteString(header() + "\n")
	b.WriteString(stSub.Render(fmt.Sprintf("Step %d of %d", m.idx+1, len(steps))) + "\n\n")
	tag := ""
	if s.required {
		tag = stBad.Render("  (required)")
	} else {
		tag = stSub.Render("  (optional)")
	}
	b.WriteString("  " + stKey.Render(s.label) + tag + "\n")
	b.WriteString("  " + stSub.Render(s.help) + "\n")
	if s.link != "" {
		b.WriteString("  " + stLink.Render(s.link) + "\n")
	}
	if _, ok := m.existing[s.key]; ok {
		b.WriteString("  " + stOK.Render("(found in your current .env — Enter to keep)") + "\n")
	}
	b.WriteString("\n  " + m.ti.View() + "\n\n")
	b.WriteString(stFoot.Render("  Enter to accept · leave blank to skip optional · Ctrl-C to quit"))
	return b.String()
}

func (m model) viewActions() string {
	var b strings.Builder
	b.WriteString(header() + "\n")
	if m.err != "" {
		b.WriteString(stBad.Render("  "+m.err) + "\n\n")
	} else {
		b.WriteString(stOK.Render("  ✓ .env saved.") + stSub.Render("  Now choose what to run (all are safe to re-run):") + "\n\n")
	}
	for i, a := range m.acts {
		box := "[ ]"
		if a.selected {
			box = stSel.Render("[x]")
		}
		cursor := "  "
		line := a.label
		if i == m.actIdx {
			cursor = stSel.Render("▸ ")
			line = stSel.Render(line)
		}
		b.WriteString(fmt.Sprintf("  %s%s %s", cursor, box, line))
		if a.note != "" {
			b.WriteString(" " + stSub.Render(a.note))
		}
		b.WriteString("\n")
	}
	b.WriteString("\n")
	b.WriteString(stFoot.Render("  ↑/↓ move · space toggle · Enter run · Ctrl-C quit"))
	return b.String()
}

func (m model) viewDone() string {
	var b strings.Builder
	b.WriteString(header() + "\n")
	b.WriteString(stOK.Render("  ✓ Setup complete.") + "\n\n")
	for _, a := range m.acts {
		switch a.status {
		case "ok":
			b.WriteString("  " + stOK.Render("✓") + " " + a.label + "\n")
		case "fail":
			b.WriteString("  " + stBad.Render("✗") + " " + a.label + "\n")
			if a.out != "" {
				b.WriteString(stSub.Render("      "+firstLine(a.out)) + "\n")
			}
		default:
			b.WriteString("  " + stSub.Render("• skipped: "+a.label) + "\n")
		}
	}
	b.WriteString("\n")
	b.WriteString(stSub.Render("  Re-run `just setup` any time — it keeps what's already configured.") + "\n")
	b.WriteString(stSub.Render("  Next: `just status` · `just tunnel` (public address) · `just` (all recipes).") + "\n\n")
	b.WriteString(stFoot.Render("  Enter to exit"))
	return b.String()
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i] + " …"
	}
	return s
}

func projectRoot() string {
	if r := os.Getenv("MC_ROOT"); r != "" {
		return r
	}
	// walk up from CWD looking for docker-compose.yml
	dir, _ := os.Getwd()
	for {
		if _, err := os.Stat(filepath.Join(dir, "docker-compose.yml")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	cwd, _ := os.Getwd()
	return cwd
}

func main() {
	root := projectRoot()
	if err := os.Chdir(root); err != nil {
		fmt.Fprintln(os.Stderr, "cannot enter project root:", err)
		os.Exit(1)
	}
	p := tea.NewProgram(initialModel(root))
	if _, err := p.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "setup error:", err)
		os.Exit(1)
	}
}
