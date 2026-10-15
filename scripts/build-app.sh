#!/usr/bin/env bash
# Build dist/CommonPlace.app: a release build, bundled with its Info.plist and
# icon, signed with the Developer ID Application identity when the keychain
# has one (hardened runtime), ad hoc otherwise.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
BIN="$BIN_DIR/CommonPlace"
MCP="$BIN_DIR/commonplace-mcp"
[ -x "$BIN" ] || { echo "FATAL: $BIN missing" >&2; exit 1; }
[ -x "$MCP" ] || { echo "FATAL: $MCP missing" >&2; exit 1; }

APP="$ROOT/dist/CommonPlace.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CommonPlace"
# The MCP server agents start, beside the app's own binary.
cp "$MCP" "$APP/Contents/MacOS/commonplace-mcp"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
# Instrument Serif, Geist and Geist Mono (SIL Open Font License; licences beside them).
cp -R "$ROOT/Resources/Fonts" "$APP/Contents/Resources/Fonts"
# The hand-made art (rendered from Resources/Art/source by scripts/render-art.sh).
mkdir -p "$APP/Contents/Resources/Art"
cp "$ROOT"/Resources/Art/*.png "$APP/Contents/Resources/Art/"

IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)}"
if [ -n "$IDENTITY" ]; then
    # Nested code first, then the bundle.
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/MacOS/commonplace-mcp"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
    echo "Signed with: $IDENTITY"
else
    codesign --force --sign - "$APP/Contents/MacOS/commonplace-mcp"
    codesign --force --sign - "$APP"
    echo "Signed ad hoc (no Developer ID identity found)"
fi
codesign --verify --strict "$APP"
echo "Built: $APP"
