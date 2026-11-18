import SwiftUI
import iScopeCore

enum ScopeTheme {
    static let accent = Color(red: 0.22, green: 0.39, blue: 0.94)
    static let purple = Color(red: 0.55, green: 0.35, blue: 0.85)
    static let green = Color(red: 0.13, green: 0.61, blue: 0.49)
    static let canvas = Color(nsColor: .textBackgroundColor)
    static let panel = Color(nsColor: .controlBackgroundColor)
    static func color(_ kind: ResultKind) -> Color {
        switch kind { case .method: return accent; case .classInfo: return purple; case .string: return green; case .symbol: return .orange }
    }
}

struct TypeIcon: View {
    let kind: ResultKind
    var body: some View {
        Image(systemName: kind.icon).font(.system(size: 15, weight: .medium))
            .foregroundStyle(ScopeTheme.color(kind)).frame(width: 32, height: 32)
            .background(ScopeTheme.color(kind).opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct SmallBadge: View {
    let text: String
    var color: Color = .secondary
    var body: some View {
        Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3).background(color.opacity(0.09), in: Capsule())
    }
}

struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            content
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
