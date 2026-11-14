# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[Semantic Versioning](https://semver.org/) (0.x: commands and config may still change).

## [Unreleased]

## [0.1.0] - YYYY-MM-DD

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

[Unreleased]: https://github.com/OWNER/titan/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/OWNER/titan/releases/tag/v0.1.0
