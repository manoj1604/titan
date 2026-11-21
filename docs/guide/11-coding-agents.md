# 11. Coding agents (Claude Code, Codex, Cursor)

**Time:** 3 minutes · **You'll learn to:** let coding agents work in your project's VM

## Nothing to do

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

That's the whole guide. For details on any setting, see the
[Configuration reference](../configuration.md). If something isn't working, see
[Troubleshooting](../troubleshooting.md).
