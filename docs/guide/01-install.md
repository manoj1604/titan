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
0.3.1
```

> You do **not** need Xcode. Titan is a ready-made program, and all project tools (Node,
> Python, compilers…) run inside the VM, not on your Mac.

## Step 3: Run `titan setup`

```bash
titan setup
```

This checks your Mac and fixes anything that's missing. It **asks before it changes
anything**. Here's what you'll see, line by line:

```console
Checking this Mac
✓ Apple silicon, macOS 26.1                          ← your Mac is supported
✓ container CLI version 1.7.1                        ← Apple's VM tool is installed
✓ container service running                          ← the VM service is started
✓ port forwarder (/opt/homebrew/share/titan)         ← part of Titan, found
    Titan will add to /Users/you/.zshrc:
      # >>> titan >>>
      # Runs project commands inside their Titan VM. Remove this block to uninstall.
      [ -x /opt/homebrew/bin/titan ] && eval "$(/opt/homebrew/bin/titan hook zsh)"
      # <<< titan <<<
    Add the shell hook to .zshrc? [Y/n]                ← press Enter to agree
✓ shell hook added to /Users/you/.zshrc
▸ Starting a test VM (debian:bookworm)…
✓ test VM: Linux aarch64 in 1.3s                     ← a real Linux VM just ran
✓ This Mac is ready for Titan.
```

What each step does:

| Step | Why it matters |
|---|---|
| **Apple `container`** | The tool from Apple that runs the VMs. If it's missing, setup offers to install it with Homebrew. |
| **Container service** | It must be running for VMs to start. The first time, it downloads a small Linux kernel (about 30 MB). |
| **Port forwarder** | Lets you open apps running in a VM at `localhost` in your browser. |
| **Shell hook** | A few lines in your shell's startup file. They make commands like `npm` and `python` run inside the right VM automatically when you're in a project folder. |
| **Test VM** | Proves everything works end to end. |

## Step 4: Open a new terminal window

The shell hook loads when a terminal starts, so **open a new terminal window or tab**
(or run `source ~/.zshrc`).

Check that the hook is active:

```console
$ echo $TITAN_HOOK
zsh
```

You're ready. Next: [The big idea →](02-key-ideas.md)

---

### If something goes wrong

- **"container CLI not found" and setup can't install it:** install Homebrew from
  [brew.sh](https://brew.sh) and run `titan setup` again, or install Apple's package from
  [github.com/apple/container/releases](https://github.com/apple/container/releases).
- **You said "no" to the shell hook:** that's fine. Titan still works through
  `titan run -- <command>`. Run `titan setup` again whenever you want the hook.
- **Anything else:** run `titan doctor` and see [Troubleshooting](../troubleshooting.md).

### Uninstall

```bash
brew uninstall titan                                     # or delete bin/titan and share/titan
rm -rf ~/Library/Application\ Support/titan ~/Library/Caches/titan
```

Then delete the block between `# >>> titan >>>` and `# <<< titan <<<` in `~/.zshrc`.
