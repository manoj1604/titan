# 5. Everyday commands

**Time:** 5 minutes · This page is the one to bookmark.

## Just work normally

In a project folder (with the shell hook from [Install](01-install.md)), type your usual
commands. They run in the VM:

```bash
npm install
npm run dev
python manage.py migrate
go test ./...
```

Which commands go to the VM? The ones listed under `shims` in `titan status`, such as
`node npm npx` or `python pip`. Everything else (`git`, `ls`, your editor) runs on your Mac
as usual.

**Hot reload works.** Edit files on your Mac and dev servers in the VM (Vite, Next.js,
nodemon, `uvicorn --reload`, Django, Flask…) reload right away. While the VM runs, Titan
passes your Mac's file changes into it. (Without that, the VM wouldn't notice edits made
on the Mac.)

## Run any command in the VM

For commands that aren't shims, or when the hook isn't loaded:

```bash
titan run -- <command>
```

```console
$ titan run -- uname -a
Linux titan-shop-65578934 6.18.56 … aarch64 GNU/Linux
$ titan run -- ls /workspaces/shop
index.html  node_modules  package.json  src  …
```

Everything after `--` goes to the command unchanged. Ctrl-C, colors and exit codes work
normally, and you can pipe output: `titan run -- npm ls | grep react`.

## Open a shell inside the VM

```console
$ titan shell
root@titan-shop-65578934:/workspaces/shop# apt-get install -y htop
…
root@titan-shop-65578934:/workspaces/shop# exit
$                                          ← back on your Mac
```

You're now *inside* the Linux VM, in your project folder. The prompt shows the user
(`root`) and the VM's name. Explore, install system packages (`apt-get install …`) and run
anything. Type `exit` (or Ctrl-D) to come back. The VM keeps running after you leave.

**`titan` works inside the shell too**, for the commands that make sense there. It asks
titan on your Mac to run them:

```console
root@titan-shop-…:/workspaces/shop# titan share 7000      # a public link (runs in the background)
root@titan-shop-…:/workspaces/shop# titan status          # also: ps, stats, lock, share --list / --stop
```

Commands that change things on your Mac (`down`, `rebuild`, `gc`…) only run on the Mac, so a
script inside the VM can't stop VMs or delete data.

Files you create in the project folder still belong to **you** on the Mac. And `code file`
(or `cursor file`) inside the shell opens that file in your editor **on the Mac**. See
[Editors](09-editors.md#open-the-editor-from-the-terminal).

> Things you install with `apt-get` live in the VM only. They stay until the VM is rebuilt.
> To make them permanent for the whole team, put the install command in
> `postCreateCommand` in `devcontainer.json`.

**From any folder, by name:**

```bash
titan shell shop                 # a project, by the name shown in `titan ps`
titan shell titan-shop-65578934  # or by its VM name
titan shell shop/postgres        # a service's VM (a root shell in the database VM)
titan shell ~/code/shop          # or by folder
```

If two projects have the same name (say, two clones), Titan lists them; use the VM name
or the folder.

**Prefer your own user** (`manoj@shop:/workspaces/shop$`, with `sudo`)? Add
`"customizations": {"titan": {"user": "me"}}` to `devcontainer.json` and run `titan rebuild`.
See [The user in the VM](../configuration.md#the-user-in-the-vm).

## Start, stop, rebuild

| You want to… | Command | What happens |
|---|---|---|
| Start the VM | `titan up` | Creates it if needed, or starts it. Usually you don't need this, because any command starts it. |
| Stop it (free memory) | `titan down` | Stops the VM (and its services). Next command restarts it in about a second. |
| Delete it | `titan down --rm` | Removes the VM. Your code and database data are kept. |
| Apply config changes | `titan rebuild` | Recreates the VM from the current `devcontainer.json`. |

**When do I need `titan rebuild`?** After you change `devcontainer.json` (a new image,
ports or setup command). Titan notices and tells you:

```console
! Environment config changed since this VM was created. Run `titan rebuild` to apply it.
```

## See what's going on

| Command | Shows |
|---|---|
| `titan status` | This project: VM state, image, ports, services, memory |
| `titan ps` | **All** Titan VMs on your Mac, with their folders and ports |
| `titan stats` | Live CPU, memory, disk and network for this project's VM (`--watch` to keep refreshing) |
| `titan logs postgres` | A service's log (`-f` to follow, `-n 50` for the last 50 lines; `--boot` for the VM's boot log) |
| `titan doctor` | Checks your Mac and this project, and tells you how to fix problems |

Example `titan ps`:

```console
PROJECT     FOLDER               STATUS   MEMORY           PORTS
shop        ~/code/shop          running  122 MB / 8.0 GB  localhost:5173
  └ postgres                     running   48 MB / 1.0 GB  localhost:5432
blog        ~/code/blog          stopped  -                localhost:3000

2 running · 1 stopped · 170 MB memory in use
```

## Run a command on your Mac instead

Sometimes you want the Mac's own tool (for example your Mac's `node`):

```bash
TITAN_DISABLE=1 node -v
```

## Useful options for any command

| Option | Effect |
|---|---|
| `--root` (on `run` and `shell`) | Run as root, in projects set to use your own user |
| `-C <folder>` | Run as if you were in that folder: `titan -C ~/code/shop status` |
| `-v` | Show the underlying commands Titan runs (good for debugging) |
| `--dry-run` | Show what would happen without doing it |
| `titan help <command>` | Help for any command |

## Cheat sheet

```text
titan new <name> -t <template>   create a project
titan up / down / rebuild        start · stop · recreate the VM
titan run -- <cmd>               run one command in the VM
titan shell                      open a shell in the VM
titan status · ps · stats        this project · all VMs · live usage
titan logs <service>             a service's log (-f to follow)
titan add postgres               add a database
titan share                      public link to your app
titan doctor                     check for problems
```

Next: [Databases and other services →](06-databases.md)
