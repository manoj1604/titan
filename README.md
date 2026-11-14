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
| `titan stats [--watch]` | Live CPU (sampled over an interval), memory vs. limit, disk and network I/O, image sizes. |
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
