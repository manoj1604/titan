# 2. The big idea

**Time:** 5 minutes · No commands to run, just the ideas behind Titan.

## The problem Titan solves

You've probably heard "it works on my machine". It happens because every computer has
different versions of Node, Python, databases and system libraries. A project that works on
one laptop breaks on another.

Titan fixes this by giving **each project its own clean Linux computer**, set up from a
file that lives in the project. Everyone who opens the project gets the same computer.

## Five words to know

### 1. Project

A folder with your code, like `~/code/shop`. Titan treats a folder as a project when it
has a Titan config file or a normal project file such as `package.json`,
`requirements.txt` or `go.mod`.

### 2. VM (virtual machine)

A small, separate Linux computer running **inside** your Mac. Each project gets its own VM.

- It starts in about a second and uses almost no resources while idle.
- It **sees your project folder**. When you edit a file on your Mac, the VM sees the
  change instantly. Nothing is copied.
- It's **isolated**. What you install in one project's VM can't break another project.

```
 Your Mac                                   VMs
 ──────────────────────────────            ───────────────────────────
 ~/code/shop      (VS Code, Finder)  ───▶   VM "shop"   Node 22
 ~/code/blog                         ───▶   VM "blog"   Node 20
 ~/code/api                          ───▶   VM "api"    Python 3.12 + Postgres
```

### 3. `devcontainer.json`: the recipe

A small file in your project (`.devcontainer/devcontainer.json`) that describes the VM:
which language version, which ports, which setup commands. Example:

```jsonc
{
  "image": "node:22-bookworm",          // Linux with Node 22
  "forwardPorts": [3000],               // your app's port, opened on your Mac
  "postCreateCommand": "npm install"    // run once when the VM is created
}
```

It's an industry-standard format, so VS Code Dev Containers and GitHub Codespaces read the
same file. You often don't have to write it at all: Titan can create it for you.

### 4. `titan.lock`: the exact versions

"Node 22" can mean slightly different builds over time. `titan.lock` records the **exact**
build Titan used (a long ID called a *digest*), so a teammate gets precisely the same one,
not just "Node 22". Titan writes it for you. You just commit it.

### 5. Shell hook

A few lines Titan adds to your terminal's startup file. In a project folder, it makes your
normal commands run **in the project's VM**:

```console
$ cd ~/code/shop
titan: shop → VM  (node npm npx)       ← the hook tells you it's active
$ node -v
v22.23.5                               ← this is the VM's Node, not your Mac's
```

Outside project folders, everything behaves exactly as before.

## What happens when you type a command

```
 you type:   npm test
               │
               ▼
 shell hook:  "this folder is the 'shop' project, run it in its VM"
               │
               ▼
 VM "shop":   starts if needed (about 1 s), runs npm test, sends the output back
```

Your keyboard, colors, Ctrl-C and exit codes all work as if the command ran on your Mac.

## The files Titan uses

| File | Where | Commit it to git? | What it's for |
|---|---|---|---|
| `.devcontainer/devcontainer.json` | your project | **yes** | The recipe for the VM |
| `titan.lock` | your project | **yes** | Exact versions, so everyone matches |
| `.titan/` | your project | no (it hides itself from git) | Titan's local notes and command shortcuts |

That's everything. Next: [Your first project →](03-first-project.md)
