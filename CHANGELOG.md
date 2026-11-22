# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[Semantic Versioning](https://semver.org/) (0.x: commands and config may still change).

## [Unreleased]

## [0.5.0] - 2026-11-22

### Changed — fewer, simpler commands
- `titan create [node|python|go|rust|ruby|java]` replaces `setup`, `new` and `init`: run it in a
  folder you made (empty, or existing code). It detects or uses the named language (`@version`
  optional), writes `devcontainer.json`, starts the VM, and the first time sets up the Mac
  (container service, shell, VS Code, Claude Code). Starter code comes from the framework's own
  generator (`npm create vite@latest .`), which runs in the VM.
- `titan up --rebuild` replaces `rebuild`; `titan status` shows live CPU/memory (replaces
  `stats`) and `--all` lists every VM (replaces `ps`); `titan gc --cache` replaces `cache clean`.
- Removed `lock` (titan.lock is still written; delete it and `titan up --rebuild` to refresh),
  `vscode` and `agents` (now automatic in `titan create`).

## [0.4.0] - 2026-11-21

### Added — AI-ready
- Coding agents on the Mac (Claude Code, Codex, Cursor), scripts and Makefiles now run project
  commands in the VM too: smart shims in `~/.titan/shims`, first on `PATH` for every shell
  (`.zshenv`, `.zprofile`, bash profile), pick the VM inside a Titan project and the Mac
  elsewhere.
- `AGENTS.md` / `CLAUDE.md` notes for agents (commands run in the VM, ports, services, what not
  to do): written by `titan new`, offered by `titan init`, kept current by `titan up`,
  `titan agents [--remove]`.
- Claude Code on the Mac, in Titan projects: every Bash command runs in the VM (project paths
  translated; `git`/`gh`/`titan` stay on the Mac) and file writes outside the project are refused,
  via a PreToolUse hook added to `~/.claude/settings.json` (never auto-approves;
  `TITAN_NO_CLAUDE_HOOK=1` opts out).
- `--json` for `titan status` and `titan share --list`.

### Changed
- The shell hook works behind the scenes: `titan new`, `init` and `up` add it to `~/.zshrc` when
  it's missing (unless declined in `titan setup` or `TITAN_NO_SHELL_HOOK` is set), it prints
  nothing on `cd`, and `titan hook` is no longer listed in `titan --help`.

### Added — housekeeping
- Unused VMs stop by themselves after 2 hours (no attached session, no shared link, CPU near
  zero), freeing their memory; the next command starts them again. `"idleStop": "30m"` / `false`
  per project (no rebuild needed) or `TITAN_IDLE_STOP` for all projects.

## [0.3.2] - 2026-11-21

### Added
- `titan logs [service]`: a service's log (`-f`, `-n`), or the VM's boot log (`--boot`); also
  works inside the VM (without `-f`).

### Fixed
- Hot reload: edits made on the Mac never raised file events inside the VM, so Vite, Next,
  nodemon, `uvicorn --reload`… didn't reload. A background relay (started with the VM, stopped
  by `titan down`) now touches changed files inside the VM; verified with Vite HMR through a
  `titan share` tunnel. `TITAN_NO_FILE_RELAY=1` turns it off.

## [0.3.1] - 2026-11-21

### Added
- `titan` inside the VM (in `titan shell` and VS Code terminals): `share`, `status`, `ps`, `stats`,
  `lock` are run by titan on the Mac through the bridge; commands that change the Mac (`down`,
  `rebuild`, `gc`…) are refused there; `titan share` from the VM runs in the background.
- `titan share <port>` works for any port, not just `forwardPorts`: the tunnel goes straight to
  the VM (no Mac port, so no clash with Mac apps on the same port), with an on-demand forwarder
  for apps bound to 127.0.0.1; sharing an already-shared port returns its link.
- `titan vscode --global` also hides `.titan` from the editor's explorer and search
  (`files.exclude`, keeping other exclusions); `--show-titan-folder` / `--hide-titan-folder`
  toggle it.

## [0.3.0] - 2026-11-21

### Added
- `titan vscode --global`: VS Code terminals open inside the VM in every Titan project and stay
  on the Mac elsewhere (`titan shell --or-mac`); minimal edit of the user settings with a
  backup; `--remove` undoes it; `--editor cursor` for Cursor.
- `titan share` grows up: `--background` (survives closing the terminal; `--list`,
  `--stop`, shown in `titan ps`/`status`, closed by `titan down`), `--protect`/`--password`
  (visitors need a password), `--ttl`, several ports at once, a visit log (`--log`), a
  friendly "app isn't answering" page, and automatic reconnects. A new helper, `titan-gate`,
  sits in front of each tunnel.
- `titan share --domain dev.example.com` (**new, not yet tested against a real domain**): a
  stable address on your own Cloudflare domain (named tunnel + DNS record, never overwriting an
  existing record), remembered per project; `--always` brings it up with `titan up`.
- Project icon, README header with badges and a terminal demo, and a GitHub social preview
  image (`docs/assets/`, regenerated with `scripts/brand/render.sh`).
- `titan shell <name>` enters a VM from any folder: a project name (`shop`), VM name,
  service (`shop/postgres`) or path.

### Fixed
- Development builds couldn't find their helpers with newer SwiftPM (`.build/debug` is now a
  symlink into `.build/out`).

## [0.2.1] - 2026-11-21

### Fixed
- **`titan shell` froze in a real terminal:** the VM session ran in its own process group, so
  it couldn't read the keyboard and spun at 100% CPU. It now runs in titan's process group.

## [0.2.0] - 2026-11-20

### Added
- Step-by-step user guide (`docs/guide/`, 10 chapters) and an FAQ.
- `titan lock` shows every pin (app, services, toolchains).
- Opt-in **own Linux user** (`customizations.titan.user: "me"`): a user named after you,
  with your Mac uid, passwordless sudo, and the prompt `you@project:/workspaces/project$`;
  `titan run --root` / `titan shell --root` for root. The default stays root. The Dev
  Container `remoteUser` is now honored.
- Inside `titan shell`, `code`/`cursor`/`zed`/`subl <file>` open the file in that editor
  **on the Mac**; `open`/`xdg-open` and `$BROWSER` open the Mac's browser.

### Fixed
- In `titan shell`, login shells reset `PATH`, so projects using the shared toolchain store
  couldn't find `node`/`python` inside the shell.
- `titan lock --update` dropped service and toolchain pins from titan.lock; it now
  refreshes all of them.
- End-to-end test no longer assumes port 3000 is free.

## [0.1.0] - 2026-11-15

First public release.

### Added
- One Linux VM per project on Apple's `container` runtime, defined by `devcontainer.json`
  (image, build, ports, env, lifecycle commands) and pinned by digest in `titan.lock`.
- Zero-config detection for Node, Python, Go, Rust, Ruby and Java, including versions,
  package managers and framework ports; `titan init` saves it as a devcontainer.json.
- `titan setup`: installs Apple `container` (Homebrew), starts its service, adds the shell
  hook (asks first), runs a test VM.
- `titan new`: new project from templates (vite, next, node, fastapi, django, flask, python,
  go, rust); generators run inside the VM; plan with download sizes and a disk check first.
- Shell hook (zsh, bash): project commands run in the VM; fresh clones of projects with Titan
  config are routed on `cd` without `titan up`; `titan new` moves the shell into the project.
- In-VM port forwarder: dev servers bound to 127.0.0.1/::1 are reachable from the Mac; busy
  ports are remapped to the next free one.
- Services (`titan add postgres redis`, or any image): one VM each, reachable by name,
  `DATABASE_URL`/`REDIS_URL`, data on volumes kept across rebuilds.
- Shared toolchain store: Node and Python installed once per Mac and mounted read-only (Dev
  Container `features`), roughly half the disk of one image per runtime at native speed.
- Shared npm/pip/Go module cache across VMs.
- `titan share`: public HTTPS link via a Cloudflare quick tunnel.
- `titan status`, `titan ps`, `titan stats`, `titan doctor`, `titan gc`, `titan cache`,
  `titan lock`, `titan vscode`.

[Unreleased]: https://github.com/manoj1604/titan/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/manoj1604/titan/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/manoj1604/titan/compare/v0.3.2...v0.4.0
[0.3.2]: https://github.com/manoj1604/titan/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/manoj1604/titan/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/manoj1604/titan/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/manoj1604/titan/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/manoj1604/titan/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/manoj1604/titan/releases/tag/v0.1.0
