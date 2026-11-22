# 4. Use Titan with an existing project

**Time:** 5 minutes · **You'll need:** a project you already have (Node, Python, Go, Rust,
Ruby or Java)

There are two situations:

- **A. The project already has Titan files** (`devcontainer.json` or `titan.lock`), for
  example a teammate's project. Just use it.
- **B. It doesn't have them yet.** Titan figures out what the project needs.

## A. The project already has Titan files

```bash
git clone https://github.com/acme/shop
cd shop
```

Titan quietly notices the project and gets it ready, without starting anything yet. Now run
any normal command:

```console
$ npm test
▸ Setting up shop (first run; later runs start instantly)…
▸ Pulling node:22-bookworm (pinned by titan.lock)
▸ Creating VM titan-shop-fe508201 from node:22-bookworm@sha256:e13726ca…
▸ postCreate: npm install
✓ shop is ready
# tests 3
# pass 3
```

The first command built the VM, using the **exact** versions from `titan.lock`, and then
ran your tests. Every command after that starts instantly and quietly. There's no README
to follow and nothing to install.

## B. The project has no Titan files yet

```bash
cd ~/code/my-api
titan create
```

Titan **detects** what the project needs from the files already in it, writes it down in
`.devcontainer/devcontainer.json` and starts the VM:

| If it finds… | The VM gets… |
|---|---|
| `package.json` (+ `.nvmrc` or `engines.node`) | Node at that version; installs with npm, pnpm, yarn or bun, matching your lockfile |
| `requirements.txt`, `pyproject.toml`, `Pipfile`, `uv.lock` (+ `.python-version`) | Python at that version; installs your dependencies |
| `go.mod` | Go at the version in the `go` line |
| `Cargo.toml` | Rust |
| `Gemfile` (+ `.ruby-version`) | Ruby; runs `bundle install` |
| `pom.xml` / `build.gradle` | Java 21 with Maven / Gradle |

It also opens the usual port for your framework: Vite 5173, Next.js 3000, Django and
FastAPI 8000, Flask 5000, Go 8080.

```console
$ titan create
✓ Wrote /Users/you/code/my-api/.devcontainer/devcontainer.json (python)
▸ Pulling python:3.12-bookworm
▸ Creating VM titan-my-api-6d1e1b90 from python:3.12-bookworm
▸ postCreate: pip install -r requirements.txt
✓ my-api is ready → http://localhost:8000
```

Now `python`, `pip` and friends run in the VM whenever you're in this folder.

### Share the setup with your team

Look at `.devcontainer/devcontainer.json`. You can adjust it (ports, version, setup
command; then `titan up --rebuild`). Then commit it with `titan.lock`:

```bash
git add .devcontainer/devcontainer.json titan.lock
git commit -m "Add Titan dev environment"
```

From now on, anyone who clones the repo is in situation A.

> **Tip:** `titan create --dry-run` shows the file without writing it.

## Monorepos (several apps in one repo)

Titan picks the project root automatically:

- In `frontend/` and `backend/` with their own `package.json` and `go.mod`, **each gets its
  own VM**.
- In a workspace (a root `package.json` with `workspaces`), the **root** is the project, so
  all packages share one VM.

Run `titan status` in any folder to see which project and VM it belongs to.

## If something goes wrong

- **The setup command failed** (for example `npm install`): fix the cause, then run
  `titan up` again. It picks up where it stopped.
- **Wrong version detected:** add `.nvmrc` / `.python-version`, or edit
  `"image"` in the file. Then run `titan up --rebuild`.
- **"… isn't a project Titan recognizes":** the folder has no project files. Run
  `titan create node` (or `python`, `go`…) to set it up for a language.

Next: [Everyday commands →](05-everyday-use.md)
