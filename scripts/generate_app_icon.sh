#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS_DIR="$ROOT/assets"
TMP_DIR="$(mktemp -d)"
ICONSET_DIR="$TMP_DIR/AppIcon.iconset"
OUT_ICNS="$ASSETS_DIR/AppIcon.icns"
OUT_PREVIEW="$ASSETS_DIR/AppIcon-preview.png"

mkdir -p "$ASSETS_DIR" "$ICONSET_DIR"

cat > "$TMP_DIR/generate.swift" <<'SWIFT'
import AppKit

struct IconGenerator {
    let outputDir: URL

    func run() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let entries: [(String, Int)] = [
            ("icon_16x16.png", 16),
            ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32),
            ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128),
            ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256),
            ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512),
            ("icon_512x512@2x.png", 1024)
        ]

        for (name, size) in entries {
            let image = drawIcon(size: size)
            let url = outputDir.appendingPathComponent(name)
            try write(image: image, to: url)
        }
    }

    private func drawIcon(size: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        let radius = CGFloat(size) * 0.225

        let background = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        let gradient = NSGradient(colorsAndLocations:
            (NSColor(calibratedRed: 0.10, green: 0.15, blue: 0.35, alpha: 1.0), 0.0),
            (NSColor(calibratedRed: 0.16, green: 0.25, blue: 0.52, alpha: 1.0), 0.55),
            (NSColor(calibratedRed: 0.24, green: 0.38, blue: 0.70, alpha: 1.0), 1.0)
        )!
        gradient.draw(in: background, angle: -90)

        let inset = CGFloat(size) * 0.06
        let highlightRect = rect.insetBy(dx: inset, dy: inset)
        let highlight = NSBezierPath(roundedRect: highlightRect, xRadius: radius * 0.85, yRadius: radius * 0.85)
        NSColor.white.withAlphaComponent(0.08).setFill()
        highlight.fill()

        let symbolSize = CGFloat(size) * 0.66
        let config = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .bold, scale: .large)
        if let symbol = NSImage(systemSymbolName: "bolt.horizontal.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            let symbolRect = NSRect(
                x: (CGFloat(size) - symbolSize) / 2,
                y: (CGFloat(size) - symbolSize) / 2,
                width: symbolSize,
                height: symbolSize
            )
            NSColor.white.withAlphaComponent(0.95).set()
            symbol.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1)
        }

        image.unlockFocus()
        return image
    }

    private func write(image: NSImage, to url: URL) throws {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "IconGenerator", code: 1)
        }
        try data.write(to: url)
    }
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
do {
    try IconGenerator(outputDir: output).run()
} catch {
    fputs("Icon generation failed: \(error)\n", stderr)
    exit(1)
}
SWIFT

swift "$TMP_DIR/generate.swift" "$ICONSET_DIR"
iconutil -c icns "$ICONSET_DIR" -o "$OUT_ICNS"
cp "$ICONSET_DIR/icon_512x512.png" "$OUT_PREVIEW"

rm -rf "$TMP_DIR"
echo "Generated:"
echo "  $OUT_ICNS"
echo "  $OUT_PREVIEW"
