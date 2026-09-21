#!/usr/bin/env bash
# Runs once, inside the container, after creation.
set -euo pipefail

# --- Claude Code config: disposable per-container copy ---------------------
# /claude-seed is the allowlisted copy `just up` stages from host ~/.claude
# (config only, incl. .git so `git status`/`git diff` inside shows what the
# agent changed). The copy is disposable: to keep a change, redo it on the
# host checkout and commit/push there (no credentials in here).
if [ ! -e "$HOME/.claude/.seeded" ] && [ -d /claude-seed ]; then
  mkdir -p "$HOME/.claude"
  cp -a /claude-seed/. "$HOME/.claude/"

  # Plugin registries hold absolute host paths (/home/<user>/.claude/plugins/...).
  for f in "$HOME/.claude/plugins/installed_plugins.json" "$HOME/.claude/plugins/known_marketplaces.json"; do
    if [ -f "$f" ]; then sed -i -E "s#\"/[^\"]*/\.claude/plugins/#\"$HOME/.claude/plugins/#g" "$f"; fi
  done

  # Global state stays container-local: nothing from the host ~/.claude.json
  # (other projects' metadata, host MCP servers). Just skip onboarding.
  if [ ! -f "$HOME/.claude.json" ]; then
    echo '{"hasCompletedOnboarding": true}' > "$HOME/.claude.json"
  fi

  cat >> "$HOME/.claude/CLAUDE.md" <<'EOF'

# Devcontainer isolation (container-only note)

You run inside a devcontainer that isolates confidential content.

- `confidential/`, `.git/git-crypt/` and, in Obsidian vaults, `.claudian/` are
  masked with empty mounts on purpose. They are not empty on the host. Do not
  try to read, restore, decrypt or work around them.
- Because of the masks, `git status` lists their tracked files as deleted.
  These deletions are not real. Never stage or commit them.
- Stage explicit paths only (`git add <path>...`). Never use `git add -A`,
  `git add .`, `git add -u` or `git commit -a`.
- Before every commit, run `git diff --cached --name-status`. If it shows any
  `D` entry under a masked path, unstage it with `git restore --staged <path>`.
- `.git/hooks`, `.git/config`, `.devcontainer/`, `justfile`, `.claude/` and
  `.obsidian/` may be read-only on purpose. Do not work around that.
EOF

  touch "$HOME/.claude/.seeded"
  echo "post-create: seeded ~/.claude from /claude-seed (allowlisted, disposable)"
fi

# Auth comes from /run/secrets/claude-oauth-token (see the claude wrapper in
# the image). A copied .credentials.json (older seeds) shares the host's
# rotating refresh token and logs host or container out, so drop it.
if [ -f "$HOME/.claude/.credentials.json" ]; then
  rm -f "$HOME/.claude/.credentials.json"
  echo "post-create: removed copied ~/.claude/.credentials.json (use the setup-token file)"
fi
if [ ! -r /run/secrets/claude-oauth-token ]; then
  echo "post-create: NOTE no /run/secrets/claude-oauth-token; run \`claude login\` here or set it up on the host"
fi

# --- Claude Code sandbox: container-local adjustments ----------------------
# Both edits land in the container's copy of ~/.claude/settings.json only; the
# host settings and the project's .claude/settings.json stay untouched.
workspace=$(cd "$(dirname "$0")/.." && pwd)
settings="$HOME/.claude/settings.json"
[ -f "$settings" ] || echo '{}' > "$settings"

# jq <args...> '<filter>' applied in place; non-zero (and untouched) on failure.
edit_settings() {
  local tmp
  tmp=$(mktemp "$HOME/.claude/.settings.XXXXXX")
  if jq "$@" "$settings" > "$tmp"; then mv "$tmp" "$settings"; else rm -f "$tmp"; return 1; fi
}

# 1. Nested sandbox: inside a container bwrap cannot mount a fresh procfs
#    ("Can't mount proc on /proc: Operation not permitted"), so every sandboxed
#    command fails. This upstream flag ("for Docker environments") binds the
#    existing /proc instead. It is the container's own /proc in the container's
#    PID namespace, so sandboxed commands see the container's processes rather
#    than only themselves; the podman boundary is unaffected.
if edit_settings '.sandbox.enableWeakerNestedSandbox = true'; then
  echo "post-create: sandbox enableWeakerNestedSandbox = true (nested in a container)"
else
  echo "post-create: WARNING — could not set sandbox.enableWeakerNestedSandbox;" \
       "sandboxed commands will fail to mount /proc" >&2
fi

# 2. The sandbox write-protects Claude Code's config paths, and for one that
#    does not exist yet it creates a placeholder to mount over. devcontainer.json
#    mounts the workspace .claude read-only, so that creation fails with
#    "Can't create file .../.claude/skills: Read-only file system". Naming the
#    directory itself in denyWrite makes the sandbox skip its missing children
#    ("already uncreatable") instead. Absolute path: `./` in user settings would
#    resolve to ~/.claude, not to the project.
if findmnt -rno OPTIONS -M "$workspace/.claude" 2>/dev/null | grep -qw ro; then
  if edit_settings --arg p "$workspace/.claude" \
      '.sandbox.filesystem.denyWrite = (((.sandbox.filesystem.denyWrite // []) + [$p]) | unique)'; then
    echo "post-create: sandbox denyWrite += $workspace/.claude (read-only overlay)"
  else
    echo "post-create: WARNING — could not add $workspace/.claude to" \
         "sandbox.filesystem.denyWrite; sandboxed commands will fail" >&2
  fi
fi

# --- tealdeer: populate the tldr page cache -------------------------------
command -v tldr >/dev/null && tldr --update >/dev/null 2>&1 || true

# --- Sanity: verify bwrap can actually sandbox in here --------------------
if command -v bwrap >/dev/null; then
  # --proc matters: mounting a fresh procfs is the step that fails when the
  # container's /proc is not fully visible, and Claude Code's sandbox does it
  # on every command. A plain --ro-bind probe passes while the sandbox is broken.
  if bwrap --dev-bind / / --proc /proc true 2>/dev/null; then
    echo "post-create: bwrap OK (nested userns and /proc mount available)"
  else
    echo "post-create: WARNING — bwrap failed. Claude Code with" \
         "failIfUnavailable=true will refuse to run commands." \
         "Check podman seccomp/caps." >&2
  fi
fi
