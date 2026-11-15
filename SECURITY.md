# Security policy

## Reporting a vulnerability

Please **do not open a public issue** for security problems. Report them privately through
GitHub's [private vulnerability reporting](https://github.com/manoj1604/titan/security/advisories/new)
("Security" tab → "Report a vulnerability").

Please include what you found, how to reproduce it, and what an attacker could do with it.
We aim to acknowledge reports within 3 working days and to agree on a fix and disclosure
timeline with you. We're happy to credit you in the advisory.

## Supported versions

Titan is in 0.x. Security fixes go into the latest release only.

## Scope notes

Some behaviour is intended, but worth knowing about:

- **VMs see the project folder read-write**, plus the shared package cache
  (`~/Library/Caches/titan/shared`). They don't see the rest of your home folder.
- **`postCreateCommand` and generators run code from the project inside its VM.** Treat an
  untrusted repository's devcontainer.json the way you'd treat its build scripts.
- **Ports are published on `127.0.0.1` only.** `titan share` deliberately makes one port
  public through a Cloudflare quick tunnel, until you stop it.
- **The shell hook only routes folders with committed Titan config** (devcontainer.json,
  titan.lock) or ones you've run `titan up` in.
