import SwiftUI

/// Questions people actually arrive with, answered where they will look.
///
/// Help is a reference: keys, vocabulary, symptoms. This is the other half, the
/// "wait, what does that mean for me" half, and the MCP server is why it was
/// needed. Following a sibling app, which keeps Help and FAQ apart for the same
/// reason.
///
/// The text itself lives in `Manual.swift` alongside Help's, so one search can
/// cover both pages and so an entry without a worked example is visible next to
/// the ones that have one.
struct FAQPage: View {
    var body: some View {
        ManualPage(page: .faq)
    }
}
