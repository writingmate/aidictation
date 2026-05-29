import SwiftUI
import UIKit
import WhisperMateShared

typealias KeyboardRecordingState = AIDictationRecordingState
typealias KeyboardRecordingViewModel = AIDictationRecordingViewModel

struct KeyboardRecordingView: View {
    @ObservedObject var model: KeyboardRecordingViewModel
    let onPrimaryAction: () -> Void
    let onPauseAction: () -> Void

    var body: some View {
        AIDictationRecordingSurface(
            model: model,
            backgroundColor: Color(uiColor: KeyboardPalette.backgroundColor),
            onPrimaryAction: onPrimaryAction,
            onPauseAction: onPauseAction
        )
    }
}

enum KeyboardPalette {
    static let backgroundColor = UIColor { traitCollection in
        traitCollection.userInterfaceStyle == .dark
            ? UIColor(red: 0.17, green: 0.17, blue: 0.18, alpha: 1.0)
            : UIColor(red: 0.82, green: 0.84, blue: 0.88, alpha: 1.0)
    }
}
