# Getting started

## 1. Install

You need a Mac with Apple silicon running macOS 26 or later.

```bash
brew install OWNER/titan/titan     # or use the release tarball, see the README
titan setup
```

`titan setup` walks through everything once:

```
Checking this Mac
✓ Apple silicon, macOS 26.1
✓ container CLI version 1.7.1
✓ container service running
✓ port forwarder (/opt/homebrew/share/titan)
    Titan will add to ~/.zshrc:
      # >>> titan >>>
      [ -x /opt/homebrew/bin/titan ] && eval "$(/opt/homebrew/bin/titan hook zsh)"
      # <<< titan <<<
    Add the shell hook to .zshrc? [Y/n]
✓ shell hook added to ~/.zshrc
✓ test VM: Linux aarch64 in 1.3s
✓ This Mac is ready for Titan.
```

- If Apple `container` is missing, it offers `brew install container`.
- The first service start downloads the Linux kernel (about 30 MB).
- The shell hook makes project commands run in the project's VM. Setup shows the exact
  lines and asks before editing your shell config. To uninstall, delete the marked block.

Open a new terminal afterwards so the hook loads.

## 2. Create a project

```bash
titan new shop --template vite --with postgres
```

Titan shows what it will download and checks disk space. After you confirm, it:

1. creates `shop/`, runs `git init`, and writes `.devcontainer/devcontainer.json`
2. starts Postgres in its own VM, then the app VM
3. runs the framework's own generator (`npm create vite`) **inside the VM**
4. runs `npm install`, pins every image in `titan.lock`, and moves your terminal into `shop/`

```bash
npm run dev            # → http://localhost:5173
```

Leave out `--template` to pick from a list. To set up a folder that already has code, run
`titan new .` there: the stack is detected, and nothing is generated over your files.

## 3. Use it day to day

Inside a project, with the hook loaded, just work:

```bash
npm install            # these run in the VM
npm test
python manage.py migrate
```

| You want to… | Run |
|---|---|
| see what's running | `titan status` (this project), `titan ps` (all projects) |
| open a shell in the VM | `titan shell` |
| run one command explicitly | `titan run -- <cmd>` |
| run a command on the Mac instead | `TITAN_DISABLE=1 <cmd>` |
| stop the VM / delete it | `titan down` / `titan down --rm` (service data is kept) |
| apply config changes | `titan rebuild` |
| add a database | `titan add postgres` (then `titan up`) |
| share your app publicly | `titan share` |

VS Code: open the folder as usual. Its integrated terminal loads your shell, and therefore
the hook. `titan vscode` can also make new terminals open directly inside the VM.

## 4. Share the setup with your team

Commit `.devcontainer/devcontainer.json` and `titan.lock`. A teammate with Titan installed
then only needs to:

```bash
git clone …/shop && cd shop
npm test               # first run sets up the VM, pinned to your exact images
```

The same `devcontainer.json` also works in VS Code Dev Containers and GitHub Codespaces
for teammates who don't use Titan.

## Existing projects without any config

`titan up` works with zero config. It detects the stack and versions from the files already
in the repo:

| Found | VM gets |
|---|---|
| `package.json` (+ `.nvmrc`, `engines.node`, lockfile) | Node at that major version, `npm ci`/`pnpm`/`yarn`/`bun` install |
| `pyproject.toml`, `requirements.txt`, `Pipfile`, `uv.lock` (+ `.python-version`) | Python at that version, matching install |
| `go.mod` | Go at the `go` directive's version |
| `Cargo.toml`, `Gemfile`, `pom.xml`, `build.gradle` | Rust, Ruby, Java (Maven or Gradle) |

Ports follow the framework (Vite 5173, Next 3000, Django 8000, Flask 5000, and so on). Run
`titan init` to save what was detected as a `devcontainer.json`, so the team gets it too.
