# Titan

**Every project gets its own Linux micro-VM on your Mac, with zero setup.**
It ends "works on my machine" by giving every developer, CI and AI agent the same
pinned environment, without Docker Desktop.

Titan is built on Apple's [`container`](https://github.com/apple/container) runtime,
which runs each Linux container in its own lightweight VM on Apple silicon.

```console
$ cd my-node-app
$ titan up
▸ Pulling node:20-bookworm
▸ Creating VM titan-my-node-app-3f2a91c0 from node:20-bookworm
▸ postCreate: npm ci
✓ my-node-app is running in titan-my-node-app-3f2a91c0
  config   detected: node (package.json, .nvmrc, package-lock.json)
  ports    http://localhost:3000
  shims    node npm npx

$ npm test        # with the shell hook, this runs inside the VM
```

## Requirements

- Apple silicon Mac, macOS 26 or later
- Apple's `container` CLI: install the signed package from
  [github.com/apple/container/releases](https://github.com/apple/container/releases)
- Swift 6 toolchain (Xcode 16+) to build

## Install

```sh
make install                     # builds release and copies to /usr/local/bin
echo 'eval "$(titan hook zsh)"' >> ~/.zshrc   # or: titan hook bash
titan doctor
```

## Commands

| Command | What it does |
|---|---|
| `titan up [--rebuild]` | Create or start the project VM. Works with **no config**: detects Node, Python, Go, Rust, Ruby, Java. |
| `titan run -- <cmd>` | Run a command in the VM. Starts it if needed. Your cwd and absolute paths are mapped into the VM. |
| `titan shell` | Interactive shell in the VM. |
| `titan down [--rm]` | Stop (or delete) the VM. |
| `titan rebuild` | Recreate the VM from the current config. |
| `titan status` / `titan doctor` | What's configured and running, and what's missing. |
| `titan ps [--all] [--json]` | Every Titan VM on this Mac: project, folder, status, memory, localhost ports, services. |
| `titan stats [--watch]` | Live CPU (sampled over an interval), memory vs. limit, disk and network I/O, image sizes. |
| `titan gc [--all] [--dry-run]` | Delete images no project or VM needs (keeps images pinned by projects you've `titan up`'d). |
| `titan new <name> [-t template] [--with postgres]` | New project: folder, git, devcontainer, pinned images, VM, starter code (generated inside the VM), then cds you in. |
| `titan add postgres redis` | Add services: each in its own VM, reachable by name, data kept across rebuilds. |
| `titan share [PORT] [--copy]` | Public HTTPS link to the app via a Cloudflare quick tunnel (needs `cloudflared`; closes on Ctrl-C). |
| `titan cache [clean]` | Show or clear the package cache shared by all VMs. |
| `titan init` | Write a standard `.devcontainer/devcontainer.json` from detection. |
| `titan lock [--update]` | Show or refresh the image digest pinned in `titan.lock`. |
| `titan hook zsh\|bash` | Shell integration: `cd` into a project and its tools route to the VM. |
| `titan vscode` | Make VS Code's integrated terminal open inside the VM. |

Every command accepts `-C <dir>`, `--verbose` and `--dry-run` (print the `container`
commands instead of running them).

## How it works

```
 terminal / VS Code terminal / AI agent
        │   npm test   (shim in .titan/bin, put first on PATH by the shell hook)
        ▼
 titan run ──► container exec --workdir /workspaces/app/<your cwd> <vm> npm test
        │
 per-project micro-VM  ◄── image pinned by digest in titan.lock
   /workspaces/app  ◄── your checkout, shared over virtiofs
   127.0.0.1:3000   ◄── forwardPorts published to the Mac
```

- **Config:** Titan reads the standard Dev Container format (`.devcontainer/devcontainer.json`
  or `.devcontainer.json`), so the same file works with VS Code Dev Containers and Codespaces
  for teammates who aren't on Titan. Supported today: `image`, `build.dockerfile/context/args`,
  `forwardPorts`, `containerEnv`, `remoteEnv`, `workspaceFolder`, `postCreateCommand`,
  `postStartCommand`, plus Titan-specific settings:

  ```jsonc
  "customizations": { "titan": { "shims": ["node", "npm"], "cpus": 4, "memory": "8G" } }
  ```

- **Reproducibility:** the first `titan up` writes `titan.lock` with the image digest.
  Commit it, and every machine pulls the exact same bits.
- **Drift detection:** Titan hashes the resolved environment, including Dockerfile
  contents. If the config changes, a stopped VM is recreated automatically and a running
  VM shows a warning telling you to run `titan rebuild`.
- **Shims:** `.titan/bin/<tool>` runs `titan run -- <tool>`. Set `TITAN_DISABLE=1`
  to fall through to the host binary for one command.
- **State:** `.titan/` is machine-local and ignores itself in git; `titan.lock` is meant to be committed.

## Project layout

```

By default a new VM gets half your Mac's RAM, capped at 8 GB (Apple `container` alone defaults to 1 GB, which kills Rust and Java builds). Set `memory` to override it.

Sources/TitanCore/
  Config/        devcontainer.json (JSONC) parsing, environment resolution + hashing
  Detection/     zero-config stack detection
  Project/       project discovery, VM naming, host↔guest path mapping, state + lockfile
  Runtime/       ContainerRuntime protocol + Apple `container` CLI backend
  Engine/        up / run / shell / down orchestration
  Integrations/  shims, zsh/bash hook, VS Code terminal profile
Sources/titan/   CLI (swift-argument-parser)
Tests/           swift-testing suite, using a fake runtime (no VM needed)
```

## Roadmap

- **v0.2: Never broken.** `titan doctor` diffing against teammates and CI, snapshots and restore, `titan db reset`
- **v0.3: Unique.** Per-branch environments, database branching, AI-agent sandbox mode, native VS Code extension
- **v0.4: Share.** `titan share` reproducible bug bundles, `titan review <PR>`, `titan expose`, local CI
- Native backend on `Containerization.framework` (replacing the CLI shell-out), compose / multi-service,
  automatic HTTPS, `*.titan.local` DNS

## Shared package cache

Every VM mounts `~/Library/Caches/titan/shared` at `/titan-cache`, and `npm`, `pip` and Go modules
are pointed at it, so a package is downloaded once per Mac instead of once per project
(measured: `npm ci` 0.9s warm vs 2–4.5s cold; pip installed 22 packages with zero downloads).

Only caches that stay consistent **without file locks** are shared: `flock` on a virtiofs mount is
not honoured across VMs, so lock-based caches (cargo, gradle, maven, uv, the Go build cache) stay
inside each VM. Opt out per project with `"customizations": {"titan": {"sharedCache": false}}`;
a project's own `containerEnv` (e.g. `PIP_CACHE_DIR`) always wins.

## Ports

Dev servers that listen only on `127.0.0.1` / `localhost` (Vite, Django, Flask, Rails…) work
without `--host` flags: Apple's container port publishing only reaches the VM's network
interface, so Titan mounts a tiny static forwarder (`forwarder/`, Go, ~2 MB) read-only into
the VM, publishes each Mac port to it (VM ports 61000+), and it relays to wherever the app
listens (127.0.0.1, ::1, or 0.0.0.0). It never takes the app's own port. Building it needs Go
(`make install`).


Each port in `forwardPorts` is published on `localhost`. If it's already taken (another project's VM
or a local app), Titan picks the next free port above it and says so: `http://localhost:3001 (→ 3000 in VM)`.
The app inside the VM still listens on its usual port, and `titan status` shows the mapping. A stopped
VM whose port was taken in the meantime is recreated with a free one. Set
`"customizations": {"titan": {"strictPorts": true}}` to fail instead.

## Services

```jsonc
"customizations": { "titan": {
  "services": ["postgres", "redis"]            // presets, or:
  // "services": { "db": "postgres:15",
  //               "search": { "image": "getmeili/meilisearch:v1.8", "port": 7700, "data": "/meili_data" } }
}}
```

- Each service runs in **its own VM**, started before the app (so `postCreateCommand` can run migrations).
- The app reaches it **by name** (`postgres:5432`). Apple's container network has no DNS between VMs and
  assigns new IPs on every start, so Titan rewrites the app VM's `/etc/hosts` on each `titan up`.
- Presets set `DATABASE_URL` / `REDIS_URL` for the app (your own `containerEnv`/`remoteEnv` wins).
- Data lives on a named volume: it survives `titan rebuild` and `titan down --rm`; only
  `titan down --volumes` deletes it.
- Ports are also published on `localhost` (remapped if busy) for GUI tools like TablePlus.
- Service images are pinned in `titan.lock` next to the app image; adding a service never rebuilds the app VM.

Presets: `postgres` (16, user/password `postgres`, db `app`), `redis` (7).

## Joining a project: clone, cd, work

With the hook installed (`eval "$(titan hook zsh)"` in `~/.zshrc`), a teammate never runs `titan up`:

```
$ git clone …/shop-api && cd shop-api
titan: shop-api → VM (node npm npx)  first command sets it up (~1 min)
$ npm test
▸ Setting up shop-api (first run; later runs start instantly)…
✓ shop-api is ready
# pass 3
```

- Projects that **opted in** (committed `titan.lock` or a devcontainer.json) are routed on `cd`:
  the hook runs `titan activate`, which writes the shims without starting the VM (~10 ms).
  It re-activates when the config is newer than the shims (e.g. after a `git pull`).
- The first command sets the VM up with visible progress; after that, shims are silent.
- Plain repos (only `package.json` etc.) get a one-time hint, never silent takeover.
- Zero-config ports follow the framework: Vite/SvelteKit 5173, Angular 4200, Astro 4321,
  Next/Express 3000, Flask 5000 (+8000), Django/FastAPI 8000.
- `TITAN_QUIET=1` silences the hook; `TITAN_DISABLE=1` runs commands on the Mac.

## Starting a new project

```
$ titan new shop --template vite --with postgres
  shop  (Vite + React + TypeScript)
  runtime   Node 22      node:22-bookworm         on this Mac
  service   postgres     postgres:16-bookworm     ↓ ~160 MB
  disk      ~640 MB needed, 4.6 GB free ✓
Create shop? [Y/n]
…
✓ shop is ready → http://localhost:5173
  Next: npm run dev            # (the shell hook already moved you into shop/)
```

- Templates: `vite`, `next`, `node`, `fastapi`, `django`, `flask`, `python`, `go`, `rust`
  (no `--template` on a terminal shows a picker).
- Versions come from Titan's catalog (Node 22 LTS, Python 3.12, Go 1.23, Postgres 16, Redis 7);
  `--runtime-version 20` overrides. Everything is pinned in `titan.lock` from the first commit.
- Generators (`npm create vite`, `django-admin`, `cargo new`…) run **inside the VM**: the Mac
  needs no Node/Python/Go. Downloads and disk are shown first; low disk stops before pulling.
- `titan new .` in a folder with code detects the stack instead of generating over it.
