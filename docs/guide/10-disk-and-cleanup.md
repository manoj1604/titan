# 10. Disk space, memory and cleanup

**Time:** 5 minutes · **You'll learn to:** see what Titan uses, and free space and memory

## What uses disk space

| Thing | Typical size | Shared? |
|---|---|---|
| **Images** (the Linux base for a VM) | 0.5–1.5 GB each on disk | Yes: one image serves every project that uses it |
| **Toolchains** (Node, Python from the shared store) | ~90–200 MB each | Yes: one copy per version for all projects |
| **Each VM** | ~20 MB | No (but it's tiny: VMs are copy-on-write clones) |
| **Database data** | whatever your data is | No, per project |
| **Package cache** (npm, pip, Go modules) | grows with use | Yes: each package downloaded once per Mac |

So ten Node projects cost about the same disk as one, plus each project's own files.

## What uses memory

Each running VM uses memory as it needs it, up to its limit:

- **Limit:** half your Mac's RAM, at most 8 GB. A 16 GB Mac gets 8 GB per VM.
- **Idle VM:** about 60–120 MB.
- A VM doesn't give memory back to macOS until it **stops**.

See it all:

```console
$ titan ps
PROJECT     FOLDER               STATUS   MEMORY           PORTS
shop        ~/code/shop          running  640 MB / 8.0 GB  localhost:5173
blog        ~/code/blog          running  210 MB / 8.0 GB  localhost:3000

2 running · 850 MB memory in use
```

**Free memory:** stop projects you're not using with `titan down` (in that project, or
`titan -C ~/code/blog down`). They restart in about a second when you need them.

**Change a project's memory limit** in `devcontainer.json`, then `titan rebuild`:

```jsonc
"customizations": { "titan": { "memory": "4G", "cpus": 2 } }
```

If a build gets killed with **exit code 137**, the VM ran out of memory. Raise the limit.
`titan stats` shows usage against the limit live.

## Clean up

### Old images and toolchains: `titan gc`

Shows what no project needs any more, and deletes it after asking:

```console
$ titan gc
keep    docker.io/library/node:22-bookworm  (needed by shop)
keep    docker.io/library/postgres:16-bookworm  (used by a VM)
remove  docker.io/library/golang:1.23-bookworm  280 MB
remove  titan-tool-node-20-ffffffffffff  (toolchain no project uses)

1 image(s), 280 MB download size (plus their unpacked copies on disk).
1 toolchain volume(s).
Delete them? [y/N]
```

- `titan gc --dry-run` only shows the list.
- It only removes things **Titan** created. `--all` also removes other unused images.
- Anything deleted is downloaded again automatically if a project needs it later.

> Titan knows about projects you've run `titan up` in. An old project you haven't opened
> since installing Titan just re-downloads its image next time. Nothing breaks.

### The package cache: `titan cache`

```console
$ titan cache
location    /Users/you/Library/Caches/titan/shared  (mounted in VMs at /titan-cache)
go modules  0 B
npm         310 MB
pip         45 MB
total       355 MB

$ titan cache clean        # empties it (packages are re-downloaded when needed)
```

### Remove a project's VM

```bash
titan down --rm          # remove the VM, keep database data
titan down --volumes     # remove the VM and its database data
```

Deleting the project folder doesn't remove its VM. Run `titan down --rm` first, or find
leftovers later: `titan ps` marks them with `?`, and `container delete <name>` removes them.

## A quick health routine

Once in a while:

```bash
titan ps            # anything running that you don't need? → titan down
titan gc            # old images/toolchains? → delete
```

That's the whole guide. For details on any setting, see the
[Configuration reference](../configuration.md). If something isn't working, see
[Troubleshooting](../troubleshooting.md).
