#!/bin/bash
# Maintainer-only: regenerates the Finder layout of the release DMG, which Scripts/release.sh copies into
# every DMG (it is not part of the release or install path and needs a logged-in GUI session):
#   Resources/DMG/background.tiff   640x400 pt background, 1x + 2x
#   Resources/DMG/DS_Store          the volume's .DS_Store: icon view, no toolbar, icon positions, background
#                                   (no leading dot: .gitignore ignores .DS_Store)
# Finder itself writes the .DS_Store, so the first run asks once to let the terminal control Finder. Finder records
# whether its tab bar is showing, so choose View > Hide Tab Bar in Finder first (the script checks).
# Commit both files after checking a DMG built with them in Light and Dark appearance.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/Resources/DMG"
VOL=/Volumes/Lint # release.sh names the volume Lint; the background is found by this path
WORK=""
MOUNTED=""

die() { echo "error: $*" >&2; exit 1; }
cleanup() {
  if [ -n "$MOUNTED" ]; then hdiutil detach "$VOL" -quiet || hdiutil detach "$VOL" -force -quiet || true; fi
  if [ -n "$WORK" ]; then rm -rf "$WORK"; fi
}
trap cleanup EXIT

[ ! -e "$VOL" ] || die "$VOL already exists; eject that volume first"
# Under /tmp, not $TMPDIR: the background's alias in .DS_Store records the path of the image it was made on.
WORK=$(mktemp -d /tmp/lint-dmg-layout.XXXXXX)
mkdir -p "$OUT"

echo "==> Drawing the background"
cat >"$WORK/background.swift" <<'SWIFT'
import AppKit

let W: CGFloat = 640, H: CGFloat = 400

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

// A four-pointed sparkle with pinched sides.
func sparkle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ fill: NSColor) {
    let tips = [NSPoint(x: x, y: y - r), NSPoint(x: x + r, y: y), NSPoint(x: x, y: y + r), NSPoint(x: x - r, y: y)]
    let path = NSBezierPath()
    path.move(to: tips[0])
    for (a, b) in zip(tips, tips.dropFirst() + [tips[0]]) {
        let pinch = NSPoint(x: x + (a.x + b.x - 2 * x) * 0.14, y: y + (a.y + b.y - 2 * y) * 0.14)
        path.curve(to: b, controlPoint1: pinch, controlPoint2: pinch)
    }
    fill.setFill()
    path.fill()
}

// Drawn in points with y pointing down, like Finder's icon positions: Lint.app at (160, 205),
// Applications at (480, 205), 128 pt icons, labels just below y 270.
func draw(_ ctx: CGContext) {
    // Violet mid-tones: the label rows stay near relative luminance 0.2, so Finder's black (Light) and
    // white (Dark) labels both read.
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [color(0xa27cfa).cgColor, color(0x8e62f5).cgColor, color(0x774de3).cgColor] as CFArray,
                              locations: [0, 0.62, 1])!
    ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: H), options: [])

    for (x, y, r, hex, alpha) in [
        (54.0, 60.0, 17.0, 0xffffff, 0.9), (98, 108, 8, 0xfcd34d, 0.9), (584, 56, 14, 0xffffff, 0.85),
        (546, 118, 7, 0xffffff, 0.7), (600, 346, 15, 0xfcd34d, 0.85), (42, 350, 10, 0xffffff, 0.75),
        (320, 348, 9, 0xffffff, 0.6), (206, 42, 7, 0xfcd34d, 0.8),
    ] as [(CGFloat, CGFloat, CGFloat, UInt32, CGFloat)] {
        sparkle(x, y, r, color(hex, alpha))
    }

    // The arrow: a dashed arch from Lint.app over to Applications, ending in a rounded head.
    let amber = color(0xfcd34d)
    let shadow = NSShadow()
    shadow.shadowColor = color(0x2e1065, 0.45)
    shadow.shadowBlurRadius = 4
    shadow.shadowOffset = NSSize(width: 0, height: -2)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    ctx.beginTransparencyLayer(auxiliaryInfo: nil) // one shadow for the whole arrow
    let start = NSPoint(x: 232, y: 176), c1 = NSPoint(x: 262, y: 96), c2 = NSPoint(x: 370, y: 96)
    let end = NSPoint(x: 398, y: 160)
    let shaft = NSBezierPath()
    shaft.move(to: start)
    shaft.curve(to: end, controlPoint1: c1, controlPoint2: c2)
    shaft.lineWidth = 10
    shaft.lineCapStyle = .round
    shaft.setLineDash([14, 16], count: 2, phase: 0)
    amber.setStroke()
    shaft.stroke()
    let dx = end.x - c2.x, dy = end.y - c2.y, len = (dx * dx + dy * dy).squareRoot()
    let u = NSPoint(x: dx / len, y: dy / len), n = NSPoint(x: -u.y, y: u.x)
    let base = NSPoint(x: end.x - u.x * 4, y: end.y - u.y * 4)
    let head = NSBezierPath()
    head.move(to: NSPoint(x: base.x + u.x * 30, y: base.y + u.y * 30))
    head.line(to: NSPoint(x: base.x + n.x * 17, y: base.y + n.y * 17))
    head.line(to: NSPoint(x: base.x - n.x * 17, y: base.y - n.y * 17))
    head.close()
    head.lineWidth = 8
    head.lineJoinStyle = .round
    amber.setFill()
    head.fill()
    head.stroke()
    ctx.endTransparencyLayer()
    NSGraphicsContext.restoreGraphicsState()

    // The words, hand-lettered and a little tilted, with a dark violet outline.
    let font = NSFont(name: "MarkerFelt-Wide", size: 40) ?? NSFont(name: "ChalkboardSE-Bold", size: 38)
        ?? .boldSystemFont(ofSize: 36)
    let words = "drag to here"
    let size = NSAttributedString(string: words, attributes: [.font: font]).size()
    ctx.saveGState()
    ctx.translateBy(x: 318, y: 62)
    ctx.rotate(by: -5 * .pi / 180)
    ctx.setLineJoin(.round)
    let at = NSPoint(x: -size.width / 2, y: -size.height / 2)
    NSAttributedString(string: words, attributes: [.font: font, .strokeColor: color(0x2e1065), .strokeWidth: 18]).draw(at: at)
    NSAttributedString(string: words, attributes: [.font: font, .foregroundColor: color(0xfffbeb)]).draw(at: at)
    ctx.restoreGState()
}

func render(scale: CGFloat, to path: String) {
    let ctx = CGContext(data: nil, width: Int(W * scale), height: Int(H * scale), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: 0, y: H)
    ctx.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    draw(ctx)
    NSGraphicsContext.restoreGraphicsState()
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    rep.size = NSSize(width: W, height: H) // 72 or 144 dpi, so both resolutions are 640x400 pt
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let dir = CommandLine.arguments[1]
render(scale: 1, to: "\(dir)/background.png")
render(scale: 2, to: "\(dir)/background@2x.png")
SWIFT
swift "$WORK/background.swift" "$WORK" || die "cannot draw the background"
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$WORK/background.tiff" >/dev/null \
  || die "tiffutil cannot combine the 1x and 2x backgrounds"
tiffutil -lzw "$WORK/background.tiff" -out "$OUT/background.tiff" >/dev/null || die "tiffutil cannot compress the background"

echo "==> Laying out the window in Finder"
hdiutil create -size 20m -fs HFS+ -volname Lint -ov "$WORK/layout.dmg" >/dev/null || die "hdiutil create failed"
hdiutil attach "$WORK/layout.dmg" -noautoopen >/dev/null || die "cannot mount the layout image"
MOUNTED=1
[ -d "$VOL" ] || die "the layout image is not mounted at $VOL"
mkdir "$VOL/.background" "$VOL/Lint.app" # an empty stand-in: Finder only records the name and position
cp "$OUT/background.tiff" "$VOL/.background/background.tiff"
ln -s /Applications "$VOL/Applications"
osascript <<'APPLESCRIPT' || die "Finder could not lay out the window (allow the terminal to control Finder and run this again)"
tell application "Finder"
  tell disk "Lint"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    -- The bounds include the title bar: 28 pt up to macOS 15, 32 pt on macOS 27, where the empty bottom 4 pt
    -- of the background is hidden.
    set bounds of container window to {200, 120, 840, 548}
    set opts to icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set background picture of opts to file ".background:background.tiff"
    set position of item "Lint.app" of container window to {160, 205}
    set position of item "Applications" of container window to {480, 205}
    close
  end tell
  -- Finder saves a closed window's settings to .DS_Store when the window is opened again; reopening at once
  -- would bring back its default size instead.
  delay 5
  open disk "Lint"
  delay 1
  close container window of disk "Lint"
end tell
APPLESCRIPT

# Take the .DS_Store once it holds the window settings ("bwsp") and its size has stopped changing.
size=-1
for _ in $(seq 60); do
  sleep 1
  now=$(stat -f %z "$VOL/.DS_Store" 2>/dev/null || echo -1)
  LC_ALL=C grep -aq bwspblob "$VOL/.DS_Store" 2>/dev/null && [ "$now" = "$size" ] && break
  size=$now
done
LC_ALL=C grep -aq bwspblob "$VOL/.DS_Store" 2>/dev/null || die "Finder did not save the window settings to $VOL/.DS_Store"
cat >"$WORK/window.swift" <<'SWIFT'
import AppKit
// Prints ShowTabView and the window size from the window settings record ("bwsp", a binary plist) in a .DS_Store.
let data = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let key = data.range(of: Data("bwspblob".utf8))!
let size = data.subdata(in: key.upperBound..<key.upperBound + 4).reduce(0) { $0 << 8 | Int($1) }
let blob = data.subdata(in: key.upperBound + 4..<key.upperBound + 4 + size)
let settings = try! PropertyListSerialization.propertyList(from: blob, format: nil) as! [String: Any]
let bounds = NSRectFromString(settings["WindowBounds"] as? String ?? "")
print(settings["ShowTabView"] as? Bool ?? false, "\(Int(bounds.width))x\(Int(bounds.height))")
SWIFT
read -r tabbar window < <(swift "$WORK/window.swift" "$VOL/.DS_Store")
[ "$window" = 640x428 ] || die "Finder saved a $window window instead of 640x428; run this again"
[ "$tabbar" = false ] \
  || die "Finder saved a visible tab bar, which would cover the top of the background; choose View > Hide Tab Bar in Finder and run this again"
cp "$VOL/.DS_Store" "$WORK/DS_Store"
hdiutil detach "$VOL" -quiet || hdiutil detach "$VOL" -force -quiet || die "cannot unmount $VOL"
MOUNTED=""

# Finder's bookmark of the background (record pBBk) also names this Mac's Data volume by its UUID, which
# would then ship in every DMG. Finder finds the background by its path, so blank that UUID: it keeps its
# length, and the bookmark stays valid.
volume_uuid() { diskutil info "$1" | awk -F': *' '/Volume UUID/ {print $2}'; }
DATA_UUID=$(volume_uuid /System/Volumes/Data)
[ -n "$DATA_UUID" ] || die "cannot read the UUID of the Data volume"
LC_ALL=C perl -0777 -pi -e "s/\Q$DATA_UUID\E/00000000-0000-0000-0000-000000000000/g" "$WORK/DS_Store"
for id in "$HOME" "$DATA_UUID" "$(volume_uuid /)"; do
  ! LC_ALL=C grep -aqF "$id" "$WORK/DS_Store" || die "the .DS_Store records $id of this Mac; it must not be published"
done
cp "$WORK/DS_Store" "$OUT/DS_Store"

echo "==> Done"
echo "   $OUT/background.tiff"
echo "   $OUT/DS_Store"
