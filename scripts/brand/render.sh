#!/bin/bash
# Regenerates Titan's brand assets in docs/assets/:
#   icon.svg (source of truth), icon-512.png, social-preview.png (1280x640), demo.svg
# Needs python3 and Google Chrome (used headless to render SVG/HTML to PNG).
set -euo pipefail
cd "$(dirname "$0")/../.."
A="$PWD/docs/assets"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$A"

python3 scripts/brand/make_icon.py "$A/icon.svg"
python3 scripts/brand/make_demo.py "$A/demo.svg"

shot() {  # shot <html> <png> <width> <height> [transparent]
  local extra=(); [ "${5:-}" = transparent ] && extra=(--default-background-color=00000000)
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --allow-file-access-from-files \
    --force-device-scale-factor=1 ${extra[@]+"${extra[@]}"} --window-size="$3,$4" --screenshot="$2" "file://$1" >/dev/null 2>&1
}
printf '<!doctype html><body style="margin:0;background:transparent"><img src="file://%s/icon.svg" width="512" height="512" style="display:block"></body>' "$A" > "$TMP/icon.html"
shot "$TMP/icon.html" "$A/icon-512.png" 512 512 transparent
sed "s|ICON_URL|file://$A/icon.svg|" scripts/brand/social-preview.html > "$TMP/social.html"
shot "$TMP/social.html" "$A/social-preview.png" 1280 640
echo "Regenerated: $(cd "$A" && ls icon.svg icon-512.png social-preview.png demo.svg | tr '\n' ' ')"
