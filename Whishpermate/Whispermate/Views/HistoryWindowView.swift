import SwiftUI
import WhisperMateShared

struct HistoryWindowView: View {
    @ObservedObject private var historyManager = HistoryManager.shared
    @Environment(\.dismiss) var dismiss

    var body: some View {
        HistoryView(historyManager: historyManager) { recording in
            AppState.shared.retranscribe(recording: recording)
        }
            .onAppear {
                // Set window identifier for identification
                if let window = NSApplication.shared.windows.first(where: { $0.title == "History" }) {
                    window.identifier = WindowIdentifiers.history
                }
            }
    }
}
