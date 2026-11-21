# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[Semantic Versioning](https://semver.org/) (0.x: commands and config may still change).

## [Unreleased]

### Added
- `titan share` grows up: `--background` (survives closing the terminal; `--list`,
  `--stop`, shown in `titan ps`/`status`, closed by `titan down`), `--protect`/`--password`
  (visitors need a password), `--ttl`, several ports at once, a visit log (`--log`), a
  friendly "app isn't answering" page, and automatic reconnects. A new helper, `titan-gate`,
  sits in front of each tunnel.
- `titan share --domain dev.example.com`: a stable address on your own Cloudflare domain
  (named tunnel + DNS record, never overwriting an existing record), remembered per
  project; `--always` brings it up with `titan up`.
- Project icon, README header with badges and a terminal demo, and a GitHub social preview
  image (`docs/assets/`, regenerated with `scripts/brand/render.sh`).
- `titan shell <name>` enters a VM from any folder: a project name (`shop`), VM name,
  service (`shop/postgres`) or path.

### Fixed
- **`titan shell` froze in a real terminal (0.2.0):** the VM session ran in its own process
  group, so it couldn't read the keyboard and spun at 100% CPU. It now runs in titan's process
  group (posix_spawn), verified with a real pseudo-terminal.
- Development builds couldn't find their helpers with newer SwiftPM (`.build/debug` is now a
  symlink into `.build/out`).

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

[Unreleased]: https://github.com/manoj1604/titan/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/manoj1604/titan/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/manoj1604/titan/releases/tag/v0.1.0
