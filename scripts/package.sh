#!/bin/bash
# Builds a release tarball: dist/titan-<version>-macos-arm64.tar.gz (+ .sha256).
#
# Layout (a standard prefix, so Homebrew and manual installs work the same way):
#   bin/titan
#   share/titan/titan-fwd-linux-arm64          in-VM port forwarder (static Linux binary)
#   share/man/man1/titan.1
#   share/zsh/site-functions/_titan, share/bash-completion/completions/titan,
#   share/fish/vendor_completions.d/titan.fish
#   LICENSE NOTICE README.md CHANGELOG.md
#
# Needs: Swift 6, Go (for the forwarder). Usage: scripts/package.sh [version]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(sed -n 's/.*current = "\(.*\)".*/\1/p' Sources/TitanCore/Version.swift)}"
CODE_VERSION="$(sed -n 's/.*current = "\(.*\)".*/\1/p' Sources/TitanCore/Version.swift)"
if [ "$VERSION" != "$CODE_VERSION" ]; then
  echo "error: version $VERSION doesn't match Sources/TitanCore/Version.swift ($CODE_VERSION)" >&2
  exit 1
fi
NAME="titan-$VERSION-macos-arm64"
STAGE="dist/$NAME"

echo "==> Building titan $VERSION (release, arm64)"
swift build -c release --arch arm64
make forwarder >/dev/null

echo "==> Generating man page"
swift package plugin --allow-writing-to-package-directory generate-manual >/dev/null

rm -rf "$STAGE" && mkdir -p "$STAGE"/{bin,share/titan,share/man/man1,share/zsh/site-functions,share/bash-completion/completions,share/fish/vendor_completions.d}
install -m 755 .build/arm64-apple-macosx/release/titan "$STAGE/bin/titan"
install -m 755 .build/titan-share/titan-fwd-linux-arm64 "$STAGE/share/titan/"
install -m 644 .build/plugins/GenerateManual/outputs/titan/titan.1 "$STAGE/share/man/man1/titan.1"
"$STAGE/bin/titan" --generate-completion-script zsh  > "$STAGE/share/zsh/site-functions/_titan"
"$STAGE/bin/titan" --generate-completion-script bash > "$STAGE/share/bash-completion/completions/titan"
"$STAGE/bin/titan" --generate-completion-script fish > "$STAGE/share/fish/vendor_completions.d/titan.fish"
cp LICENSE NOTICE README.md CHANGELOG.md "$STAGE/"

# Sanity: the packaged binary runs and finds its forwarder.
test "$("$STAGE/bin/titan" --version)" = "$VERSION"

tar -C dist -czf "dist/$NAME.tar.gz" "$NAME"
(cd dist && shasum -a 256 "$NAME.tar.gz" > "$NAME.tar.gz.sha256")
echo "==> dist/$NAME.tar.gz"
cat "dist/$NAME.tar.gz.sha256"
