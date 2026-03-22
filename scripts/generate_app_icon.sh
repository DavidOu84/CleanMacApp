#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ICON_DIR="$ROOT_DIR/dist/icon"
MASTER_PNG="$ICON_DIR/AppIcon-1024.png"
ICONSET="$ICON_DIR/AppIcon.iconset"
ICNS="$ICON_DIR/AppIcon.icns"

mkdir -p "$ICON_DIR"

TMP_SWIFT="$(mktemp /tmp/cleanmacapp-icon.XXXXXX.swift)"
trap 'rm -f "$TMP_SWIFT"' EXIT

cat >"$TMP_SWIFT" <<'SWIFT'
import AppKit
import Foundation

guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: generate_icon.swift <output_png>\n", stderr)
    exit(1)
}

let outputPath = CommandLine.arguments[1]
let size = 1024.0
let rect = NSRect(x: 0, y: 0, width: size, height: size)

let image = NSImage(size: rect.size)
image.lockFocus()

NSColor.clear.setFill()
rect.fill()

let bgRect = NSRect(x: 64, y: 64, width: 896, height: 896)
let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: 200, yRadius: 200)
let gradient = NSGradient(
    colors: [
        NSColor(calibratedRed: 0.13, green: 0.37, blue: 0.98, alpha: 1.0),
        NSColor(calibratedRed: 0.04, green: 0.68, blue: 0.96, alpha: 1.0),
        NSColor(calibratedRed: 0.11, green: 0.86, blue: 0.72, alpha: 1.0),
    ]
)!
gradient.draw(in: bgPath, angle: -45)

let cPath = NSBezierPath()
cPath.appendArc(
    withCenter: NSPoint(x: size * 0.5, y: size * 0.5),
    radius: 230,
    startAngle: 35,
    endAngle: 325,
    clockwise: false
)
cPath.lineWidth = 120
cPath.lineCapStyle = .round
NSColor(calibratedWhite: 1.0, alpha: 0.95).setStroke()
cPath.stroke()

let slash = NSBezierPath(roundedRect: NSRect(x: 566, y: 440, width: 248, height: 88), xRadius: 36, yRadius: 36)
NSColor(calibratedWhite: 1.0, alpha: 0.93).setFill()
slash.fill()

let sparkle = NSBezierPath()
sparkle.move(to: NSPoint(x: 772, y: 798))
sparkle.line(to: NSPoint(x: 798, y: 860))
sparkle.line(to: NSPoint(x: 860, y: 886))
sparkle.line(to: NSPoint(x: 798, y: 912))
sparkle.line(to: NSPoint(x: 772, y: 974))
sparkle.line(to: NSPoint(x: 746, y: 912))
sparkle.line(to: NSPoint(x: 684, y: 886))
sparkle.line(to: NSPoint(x: 746, y: 860))
sparkle.close()
NSColor(calibratedRed: 1.0, green: 0.84, blue: 0.30, alpha: 0.96).setFill()
sparkle.fill()

image.unlockFocus()

guard
    let tiffData = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiffData),
    let pngData = bitmap.representation(using: .png, properties: [:])
else {
    fputs("Failed to render icon image.\n", stderr)
    exit(1)
}

do {
    try pngData.write(to: URL(fileURLWithPath: outputPath))
    print("Generated master icon: \(outputPath)")
} catch {
    fputs("Failed writing icon png: \(error)\n", stderr)
    exit(1)
}
SWIFT

swift "$TMP_SWIFT" "$MASTER_PNG" >/dev/null

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

make_icon() {
  local size="$1"
  local name="$2"
  sips -z "$size" "$size" "$MASTER_PNG" --out "$ICONSET/$name" >/dev/null
}

make_icon 16 "icon_16x16.png"
make_icon 32 "icon_16x16@2x.png"
make_icon 32 "icon_32x32.png"
make_icon 64 "icon_32x32@2x.png"
make_icon 128 "icon_128x128.png"
make_icon 256 "icon_128x128@2x.png"
make_icon 256 "icon_256x256.png"
make_icon 512 "icon_256x256@2x.png"
make_icon 512 "icon_512x512.png"
make_icon 1024 "icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o "$ICNS"
echo "Generated icon: $ICNS"
