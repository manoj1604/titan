# FAQ

### Is Titan like Docker Desktop?
It solves a similar problem in a different way. Docker Desktop runs one big Linux VM that
all containers share. Titan gives **each project its own lightweight VM** (Apple's
`container` technology), set up from the project's own `devcontainer.json`. There's no
Docker, no background app and no account.

### Do I need Docker installed?
No.

### Do I need Xcode?
No. Titan is a ready-made program, and project tools (Node, Python, compilers) run in the
VM. Homebrew itself installs Apple's small Command Line Tools, but not Xcode.

### Does it work on Intel Macs or older macOS?
No. It needs Apple silicon and macOS 26 or later, because that's what Apple's `container`
requires.

### Do I need Node/Python/Go on my Mac?
No. They run inside each project's VM, even when you create a new project with `titan new`.

### Is it slow?
No. VMs start in about a second, commands start in about 0.15 s, and code runs at native
Apple-silicon speed (they're arm64 Linux VMs). File edits are visible in the VM instantly.

### How much disk and memory does it use?
A VM is about 20 MB on disk; images and toolchains are shared between projects. An idle VM
uses about 60–120 MB of memory. See [Disk space, memory and cleanup](guide/10-disk-and-cleanup.md).

### Where are my files? Are they inside the VM?
Your files stay in your project folder **on your Mac**. The VM sees that folder, so edits on
either side appear instantly. Nothing is copied, and deleting a VM never deletes your code.

### Can two projects run at the same time?
Yes, each in its own VM. If they want the same port, the second one gets the next free port
(Titan tells you which).

### Can several projects share one VM?
Not yet. One VM per project keeps projects from breaking each other. An opt-in shared mode
is on the roadmap.

### Does Titan send any data anywhere?
No telemetry. Titan only contacts image registries when it downloads images, and Cloudflare
when **you** run `titan share`.

### Can I use my existing `devcontainer.json`?
Usually yes: image, build, ports, environment variables and setup commands work. Not yet
supported: Docker Compose files, Dev Container features other than `node`/`python`, and
non-root users. See the [Configuration reference](configuration.md).

### My teammates don't use Titan. Is that a problem?
No. The same `devcontainer.json` works in VS Code Dev Containers and GitHub Codespaces.

### Can I run GUI apps or Docker inside the VM?
GUI apps: no, the VMs are for command-line tools and servers. Docker-in-VM: not supported yet.

### How do I update Titan?
`brew upgrade titan`. Your projects and VMs keep working.

### How do I reset a project completely?
`titan down --volumes` (removes the VM and database data), then `titan up`.

### Is it free?
Yes. Titan is open source under the Apache 2.0 license.
