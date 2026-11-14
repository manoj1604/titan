# Troubleshooting

Start with `titan doctor` (this Mac and project) and `titan setup` (fixes what's missing).
Add `-v` to any command to see the `container` commands it runs, or `--dry-run` to print them
without running anything.

### "Apple's `container` CLI was not found"
Run `titan setup` (it offers `brew install container`), or install the package from
[apple/container releases](https://github.com/apple/container/releases).

### Commands run on the Mac, not in the VM
- Is the hook loaded? `echo $TITAN_HOOK` should print `zsh` or `bash`. If not, run
  `titan setup` and open a new terminal.
- Does the project have Titan config? The hook only routes projects with
  `devcontainer.json`, `titan.lock`, or ones you've run `titan up` in. For others, run
  `titan up` (or `titan init`) once.
- `type npm` should point into `<project>/.titan/bin`.

### "… isn't a project Titan recognizes"
`titan run` and the shims won't create a VM in a folder with no config or manifest, such as
your home folder. Use `titan new .` to start a project there, or `titan up` to create a plain
Debian VM anyway.

### My app is running but `localhost` doesn't load
- Check the actual URL: `titan status` shows the port mapping. If the port was busy, Titan
  published the next free one (for example `5174 → 5173`).
- VMs created before Titan had the port forwarder can't reach apps bound to `127.0.0.1`.
  `titan status` says so; `titan rebuild` fixes it.
- Is the port listed in `forwardPorts`? Zero-config projects forward the framework's usual
  port only.

### "Port 3000 already in use"
Another project's VM or a local app holds it, and `strictPorts` is on. Stop the other one
(`titan ps` shows which project holds it), change `forwardPorts`, or turn off `strictPorts`
so Titan remaps the port.

### A build was killed (exit code 137)
The VM ran out of memory. Raise `customizations.titan.memory` (for example `"8G"`), then run
`titan rebuild`. `titan stats` shows memory use against the limit.

### The app can't reach `postgres`
Run `titan up` again: it rewrites the app VM's `/etc/hosts` with the services' current IPs.
Those change whenever a service VM restarts, which matters if one was restarted outside
Titan. `titan status` shows each service's state.

### Running out of disk
`titan gc --dry-run` shows what can go: images no project needs and unused toolchains. Then
run `titan gc`. `titan cache clean` empties the shared package cache. Images cost about 3× their
download size on disk (a compressed and an unpacked copy).

### First `titan setup` hangs at "Starting the container service"
The first start downloads the Linux kernel. If it seems stuck, run `container system start`
yourself to see its prompts, then run `titan setup` again.

### Remove Titan completely
```bash
titan ps                       # then `titan down --volumes` in each project you want gone
titan gc --all
brew uninstall titan           # or delete bin/titan and share/titan from your prefix
rm -rf ~/Library/Application\ Support/titan ~/Library/Caches/titan
# and delete the "# >>> titan >>>" block from ~/.zshrc
```

### Still stuck?
Open an issue with the output of `titan doctor`, `titan --version`, `container --version`, and
the failing command run with `-v`.
