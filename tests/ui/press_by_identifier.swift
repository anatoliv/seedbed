// Presses one control in a running app by its accessibility identifier, and
// says what it found before it does.
//
// Written because the MCP settings pane cannot be driven any other way. SwiftUI
// publishes no usable label for any button in it: every one of them answers
// `missing value` for its title, which this driver prints so the next person
// can see that is still true. Pressing by position is not an option there,
// because two "Regenerate" buttons sit a few points above the one that matters
// and hitting either rotates a bearer token and breaks every configured client.
//
// **It deliberately prints almost nothing it reads.** The pane renders both
// bearer tokens as static text, so a driver that dumped the tree it walks would
// put them in a transcript. What comes out is a count of matches, the matched
// element's role and title, and whether some static text begins with one of the
// phrases passed in `--expect`. Never a value.
//
// Build and run:
//
//     swiftc -O tests/ui/press_by_identifier.swift -o /tmp/press
//     /tmp/press --pid 1234 --identifier mcp.updateClientConfig
//
// Requires the calling process to hold macOS accessibility permission; it says
// so and exits 3 rather than reporting a control it cannot see.

import ApplicationServices
import Foundation

func string(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
    else { return nil }
    return value as? String
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString,
                                        &value) == .success,
          let list = value as? [AXUIElement]
    else { return [] }
    return list
}

/// Every element under `root`, breadth first. Capped so a tree that cycles ends
/// the run instead of hanging it.
func walk(_ root: AXUIElement, limit: Int = 20000) -> [AXUIElement] {
    var found: [AXUIElement] = []
    var queue = [root]
    while let element = queue.first, found.count < limit {
        queue.removeFirst()
        found.append(element)
        queue.append(contentsOf: children(element))
    }
    return found
}

func argument(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name),
          index + 1 < CommandLine.arguments.count
    else { return nil }
    return CommandLine.arguments[index + 1]
}

guard AXIsProcessTrusted() else {
    print("no accessibility permission: nothing was pressed")
    exit(3)
}
guard let rawPid = argument("--pid"), let pid = pid_t(rawPid),
      let wanted = argument("--identifier")
else {
    FileHandle.standardError.write(
        Data("usage: press_by_identifier --pid N --identifier ID [--expect PREFIX] [--dry-run]\n"
            .utf8))
    exit(2)
}

let elements = walk(AXUIElementCreateApplication(pid))
print("elements walked: \(elements.count)")

let matches = elements.filter { string($0, "AXIdentifier") == wanted }
print("matches for \(wanted): \(matches.count)")
// One, or nothing is pressed. Two controls answering to the same name means the
// press is a coin toss, which is the failure the identifier exists to remove.
guard matches.count == 1 else {
    print("refusing to press: expected exactly one control with that identifier")
    exit(1)
}
let button = matches[0]
print("role: \(string(button, kAXRoleAttribute as String) ?? "(none)")")
print("title: \(string(button, kAXTitleAttribute as String) ?? "(missing value)")")

guard !CommandLine.arguments.contains("--dry-run") else {
    print("dry run: nothing pressed")
    exit(0)
}

let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
print("AXPress: \(result == .success ? "success" : "error \(result.rawValue)")")
guard result == .success else { exit(1) }

guard let expected = argument("--expect") else { exit(0) }
// Let the view publish whatever the press produced, then look for it. Only the
// phrase that was passed in is ever printed back.
Thread.sleep(forTimeInterval: 2.0)
let after = walk(AXUIElementCreateApplication(pid))
let found = after.contains { element in
    string(element, kAXRoleAttribute as String) == kAXStaticTextRole as String
        && (string(element, kAXValueAttribute as String)?.hasPrefix(expected) ?? false)
}
print("static text beginning \"\(expected)\": \(found ? "on screen" : "not found")")
exit(found ? 0 : 1)
