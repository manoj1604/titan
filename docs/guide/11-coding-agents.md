# 11. Coding agents (Claude Code, Codex, Cursor)

**Time:** 5 minutes · **You'll learn to:** let coding agents work in your project's VM, and
run an agent inside the VM as a sandbox

Titan works with coding agents in two ways:

| | Agent runs on your Mac | Agent runs **inside** the VM |
|---|---|---|
| How | Use Claude Code, Codex or Cursor as usual | `titan agent claude` (or `codex`) |
| Its commands (`npm test`…) run | in the VM | in the VM |
| It can touch | your whole Mac (as always) | only this project's folder and its VM |
| Good for | everyday work | letting an agent work without asking permission for each step |

## Agents on your Mac: nothing to do

Open Claude Code, Codex or Cursor in a Titan project and work normally. When the agent runs
`npm test`, `pytest` or `go build`, it runs **in the project's VM**, with the project's exact
tools, just like when you type it.

This works because Titan puts small "smart" commands first on your `PATH` for every shell,
including the non-interactive ones agents and scripts use. In a project folder they run in
the VM; anywhere else they run your Mac's version. A fresh clone is set up on its first
command.

### Tell the agent about the VM: `AGENTS.md`

Titan writes a short **"Dev environment"** section for agents into `AGENTS.md` (read by
Codex, Cursor and most agents), and links it from `CLAUDE.md` for Claude Code:

- commands run in the VM; `titan run -- <command>` always does
- the app's ports, and how to reach services (`postgres` by name, `$DATABASE_URL`)
- don't install runtimes on the Mac; don't delete data (`titan down --volumes`, `titan gc`)

`titan new` adds it. For an existing project, `titan init` asks first. Add or refresh it
any time with `titan agents` (remove it with `titan agents --remove`). Only Titan's fenced
section is touched, `titan up` keeps it up to date, and you should commit both files so
teammates' agents get them.

Agents and scripts can read the project's state as JSON: `titan status --json`,
`titan ps --json`, `titan share --list --json`.

## An agent inside the VM: `titan agent`

```console
$ titan agent claude
titan: installing Claude Code (once for all projects)…
✅ Installation complete!
╭───────────────────────────────╮
│ ✻ Welcome to Claude Code!     │
```

- **Installed once for all projects.** The agent and its login are kept in `~/.titan/agents`
  on your Mac, shared by every VM. Starting it in another project takes a second.
- **Log in once.** The login link opens in your Mac's browser. Or set `ANTHROPIC_API_KEY` /
  `OPENAI_API_KEY` on the Mac and Titan passes it in.
- **A sandbox.** The agent only sees this project's folder and its VM, not your home
  folder, SSH keys, other projects or the rest of your Mac.

So you can let it work without permission prompts:

```bash
titan agent claude --auto        # Claude Code with --dangerously-skip-permissions
titan agent codex --auto         # Codex with --dangerously-bypass-approvals-and-sandbox
```

> ⚠️ **The project folder is shared live with the VM**, so an agent can still change or
> delete your project's files. Commit (or stash) your work first, and review its changes with
> `git diff`. It also has internet access.

More:

| You want to… | Run |
|---|---|
| pass arguments to the agent | `titan agent codex -- exec "fix the failing test"` |
| update the shared copy | `titan agent claude --update` |
| remove agents and logins | `rm -rf ~/.titan/agents` |

> VMs created before Titan 0.4 don't have the shared folder: the agent still works, but it's
> installed and logged in inside that VM only. `titan rebuild` switches it to the shared one.

That's the whole guide. For details on any setting, see the
[Configuration reference](../configuration.md). If something isn't working, see
[Troubleshooting](../troubleshooting.md).
