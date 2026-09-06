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
          let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
          let width = b["Width"], let height = b["Height"], width > 200, height > 200
    else { continue }
    // The window NUMBER, not its rect. `screencapture -R` grabs a region of
    // screen, so anything stacked above the target is what you photograph —
    // which is how a capture aimed at Seedbed came back showing the terminal in
    // front of it. `-l<id>` captures the window's own content, occluded or not.
    let num = w[kCGWindowNumber as String] as? Int ?? 0
    print("\(num) \(Int(width))x\(Int(height))")
}
