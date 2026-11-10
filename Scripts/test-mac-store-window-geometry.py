#!/usr/bin/env python3
"""Execute the real pure Swift capture policy without launching XCTest or an app."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
source = (ROOT / 'UITests/NeoAnki2UITests/MacStoreProductionReviewJourneyTests.swift').read_text()
start = source.index('enum MacStoreCaptureGeometry {')
opening = source.index('{', start)
depth, end = 1, opening + 1
while depth:
    depth += (source[end] == '{') - (source[end] == '}')
    end += 1
helper = source[start:end]
checks = r'''
let visible = CGRect(x: 0, y: 33, width: 1728, height: 998)
let observedOrigin = CGPoint(x: 384, y: 212)
let actual = MacStoreCaptureGeometry.preferredSize(at: observedOrigin, within: visible)
precondition(actual == CGSize(width: 1280, height: 800), "The retained failed frame must resize in place, without a titlebar move")
precondition(visible.contains(CGRect(origin: observedOrigin, size: actual!)), "The selected target must fit fully on screen")
precondition(!visible.contains(CGRect(origin: observedOrigin, size: CGSize(width: 1440, height: 900))))
precondition(MacStoreCaptureGeometry.preferredSize(at: CGPoint(x: 0, y: 33), within: visible) == CGSize(width: 1440, height: 900), "Keep the larger accepted size when it already fits")
precondition(MacStoreCaptureGeometry.preferredSize(at: CGPoint(x: 448, y: 231), within: visible) == CGSize(width: 1280, height: 800), "An exact screen boundary is contained")
precondition(MacStoreCaptureGeometry.preferredSize(at: CGPoint(x: 448.1, y: 231), within: visible) == nil, "Do not select an offscreen target")
precondition(MacStoreCaptureGeometry.preferredSize(at: .zero, within: CGRect(x: 0, y: 0, width: 1024, height: 768)) == nil)
precondition(!MacStoreCaptureGeometry.acceptsPointSize(CGSize(width: 960, height: 640)), "The old app default must not masquerade as a Store viewport")
for pixels in [(1280, 800), (1440, 900), (2560, 1600), (2880, 1800)] {
    precondition(MacStoreCaptureGeometry.acceptsPixels(width: pixels.0, height: pixels.1))
}
for pixels in [(3456, 2234), (1280, 900), (1280, 799)] {
    precondition(!MacStoreCaptureGeometry.acceptsPixels(width: pixels.0, height: pixels.1), "Reject desktop, mixed-ratio, or clipped pixels")
}
let fullScreen = CGRect(x: 0, y: 0, width: 1280, height: 800)
precondition(MacStoreCaptureGeometry.isAcceptedScreenFrame(fullScreen, screen: fullScreen), "Repeated captures must leave exact Full Screen geometry unchanged")
for invalid in [CGRect(x: 0, y: 0, width: 1279, height: 796),
                CGRect(x: 0, y: 30, width: 1280, height: 754),
                CGRect(x: 1, y: 0, width: 1280, height: 800)] {
    precondition(!MacStoreCaptureGeometry.isAcceptedScreenFrame(invalid, screen: fullScreen), "Short, clipped, or offset frames must not bypass preparation")
}
let unsupportedDisplay = CGRect(x: 0, y: 0, width: 1728, height: 1117)
precondition(!MacStoreCaptureGeometry.isAcceptedScreenFrame(unsupportedDisplay, screen: unsupportedDisplay))
// Reproduce the measured mouse response: +160 moved width +156, +100 moved height +94.
for (initial, target, loss) in [(960.0, 1280.0, 4.0), (640.0, 800.0, 6.0), (1440.0, 1280.0, -4.0)] {
    var current = initial
    var gestures = 0
    let final = MacStoreCaptureGeometry.resizeExtent(initial, to: target) { requested in
        gestures += 1
        current += requested - loss
        return current
    }
    precondition(final == target && gestures == 2, "Observed drag loss must be corrected from frame feedback")
}
var ineffectiveGestures = 0
let unchanged = MacStoreCaptureGeometry.resizeExtent(960, to: 1280) { _ in
    ineffectiveGestures += 1
    return 960
}
precondition(unchanged == 960 && ineffectiveGestures == 1, "Do not repeat ineffective mouse input")
var unnecessaryGestures = 0
_ = MacStoreCaptureGeometry.resizeExtent(1280, to: 1280) { value in
    unnecessaryGestures += 1
    return value
}
precondition(unnecessaryGestures == 0, "An accepted dimension needs no gesture")
print("Mac Store capture geometry regression passed")
'''
with tempfile.TemporaryDirectory(prefix='neoanki-mac-geometry-') as folder:
    script = Path(folder) / 'geometry.swift'
    script.write_text('import Foundation\nimport CoreGraphics\n' + helper + '\n' + checks)
    subprocess.run(['swift', str(script)], check=True)
