"""Generates Titan's icon: an isometric block-built "T" with a prompt chevron, on a gradient tile."""
import math, sys

COS, SIN = math.cos(math.radians(30)), math.sin(math.radians(30))

def iso(x, y, z):
    return ((x - y) * COS, (x + y) * SIN - z)

# Boxes in grid units: the T's bar and stem.
BAR = dict(x=(0, 3), y=(0, 1), z=(3, 4))
STEM = dict(x=(1, 2), y=(0, 1), z=(0, 3))

def faces(b, top=True):
    (x0, x1), (y0, y1), (z0, z1) = b["x"], b["y"], b["z"]
    out = []
    out.append(("left",  [(x0, y1, z0), (x1, y1, z0), (x1, y1, z1), (x0, y1, z1)]))   # faces +y (lower-left)
    out.append(("right", [(x1, y0, z0), (x1, y1, z0), (x1, y1, z1), (x1, y0, z1)]))   # faces +x (lower-right)
    if top:
        out.append(("top", [(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)]))
    return out

polys = faces(STEM, top=False) + faces(BAR)   # painter's order: stem first, bar above it

# Fit into the tile.
pts = [iso(*p) for _, poly in polys for p in poly]
minx, maxx = min(p[0] for p in pts), max(p[0] for p in pts)
miny, maxy = min(p[1] for p in pts), max(p[1] for p in pts)
SIZE, MARGIN = 512, 92
scale = min((SIZE - 2 * MARGIN) / (maxx - minx), (SIZE - 2 * MARGIN) / (maxy - miny))
ox = SIZE / 2 - (minx + maxx) / 2 * scale
oy = SIZE / 2 - (miny + maxy) / 2 * scale + 6   # optical centring: a touch lower

def P(x, y, z):
    sx, sy = iso(x, y, z)
    return f"{ox + sx * scale:.1f},{oy + sy * scale:.1f}"

FILL = {"top": "#FFFFFF", "left": "#E4DEFF", "right": "#BDB0FA"}
shapes = "\n".join(
    f'    <polygon points="{" ".join(P(*p) for p in poly)}" fill="{FILL[kind]}"/>' for kind, poly in polys)

# A ">_" prompt on the stem's front (left-facing, y=1) face: x in [1,2], z in [0,3].
chev = " ".join(P(*p) for p in [(1.22, 1, 2.30), (1.66, 1, 1.86), (1.22, 1, 1.42)])
under = f'{P(1.24, 1, 0.92)} {P(1.80, 1, 0.92)}'
prompt = (f'    <polyline points="{chev}" fill="none" stroke="#5B3FD9" stroke-width="{scale*0.13:.1f}" '
          f'stroke-linecap="round" stroke-linejoin="round"/>\n'
          f'    <polyline points="{under}" fill="none" stroke="#5B3FD9" stroke-width="{scale*0.13:.1f}" stroke-linecap="round"/>')

svg = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512" role="img" aria-label="Titan">
  <title>Titan</title>
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#4F46E5"/>
      <stop offset="1" stop-color="#8B3FE8"/>
    </linearGradient>
    <radialGradient id="glow" cx="0.3" cy="0.2" r="0.9">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.22"/>
      <stop offset="0.6" stop-color="#FFFFFF" stop-opacity="0"/>
    </radialGradient>
    <filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="10" stdDeviation="12" flood-color="#1E1065" flood-opacity="0.35"/>
    </filter>
  </defs>
  <rect width="512" height="512" rx="114" fill="url(#bg)"/>
  <rect width="512" height="512" rx="114" fill="url(#glow)"/>
  <g filter="url(#shadow)" stroke="#FFFFFF" stroke-width="1" stroke-linejoin="round">
{shapes}
  </g>
  <g>
{prompt}
  </g>
</svg>
'''
open(sys.argv[1], "w").write(svg)
print("wrote", sys.argv[1], f"(scale {scale:.1f}px per unit)")
