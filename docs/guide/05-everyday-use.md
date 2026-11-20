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
manoj@shop:/workspaces/shop$ whoami
manoj
manoj@shop:/workspaces/shop$ sudo apt-get install -y htop
…
manoj@shop:/workspaces/shop$ exit
$                                          ← back on your Mac
```

You're now *inside* the Linux VM, in your project folder, as **your own user**. It has
your Mac username, and the prompt shows the project name. It works like a normal Linux
machine:

| You want to… | Do |
|---|---|
| install system packages | `sudo apt-get install …` (no password) |
| install global tools | `npm i -g …`, `pip install …` (no `sudo` needed) |
| be root for a while | `titan shell --root` (or `sudo -i` inside) |
| leave | `exit` or Ctrl-D |

Files you create in the project folder belong to **you** on the Mac as well.

> Things you install with `apt-get` live in the VM only. They stay until the VM is rebuilt.
> To make them permanent for the whole team, put the install command in
> `postCreateCommand` in `devcontainer.json`.

**Which user?** Projects Titan set up (with `titan new`, `titan init`, or no config at all)
run as your user. A project with its own `devcontainer.json` runs as whoever that file says
(`remoteUser`), or as `root` if it doesn't say, just like in VS Code. To get your own user
there too, add `"customizations": {"titan": {"user": "me"}}`.

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
| `--root` (on `run` and `shell`) | Run as root instead of your user |
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
titan add postgres               add a database
titan share                      public link to your app
titan doctor                     check for problems
```

Next: [Databases and other services →](06-databases.md)
