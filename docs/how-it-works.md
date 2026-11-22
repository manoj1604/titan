# How it works

```
 Mac                                         Linux VMs (Apple container)
 ───────────────────────────────            ────────────────────────────────────
 ~/code/shop/  (your editor)  ── virtiofs ──▶ /workspaces/shop   VM "titan-shop-…"
 $ npm test                                   npm test ◀── container exec
   └ .titan/bin/npm (shim) ── titan run ──────┘
 localhost:5173 ── published port ──▶ :61000 titan-fwd ──▶ 127.0.0.1:5173 (Vite)
                                       VM "titan-shop-…-postgres"  ◀── /etc/hosts "postgres"
 ~/Library/Caches/titan/shared ─ virtiofs ─▶ /titan-cache (npm, pip, Go modules)
 volume titan-tool-node-22-… ── read-only ──▶ /opt/titan/tools/node
```

## One VM per project

Titan drives Apple's `container` CLI. Each project gets a VM named
`titan-<folder>-<hash of path>`, so two clones of the same repo get separate VMs. The VM:

- mounts the project folder at `workspaceFolder` (virtiofs, so edits on the Mac appear
  instantly)
- keeps running an idle loop, so commands start in about 0.15 s via `container exec`
- is an APFS clone of its image, costing about 19 MB of real disk per VM
- gets half your RAM as its limit, at most 8 GB. Apple `container` defaults to 1 GB, which
  kills Rust, Java and webpack builds. RAM is only used as needed, but a VM doesn't return
  memory to macOS until it stops.

**Project discovery** walks up from the current folder. The nearest `devcontainer.json`,
`titan.lock` or `.titan/bin` wins. Otherwise, within the git repository, Titan picks the
**highest** folder that has a language manifest, so a workspace root beats its member
packages while unrelated apps in a monorepo get their own VMs.

**Drift detection:** the resolved environment is hashed. When the config changes, a stopped
VM is recreated on the next `up`, and a running one gets a warning.

## The user in the VM

Commands run as root by default (or the spec's `remoteUser`). With `"user": "me"`, Titan
runs them as a Linux user named after you instead. When the VM is created, Titan (as root)
creates that user with your Mac uid, adds a passwordless sudoers entry, hands it `/usr/local` (so global
installs work without sudo), and puts the project name in the prompt. Apple `container`
can't change a VM's hostname, so the prompt shows the project instead. Every `container exec`
then passes `--user` plus `HOME`/`USER`. The state file records that the user exists, so
older VMs without it keep using root instead of failing.

## Commands in the VM: shims and the shell hook

`titan run -- <cmd>` maps your current folder and any absolute paths inside the project into
the VM, then **replaces itself** with `container exec` (via `execvp`). That way the TTY, stdin,
signals (Ctrl-C) and the exit code behave exactly as if the command ran locally.

The shell hook (`titan hook zsh|bash`) puts `.titan/bin` first on `PATH` inside a project. That
folder holds small shim scripts (`npm` → `titan run --shim -- npm …`). On `cd` into a project
that has committed Titan config but no shims yet (a fresh clone), the hook runs
`titan activate`, which writes the shims **without** starting the VM, in about 10 ms. The first
real command then sets up the VM, showing progress. Folders without Titan config only get a
one-time hint, and Titan never takes them over silently.

## Opening the Mac editor from inside the VM

`titan shell` doesn't replace itself with `container exec` like `titan run` does. It runs
the session as a child, so it can serve requests from inside the VM while the session lasts.
The channel is a mailbox folder in the project (`.titan/open/`), visible in the VM through
the workspace mount, so there's no network listener and no firewall prompt.

Helper scripts in `.titan/vm-bin/` (`code`, `cursor`, `zed`, `subl`, `open`, `xdg-open`,
first on `PATH` in the session, with `$BROWSER` pointing at `xdg-open`) write a request with a
per-session token. The Mac side checks the token, maps `/workspaces/<project>/…` back to the
project folder, and runs the editor or `open` directly (no shell). Only project files and
http(s) URLs are accepted.

Login shells reset `PATH` from `/etc/profile`, so Titan passes the VM's `PATH` as
`TITAN_PATH` and restores it from `/etc/profile.d/zz-titan-path.sh`. That keeps the toolchain
store and the helpers on `PATH` in `titan shell`.

## Ports: the in-VM forwarder

Apple `container` publishes a Mac port to the VM's **network interface**, so an app bound to
`127.0.0.1` inside the VM is unreachable. That's the default for Vite, Django, Flask and
Rails. Titan mounts a small static forwarder (`forwarder/`, Go, about 2 MB) read-only at
`/opt/titan/fwd`. It publishes each Mac port to a forwarder port (61000 and up), and relays
every connection to the app at `127.0.0.1`, then `::1`, then the VM's own addresses. It never
binds the app's own port, so apps that bind `0.0.0.0` still start normally.

If a port is busy on the Mac, Titan publishes the next free one and says so
(`localhost:5174 → 5173 in VM`). `titan status` and `titan status --all` show the mapping.

## Services

Each service (`postgres`, `redis`, or any image) runs in its own VM, started **before** the app,
so `postCreateCommand` can run migrations. Its data lives on a named volume that survives
`titan up --rebuild`.

Apple's container network has **no DNS between VMs**, and a VM gets a **new IP on every
start**. So on every `titan up`, Titan rewrites the marked lines of the app VM's `/etc/hosts`
with the current IPs, and the app reaches `postgres` by name. Readiness is checked inside the
service VM by reading `/proc/net/tcp`, which needs no tools in the image.

## Shared toolchain store

Configs that ask for Node or Python as a standard Dev Container feature on top of a base image
(`buildpack-deps:bookworm`) plus a toolchain requested as a standard Dev Container feature.
Each exact toolchain build is:

1. copied once from its official slim image (`node:22-bookworm-slim`), pinned by digest
2. into a content-addressed volume (`titan-tool-node-22-<digest>`). Python's `.pyc` files are
   compiled at this point, because without them imports from a read-only store were 3–4×
   slower
3. mounted **read-only** into every VM that uses it, so several VMs share one volume

Writable places cover what a read-only store can't hold: a Python virtualenv at
`/opt/titan/venv`, and npm globals and corepack shims in `/root/.npm-global`. Filling is
serialized with a lock on the Mac, and a "ready" marker detects half-filled volumes.

**Measurements** (Node 22, Python 3.12):

| | Baked-in image | Shared folder (virtiofs) | Read-only volume (Titan) |
|---|---|---|---|
| `npm test` | 281 ms | 392 ms | **280 ms** |
| `pytest` | 134 ms | 187 ms | **132 ms** |
| Disk, Node + Python | ~3.0 GB | | **~1.6 GB** |
| Each extra Node version | ~1.6 GB | | **~0.19 GB** |

## Shared package cache

`~/Library/Caches/titan/shared` is mounted at `/titan-cache` in every VM, and npm, pip and
Go modules use it, so each package is downloaded once per Mac. In tests, a warm cache took
`npm ci` from 2–4.5 s down to 0.9 s.

Only caches that stay consistent **without file locks** are shared. `flock` on a virtiofs
folder is not honored across VMs (tested: a second VM acquired a lock the first one held),
so lock-based caches stay inside each VM: cargo, gradle, maven, uv and the Go build cache.

## Garbage collection

`titan up` records each project in `~/Library/Application Support/titan/projects.json`.
`titan gc` keeps images used by any VM or pinned by a known project. It removes the rest of
the images Titan created, plus toolchain volumes no project pins, and it asks first.

## Design decisions

- **Apple `container`, not Docker.** It's open source and ships with macOS-native
  virtualization, and every VM has its own kernel. Titan shells out to its CLI behind a
  `ContainerRuntime` protocol, so a native Containerization.framework backend could replace
  it later.
- **Dev Container format, not a new one.** Existing configs work, and Titan configs work in VS
  Code and Codespaces too.
- **Isolation over density.** The default is one VM per project. Sharing happens at the
  layers where it's safe: images (APFS clones), read-only toolchains, and lock-free caches.
- **Never surprise.** Titan doesn't take over folders without opt-in, shows downloads and disk
  needs before pulling, asks before editing shell config, and never deletes data unless asked.
