# 3. Your first project

**Time:** about 10 minutes · **You'll build:** a small web app, running in its own VM

You don't need Node, Python or anything else installed on your Mac. Titan runs it all in
the VM.

## Step 1: Create the project

Go to the folder where you keep your code and run:

```bash
cd ~/code
titan new shop --template vite
```

Titan first shows you **what it will download** and checks that you have enough disk space:

```console
  shop  (Vite + React + TypeScript)
  base      Debian + tools  buildpack-deps:bookworm  ↓ ~324 MB
  runtime   Node 22         shared toolchain store   ↓ ~76 MB
  database  none (add later: titan add postgres)
  disk      ~1.6 GB needed, 9.7 GB free ✓

Create shop? [Y/n]
```

- `↓ ~324 MB` means it needs to download this. `on this Mac` means it's already there,
  so your second project is much faster.
- Press **Enter** to continue.

Then it does the work:

```console
▸ Pulling buildpack-deps:bookworm
▸ Installing node 22 into the shared toolchain store (once per Mac)…
▸ Creating VM titan-shop-65578934 from buildpack-deps:bookworm
▸ generate: … npm create vite@latest shop -- --template react-ts …
▸ postCreate: npm install
✓ shop is ready → http://localhost:5173
  Next: npm run dev
```

In one step, Titan:

1. created the `shop` folder and a git repository
2. wrote `.devcontainer/devcontainer.json` (the recipe) and `titan.lock` (exact versions)
3. started a VM and ran Vite's own project generator **inside it**
4. installed the dependencies
5. **moved your terminal into `shop/`** (that's the shell hook at work)

The first project downloads a few hundred MB, so it takes a minute or two. Later projects
reuse what's already on your Mac.

## Step 2: Start the app

```bash
npm run dev
```

```console
  VITE v6.0.0  ready in 412 ms
  ➜  Local:   http://localhost:5173/
```

Open **http://localhost:5173** in your browser. You'll see the Vite welcome page.

That `npm` ran **inside the VM**, using the VM's Node 22, and the browser on your Mac
reaches it through `localhost`. Press **Ctrl-C** in the terminal to stop the app.

## Step 3: Edit some code

Open the project in your editor:

```bash
code .          # VS Code; or open the folder in any editor
```

Change some text in `src/App.tsx` and save. The page in your browser updates right away.
Your files live on your Mac, and the VM sees every change instantly.

## Step 4: Look around

```console
$ titan status
project   /Users/you/code/shop
vm        titan-shop-65578934  running
config    .devcontainer/devcontainer.json
image     buildpack-deps:bookworm
workspace /workspaces/shop
ports     5173
shims     node npm npx
resources 4 CPUs, 8.0 GB memory
```

| Line | Meaning |
|---|---|
| `vm … running` | This project's VM, and whether it's running |
| `workspace` | Where your project folder appears inside the VM |
| `ports` | Ports opened on your Mac's `localhost` |
| `shims` | Commands that automatically run in the VM here |
| `resources` | The VM's CPUs and memory limit (memory is only used as needed) |

## Step 5: Stop for the day

```bash
titan down
```

The VM stops and frees its memory. Next time you run any command in the project, it starts
again in about a second. Nothing is lost: your code is on your Mac, and the VM's installed
packages are kept.

## Other templates

```bash
titan new api   --template fastapi      # Python API
titan new site  --template next         # Next.js
titan new blog  --template django       # Django
titan new tool  --template go           # Go web server
titan new cli   --template rust         # Rust (cargo)
titan new demo                          # no template: choose from a list
```

All templates: `vite`, `next`, `node`, `fastapi`, `django`, `flask`, `python`, `go`, `rust`.

**Add a database while creating:** `titan new shop --template vite --with postgres`. See
[Databases](06-databases.md).

**Choose a version:** `titan new api --template fastapi --runtime-version 3.13`.

## Recap

| You did | Command |
|---|---|
| Created a project, its VM and starter code | `titan new shop --template vite` |
| Ran the app | `npm run dev` |
| Checked on it | `titan status` |
| Stopped it | `titan down` |

Next: [Use Titan with an existing project →](04-existing-projects.md)
