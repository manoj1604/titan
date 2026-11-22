# 3. Your first project

**Time:** about 10 minutes · **You'll build:** a small web app, running in its own VM

You don't need Node, Python or anything else installed on your Mac. Titan runs it all in
the VM.

## Step 1: Make a folder and set it up

```bash
mkdir -p ~/code/shop && cd ~/code/shop
titan create node
```

```console
✓ Wrote ~/code/shop/.devcontainer/devcontainer.json (node)
▸ Pulling node:22-bookworm
▸ Creating VM titan-shop-65578934 from node:22-bookworm
✓ shop is ready → http://localhost:3000
  Wrote notes for coding agents: AGENTS.md, CLAUDE.md
```

In one step, Titan:

1. wrote `.devcontainer/devcontainer.json` (the recipe) and `titan.lock` (exact versions)
2. started a Linux VM with Node 22
3. wrote short notes for coding agents (`AGENTS.md`)

The first project downloads a few hundred MB, so it takes a minute or two. Later projects
reuse what's already on your Mac.

**Other languages:** `titan create python`, `go`, `rust`, `ruby` or `java`. Pick a version
with `@`: `titan create python@3.13`. Add a database with `--with postgres` (see
[Databases](06-databases.md)).

## Step 2: Make the starter code

Use the framework's own generator, just as you would without Titan. It runs **in the VM**:

```bash
npm create vite@latest . -- --template react-ts
npm install
```

Vite notices the folder isn't empty (Titan's files are there): choose **Ignore files and
continue**. (For Python: `pip install fastapi uvicorn`; for Go: `go mod init shop`; and so on.)

## Step 3: Start the app

```bash
npm run dev
```

```console
  VITE v6.0.0  ready in 412 ms
  ➜  Local:   http://localhost:5173/
```

Open **http://localhost:5173** in your browser. That `npm` ran **inside the VM**, using
the VM's Node 22, and your browser reaches it through `localhost`. Press **Ctrl-C** to stop.

## Step 4: Edit some code

Open the project in your editor (`code .` for VS Code), change some text in `src/App.tsx`
and save. The page in your browser updates right away. Your files live on your Mac, and
the VM sees every change instantly.

## Step 5: Look around

```console
$ titan status
project   /Users/you/code/shop
vm        titan-shop-65578934  running
usage     2% CPU, 180 MB of 8.0 GB memory
image     node:22-bookworm
workspace /workspaces/shop
ports     3000, 5173
shims     node npm npx
```

| Line | Meaning |
|---|---|
| `vm … running` | This project's VM, and whether it's running |
| `usage` | What the VM uses right now |
| `workspace` | Where your project folder appears inside the VM |
| `ports` | Ports opened on your Mac's `localhost` |
| `shims` | Commands that automatically run in the VM here |

`titan status --all` lists every Titan VM on your Mac.

## Step 6: Stop for the day

```bash
titan down
```

The VM stops and frees its memory. Next time you run any command in the project, it starts
again in about a second. Nothing is lost. (Titan also stops VMs you haven't used for 2
hours.)

## Recap

| You did | Command |
|---|---|
| Set up a folder and its VM | `titan create node` |
| Made starter code | `npm create vite@latest .` |
| Ran the app | `npm run dev` |
| Checked on it | `titan status` |
| Stopped it | `titan down` |

Next: [Use Titan with an existing project →](04-existing-projects.md)
