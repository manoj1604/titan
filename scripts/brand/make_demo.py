"""Terminal demo image for the README (output mirrors real `titan new` / `titan shell` runs)."""
import sys
from xml.sax.saxutils import escape
W, LH, PAD, TOP = 880, 24, 26, 64
C = {"p": "#7EE787", "cmd": "#E6EDF3", "dim": "#8B949E", "step": "#79C0FF", "ok": "#56D364", "url": "#D2A8FF", "hi": "#E6EDF3"}
lines = [
    [("p", "$ "), ("cmd", "titan new shop --template vite --with postgres")],
    [("hi", "  shop"), ("dim", "  (Vite + React + TypeScript)")],
    [("dim", "  base      Debian + tools  buildpack-deps:bookworm  on this Mac")],
    [("dim", "  runtime   Node 22         shared toolchain store   on this Mac")],
    [("dim", "  service   postgres        postgres:16-bookworm     ↓ ~160 MB")],
    [("dim", "  disk      ~640 MB needed, 9.7 GB free "), ("ok", "✓")],
    [("step", "▸ "), ("cmd", "Starting service "), ("hi", "postgres")],
    [("step", "▸ "), ("cmd", "Creating VM titan-shop-65578934 from buildpack-deps:bookworm")],
    [("step", "▸ "), ("cmd", "generate: npm create vite@latest shop -- --template react-ts")],
    [("step", "▸ "), ("cmd", "postCreate: npm install")],
    [("ok", "✓ "), ("cmd", "shop is ready → "), ("url", "http://localhost:5173")],
    [],
    [("p", "$ "), ("cmd", "npm run dev"), ("dim", "                                  # runs in the VM")],
    [("dim", "  VITE v6.0.0  ready in 412 ms   ➜  Local: "), ("url", "http://localhost:5173/")],
    [],
    [("p", "$ "), ("cmd", "titan shell")],
    [("hi", "root@titan-shop-65578934:/workspaces/shop# "), ("cmd", "code src/App.tsx"), ("dim", "   # opens on your Mac")],
]
H = TOP + len(lines) * LH + PAD
out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" aria-label="titan new creating a Vite project with Postgres, then npm run dev and titan shell">',
       '  <title>A Titan session</title>',
       f'  <rect width="{W}" height="{H}" rx="12" fill="#0D1117"/>',
       f'  <rect x="0.5" y="0.5" width="{W-1}" height="{H-1}" rx="12" fill="none" stroke="#30363D"/>',
       '  <circle cx="22" cy="20" r="6" fill="#FF5F57"/><circle cx="42" cy="20" r="6" fill="#FEBC2E"/><circle cx="62" cy="20" r="6" fill="#28C840"/>',
       f'  <text x="{W/2}" y="25" text-anchor="middle" fill="#8B949E" font-family="-apple-system, Segoe UI, Helvetica, sans-serif" font-size="13">~/code</text>',
       '  <g font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="14.5">']
for i, segs in enumerate(lines):
    if not segs: continue
    spans = "".join(f'<tspan fill="{C[c]}">{escape(t)}</tspan>' for c, t in segs)
    out.append(f'    <text xml:space="preserve" style="white-space:pre" x="{PAD}" y="{TOP + i * LH}">{spans}</text>')
out += ['  </g>', '</svg>']
open(sys.argv[1], 'w').write("\n".join(out) + "\n")
