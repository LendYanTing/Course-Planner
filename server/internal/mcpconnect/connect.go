// Package mcpconnect serves the human-facing page that turns an ordinary
// login into a long-lived MCP credential (docs/mcp.md §11).
//
// It deliberately lives outside /api/v1: this is a browser form for people,
// not part of the versioned JSON API. The page is self-contained so an MCP
// user needs nothing but the backend host and a browser — no Next.js app, no
// OAuth dance. A local helper (scripts/mcp-connect.js) can drive it by
// passing a loopback redirect_uri.
package mcpconnect

import (
	"html/template"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/carryingon/courseplanner/server/internal/auth"
	"github.com/carryingon/courseplanner/server/internal/mcptoken"
	"github.com/carryingon/courseplanner/server/internal/platform/httpx"
	"github.com/carryingon/courseplanner/server/internal/user"
)

const maxFormBytes = 64 << 10

// originRejected explains a 403 that retrying cannot fix: the browser is
// posting from an origin that does not match the host it fetched the form
// from. Worth its own message so the user does not retype credentials in a
// loop.
const originRejected = "请求来源不被允许：浏览器上报的 Origin 与本站不一致。请直接在本机用 127.0.0.1 或 localhost 打开本页，不要经过代理，也不要在嵌套页面里提交。"

// Service renders the connect page and mints the token.
type Service struct {
	users   *user.Repo
	tokens  *mcptoken.Repo
	limiter *attemptLimiter
}

func NewService(users *user.Repo, tokens *mcptoken.Repo) *Service {
	return &Service{users: users, tokens: tokens, limiter: newAttemptLimiter()}
}

// rejectOrigin records a cross-origin attempt (docs/security.md §7: permission
// denials are logged). The Origin header is not a credential.
func (s *Service) rejectOrigin(r *http.Request) {
	s.users.RecordAuthEvent(r.Context(), "", "", "denied", "mcp connect origin rejected: "+r.Header.Get("Origin"))
	slog.Warn("mcp connect rejected",
		"origin", r.Header.Get("Origin"),
		"referer", r.Header.Get("Referer"),
		"host", r.Host,
		"remote", r.RemoteAddr)
}

// Page renders the login form (GET /mcp/connect).
func (s *Service) Page(w http.ResponseWriter, r *http.Request) {
	setPageHeaders(w)
	if !sameOrigin(r) {
		s.rejectOrigin(r)
		s.render(w, http.StatusForbidden, view{ErrorMessage: originRejected})
		return
	}
	q := r.URL.Query()
	redirect, ok := sanitizeRedirect(q.Get("redirect_uri"))
	s.render(w, http.StatusOK, view{
		Name:        clamp(q.Get("name"), 64),
		ScopeChoice: scopeChoice(q.Get("scopes")),
		RedirectURI: redirect,
		HasRedirect: ok,
	})
}

// Submit authenticates the user and issues an MCP token (POST /mcp/connect).
func (s *Service) Submit(w http.ResponseWriter, r *http.Request) {
	setPageHeaders(w)
	if !sameOrigin(r) {
		s.rejectOrigin(r)
		s.render(w, http.StatusForbidden, view{ErrorMessage: originRejected})
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxFormBytes)
	if err := r.ParseForm(); err != nil {
		s.render(w, http.StatusBadRequest, view{ErrorMessage: "表单无法解析。"})
		return
	}

	username := strings.TrimSpace(r.PostFormValue("username"))
	password := r.PostFormValue("password")
	state := view{
		Name:        clamp(r.PostFormValue("name"), 64),
		ScopeChoice: scopeChoice(r.PostFormValue("scopes")),
		ExpiryDays:  parseExpiryDays(r.PostFormValue("expires_in_days")),
		ShowForm:    true,
	}
	if state.Name == "" {
		state.Name = "MCP client"
	}
	state.RedirectURI, state.HasRedirect = sanitizeRedirect(r.PostFormValue("redirect_uri"))

	ip := clientIP(r)
	if !s.limiter.allow(ip, username) {
		s.users.RecordAuthEvent(r.Context(), "", username, "denied", "mcp connect rate limited")
		state.ErrorMessage = "登录失败次数过多，请稍后再试。"
		s.render(w, http.StatusTooManyRequests, state)
		return
	}

	// Every failure below renders the same message: the page must not reveal
	// whether a username exists (docs/security.md §7).
	rejected := func(auditUserID, detail string) {
		s.limiter.fail(ip, username)
		s.users.RecordAuthEvent(r.Context(), auditUserID, username, "login_failure", detail)
		state.ErrorMessage = "用户名或密码错误。"
		s.render(w, http.StatusUnauthorized, state)
	}

	u, err := s.users.ByUsername(r.Context(), username)
	if err != nil {
		rejected("", "unknown username")
		return
	}
	ok, err := auth.VerifyPassword(password, u.PasswordHash)
	if err != nil || !ok {
		rejected(u.ID, "bad password")
		return
	}
	s.limiter.reset(ip, username)
	s.users.RecordAuthEvent(r.Context(), u.ID, u.Username, "login_success", "mcp connect")

	scopes := []string{mcptoken.ScopeRead}
	if state.ScopeChoice == mcptoken.ScopeWrite {
		scopes = append(scopes, mcptoken.ScopeWrite)
	}
	token, secret, err := s.tokens.Create(r.Context(), u.ID, state.Name, scopes, state.ExpiryDays)
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	s.users.RecordAuthEvent(r.Context(), u.ID, u.Username, "mcp_token_created", token.TokenPrefix+" (connect page)")

	if state.HasRedirect {
		// Hand the secret to the waiting local helper instead of showing it.
		http.Redirect(w, r, redirectWithToken(state.RedirectURI, secret, token), http.StatusSeeOther)
		return
	}
	s.render(w, http.StatusOK, successView(u.Username, secret, token, serverURL(r)))
}

func (s *Service) render(w http.ResponseWriter, status int, v view) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(status)
	_ = pageTmpl.Execute(w, v)
}

// view is the single shape the template renders: the form, an error above the
// form, or the issued token.
type view struct {
	ErrorMessage string
	// ShowForm is false for failures that retrying cannot fix, so the user is
	// not invited to retype a password into a form that will fail again.
	ShowForm bool

	// form state
	Name        string
	ScopeChoice string
	RedirectURI string
	HasRedirect bool
	ExpiryDays  int

	// success state
	Username     string
	Token        string
	TokenPrefix  string
	Scopes       string
	ExpiresAt    string
	ServerURL    string
	ClientConfig string
	ReadOnly     bool
}

func successView(username, secret string, token mcptoken.Token, origin string) view {
	endpoint := origin + "/api/v1/mcp"
	return view{
		Username:     username,
		Token:        secret,
		TokenPrefix:  token.TokenPrefix,
		Scopes:       strings.Join(token.Scopes, ", "),
		ExpiresAt:    formatOrNever(token.ExpiresAt),
		ServerURL:    endpoint,
		ClientConfig: clientConfig(endpoint, secret),
		ReadOnly:     !token.CanWrite(),
	}
}

// --- helpers -----------------------------------------------------------------

// setPageHeaders locks the page down: it carries a secret, so it must not be
// cached, framed, indexed, or allowed to load remote subresources.
func setPageHeaders(w http.ResponseWriter) {
	w.Header().Set("Cache-Control", "no-store, no-cache, must-revalidate, private")
	w.Header().Set("Pragma", "no-cache")
	w.Header().Set("X-Frame-Options", "DENY")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("X-Robots-Tag", "noindex, nofollow")
	w.Header().Set("Content-Security-Policy",
		"default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; form-action 'self'; base-uri 'none'")
}

// sameOrigin rejects cross-site form posts.
//
// Only a concrete, mismatching origin is fatal. Browsers omit Origin on
// same-site navigation, and in-app webviews frequently report an opaque origin
// ("null") — which carries no usable information anyway, since any page can
// produce it (a sandboxed iframe) and it cannot be trusted either way. The
// binding controls stay elsewhere: the credential must be typed by hand, and
// redirect_uri is pinned to loopback. So an opaque/absent origin is treated as
// "unknown" rather than "hostile" (docs/mcp.md §11).
func sameOrigin(r *http.Request) bool {
	origin := strings.TrimSpace(r.Header.Get("Origin"))
	if origin != "" && !strings.EqualFold(origin, "null") {
		u, err := url.Parse(origin)
		if err != nil || u.Host == "" {
			return false
		}
		return strings.EqualFold(u.Host, r.Host)
	}
	// Opaque origin: fall back to the referrer when the browser sends one.
	// (Our own Referrer-Policy: no-referrer means it usually will not.)
	referer := strings.TrimSpace(r.Header.Get("Referer"))
	if referer == "" {
		return true
	}
	u, err := url.Parse(referer)
	if err != nil || u.Host == "" {
		return false
	}
	return strings.EqualFold(u.Host, r.Host)
}

// sanitizeRedirect accepts only loopback callbacks. Anything else would turn
// this page into a token-exfiltration channel.
func sanitizeRedirect(raw string) (string, bool) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", false
	}
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "http" || u.Opaque != "" || u.User != nil || u.Fragment != "" {
		return "", false
	}
	switch u.Hostname() {
	case "127.0.0.1", "localhost", "::1":
	default:
		return "", false
	}
	return u.String(), true
}

func redirectWithToken(base, secret string, token mcptoken.Token) string {
	u, err := url.Parse(base)
	if err != nil {
		return base
	}
	q := u.Query()
	q.Set("token", secret)
	q.Set("tokenId", token.ID)
	q.Set("name", token.Name)
	q.Set("scopes", strings.Join(token.Scopes, ","))
	if token.ExpiresAt != nil {
		q.Set("expiresAt", token.ExpiresAt.UTC().Format(time.RFC3339))
	}
	u.RawQuery = q.Encode()
	return u.String()
}

func scopeChoice(raw string) string {
	if strings.EqualFold(strings.TrimSpace(raw), mcptoken.ScopeRead) {
		return mcptoken.ScopeRead
	}
	return mcptoken.ScopeWrite
}

func parseExpiryDays(raw string) int {
	days, err := strconv.Atoi(strings.TrimSpace(raw))
	if err != nil || days < 0 || days > 3650 {
		return 0
	}
	return days
}

func clamp(s string, max int) string {
	s = strings.TrimSpace(s)
	if len(s) > max {
		return s[:max]
	}
	return s
}

func formatOrNever(t *time.Time) string {
	if t == nil {
		return "长期有效（不会自动过期）"
	}
	return t.UTC().Format(time.RFC3339) + " UTC"
}

func clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// serverURL rebuilds the externally visible origin, honouring the HTTPS edge
// the backend is documented to sit behind.
func serverURL(r *http.Request) string {
	scheme := "http"
	if r.TLS != nil || strings.EqualFold(r.Header.Get("X-Forwarded-Proto"), "https") {
		scheme = "https"
	}
	return scheme + "://" + r.Host
}

func clientConfig(endpoint, token string) string {
	return "{\n" +
		"  \"mcpServers\": {\n" +
		"    \"course-planner\": {\n" +
		"      \"type\": \"http\",\n" +
		"      \"url\": \"" + endpoint + "\",\n" +
		"      \"headers\": { \"Authorization\": \"Bearer " + token + "\" }\n" +
		"    }\n" +
		"  }\n" +
		"}"
}

// --- login throttling --------------------------------------------------------

// attemptLimiter throttles failed logins in memory. Two buckets are checked:
// per (client, username) so one attacker cannot lock a specific account, and
// per client so spraying many usernames is still capped. Both are pruned on
// access, so the map cannot grow without bound.
type attemptLimiter struct {
	mu         sync.Mutex
	byIdentity map[string][]time.Time
	byClient   map[string][]time.Time
	perIDMax   int
	perIPMax   int
	window     time.Duration
}

func newAttemptLimiter() *attemptLimiter {
	return &attemptLimiter{
		byIdentity: map[string][]time.Time{},
		byClient:   map[string][]time.Time{},
		perIDMax:   10,
		perIPMax:   50,
		window:     5 * time.Minute,
	}
}

func (l *attemptLimiter) allow(ip, username string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.prune(l.byIdentity, identityKey(ip, username))) < l.perIDMax &&
		len(l.prune(l.byClient, ip)) < l.perIPMax
}

func (l *attemptLimiter) fail(ip, username string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	key := identityKey(ip, username)
	l.byIdentity[key] = append(l.prune(l.byIdentity, key), time.Now())
	l.byClient[ip] = append(l.prune(l.byClient, ip), time.Now())
}

func (l *attemptLimiter) reset(ip, username string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	delete(l.byIdentity, identityKey(ip, username))
}

// prune drops attempts older than the window and returns the survivors. The
// caller must hold the lock.
func (l *attemptLimiter) prune(bucket map[string][]time.Time, key string) []time.Time {
	hits := bucket[key]
	cutoff := time.Now().Add(-l.window)
	kept := hits[:0]
	for _, t := range hits {
		if t.After(cutoff) {
			kept = append(kept, t)
		}
	}
	if len(kept) == 0 {
		delete(bucket, key)
		return nil
	}
	bucket[key] = kept
	return kept
}

func identityKey(ip, username string) string {
	return ip + "|" + strings.ToLower(username)
}

// --- page --------------------------------------------------------------------

var pageTmpl = template.Must(template.New("connect").Parse(pageHTML))

const pageHTML = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>连接 MCP 客户端 · Course Planner</title>
<style>
  :root { color-scheme: light dark; }
  * { box-sizing: border-box; }
  body { margin: 0; padding: 40px 16px; font: 15px/1.6 -apple-system, "Segoe UI", "Microsoft YaHei", system-ui, sans-serif; background: #f5f6f8; color: #1c1f24; }
  .card { max-width: 620px; margin: 0 auto; background: #fff; border: 1px solid #e3e6ea; border-radius: 14px; padding: 28px 28px 32px; box-shadow: 0 8px 28px rgba(20, 24, 32, .06); }
  h1 { margin: 0 0 6px; font-size: 20px; }
  p.lead { margin: 0 0 22px; color: #5c6570; }
  label { display: block; margin: 16px 0 6px; font-weight: 600; font-size: 13px; color: #3a424c; }
  input[type=text], input[type=password], select { width: 100%; padding: 10px 12px; border: 1px solid #cfd5dc; border-radius: 9px; font: inherit; background: #fff; color: inherit; }
  input:focus, select:focus { outline: 2px solid #2f6feb; outline-offset: 1px; border-color: #2f6feb; }
  .choices { display: flex; flex-direction: column; gap: 8px; }
  .choice { display: flex; gap: 10px; align-items: flex-start; padding: 10px 12px; border: 1px solid #cfd5dc; border-radius: 9px; }
  .choice input { margin: 3px 0 0; }
  .choice small { display: block; color: #6b7480; font-weight: 400; }
  button { margin-top: 24px; width: 100%; padding: 11px 16px; border: 0; border-radius: 9px; background: #2f6feb; color: #fff; font: inherit; font-weight: 600; cursor: pointer; }
  button:hover { background: #245ac4; }
  .hint { margin-top: 14px; font-size: 12.5px; color: #6b7480; }
  .banner { padding: 12px 14px; border-radius: 9px; margin-bottom: 18px; font-size: 14px; }
  .banner.err { background: #fdecec; border: 1px solid #f3c2c2; color: #8f2323; }
  .banner.ok { background: #eaf6ee; border: 1px solid #bfe3ca; color: #1f6b38; }
  textarea, pre { width: 100%; padding: 12px; border: 1px solid #cfd5dc; border-radius: 9px; background: #f8f9fb; color: inherit; font: 13px/1.5 ui-monospace, SFMono-Regular, Consolas, monospace; }
  textarea { height: 74px; resize: vertical; }
  pre { overflow-x: auto; white-space: pre; }
  .row { display: flex; gap: 8px; margin-top: 10px; }
  .row button { margin: 0; width: auto; padding: 8px 14px; background: #eef1f5; color: #2b323b; border: 1px solid #cfd5dc; font-weight: 500; }
  .row button:hover { background: #e3e7ec; }
  .warn { margin-top: 18px; padding: 12px 14px; border-radius: 9px; background: #fff7e6; border: 1px solid #f0d9a8; font-size: 13.5px; color: #7a5312; }
  .kv { margin-top: 22px; font-size: 13.5px; color: #4a525c; }
  .kv div { margin-top: 6px; word-break: break-all; }
  code { font: 12.5px ui-monospace, Consolas, monospace; background: #f0f2f5; padding: 1px 5px; border-radius: 5px; }
</style>
</head>
<body>
<div class="card">
{{if .ErrorMessage}}
  <h1>连接失败</h1>
  <div class="banner err">{{.ErrorMessage}}</div>
  {{if .ShowForm}}
  <form method="post" action="/mcp/connect">
    <input type="hidden" name="name" value="{{.Name}}">
    <input type="hidden" name="scopes" value="{{.ScopeChoice}}">
    <input type="hidden" name="expires_in_days" value="{{.ExpiryDays}}">
    {{if .HasRedirect}}<input type="hidden" name="redirect_uri" value="{{.RedirectURI}}">{{end}}
    <label for="u2">用户名</label>
    <input id="u2" type="text" name="username" autocapitalize="none" autocomplete="username" required>
    <label for="p2">密码</label>
    <input id="p2" type="password" name="password" autocomplete="current-password" required>
    <button type="submit">重试</button>
  </form>
  {{end}}
{{else if .Token}}
  <h1>MCP 凭证已生成</h1>
  <div class="banner ok">已为 {{.Username}} 签发凭证「{{.Name}}」。以下内容只显示这一次。</div>

  <label for="tokenText">Token（只显示一次）</label>
  <textarea id="tokenText" readonly>{{.Token}}</textarea>
  <div class="row">
    <button type="button" onclick="copyToken()">复制 token</button>
    <button type="button" onclick="selectToken()">全选</button>
  </div>

  <div class="warn">请立即保存到密码管理器。离开本页后无法再次查看；一旦泄露，可吊销这枚凭证（<code>{{.TokenPrefix}}…</code>）。</div>

  <label for="clientCfg">客户端配置（粘贴到 MCP 客户端设置）</label>
  <pre id="clientCfg">{{.ClientConfig}}</pre>
  <div class="row"><button type="button" onclick="copyConfig()">复制配置</button></div>

  <div class="kv">
    <div>端点：<code>{{.ServerURL}}</code></div>
    <div>权限：{{.Scopes}}{{if .ReadOnly}}（只读，写入工具会被拒绝）{{end}}</div>
    <div>有效期：{{.ExpiresAt}}</div>
    <div>自检：<code>curl -s {{.ServerURL}} -H 'Authorization: Bearer &lt;token&gt;' -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'</code></div>
  </div>
{{else}}
  <h1>连接 MCP 客户端</h1>
  <p class="lead">用你的 Course Planner 账号登录，为 Claude Desktop / Claude Code / Cursor 等客户端签发一枚长效 token。</p>
  <form method="post" action="/mcp/connect">
    <label for="name">客户端名称</label>
    <input id="name" type="text" name="name" value="{{.Name}}" maxlength="64" placeholder="Claude Desktop">
    {{if .HasRedirect}}<input type="hidden" name="redirect_uri" value="{{.RedirectURI}}">{{end}}

    <label>权限范围</label>
    <div class="choices">
      <label class="choice" for="s-read">
        <input id="s-read" type="radio" name="scopes" value="read" {{if eq .ScopeChoice "read"}}checked{{end}}>
        <span>只读<small>只能读取课程与待办，适合只做查询 / 排期的 Agent</small></span>
      </label>
      <label class="choice" for="s-write">
        <input id="s-write" type="radio" name="scopes" value="write" {{if eq .ScopeChoice "write"}}checked{{end}}>
        <span>读写<small>可创建与修改，写入仍需你在客户端里确认</small></span>
      </label>
    </div>

    <label for="exp">有效期</label>
    <select id="exp" name="expires_in_days">
      <option value="0" {{if eq .ExpiryDays 0}}selected{{end}}>长期有效</option>
      <option value="30" {{if eq .ExpiryDays 30}}selected{{end}}>30 天</option>
      <option value="90" {{if eq .ExpiryDays 90}}selected{{end}}>90 天</option>
      <option value="365" {{if eq .ExpiryDays 365}}selected{{end}}>365 天</option>
    </select>

    <label for="u">用户名</label>
    <input id="u" type="text" name="username" autocapitalize="none" autocomplete="username" required>
    <label for="p">密码</label>
    <input id="p" type="password" name="password" autocomplete="current-password" required>

    <button type="submit">生成 token</button>
    <div class="hint">token 明文只显示一次；服务端只保存 SHA-256 哈希，随时可吊销。</div>
  </form>
{{end}}
</div>
<script>
function selectToken() {
  var el = document.getElementById('tokenText');
  if (el) { el.focus(); el.select(); }
}
function copyToken() {
  var el = document.getElementById('tokenText');
  if (el) { copyText(el.value, el); }
}
function copyConfig() {
  var el = document.getElementById('clientCfg');
  if (el) { copyText(el.textContent, el); }
}
function copyText(text, el) {
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).then(function () { el.focus(); }, function () { selectToken(); });
    return;
  }
  selectToken();
}
</script>
</body>
</html>
`
