#!/usr/bin/env bash
# Host-side tests for devc; no podman needed. Run: devc/tests/run.sh
# shellcheck disable=SC2016  # $w and \(...) in single quotes are jq's, not the shell's
set -uo pipefail

devc_dir=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/devc-tests.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

export DEVC_SHARE=/share/devc
export DEVC_MOUNTS_ENV="$tmp/mounts.env"
# The Obsidian bridge socket lives under it (vaults); just's shebang recipes
# need a writable one too.
export XDG_RUNTIME_DIR="$tmp/rt"
mkdir -m 700 "$XDG_RUNTIME_DIR"
# Slot 10 before 2 on purpose: output must follow slot numbers, not file order.
cat > "$DEVC_MOUNTS_ENV" <<'EOF'
DEVC_MOUNT_10=type=bind,source=${HOME}/tok,target=/run/secrets/claude-oauth-token,readonly
DEVC_MOUNT_2=type=bind,source=${HOME}/.config/nvim,target=/home/dev/.config/nvim,readonly
EOF

passed=0 failed=0
ok()  { passed=$((passed + 1)); printf '\033[32mok  \033[0m %s\n' "$1"; }
bad() { failed=$((failed + 1)); printf '\033[31mFAIL\033[0m %s\n     %s\n' "$1" "$2"; }
# repo <name>: fresh git repo under $tmp, prints its path
repo() { git init -q "$tmp/$1" && printf '%s' "$tmp/$1"; }
# gen <workspace>: config into $cfg, stderr into $err; gen-config's status
cfg="$tmp/out.json" err="$tmp/err.txt"
gen() { "$devc_dir/gen-config" "$1" > "$cfg" 2> "$err"; }
# generates <name> <workspace>: gen must succeed
generates() { if gen "$2"; then ok "$1"; else bad "$1" "$(cat "$err")"; fi; }
# check <name> <jq filter> [jq args...]: filter must be true on $cfg; $w is set
check() {
  local name=$1 filter=$2; shift 2
  if jq -e --arg w "$w" "$@" "$filter" "$cfg" >/dev/null; then ok "$name"
  else bad "$name" "mounts: $(jq -c .mounts "$cfg" 2>&1)"; fi
}
# refuses <name> <workspace> <stderr pattern>: gen must fail with that message
refuses() {
  if gen "$2"; then bad "$1" "exited 0"
  elif grep -q -- "$3" "$err"; then ok "$1"
  else bad "$1" "stderr: $(cat "$err")"; fi
}

# --- plain repo, no .claude ---------------------------------------------------
w=$(repo plain)
generates "plain: exits 0" "$w"
check "plain: exact mount list (slot order, \${HOME} expanded)" '.mounts == [
  "type=tmpfs,target=\($w)/confidential,notmpcopyup",
  "type=tmpfs,target=\($w)/.git/git-crypt,notmpcopyup",
  "type=bind,source=\($w)/.git/hooks,target=\($w)/.git/hooks,readonly",
  "type=bind,source=\($w)/.git/config,target=\($w)/.git/config,readonly",
  "type=tmpfs,target=\($w)/.claude,notmpcopyup,readonly",
  "type=bind,source=/share/devc,target=/opt/devc,readonly",
  "type=bind,source=\(env.HOME)/.config/nvim,target=/home/dev/.config/nvim,readonly",
  "type=bind,source=\(env.HOME)/tok,target=/run/secrets/claude-oauth-token,readonly"
]'
check "plain: path identity" \
  '.workspaceFolder == $w and .workspaceMount == "type=bind,source=\($w),target=\($w)"'
check "plain: fixed image, user and label" \
  '.image == "ghcr.io/butzo/arch-dev:aio" and .remoteUser == "dev"
   and (.runArgs | index(["--label", "devc.managed=true"]) != null)
   and (.runArgs | index("--userns=keep-id") != null)'
check "plain: post-create from /opt/devc" '.postCreateCommand == ["/opt/devc/post-create.sh", $w]'
check "plain: no security options" \
  '[.runArgs[] | select(test("security-opt|cap-add|privileged|unmask|systempaths"))] == []
   and (has("privileged") | not) and (has("capAdd") | not) and (has("securityOpt") | not)'
# Podman creates a missing tmpfs target itself, owned by nobody; the host user
# then cannot write it (Claudian keeps its settings in .claudian/).
# owned <name> <path...>: each path must be a directory owned by the caller
owned() {
  local name=$1 p; shift
  for p in "$@"; do
    if [ ! -d "$p" ]; then bad "$name" "$p is not a directory"; return; fi
    if [ "$(stat -c %u "$p")" != "$(id -u)" ]; then bad "$name" "$p not owned by $(id -u)"; return; fi
  done
  ok "$name"
}
owned "plain: tmpfs targets pre-created, owned by the user" \
  "$w/confidential" "$w/.git/git-crypt" "$w/.claude"

# --- repo with .claude and justfile -------------------------------------------
w=$(repo claude)
mkdir "$w/.claude" && touch "$w/justfile"
generates "claude+justfile: exits 0" "$w"
check "claude+justfile: .claude read-only bind" \
  '.mounts | index("type=bind,source=\($w)/.claude,target=\($w)/.claude,readonly") != null'
check "claude+justfile: no .claude tmpfs" '[.mounts[] | select(startswith("type=tmpfs,target=\($w)/.claude"))] == []'
check "claude+justfile: justfile read-only bind" \
  '.mounts | index("type=bind,source=\($w)/justfile,target=\($w)/justfile,readonly") != null'

# --- Obsidian vault -----------------------------------------------------------
w=$(repo vault)
mkdir "$w/.obsidian"
generates "vault: exits 0" "$w"
check "vault: .obsidian read-only bind" \
  '.mounts | index("type=bind,source=\($w)/.obsidian,target=\($w)/.obsidian,readonly") != null'
check "vault: .claudian masked" '.mounts | index("type=tmpfs,target=\($w)/.claudian,notmpcopyup") != null'
owned "vault: .claudian pre-created, owned by the user" "$w/.claudian"
vid=$(printf %s "$w" | sha256sum | cut -c1-16)
bridge_dir="$XDG_RUNTIME_DIR/obsidian-bridge/$vid"
check "vault: bridge socket dir bound read-write at /run/obsidian-bridge" \
  '.mounts | index("type=bind,source=\($d)/run,target=/run/obsidian-bridge") != null' --arg d "$bridge_dir"
owned "vault: bridge socket dir pre-created, owned by the user" "$bridge_dir" "$bridge_dir/run"
if [ "$(stat -c %a "$bridge_dir")" = 700 ]; then ok "vault: bridge dir mode 700"
else bad "vault: bridge dir mode 700" "mode $(stat -c %a "$bridge_dir")"; fi
(unset XDG_RUNTIME_DIR; refuses "vault: no XDG_RUNTIME_DIR refused" "$w" "XDG_RUNTIME_DIR")

# --- repo with its own .devcontainer ------------------------------------------
w=$(repo owndc)
mkdir "$w/.devcontainer"
printf '{"image":"evil:latest","mounts":["type=bind,source=/,target=/host"],"privileged":true}\n' \
  > "$w/.devcontainer/devcontainer.json"
generates "own .devcontainer: exits 0" "$w"
check "own .devcontainer: read-only bind" \
  '.mounts | index("type=bind,source=\($w)/.devcontainer,target=\($w)/.devcontainer,readonly") != null'
check "own .devcontainer: ignored (image, mounts, privileged)" \
  '.image == "ghcr.io/butzo/arch-dev:aio" and (has("privileged") | not)
   and ([.mounts[] | select(contains("/host"))] == [])'

# --- no justfile / .obsidian / .devcontainer: no overlays for them -------------
w="$tmp/plain"
gen "$w"
check "plain: no overlays for absent optional paths" \
  '[.mounts[] | select(test("/(justfile|\\.obsidian|\\.devcontainer|\\.claudian)[,]|obsidian-bridge"))] == []'

# --- symlinked workspace resolves to the physical path ------------------------
ln -s "$tmp/plain" "$tmp/link"
w="$tmp/plain"
generates "symlink: exits 0" "$tmp/link"
check "symlink: physical path used" '.workspaceFolder == $w'

# --- refusals -----------------------------------------------------------------
refuses "path with ':' refused" "$(repo 'a:b')" "contains ',' or ':'"
refuses "path with ',' refused" "$(repo 'a,b')" "contains ',' or ':'"
mkdir "$tmp/wt" && echo 'gitdir: /elsewhere' > "$tmp/wt/.git"
refuses ".git file (worktree) refused" "$tmp/wt" "is not a directory"
mkdir "$tmp/nogit"
refuses "no .git refused" "$tmp/nogit" "is not a directory"
w=$(repo nohooks) && rm -rf "$w/.git/hooks"
refuses "missing .git/hooks refused" "$w" ".git/hooks is missing"
refuses "missing workspace refused" "$tmp/does-not-exist" "no such workspace"

# --- no mounts.env ------------------------------------------------------------
w="$tmp/plain"
DEVC_MOUNTS_ENV="$tmp/absent.env" generates "no mounts.env: exits 0" "$w"
check "no mounts.env: no personal mounts" '[.mounts[] | select(contains("/home/dev") or contains("/run/secrets"))] == []'
if grep -q "no personal mounts" "$err"; then ok "no mounts.env: NOTE on stderr"
else bad "no mounts.env: NOTE on stderr" "$(cat "$err")"; fi

# --- _guard: token gate and ~/.claude refusal (devc.just) ----------------------
export DEVC_CACHE="$tmp/cache"
w=$(repo guarded)
tok="$tmp/token"
# guard_env <mounts.env lines...>: write them as the mounts.env for _guard
guard_env() { printf '%s\n' "$@" > "$tmp/guard.env"; }
slot="DEVC_MOUNT_10=type=bind,source=$tok,target=/run/secrets/claude-oauth-token,readonly"
# guard <name> <pattern>: _guard must fail with <pattern> on stderr; "" = must pass
guard() {
  local out rc
  out=$(cd "$w" && DEVC_MOUNTS_ENV="$tmp/guard.env" just --justfile "$devc_dir/devc.just" _guard 2>&1) && rc=0 || rc=$?
  if [ -z "$2" ]; then
    if [ "$rc" -eq 0 ]; then ok "$1"; else bad "$1" "$out"; fi
  elif [ "$rc" -eq 0 ]; then bad "$1" "exited 0"
  elif grep -q -- "$2" <<<"$out"; then ok "$1"
  else bad "$1" "$out"; fi
}

guard_env 'DEVC_MOUNT_1=type=bind,source=${HOME}/.config/nvim,target=/home/dev/.config/nvim,readonly'
guard "guard: no token slot refused" "no mount in .* targets /run/secrets/claude-oauth-token"
guard "guard: no token slot prints the slot line" "echo 'DEVC_MOUNT_10="
guard_env "$slot"
guard "guard: missing token file refused" "token file $tok is missing"
guard "guard: missing token file prints setup-token" "claude setup-token"
install -m 600 /dev/null "$tok"
guard "guard: empty token file refused" "token file $tok is empty"
echo sk-test > "$tok" && chmod 644 "$tok"
guard "guard: mode 644 refused" "has mode 644, needs 600"
chmod 600 "$tok"
guard "guard: valid token passes" ""
guard_env "$slot" 'DEVC_MOUNT_9=type=bind,source=${HOME}/.claude,target=/claude-seed,readonly'
guard "guard: mount of ~/.claude refused" "mounts all of ~/.claude"
guard_env "$slot" 'DEVC_MOUNT_9=type=bind,source=${HOME}/.claude/,target=/claude-seed,readonly'
guard "guard: mount of ~/.claude/ refused" "mounts all of ~/.claude"
guard_env "$slot" 'DEVC_MOUNT_9=type=bind,source=${HOME}/.cache/devcontainer/claude-seed,target=/claude-seed,readonly'
guard "guard: staged seed mount passes" ""
w="$tmp/wt"
guard "guard: gen-config failure stops it" "is not a directory"

# --- obsidian-bridge serve: allowlist and validation (bridge/) -----------------
# A fake `obsidian` on PATH echoes its argv, one per line, or prints an
# Obsidian-style error (the real CLI exits 0 on errors).
bridge="$devc_dir/../bridge/obsidian-bridge"
client="$devc_dir/../bridge/obsidian-client"
fake="$tmp/fakebin"; mkdir -p "$fake"
cat > "$fake/obsidian" <<'EOF'
#!/usr/bin/env bash
if [ -n "${FAKE_OBSIDIAN_ERROR:-}" ]; then echo "Error: $FAKE_OBSIDIAN_ERROR"; exit 0; fi
if [ -n "${FAKE_OBSIDIAN_SLOW:-}" ]; then sleep "$FAKE_OBSIDIAN_SLOW"; fi
printf '%s\n' "$@"
EOF
chmod 755 "$fake/obsidian"
w=$(repo "my vault") && mkdir "$w/.obsidian" "$w/Notes" "$w/sub" "$w/confidential" "$w/.claude"
touch "$w/Notes/Old name.md" "$w/a.md" "$w/justfile" "$w/confidential/secret.md" "$w/.obsidian/x"
for d in .claudian .git/x .devcontainer .trash; do mkdir -p "$w/$d" && touch "$w/$d/x"; done
# Symlinks the container could plant: out of the vault, and into masked dirs.
ln -s /etc "$w/outside"; ln -s ../confidential "$w/sub/c"; ln -s .claude "$w/x"
# serve <request lines...>: one request through `serve`, output to $out
out="$tmp/serve.out"
serve() { printf '%s\n' "$@" | PATH="$fake:$PATH" "$bridge" serve "$w" > "$out" 2>&1; }
# accepts <name> <expected argv, one per line> <request lines...>
accepts() {
  local name=$1 want=$2; shift 2
  serve "$@"
  if [ "$(cat "$out")" = "$(printf '%s\n__status=0' "$want")" ]; then ok "$name"
  else bad "$name" "$(cat "$out")"; fi
}
# denies <name> <pattern> <request lines...>: refused with __status=1, obsidian not run
denies() {
  local name=$1 pat=$2; shift 2
  serve "$@"
  if ! grep -q '__status=1' "$out"; then bad "$name" "not refused: $(cat "$out")"
  elif ! grep -q -- "$pat" "$out"; then bad "$name" "message: $(cat "$out")"
  elif grep -q '^vault=' "$out"; then bad "$name" "obsidian was run: $(cat "$out")"
  else ok "$name"; fi
}
accepts "serve: ping answers pong" "pong" ping
accepts "serve: rename passes vault, path, name" \
  "$(printf 'vault=my vault\nrename\npath=Notes/Old name.md\nname=New name')" \
  rename "path=Notes/Old name.md" "name=New name"
accepts "serve: move passes vault, path, to" \
  "$(printf 'vault=my vault\nmove\npath=a.md\nto=Archive/b.md')" \
  move "path=a.md" "to=Archive/b.md"
accepts "serve: blank line ends the request" \
  "$(printf 'vault=my vault\nrename\npath=a.md\nname=b')" \
  rename "path=a.md" "name=b" "" "name=ignored"
denies "serve: eval refused" "not allowed" eval "code=1"
denies "serve: delete refused" "not allowed" delete "path=a.md"
denies "serve: file= refused (wikilink lookup, ambiguous)" "not allowed" rename "file=a" "name=b"
denies "serve: missing name refused" "missing" rename "path=a.md"
denies "serve: duplicate key refused" "duplicate" rename "path=a.md" "name=b" "name=c"
denies "serve: malformed line refused" "malformed" rename "path=a.md" "name"
denies "serve: empty value refused" "empty" rename "path=" "name=b"
denies "serve: absolute path refused" "absolute" rename "path=/etc/passwd" "name=b"
denies "serve: .. refused" "\.\." rename "path=../x.md" "name=b"
denies "serve: .. in to refused" "\.\." move "path=a.md" "to=sub/../../x"
denies "serve: slash in name refused" "name" rename "path=a.md" "name=sub/b"
denies "serve: backslash refused" "backslash" rename "path=a\\b.md" "name=b"
denies "serve: control character refused" "control" rename "path=$(printf 'a\tb.md')" "name=b"
for d in .obsidian .claudian confidential .git .claude .devcontainer .trash; do
  denies "serve: $d/ refused" "$d" rename "path=$d/x" "name=b"
  denies "serve: move into $d/ refused" "$d" move "path=a.md" "to=$d/x"
done
denies "serve: justfile refused" "justfile" rename "path=justfile" "name=b"
# Non-canonical forms must not slip past the first-component check.
denies "serve: ./ prefix refused" "canonical" rename "path=./confidential/secret.md" "name=b"
denies "serve: // refused" "canonical" rename "path=Notes//Old name.md" "name=b"
denies "serve: /./ refused" "canonical" rename "path=Notes/./Old name.md" "name=b"
denies "serve: trailing slash refused" "canonical" move "path=a.md" "to=sub/"
denies "serve: to=. refused" "canonical" move "path=a.md" "to=."
denies "serve: missing source refused" "not found" rename "path=Notes/nope.md" "name=b"
# Symlinks: the host resolves them, the container's masks do not apply there.
denies "serve: symlink out of the vault refused" "symlink" rename "path=outside/passwd" "name=b"
denies "serve: symlink into confidential/ refused" "symlink" rename "path=sub/c/secret.md" "name=b"
denies "serve: move into a symlink to .claude/ refused" "symlink" move "path=a.md" "to=x/commands/evil.md"
denies "serve: name=.. refused" "name" rename "path=a.md" "name=.."
denies "serve: name=. refused" "name" rename "path=a.md" "name=."
denies "serve: hidden name refused" "name" rename "path=a.md" "name=.hidden"
denies "serve: malformed command refused" "malformed" "ren ame" "path=a.md" "name=b"
denies "serve: oversize request refused" "large" rename "path=$(head -c 3000 /dev/zero | tr '\0' a).md" "name=$(head -c 3000 /dev/zero | tr '\0' b)"
if printf 'rename\npath=a.md\nname=b\n' | FAKE_OBSIDIAN_ERROR='File "a" not found.' PATH="$fake:$PATH" \
    "$bridge" serve "$w" > "$out" 2>&1 && grep -q '^Error: File "a" not found' "$out" && grep -q '__status=1' "$out"; then
  ok "serve: Error: output from obsidian gives __status=1"
else bad "serve: Error: output from obsidian gives __status=1" "$(cat "$out")"; fi
if [ -n "$(ls -A "$XDG_RUNTIME_DIR/obsidian-bridge/$(printf %s "$w" | sha256sum | cut -c1-16)/log" 2>&1)" ] \
    && grep -q 'rename' "$XDG_RUNTIME_DIR/obsidian-bridge/$(printf %s "$w" | sha256sum | cut -c1-16)/log"; then
  ok "serve: requests logged on the host"
else bad "serve: requests logged on the host" "no log"; fi

# --- obsidian-bridge ensure/stop + client: end to end over a real socket -------
# Needs a Unix socket; a Claude Code sandbox (allowUnixSockets empty) refuses
# that with EPERM, so the section is skipped there and runs on the host.
if { timeout 1 socat UNIX-LISTEN:"$tmp/probe" /dev/null 2>&1 || true; } | grep -q 'not permitted'; then
  printf '\033[33mSKIP\033[0m ensure/client tests: Unix sockets not permitted here (sandbox?); run on the host\n'
else
bid=$(printf %s "$w" | sha256sum | cut -c1-16)
sock="$XDG_RUNTIME_DIR/obsidian-bridge/$bid/run/sock"
ens="$tmp/ensure.out"
if PATH="$fake:$PATH" "$bridge" ensure "$w" > "$ens" 2>&1 && [ -S "$sock" ]; then ok "ensure: starts the listener"
else bad "ensure: starts the listener" "$(cat "$ens")"; fi
# A caller that pipes stdout/stderr (the Claudian wrapper's spawnSync) must
# get EOF back: the listener may not inherit the pipes.
# stop must not block on a lock the listener inherited.
if timeout 5 "$bridge" stop "$w" >/dev/null 2>&1; then ok "stop: returns while a listener was running (lock not inherited)"
else bad "stop: returns while a listener was running (lock not inherited)" "timed out"; fi
# This listener's fake obsidian also sleeps: the real CLI takes longer than
# socat's default 0.5 s post-EOF timeout, and the response must survive that.
if FAKE_OBSIDIAN_SLOW=1 PATH="$fake:$PATH" timeout 10 bash -c 'out=$("$1" ensure "$2" 2>&1); echo "$out"' _ "$bridge" "$w" > "$ens" 2>&1; then
  ok "ensure: returns to a caller that captures its output (listener detached)"
else bad "ensure: returns to a caller that captures its output (listener detached)" "timed out or failed: $(cat "$ens")"; fi
if grep -q alwaysUpdateLinks "$ens"; then ok "ensure: warns when alwaysUpdateLinks is off"
else bad "ensure: warns when alwaysUpdateLinks is off" "$(cat "$ens")"; fi
echo '{"alwaysUpdateLinks": true}' > "$w/.obsidian/app.json"
pid1=$(cat "$XDG_RUNTIME_DIR/obsidian-bridge/$bid/pid")
if PATH="$fake:$PATH" "$bridge" ensure "$w" > "$ens" 2>&1 && [ "$(cat "$XDG_RUNTIME_DIR/obsidian-bridge/$bid/pid")" = "$pid1" ] \
    && ! grep -q alwaysUpdateLinks "$ens"; then ok "ensure: idempotent, no warning when links update"
else bad "ensure: idempotent, no warning when links update" "$(cat "$ens")"; fi
if [ "$(stat -c %a "$sock")" = 600 ]; then ok "ensure: socket mode 600"; else bad "ensure: socket mode 600" "$(stat -c %a "$sock")"; fi
if [ "$(ls -A "$XDG_RUNTIME_DIR/obsidian-bridge/$bid/run")" = sock ]; then ok "ensure: mounted dir holds only the socket"
else bad "ensure: mounted dir holds only the socket" "$(ls -A "$XDG_RUNTIME_DIR/obsidian-bridge/$bid/run")"; fi
# client <name> <expected stdout> <expected exit> <args...>
cl() {
  local name=$1 want=$2 code=$3 got rc; shift 3
  got=$(OBSIDIAN_BRIDGE_SOCK="$sock" "$client" "$@" 2>&1) && rc=0 || rc=$?
  if [ "$got" = "$want" ] && [ "$rc" = "$code" ]; then ok "$name"
  else bad "$name" "exit $rc: $got"; fi
}
cl "client: ping" "pong" 0 ping
touch "$w/a b.md"
cl "client: rename round trip over a slow CLI, trailer stripped" "$(printf 'vault=my vault\nrename\npath=a b.md\nname=c d')" 0 rename "path=a b.md" "name=c d"
cl "client: refusal exits 1" "Error: refused: command not allowed: eval" 1 eval "code=1"
cl "client: non key=value argument" "obsidian: expected key=value, got: foo" 2 rename foo
if OBSIDIAN_BRIDGE_SOCK="$tmp/nosock" "$client" ping > "$out" 2>&1; then bad "client: missing socket" "exited 0"
elif grep -q "devc up" "$out" && [ "$("$client" help | head -c 8)" = "obsidian" ]; then ok "client: missing socket names devc up; help works"
else bad "client: missing socket names devc up; help works" "$(cat "$out")"; fi
if timeout 5 "$bridge" stop "$w" > "$ens" 2>&1 && [ ! -e "$sock" ] && ! kill -0 "$pid1" 2>/dev/null; then ok "stop: listener gone, socket removed"
else bad "stop: listener gone, socket removed" "$(cat "$ens")"; fi
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
