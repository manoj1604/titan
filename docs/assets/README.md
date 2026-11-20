# Brand assets

| File | Use |
|---|---|
| `icon.svg` | The Titan icon (source of truth): an isometric block letter **T** with a `>_` prompt |
| `icon-512.png` | PNG of the icon, transparent background (avatars, places without SVG) |
| `social-preview.png` | 1280×640 link preview (GitHub → Settings → General → Social preview) |
| `demo.svg` | Terminal session shown in the README |

The icon is a solid "T" (Titan: something sturdy) built from blocks, like the isolated VMs
Titan stacks from shared layers. The prompt marks it as a command-line tool. Colors: indigo
`#4F46E5` → violet `#8B3FE8`, block faces `#FFFFFF` / `#E4DEFF` / `#BDB0FA`, prompt `#5B3FD9`.

Everything here is generated. To change it, edit `scripts/brand/` and run:

```bash
scripts/brand/render.sh
```

The assets are licensed under Apache-2.0 with the rest of the project.
