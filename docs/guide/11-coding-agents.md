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

### Claude Code: everything it does happens in the VM

For **Claude Code**, Titan goes further (it sets this up by itself the first time you use
`titan up`, `new` or `init` on a Mac with Claude Code):

- **Every command** Claude runs goes to the VM, not just `npm` and friends: `ls`, `rm`,
  scripts, `curl … | sh`. Mac paths of the project are translated to the VM's.
- **It only writes inside the project folder** (which is the VM's folder). A write anywhere
  else on your Mac is refused, and Claude is told why. Its own memory and scratch files still
  work.
- `git`, `gh` and `titan` stay on the Mac (they only touch the project's `.git`, and pushing
  needs your Mac's credentials).
- Your permission settings still apply: Titan only reroutes commands, it never approves them.
  Prompts show the `titan run -- …` form.
- Outside Titan projects, Claude behaves exactly as before.

It's a hook in `~/.claude/settings.json` (your other settings are kept; a backup is saved
next to it). Turn it off by removing the two `titan agent-hook claude` entries, or set
`TITAN_NO_CLAUDE_HOOK=1` before Titan adds it.

> It keeps Claude working in the VM; it isn't a security sandbox. Claude can still read files
> on your Mac, and `git` runs there.

### Tell the agent about the VM: `AGENTS.md`

Titan writes a short **"Dev environment"** section for agents into `AGENTS.md` (read by
Codex, Cursor and most agents), and links it from `CLAUDE.md` for Claude Code:

- commands run in the VM; `titan run -- <command>` always does
- the app's ports, and how to reach services (`postgres` by name, `$DATABASE_URL`)
- don't install runtimes on the Mac; don't delete data (`titan down --volumes`, `titan gc`)

`titan create` adds it (for a folder with existing code it asks first). To remove it,
delete Titan's section (or the files). Only Titan's fenced
section is touched, `titan up` keeps it up to date, and you should commit both files so
teammates' agents get them.

Agents and scripts can read the project's state as JSON: `titan status --json`,
`titan status --all --json`, `titan share --list --json`.

That's the whole guide. For details on any setting, see the
[Configuration reference](../configuration.md). If something isn't working, see
[Troubleshooting](../troubleshooting.md).
