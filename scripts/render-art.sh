#!/usr/bin/env bash
# Render the hand-made art (Resources/Art/source/*.svg: SVG filters for
# gouache, dry brush, pencil and grain) to PNGs at 2x with headless Chrome,
# and the app icon to Resources/AppIcon.icns.  The PNGs are committed; run
# this only after changing a source.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
SRC="$ROOT/Resources/Art/source"
OUT="$ROOT/Resources/Art"
WORK="$ROOT/build/art"
mkdir -p "$WORK"

render() { # svg, png, scale
    local svg="$1" png="$2" scale="$3"
    local w h
    w=$(sed -n 's/.*<svg[^>]* width="\([0-9]*\)".*/\1/p' "$svg" | head -1)
    h=$(sed -n 's/.*<svg[^>]* height="\([0-9]*\)".*/\1/p' "$svg" | head -1)
    printf '<!doctype html><html><body style="margin:0;background:transparent"><img src="%s" width="%s" height="%s" style="display:block"></body></html>' \
        "file://$svg" "$w" "$h" > "$WORK/view.html"
    "$CHROME" --headless=new --disable-gpu --hide-scrollbars --allow-file-access-from-files \
        --default-background-color=00000000 --force-device-scale-factor="$scale" \
        --window-size="$w,$h" --virtual-time-budget=3000 --screenshot="$png" "file://$WORK/view.html" 2>/dev/null
    echo "Rendered $(basename "$png")"
}

for svg in "$SRC"/*.svg; do
    name="$(basename "$svg" .svg)"
    [ "$name" = icon ] && continue
    render "$svg" "$OUT/$name.png" 2
done

render "$SRC/icon.svg" "$WORK/icon-1024.png" 1
ICONSET="$WORK/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for base in 16 32 128 256 512; do
    sips -z "$base" "$base" "$WORK/icon-1024.png" --out "$ICONSET/icon_${base}x${base}.png" >/dev/null
    sips -z $((base * 2)) $((base * 2)) "$WORK/icon-1024.png" --out "$ICONSET/icon_${base}x${base}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"
echo "Built Resources/AppIcon.icns"
