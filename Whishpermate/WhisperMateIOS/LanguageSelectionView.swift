import SwiftUI
import WhisperMateShared

struct LanguageSelectionView: View {
    @ObservedObject var languageManager: LanguageManager

    var body: some View {
        List {
            Section(footer: Text("Select the languages you speak. Auto-detect works best for single-language dictation.")) {
                ForEach(Language.allCases) { language in
                    Button(action: {
                        languageManager.toggleLanguage(language)
                    }) {
                        HStack {
                            Text(language.flag)
                                .font(.title3)

                            Text(language.displayName)
                                .foregroundColor(.primary)

                            Spacer()

                            if languageManager.isSelected(language) {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                                    .fontWeight(.semibold)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Language")
        .navigationBarTitleDisplayMode(.inline)
    }
}
