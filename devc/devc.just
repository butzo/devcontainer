# Host recipes behind `devc`, run for the repo in the current directory:
#   devc <recipe>  =  just --justfile ~/.local/share/devc/devc.just --working-directory "$PWD" <recipe>
# Nothing in the repo configures the container: gen-config writes its
# devcontainer.json to ~/.cache/devc/<id>/ on every up.

engine := "podman"
# getcwd(), so already the physical path gen-config and the CLI labels use
ws := invocation_directory()
id := shell('printf %s "$1" | sha256sum | cut -c1-16', ws)
cfg := env("DEVC_CACHE", home_directory() / ".cache/devc") / id / "devcontainer.json"
export DEVC_MOUNTS_ENV := env("DEVC_MOUNTS_ENV", home_directory() / ".config/devcontainer/mounts.env")
token_target := "/run/secrets/claude-oauth-token"
# Claude Code config the container may see: an allowlisted copy of ~/.claude,
# mounted at /claude-seed by mounts.env. The rest of ~/.claude (projects/,
# file-history/, backups/, ...) holds every other project's transcripts.
seed_dir := "~/.cache/devcontainer/claude-seed"
seed_allow := ".git .gitignore CLAUDE.md settings.json AGENTS.md plugin.json marketplace.json agents commands ecc hooks plugins rules scripts skills"
dc := "--docker-path " + engine + " --workspace-folder " + quote(ws) + " --config " + quote(cfg)
this := quote("label=devcontainer.local_folder=" + ws)

# list recipes
_default:
    @just --justfile {{ quote(justfile()) }} --list --unsorted

# write this project's devcontainer.json (masks and overlays follow what exists now)
_config:
    @mkdir -p {{ quote(parent_directory(cfg)) }}
    @{{ quote(justfile_directory() / "gen-config") }} {{ quote(ws) }} > {{ quote(cfg + ".tmp") }} \
      && mv {{ quote(cfg + ".tmp") }} {{ quote(cfg) }}

# host preconditions, checked on the generated config: no mount of ~/.claude
# itself, and a usable OAuth token file (no token = unauthenticated container)
_guard: _config
    #!/usr/bin/env bash
    set -euo pipefail
    cfg={{ quote(cfg) }} target={{ token_target }} mounts_env="$DEVC_MOUNTS_ENV"
    err() { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; }
    src() { sed -nE 's/^(.*,)?(source|src)=([^,]+).*/\3/p'; }
    if jq -r '.mounts[]' "$cfg" | src | grep -qxE "$HOME/\.claude/?"; then
      err "$mounts_env mounts all of ~/.claude; point /claude-seed at {{ seed_dir }}"; exit 1
    fi
    # `|| true`: no token mount means grep matches nothing, which pipefail
    # would otherwise turn into a silent `set -e` exit right here.
    tok=$(jq -r '.mounts[]' "$cfg" | grep -E "(^|,)(target|dst|destination)=$target(,|$)" | src | head -n1) || true
    file=${tok:-$HOME/.config/devcontainer/claude-oauth-token}
    howto() {
      printf '  fix, on the host:\n' >&2
      printf '    claude setup-token    # copy the printed token\n' >&2
      printf '    install -m 600 /dev/stdin %s    # paste, then Ctrl-D\n' "$file" >&2
      if [ -z "$tok" ]; then
        printf "    echo 'DEVC_MOUNT_10=type=bind,source=\${HOME}/.config/devcontainer/claude-oauth-token,target=%s,readonly' >> %s\n" \
          "$target" "$mounts_env" >&2
      fi
      exit 1
    }
    if [ -z "$tok" ]; then err "no mount in $mounts_env targets $target"; howto; fi
    if [ ! -f "$tok" ]; then err "token file $tok is missing"; howto; fi
    if [ ! -s "$tok" ]; then err "token file $tok is empty"; howto; fi
    mode=$(stat -c %a "$tok")
    if [ "$mode" != 600 ]; then
      err "token file $tok has mode $mode, needs 600"; printf '  fix: chmod 600 %s\n' "$tok" >&2; exit 1
    fi

# stage the allowlisted Claude Code config for /claude-seed (host side)
_seed:
    #!/usr/bin/env bash
    set -euo pipefail
    [ -d ~/.claude ] || exit 0
    mkdir -p {{ seed_dir }}
    filters=()
    for p in {{ seed_allow }}; do filters+=(--include="/$p"); done
    rsync -a --delete --delete-excluded "${filters[@]}" --exclude='/*' ~/.claude/ {{ seed_dir }}/
    chmod 700 {{ seed_dir }}  # rsync -a copies ~/.claude's mode onto it

# start-if-needed + check isolation + enter: the daily one
dev: up verify-isolation enter

# create or start the container; restarts it if a file overlay went stale
up: _guard _seed
    #!/usr/bin/env bash
    set -euo pipefail
    # A single-file bind pins an inode. Host git replaces .git/config by
    # rename (config.lock), editors may do the same to justfile; the path then
    # resolves to the new, writable file through the workspace mount. A
    # restart binds the current file again; a recreate is not needed.
    ws={{ quote(ws) }}
    stale() {
      for p in .git/config justfile; do
        [ -e "$p" ] || continue
        [ -n "$({{ engine }} exec "$1" findmnt -rno OPTIONS -M "$ws/$p" 2>/dev/null)" ] || echo "$p"
      done
    }
    cid=$({{ engine }} ps --filter label=devc.managed=true --filter {{ this }} --filter status=running -q | head -n1) || true
    if [ -n "$cid" ]; then
      # A path that appeared after creation has no bind spec: restart can't
      # help. (.claude is left out: absent at creation it is a read-only
      # tmpfs, which covers a later host .claude too.)
      specs=$({{ engine }} container inspect "$cid" | jq -r '.[0].Mounts[].Destination')
      for p in .git/config justfile .obsidian .devcontainer; do
        if [ -e "$p" ] && ! grep -qxF "$ws/$p" <<<"$specs"; then
          printf '\033[31mERROR\033[0m %s has no read-only overlay (added after the container was created); run: devc rebuild\n' "$p" >&2
          exit 1
        fi
      done
    fi
    restarted=
    if [ -n "$cid" ] && gone=$(stale "$cid") && [ -n "$gone" ]; then
      for p in $gone; do
        printf '\033[33mNOTE\033[0m %s was replaced on the host (git and some editors rewrite by rename), so its\n' "$p" >&2
        printf '     read-only overlay no longer covers it and the agent could write it.\n' >&2
      done
      printf '     Restarting the container to re-apply the overlay.\n' >&2
      {{ engine }} restart "$cid" >/dev/null
      restarted=1
    fi
    out=$(devcontainer up {{ dc }} 2>&1) || { printf '%s\n' "$out" >&2; exit 1; }
    if [ -n "$restarted" ] && gone=$(stale "$cid") && [ -n "$gone" ]; then
      printf '\033[31mERROR\033[0m still no read-only overlay after restart: %s\n' "$gone" >&2
      exit 1
    fi

# open zsh in the running container
enter:
    @devcontainer exec {{ dc }} zsh

# stop the container (its state is kept)
stop:
    {{ engine }} ps --filter label=devc.managed=true --filter {{ this }} -q | xargs -r {{ engine }} stop

# recreate the container (picks up a new image, new overlays, changed mounts.env)
rebuild: _guard _seed
    devcontainer up {{ dc }} --remove-existing-container

# pull latest weekly image, then recreate
update: && rebuild
    {{ engine }} pull ghcr.io/butzo/arch-dev:aio

# escape hatch if the devcontainer CLI misbehaves
raw-enter:
    {{ engine }} exec -it $({{ engine }} ps --filter label=devc.managed=true --filter {{ this }} -q | head -1) zsh

# check masks (empty tmpfs) and overlays (own read-only mount); errors are FAIL
verify-isolation:
    @devcontainer exec {{ dc }} bash -c '\
      ok()   { printf "\033[32mOK  \033[0m %s\n" "$*"; }; \
      warn() { printf "\033[33mWARN\033[0m %s\n" "$*"; }; \
      fail() { printf "\033[31mFAIL\033[0m %s\n" "$*"; rc=1; }; \
      mask() { fs=$(stat -f -c %T "$1" 2>&1); \
        if [ "$fs" != tmpfs ]; then fail "$1/ not a tmpfs mask ($fs)"; \
        elif ! entries=$(ls -A "$1" 2>&1); then fail "$1/ unreadable: $entries"; \
        elif [ -n "$entries" ]; then fail "$1/ has content (tmpcopyup?)"; \
        else ok "$1/ empty tmpfs"; fi; }; \
      ro() { opts=$(findmnt -rno OPTIONS -M "$1" 2>/dev/null); \
        if [ -z "$opts" ]; then fail "$1 has no read-only overlay"; \
        else case ",$opts," in *,ro,*) ok "$1 read-only";; *) fail "$1 mounted read-write";; esac; fi; }; \
      rc=0; \
      for p in confidential .git/git-crypt; do mask "$p"; done; \
      for p in .git/hooks .git/config .claude; do ro "$PWD/$p"; done; \
      for p in .devcontainer justfile; do if [ -e "$p" ]; then ro "$PWD/$p"; fi; done; \
      if [ -e .obsidian ]; then ro "$PWD/.obsidian"; mask .claudian; fi; \
      ro /opt/devc; \
      if [ -s /run/secrets/claude-oauth-token ]; then ok "OAuth token mounted"; else fail "no OAuth token at /run/secrets/claude-oauth-token"; fi; \
      for d in projects file-history session-data backups; do \
        if [ -e "/claude-seed/$d" ]; then fail "/claude-seed/$d visible (seed not staged)"; fi; \
      done; \
      f=$(git ls-tree -r --name-only HEAD -- confidential 2>/dev/null | head -1); \
      if [ -z "$f" ]; then warn "no committed confidential files to check"; \
      elif git cat-file blob "HEAD:$f" 2>/dev/null | head -c 10 | grep -qa GITCRYPT; then ok "committed blobs are ciphertext"; \
      else warn "could not confirm ciphertext ($f)"; fi; \
      if [ $rc -ne 0 ]; then echo "overlays follow what existed at creation; after adding one of these paths, run: devc rebuild"; fi; \
      exit $rc'
