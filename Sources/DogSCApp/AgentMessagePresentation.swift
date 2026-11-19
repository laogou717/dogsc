import RecorderCore
import SwiftUI

/// Finished messages keep their parsed text across unrelated chat updates.
actor AgentMarkdownCache {
    static let shared = AgentMarkdownCache()
    private final class Value: NSObject {
        let text: AttributedString
        init(_ text: AttributedString) { self.text = text }
    }
    private let cache = NSCache<NSString, Value>()

    init() { cache.countLimit = 128; cache.totalCostLimit = 1_000_000 }

    func text(_ source: String) -> AttributedString? {
        guard !Task.isCancelled else { return nil }
        if let value = cache.object(forKey: source as NSString) { return value.text }
        let parsed = (try? AttributedString(markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
        guard !Task.isCancelled else { return nil }
        cache.setObject(Value(parsed), forKey: source as NSString, cost: source.utf8.count)
        return parsed
    }
}

/// Display grouping never changes the actual operations or the agent's input.
struct AgentStepGroup: Identifiable {
    let steps: [AgentChatModel.Step]
    var id: UUID { steps[0].id }
    var isRepeatedRead: Bool { steps.count > 1 && steps[0].readOnlyMethod != nil }

    static func collect(_ steps: [AgentChatModel.Step]) -> [Self] {
        var groups: [Self] = []
        var current: [AgentChatModel.Step] = []
        for step in steps {
            if let method = step.readOnlyMethod,
               current.last?.readOnlyMethod == method {
                current.append(step)
            } else {
                if !current.isEmpty { groups.append(Self(steps: current)) }
                current = [step]
            }
        }
        if !current.isEmpty { groups.append(Self(steps: current)) }
        return groups
    }
}

/// Measure the real wrapped text, so a wide panel and a narrow panel fold at
/// the same number of lines. The full original string remains selectable.
struct AIFoldableText: View {
    let text: String
    var markdown = false
    var lineLimit = 6
    var isStreaming = false
    var lineSpacing: CGFloat = 4
    @State private var expanded = false
    @State private var fullHeight: CGFloat = 0
    @State private var foldedHeight: CGFloat = 0
    @State private var parsed: ParsedText?

    private struct ParsedText {
        let source: String
        let value: AttributedString
    }

    private var content: AttributedString {
        guard markdown else { return AttributedString(text) }
        if let parsed, parsed.source == text { return parsed.value }
        return AttributedString(text)
    }

    private var textView: some View {
        Text(content)
            .font(.appUI(size: 14))
            .lineSpacing(lineSpacing)
            .foregroundStyle(EditorTheme.primaryText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            textView
                .lineLimit(expanded || isStreaming ? nil : lineLimit)
                .textSelection(.enabled)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    if !expanded, !isStreaming { foldedHeight = height }
                }
                .background(alignment: .topLeading) {
                    if !isStreaming {
                        textView
                            .fixedSize(horizontal: false, vertical: true)
                            .hidden()
                            .accessibilityHidden(true)
                            .allowsHitTesting(false)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                    }
                }
            if !isStreaming, fullHeight > foldedHeight + 2 {
                Button {
                    // Large paragraphs open immediately; no height animation
                    // repeatedly relays out thousands of selectable glyphs.
                    expanded.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Text(appLocalized(expanded ? "收起" : "展开全文"))
                        AppLineIcon(kind: expanded ? .chevronUp : .chevronDown, size: 10)
                    }
                    .font(.appUI(size: 12))
                    .foregroundStyle(EditorTheme.accent)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(appLocalized(expanded ? "已展开" : "已收起"))
            }
        }
        .task(id: markdown ? text : nil) {
            guard markdown else { return }
            let source = text
            guard let value = await AgentMarkdownCache.shared.text(source), !Task.isCancelled else { return }
            parsed = ParsedText(source: source, value: value)
        }
    }
}

struct AIConversationBottomKey: PreferenceKey {
    static let defaultValue = AIConversationScrollMetrics(originY: 0, height: 0)
    static func reduce(value: inout AIConversationScrollMetrics, nextValue: () -> AIConversationScrollMetrics) { value = nextValue() }
}

struct AIConversationScrollMetrics: Equatable, Sendable {
    let originY: CGFloat
    let height: CGFloat
    var bottom: CGFloat { originY + height }
}

/// Content growth and async text formatting are not user scroll intent.
/// This unobserved state avoids publishing every scroll geometry sample.
@MainActor
final class AIConversationFollowState {
    enum Decision: Equatable { case atBottom, follow, readingHistory, none }
    private var previous = AIConversationBottomKey.defaultValue

    func reset() { previous = AIConversationBottomKey.defaultValue }

    func observe(_ next: AIConversationScrollMetrics, viewportHeight: CGFloat, following: Bool) -> Decision {
        let resized = abs(next.height - previous.height) > 0.5
        let moved = abs(next.originY - previous.originY) > 0.5
        previous = next
        if next.bottom <= viewportHeight + 40 { return .atBottom }
        if resized { return following ? .follow : .none }
        return moved ? .readingHistory : .none
    }
}
