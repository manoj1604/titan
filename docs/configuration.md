# Configuration

Titan reads the standard [Dev Container](https://containers.dev) file. It looks for
`.devcontainer/devcontainer.json` first, then `.devcontainer.json` (JSON with comments and
trailing commas is fine). Without either file, Titan detects the stack, as described in
[Use Titan with an existing project](guide/04-existing-projects.md#b-the-project-has-no-titan-files-yet).

## Supported `devcontainer.json` properties

| Property | Notes |
|---|---|
| `name` | Display only |
| `image` | Any OCI image; pulled for `linux/arm64` and pinned in `titan.lock` |
| `build.dockerfile`, `build.context`, `build.args` | Built with `container build`, tagged `titan-local/<project>:<hash>` |
| `workspaceFolder` | Where the project appears in the VM (default `/workspaces/<folder>`) |
| `forwardPorts` | Numbers or `"host:port"` strings. Published on `127.0.0.1`; a busy port is remapped to the next free one |
| `containerEnv` | Set when the VM is created |
| `remoteEnv` | Set for every command Titan runs in the VM (`null` values are dropped) |
| `postCreateCommand` | Runs once per new VM (string, argv array, or named map run in key order) |
| `postStartCommand` | Runs on every start |
| `features` | `ghcr.io/devcontainers/features/node` and `…/python` are served from Titan's [toolchain store](how-it-works.md#shared-toolchain-store); any other feature is an error |
| `remoteUser` | The user commands run as (it must exist in the image). Without it, commands run as root, the image default. `customizations.titan.user` takes precedence |

Not supported yet: `dockerComposeFile`, other features, `containerUser`, `mounts`, `runArgs`. Unknown keys are ignored, so files
written for VS Code keep working.

## `customizations.titan`

Titan-specific settings live under `customizations.titan`, so other tools ignore them:

```jsonc
{
  "image": "node:22-bookworm",
  "forwardPorts": [3000],
  "customizations": {
    "titan": {
      "shims": ["node", "npm", "npx", "pnpm"],   // commands the shell hook routes into the VM
      "cpus": 4,
      "memory": "8G",                             // default: half your RAM, at most 8 GB
      "sharedCache": true,                        // share npm/pip/Go module downloads between VMs
      "strictPorts": false,                       // true: fail instead of remapping a busy port
      "idleStop": "2h",                           // stop the VMs after 2 h unused ("30m", false = never)
      "user": "me",                               // optional: your own user instead of root (see below)
      "services": ["postgres", "redis"]           // see below
    }
  }
}
```

| Key | Default | Meaning |
|---|---|---|
| `shims` | detected from the stack | Commands routed into the VM by the shell hook |
| `cpus` | Apple `container` default (4) | vCPUs for the VM |
| `memory` | half of RAM, max 8 GB | VM memory limit (`"512M"`, `"4G"`) |
| `sharedCache` | `true` | Mount the shared npm/pip/Go module cache at `/titan-cache` |
| `strictPorts` | `false` | Fail rather than remap when a forwarded port is busy on the Mac |
| `idleStop` | `"2h"` | Stop the project's VMs after this long unused (`"30m"`, `"1d"`, `false` = never). Applies without a rebuild. `TITAN_IDLE_STOP` sets it for all projects |
| `user` | root (or `remoteUser`, if set) | Who runs commands: `"root"`, `"me"`, or a user that exists in the image |
| `services` | none | Extra VMs (databases, caches) next to the app |

### The user in the VM

Commands run as **root** by default (or as the spec's `remoteUser`, if set). With
`"user": "me"`, Titan instead creates a Linux user **named after your Mac user** (same uid)
when the VM is created. It gives that user passwordless `sudo` and ownership of `/usr/local`, so
`npm i -g`, `pip install` and cargo work without `sudo`. The prompt shows the project:
`manoj@shop:/workspaces/shop$`. All commands (setup, shims, `titan run`, `titan shell`) run
as that user; `--root` runs one as root.

- With `"me"`, setup commands also run as that user, so use `sudo apt-get …` in
  `postCreateCommand`.
- `sudo` is installed in the background after the VM is created (about 15 s on Debian
  images). `titan shell --root` works meanwhile.
- Changing `user` takes effect on `titan rebuild`. Until then, the VM keeps running as
  before, and `titan status` says so.

### Services

```jsonc
"services": ["postgres", "redis"]                    // presets by name
"services": {                                         // or a map: name → image or object
  "db": "postgres:15",
  "search": { "image": "getmeili/meilisearch:v1.8", "port": 7700,
              "data": "/meili_data", "env": { "MEILI_ENV": "development" } }
}
```

| Field | Meaning |
|---|---|
| `image` | Image, or a preset name (`postgres` → `postgres:16-bookworm`) |
| `port` | Port the service listens on (preset default otherwise); also published on `localhost` |
| `data` | Directory kept on a persistent volume |
| `env` | Environment for the service (merged over the preset's) |
| `command` | Override the image's command |

The service name is also its **hostname**: the app connects to `postgres:5432`.

**Presets:**

| Preset | Image | App gets |
|---|---|---|
| `postgres` | `postgres:16-bookworm` (user/password `postgres`, database `app`) | `DATABASE_URL=postgres://postgres:postgres@postgres:5432/app` |
| `redis` | `redis:7-bookworm` | `REDIS_URL=redis://redis:6379` |

`DATABASE_URL` follows overrides: setting `POSTGRES_PASSWORD` in `env` changes the URL too.
Your own `containerEnv`/`remoteEnv` always wins. Service data survives `titan rebuild` and
`titan down --rm`. Only `titan down --volumes` deletes it.

## `titan.lock`

Written on the first `titan up` and meant to be **committed**:

```json
{
  "version": 1,
  "image": "node:22-bookworm",
  "digest": "sha256:e13726ca…",
  "services": { "postgres": { "image": "postgres:16-bookworm", "digest": "sha256:a49f74…" } },
  "toolchains": { "node": { "image": "node:22-bookworm-slim", "digest": "sha256:e9f565…" } }
}
```

Every machine pulls exactly these digests. To move to newer images on purpose, run
`titan lock --update`, then `titan rebuild`.

## Files Titan writes in a project

| Path | Commit it? | What |
|---|---|---|
| `.devcontainer/devcontainer.json` | yes | The environment (from `titan init` / `titan new`) |
| `titan.lock` | yes | Image pins |
| `.titan/` | no (it ignores itself) | Local state and command shims |

## Environment variables

| Variable | Effect |
|---|---|
| `TITAN_DISABLE=1` | Shims run the Mac's command instead of the VM's |
| `TITAN_QUIET=1` | No "run `titan init`" tip in folders Titan doesn't manage yet |
| `TITAN_NO_SHELL_HOOK=1` | `titan new/init/up` don't add the shell hook to `~/.zshrc` |
| `TITAN_HOME` | Put Titan's machine-wide data (registry, caches) under this folder |
| `TITAN_SHARE_DIR` | Where to find the port forwarder binary |
| `NO_COLOR` | Disable colored output |
