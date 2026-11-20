# 7. Ports, URLs and sharing

**Time:** 5 minutes · **You'll learn to:** open your app in the browser, handle busy ports,
and share a public link

## How your app reaches the browser

Your app runs inside the VM, and Titan opens its port on your Mac's `localhost`:

```
 browser → http://localhost:5173 ──▶ VM "shop" → your app on port 5173
```

Which ports? The ones in `forwardPorts` in `devcontainer.json`, or the framework's usual port
when Titan detected your project. `titan status` lists them:

```console
ports     5173
```

**It works no matter how your app listens.** Many dev servers listen only on "localhost"
by default (Vite, Django, Flask, Rails). Normally that makes them unreachable from outside
a VM, but Titan handles it. You don't need `--host 0.0.0.0` flags.

## Add a port

Edit `devcontainer.json`:

```jsonc
"forwardPorts": [5173, 6006]      // e.g. your app + Storybook
```

Then run `titan rebuild`.

## When a port is already taken

If something on your Mac already uses the port (another project, or another app), Titan
picks the next free one and tells you:

```console
! Port 5173 is busy on this Mac; forwarding localhost:5174 → 5173 in the VM.
✓ shop is ready → http://localhost:5174
```

Your app still uses 5173 inside the VM, so nothing in your code changes. Just open the URL
Titan prints. `titan status` and `titan ps` show the mapping as `5174→5173`.

> **macOS uses port 5000** for AirPlay Receiver, so Flask apps often land on 5001. That's
> normal.

**Need the exact port** (for example for an OAuth callback URL)? Make Titan fail instead of
picking another:

```jsonc
"customizations": { "titan": { "strictPorts": true } }
```

## Share a public link

Show your work to someone, test on your phone, or receive webhooks:

```console
$ titan share
  https://quiet-river-1234.trycloudflare.com  → shop:5173
  Anyone with this link can reach your app.
  Press Ctrl-C to close it.
```

Needs `cloudflared` once (`brew install cloudflared`). A quick link needs no account. It's
random, works while the command runs, and can take about 10 seconds to start working.

### Keep it running, protect it, limit it

| You want to… | Run |
|---|---|
| keep the link after closing the terminal | `titan share --background` (or `-b`) |
| ask visitors for a password | `titan share --protect` (Titan makes one up) or `--password <yours>` |
| close it automatically | `titan share --ttl 2h` (also `30m`, `1d`) |
| share two ports | `titan share 5173 8000` (one link each) |
| see running links | `titan share --list` (also shown in `titan ps` and `titan status`) |
| see who is visiting | `titan share --log` |
| close links | `titan share --stop` (`titan down` closes them too) |

```console
$ titan share -b --protect --ttl 2h
  https://quiet-river-1234.trycloudflare.com  → shop:5173
  password: c6jb-8xsr-kp66-v46h  (any user name)
  closes at 6:15 PM
```

With a password, visitors get a login prompt. For webhooks and scripts, put it in the URL:
`https://any:c6jb-8xsr-kp66-v46h@quiet-river-1234.trycloudflare.com/hook`.

If your app isn't running, visitors see a "shop isn't answering yet" page that reloads by
itself, instead of an error.

### A stable address on your own domain

For webhooks (Stripe, GitHub), OAuth callbacks and demos, you want an address that never
changes. If your domain uses Cloudflare (the free plan is fine):

```console
$ cloudflared tunnel login                         # once: pick your domain in the browser
$ titan share --domain dev.example.com
▸ Creating Cloudflare tunnel titan-dev-example-com
▸ Pointing dev.example.com at the tunnel
  https://dev.example.com  → shop:5173
```

- Titan **remembers** the address for this project, so later `titan share` reuses it.
  `titan share --forget` goes back to quick links.
- `--always` brings it up whenever the project's VM starts (`titan up`).
- It combines with `--protect`, `--background` and `--ttl`.
- Titan **never replaces an existing DNS record**. If `dev.example.com` already points
  somewhere, it says so, and you pick another name.
- The address is stored on your Mac only, never in `devcontainer.json`, so teammates don't
  inherit your domain.

> ⚠️ **Anyone with the link can reach your app** unless you use `--protect`. Don't share
> apps with private data openly, and close links when you're done.

If your app is picky about its hostname, Titan already handles that by telling your app the
request came from `localhost`. Use `--keep-host` to pass the real public hostname through
instead.

Next: [Working in a team →](08-teams.md)
