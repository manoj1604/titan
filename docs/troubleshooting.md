# Troubleshooting

Start with `titan doctor` (this Mac and project). `titan create` fixes what's missing on the Mac.
Add `-v` to any command to see the `container` commands it runs, or `--dry-run` to print them
without running anything.

### "Apple's `container` CLI was not found"
Run `brew install container`, or install the package from
[apple/container releases](https://github.com/apple/container/releases).

### Commands run on the Mac, not in the VM
- Is the hook loaded? `echo $TITAN_HOOK` should print `zsh` or `bash`. If not, run
  `titan create` in the project and open a new terminal.
- Does the project have Titan config? The hook only routes projects with
  `devcontainer.json`, `titan.lock`, or ones you've run `titan up` in. For others, run
  `titan create` once.
- `type npm` should point into `<project>/.titan/bin`.

### "… isn't a project Titan recognizes"
`titan run` and the shims won't create a VM in a folder with no config or manifest, such as
your home folder. Run `titan create` there to set it up, or `titan up` to create a plain
Debian VM anyway.

### My app is running but `localhost` doesn't load
- Check the actual URL: `titan status` shows the port mapping. If the port was busy, Titan
  published the next free one (for example `5174 → 5173`).
- VMs created before Titan had the port forwarder can't reach apps bound to `127.0.0.1`.
  `titan status` says so; `titan up --rebuild` fixes it.
- Is the port listed in `forwardPorts`? Zero-config projects forward the framework's usual
  port only.

### My VM stopped by itself
After 2 hours unused, Titan stops a project's VMs to free memory (`.titan/relay.log` says
when). Any command starts them again. A database you only use from a Mac app (TablePlus)
doesn't count as use: set `"idleStop": false` (or a longer time) for that project.

### Hot reload doesn't pick up my edits
While the VM runs, Titan passes file changes from your Mac into it (a small background
process, log in `.titan/relay.log`). Run `titan up` to restart it. Changes inside
`node_modules`, `.git` and build folders aren't passed on (they're written inside the VM
anyway). To turn it off, set `TITAN_NO_FILE_RELAY=1`.

### "Port 3000 already in use"
Another project's VM or a local app holds it, and `strictPorts` is on. Stop the other one
(`titan status --all` shows which project holds it), change `forwardPorts`, or turn off `strictPorts`
so Titan remaps the port.

### `sudo: command not found` right after creating a VM (with `"user": "me"`)
Titan installs `sudo` in the background (about 15 s on Debian images). Wait a moment, or use
`titan shell --root` / `titan run --root -- <cmd>`. On images without `apt-get`, sudo isn't
installed; use `--root`.

### A build was killed (exit code 137)
The VM ran out of memory. Raise `customizations.titan.memory` (for example `"8G"`), then run
`titan up --rebuild`. `titan status` shows memory use against the limit.

### The app can't reach `postgres`
Run `titan up` again: it rewrites the app VM's `/etc/hosts` with the services' current IPs.
Those change whenever a service VM restarts, which matters if one was restarted outside
Titan. `titan status` shows each service's state.

### Running out of disk
`titan gc --dry-run` shows what can go: images no project needs and unused toolchains. Then
run `titan gc`. `titan gc --cache` empties the shared package cache. Images cost about 3× their
download size on disk (a compressed and an unpacked copy).

### The first `titan create` hangs at "Starting Apple's container service"
The first start downloads the Linux kernel. If it seems stuck, run `container system start`
yourself to see its prompts, then run `titan create` again.

### Remove Titan completely
```bash
titan status --all             # then `titan down --volumes` in each project you want gone
titan gc --all
brew uninstall titan           # or delete bin/titan and share/titan from your prefix
rm -rf ~/Library/Application\ Support/titan ~/Library/Caches/titan
rm -rf ~/.titan
# and delete the "# >>> titan" blocks from ~/.zshrc, ~/.zshenv and ~/.zprofile,
# and the two `titan agent-hook claude` entries from ~/.claude/settings.json
```

### Still stuck?
Open an issue with the output of `titan doctor`, `titan --version`, `container --version`, and
the failing command run with `-v`.
