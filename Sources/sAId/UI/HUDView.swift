import SwiftUI

enum HUDActivity: Sendable, Equatable { case none, loading, listening, finalizing, completed, error }

/// Pure presentation mapping. Independent notices never replace the active capture state.
struct HUDPresentation: Sendable, Equatable {
    var text: String
    var notice: String?
    var activity: HUDActivity
    var visible: Bool

    init(_ state: DictationState) {
        visible = true
        switch state.phase {
        case .loadingModels: text = "Loading model…"; activity = .loading
        case .idle: text = ""; activity = .none; visible = false
        case .listening(_, let preview, _):
            text = preview.isEmpty ? "Listening…" : Self.trailingWords(preview)
            activity = .listening
        case .finalizing(_, let preview):
            text = preview.isEmpty ? "Finishing…" : Self.trailingWords(preview)
            activity = .finalizing
        case .inserting(_, let final): text = Self.trailingWords(final); activity = .finalizing
        case .shown(let final): text = Self.trailingWords(final); activity = .completed
        case .nothingHeard: text = "Nothing heard"; activity = .none
        case .error(let message): text = message; activity = .error
        }
        switch state.message {
        case .error(let message): notice = message; visible = true
        case .nothingHeard: notice = "Nothing heard"; visible = true
        case nil: notice = nil
        }
        if notice == text { notice = nil }
    }
    private static func trailingWords(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).suffix(12).joined(separator: " ")
    }
}

struct HUDView: View {
    let presentation: HUDPresentation

    var body: some View {
        VStack(spacing: 6) {
            if let notice = presentation.notice {
                Text(notice)
                    .font(.caption).foregroundStyle(.red)
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.horizontal, 16)
                    .frame(height: 32)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            HStack(spacing: 10) {
                switch presentation.activity {
                case .listening:
                    Image(systemName: "mic.fill").symbolEffect(.pulse, options: .repeating)
                case .loading, .finalizing: ProgressView().controlSize(.small)
                case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .error: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                case .none: EmptyView()
                }
                Text(presentation.text)
                    .font(.body).lineLimit(1).truncationMode(.head)
                    .foregroundStyle(presentation.activity == .error ? Color.red : Color.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .frame(width: 560, height: 44)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
    }
}
