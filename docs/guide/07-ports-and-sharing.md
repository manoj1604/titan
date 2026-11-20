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
▸ Opening a tunnel to localhost:5173…

  https://quiet-river-1234.trycloudflare.com

  Anyone with this link can reach your app. Press Ctrl-C to close it.
```

- Needs `cloudflared` once: `brew install cloudflared`. No account required.
- The link works **only while the command runs**. Press Ctrl-C and it's gone.
- A brand-new link can take about 10 seconds before it opens.
- Options: `titan share 3000` (a specific port), `--copy` (copy the link to the
  clipboard).

> ⚠️ **Anyone with the link can use your app.** Don't share apps that contain private data,
> and close the tunnel when you're done.

If your app is picky about its hostname, Titan already handles that by telling your app the
request came from `localhost`. Use `--keep-host` to pass the real public hostname through
instead.

Next: [Working in a team →](08-teams.md)
