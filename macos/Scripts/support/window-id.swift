import CoreGraphics
import Foundation

// Bounds of every on-screen window belonging to one app. kCGWindowBounds needs
// no Screen Recording permission (window TITLES do), so this gives a rect to
// hand to `screencapture -R` without ever photographing the whole display —
// which is the point: a full-screen grab of someone's Mac catches whatever else
// they had open.
let target = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Seedbed"
guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                            kCGNullWindowID) as? [[String: Any]] else {
    FileHandle.standardError.write("could not list windows\n".data(using: .utf8)!)
    exit(1)
}
for w in list {
    guard let owner = w[kCGWindowOwnerName as String] as? String, owner == target,
          let b = w[kCGWindowBounds as String] as? [String: CGFloat],
          // Layer 0 is an ordinary window. The ⌥⌘P panel is an NSPanel and
          // floats above that, so filtering to 0 silently skipped the one
          // surface people touch most — a sweep of "every screen" that quietly
          // omits the main one is worse than no sweep. Anything at or below the
          // floating-window level counts; the menu bar and the Dock live far
          // higher and are not this app's to photograph.
          let layer = w[kCGWindowLayer as String] as? Int, layer <= 3,
          let width = b["Width"], let height = b["Height"], width > 200, height > 200
    else { continue }
    // The window NUMBER, not its rect. `screencapture -R` grabs a region of
    // screen, so anything stacked above the target is what you photograph —
    // which is how a capture aimed at Seedbed came back showing the terminal in
    // front of it. `-l<id>` captures the window's own content, occluded or not.
    let num = w[kCGWindowNumber as String] as? Int ?? 0
    print("\(num) \(Int(width))x\(Int(height))")
}
