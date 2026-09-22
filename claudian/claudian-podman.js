#!/usr/bin/env node
'use strict';

// Claudian "Claude CLI path" target: runs `claude` inside the vault's devc
// container (`devc up`). The SDK spawns this via `node <path>`, so
// it must stay a .js file. stdout carries stream-json: never write to it.

const { spawnSync, spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const cwd = process.cwd();
const CLAUDE_IN_CONTAINER = process.env.CLAUDIAN_CLAUDE_BIN || 'claude';
const DEBUG = process.env.CLAUDIAN_WRAPPER_DEBUG;

const log = (...a) => {
  if (!DEBUG) return;
  const line = `[wrapper ${new Date().toISOString()}] ${a.join(' ')}\n`;
  try { fs.appendFileSync(DEBUG, line); } catch { process.stderr.write(line); }
};

const die = (msg, code = 127) => {
  process.stderr.write(`claudian-podman: ${msg}\n`);
  process.exit(code);
};

const podman = (args) => {
  const r = spawnSync('podman', args, { encoding: 'utf8' });
  if (r.error) die(`cannot run podman: ${r.error.message}`);
  return r;
};

// --- preflight -------------------------------------------------------------
// The devcontainer CLI labels containers with the host workspace path; with
// path identity that is Claudian's cwd (or a parent of it). devc.managed
// skips leftovers of the old in-repo template (podman ANDs label filters).
const findContainer = () => {
  if (process.env.CLAUDIAN_CONTAINER) return process.env.CLAUDIAN_CONTAINER;
  for (let dir = cwd; ; dir = path.dirname(dir)) {
    const r = podman(['ps', '-a', '-q', '--filter', 'label=devc.managed=true',
      '--filter', `label=devcontainer.local_folder=${dir}`]);
    const id = r.stdout.trim().split('\n')[0];
    if (id) return id;
    if (dir === path.dirname(dir)) die(`no devc container for ${cwd}; run \`devc up\` there first`);
  }
};

const CONTAINER = findContainer();

const state = podman(['container', 'inspect', '-f', '{{.State.Status}}', CONTAINER]);
if (state.status !== 0) die(`container "${CONTAINER}" not found`);
if (state.stdout.trim() !== 'running') {
  // Restarting keeps the container's masks and overlays; nothing to re-check.
  log('starting', CONTAINER, 'from state', state.stdout.trim());
  const start = podman(['start', CONTAINER]);
  if (start.status !== 0) die(`cannot start "${CONTAINER}": ${start.stderr.trim()}`);
}

// Stale file overlays: host git replaces .git/config by rename (editors may do
// the same to justfile), which leaves the container's read-only bind over a
// deleted inode and the path writable. Only `devc up` restarts to fix that:
// restarting from here would kill a running agent session.
const ws = podman(['container', 'inspect', '-f',
  '{{index .Config.Labels "devcontainer.local_folder"}}', CONTAINER]).stdout.trim();
if (!ws) die(`container "${CONTAINER}" has no devcontainer.local_folder label`);
for (const p of ['.git/config', 'justfile']) {
  const target = path.join(ws, p);
  if (p !== '.git/config' && !fs.existsSync(target)) continue;
  const m = podman(['exec', CONTAINER, 'findmnt', '-rno', 'OPTIONS', '-M', target]);
  if (!m.stdout.trim()) {
    die(`${p} was replaced on the host (git and some editors rewrite by rename), so its ` +
        'read-only overlay no longer covers it and the agent could write it. ' +
        `Run \`devc up\` in ${ws} to restart the container.`);
  }
}

// Path identity: the vault must resolve to the same absolute path inside.
if (podman(['exec', CONTAINER, 'test', '-d', cwd]).status !== 0) {
  die(`cwd not visible inside container: ${cwd}`);
}

// --- environment -----------------------------------------------------------
// Forward only what the SDK sets. Never --env-host. Names only: podman reads
// the values from its own env, so tokens stay out of argv (visible in ps).
const ENV_PREFIXES = [/^CLAUDE_/, /^ANTHROPIC_/];
const ENV_EXACT = ['LANG', 'LC_ALL', 'TERM'];

const envNames = Object.keys(process.env)
  .filter(k => ENV_PREFIXES.some(re => re.test(k)) || ENV_EXACT.includes(k));

// --- exec ------------------------------------------------------------------
const args = [
  'exec', '-i',
  '--workdir', cwd,
  '-e', 'HOME=/home/dev',
  ...envNames.flatMap(k => ['-e', k]),
  CONTAINER,
  CLAUDE_IN_CONTAINER,
  ...process.argv.slice(2),
];

log('container:', CONTAINER);
log('cwd:', cwd);
log('env:', envNames.join(' '));
log('argv:', process.argv.slice(2).join(' '));

const child = spawn('podman', args, { stdio: 'inherit' });

for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
  process.on(sig, () => {
    log('forwarding', sig);
    child.kill(sig);
  });
}

child.on('error', err => die(`spawn failed: ${err.message}`));
child.on('exit', (code, sig) => {
  log('exit', code, sig);
  if (sig) process.exit(128 + (require('os').constants.signals[sig] || 15));
  process.exit(code ?? 1);
});
