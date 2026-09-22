#!/usr/bin/env bash
# Host-side tests for devc; no podman needed. Run: devc/tests/run.sh
# shellcheck disable=SC2016  # $w and \(...) in single quotes are jq's, not the shell's
set -uo pipefail

devc_dir=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/devc-tests.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

export DEVC_SHARE=/share/devc
export DEVC_MOUNTS_ENV="$tmp/mounts.env"
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
  '[.mounts[] | select(test("/(justfile|\\.obsidian|\\.devcontainer|\\.claudian)[,]"))] == []'

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
# just's shebang recipes need a writable runtime dir.
export XDG_RUNTIME_DIR="$tmp/rt" DEVC_CACHE="$tmp/cache"
mkdir -m 700 "$XDG_RUNTIME_DIR"
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

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
