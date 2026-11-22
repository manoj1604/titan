# 1. Install Titan

**Time:** about 5 minutes (plus downloads) · **You'll need:** your Mac and an internet connection

## Step 1: Check your Mac

Titan needs:

- **A Mac with Apple silicon** (M1, M2, M3, M4 or later). Check it: Apple menu →
  **About This Mac**. The "Chip" line should say **Apple M…**
- **macOS 26 or later.** Check it on the same screen.

Intel Macs aren't supported. Titan uses Apple's VM technology, which needs Apple silicon.

## Step 2: Install Titan

Pick **one** way.

**With Homebrew (recommended).** If you don't have Homebrew yet, install it from
[brew.sh](https://brew.sh) first.

```bash
brew install manoj1604/titan/titan
```

**Without Homebrew.** Download the release and copy it into place:

```bash
curl -fsSL https://github.com/manoj1604/titan/releases/latest/download/titan-macos-arm64.tar.gz | tar -xz
cd titan-*-macos-arm64
sudo cp -R bin share /usr/local/
```

Check that it worked:

```console
$ titan --version
0.5.0
```

> You do **not** need Xcode. Titan is a ready-made program, and all project tools (Node,
> Python, compilers…) run inside the VM, not on your Mac.

## Step 3: There is no step 3

There's no separate setup. The first time you run `titan create` in a project (next
chapters), Titan finishes setting up your Mac by itself:

| It sets up | Why it matters |
|---|---|
| **Apple's container service** | It runs the VMs. The first time, it downloads a small Linux kernel (about 30 MB). |
| **Your shell** | A few lines in `~/.zshrc`, `~/.zshenv` and `~/.zprofile` make commands like `npm` and `python` run in the right VM when you're in a project folder, in every terminal, script and coding agent. |
| **VS Code** (if installed) | Its terminal opens inside the VM in Titan projects. |
| **Claude Code** (if installed) | In Titan projects, its commands run in the VM and it only writes inside the project. |

Afterwards, **open a new terminal window or tab** so it picks up the shell changes.

You're ready. Next: [The big idea →](02-key-ideas.md)

---

### If something goes wrong

- **"Apple's container tool isn't installed":** `brew install container`, or install
  Apple's package from [github.com/apple/container/releases](https://github.com/apple/container/releases).
- **You don't want Titan to touch your shell files:** set `TITAN_NO_SHELL_HOOK=1`. Titan
  still works through `titan run -- <command>`.
- **Anything else:** run `titan doctor` and see [Troubleshooting](../troubleshooting.md).

### Uninstall

```bash
brew uninstall titan                                     # or delete bin/titan and share/titan
rm -rf ~/Library/Application\ Support/titan ~/Library/Caches/titan
```

Then delete the blocks between `# >>> titan >>>` / `# <<< titan <<<` (in `~/.zshrc`) and
`# >>> titan shims >>>` / `# <<< titan shims <<<` (in `~/.zshenv`, `~/.zprofile`), and `~/.titan`.
