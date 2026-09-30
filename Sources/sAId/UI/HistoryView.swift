import SwiftUI

struct HistoryView: View {
    @ObservedObject var store: HistoryStore
    let copy: (String) -> Void
    @State private var confirmClear = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent dictation").font(.title2)
                Spacer()
                Button("Clear History", role: .destructive) { confirmClear = true }.disabled(store.entries.isEmpty && store.errorMessage == nil)
            }
            Text("Last 50 entries, stored on this Mac.").foregroundStyle(.secondary)
            if let error = store.errorMessage { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if store.entries.isEmpty { ContentUnavailableView("No dictation yet", systemImage: "clock", description: Text("Completed dictation will appear here.")) }
            else {
                List(store.entries) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(entry.timestamp, format: .dateTime.month().day().hour().minute()).font(.caption)
                            Text(entry.targetAppID ?? "Unknown target").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Copy") { copy(entry.text) }
                        }
                        Text(entry.text).textSelection(.enabled)
                        if entry.source == .previewAfterFinalFailure { Text("Preview only · final transcription failed · not inserted").font(.caption).foregroundStyle(.orange) }
                        if let failure = entry.failure { Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    }.padding(.vertical, 5)
                }
            }
        }.padding(20)
        .confirmationDialog("Clear all dictation history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { store.clear() }
        } message: { Text("This removes saved transcript entries. A damaged original file, if present, is archived first.") }
    }
}
