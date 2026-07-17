import SwiftUI

public struct RevenueCatPaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var purchaseManager = RevenueCatManager.shared

    @State private var availableOptions: [RevenueCatPurchaseOption] = []
    @State private var selectedPeriod: RevenueCatBillingPeriod = .annual
    @State private var isLoading = true
    @State private var loadErrorMessage: String?
    @State private var activeOperation: Operation?
    @State private var feedback: Feedback?
    @State private var externalCheckoutOpened = false

    private let loadsLiveOptions: Bool

    public init() {
        loadsLiveOptions = true
    }

    #if DEBUG
        public static func validationPreview() -> RevenueCatPaywallView {
            RevenueCatPaywallView(
                previewOptions: [
                    RevenueCatPurchaseOption(period: .annual, price: "$120.00"),
                    RevenueCatPurchaseOption(period: .monthly, price: "$12.00"),
                    RevenueCatPurchaseOption(period: .lifetime, price: "$199.00"),
                ]
            )
        }
    #endif

    public var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                closeButton
                hero
                benefits
                plans

                if let feedback {
                    FeedbackView(feedback: feedback)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                actions
                purchaseTerms
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 28)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .background(Color.dsBackground)
        #if os(macOS)
            .frame(minWidth: 420, idealWidth: 440, maxWidth: 500, minHeight: 600, idealHeight: 640, maxHeight: 720)
        #endif
        .modifier(PaywallPresentationModifier(isBusy: isBusy))
        #if os(iOS)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                pinnedPurchaseAction
            }
        #endif
        .animation(.easeInOut(duration: 0.2), value: feedback)
        .task {
            guard loadsLiveOptions else { return }
            await loadPurchaseOptions()
        }
    }

    private var closeButton: some View {
        HStack {
            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.dsMutedForeground)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.dsMuted))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close upgrade")
        }
    }

    private var hero: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Color.dsPrimary)
                .frame(width: 64, height: 64)
                .background(Circle().fill(Color.dsPrimary.opacity(0.12)))
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Upgrade to Pro")
                    .font(.title.bold())
                    .foregroundStyle(Color.dsForeground)

                Text("Dictate as much as you need and keep your work moving without a monthly word limit.")
                    .font(.body)
                    .foregroundStyle(Color.dsMutedForeground)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 14) {
            PaywallBenefitRow(
                icon: "infinity",
                title: "Unlimited words",
                detail: "Transcribe without a monthly limit."
            )
            PaywallBenefitRow(
                icon: "cloud.fill",
                title: "Cloud transcription included",
                detail: "Use cloud mode for polished results."
            )
            PaywallBenefitRow(
                icon: "lifepreserver.fill",
                title: "Priority support",
                detail: "Get faster help when you need it."
            )
        }
        .padding(16)
        .dsCardStyle(cornerRadius: DSCornerRadius.large, hasShadow: false)
        .accessibilityElement(children: .contain)
    }

    private var plans: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a plan")
                .font(.headline)
                .foregroundStyle(Color.dsForeground)
                .frame(maxWidth: .infinity, alignment: .leading)

            purchaseOptions
        }
    }

    @ViewBuilder
    private var purchaseOptions: some View {
        if isLoading {
            ProgressView("Loading purchase options…")
                .frame(maxWidth: .infinity, minHeight: 112)
                .accessibilityLabel("Loading purchase options")
        } else if let loadErrorMessage {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title3)
                    .foregroundStyle(Color.dsDestructive)
                    .accessibilityHidden(true)

                Text(loadErrorMessage)
                    .font(.callout)
                    .foregroundStyle(Color.dsMutedForeground)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Try again") {
                    Task { await loadPurchaseOptions() }
                }
                .buttonStyle(.bordered)
                .tint(Color.dsPrimary)
            }
            .frame(maxWidth: .infinity, minHeight: 112)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: DSCornerRadius.medium, style: .continuous)
                    .fill(Color.dsMuted)
            )
            .accessibilityElement(children: .combine)
        } else {
            VStack(spacing: 10) {
                ForEach(availableOptions) { option in
                    PurchaseOptionButton(
                        option: option,
                        isSelected: selectedPeriod == option.period,
                        action: {
                            selectedPeriod = option.period
                            feedback = nil
                        }
                    )
                }
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 14) {
            #if os(macOS)
                primaryPurchaseAction

                if externalCheckoutOpened {
                    Button {
                        checkExternalPurchase()
                    } label: {
                        HStack(spacing: 8) {
                            if activeOperation == .checkingPurchase {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(activeOperation == .checkingPurchase ? "Checking purchase…" : "Check purchase status")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .tint(Color.dsPrimary)
                    .disabled(isBusy)
                }
            #endif

            Button {
                restorePurchases()
            } label: {
                HStack(spacing: 8) {
                    if activeOperation == .restoring {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(activeOperation == .restoring ? "Restoring purchases…" : "Restore purchases")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.dsPrimary)
            .disabled(isBusy)
            .accessibilityHint("Checks this account for an existing Pro purchase")
        }
    }

    private var primaryPurchaseAction: some View {
        Button {
            confirmPurchase()
        } label: {
            HStack(spacing: 8) {
                if activeOperation == .purchasing || purchaseManager.isPurchasing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.dsPrimaryForeground)
                }

                Text(primaryButtonTitle)
            }
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 24)
            .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(Color.dsPrimary)
        .disabled(isLoading || availableOptions.isEmpty || isBusy)
        .accessibilityHint("Starts checkout for the selected plan")
    }

    #if os(iOS)
        private var pinnedPurchaseAction: some View {
            VStack(spacing: 0) {
                Divider()
                primaryPurchaseAction
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
            .background(.ultraThinMaterial)
        }
    #endif

    private var purchaseTerms: some View {
        VStack(spacing: 8) {
            Text(termsText)
                .font(.footnote)
                .foregroundStyle(Color.dsMutedForeground)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                Link("Privacy", destination: URL(string: "https://aidictation.com/privacy")!)
                #if os(iOS)
                    Link(
                        "Terms",
                        destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
                    )
                #else
                    Link("Refund policy", destination: URL(string: "https://aidictation.com/refund")!)
                #endif
            }
            .font(.footnote)
            .foregroundStyle(Color.dsPrimary)
        }
    }

    private var selectedOption: RevenueCatPurchaseOption? {
        availableOptions.first { $0.period == selectedPeriod }
    }

    private var primaryButtonTitle: String {
        if activeOperation == .purchasing || purchaseManager.isPurchasing {
            return "Starting purchase…"
        }
        return "Continue with \(selectedPeriod.displayName)"
    }

    private var termsText: String {
        #if os(macOS)
            return "Checkout opens in your browser. Your signed-in account updates after payment is confirmed."
        #else
            if selectedPeriod == .lifetime {
                return "This is a one-time purchase charged to your Apple Account."
            }
            return "Payment is charged to your Apple Account. Your subscription renews automatically unless canceled at least 24 hours before the current period ends."
        #endif
    }

    private var isBusy: Bool {
        purchaseManager.isPurchasing || activeOperation != nil
    }

    private func loadPurchaseOptions() async {
        guard loadsLiveOptions else { return }

        isLoading = true
        loadErrorMessage = nil
        purchaseManager.clearError()

        let options = await purchaseManager.fetchAvailablePurchaseOptions()
        availableOptions = options.sorted { optionRank($0.period) < optionRank($1.period) }

        let periods = availableOptions.map(\.period)
        if periods.contains(.annual) {
            selectedPeriod = .annual
        } else if let first = periods.first {
            selectedPeriod = first
        }

        if availableOptions.isEmpty {
            loadErrorMessage = purchaseManager.errorMessage ?? "Purchase options are not available right now."
        }
        isLoading = false
    }

    private func optionRank(_ period: RevenueCatBillingPeriod) -> Int {
        switch period {
        case .annual: return 0
        case .monthly: return 1
        case .lifetime: return 2
        }
    }

    private func confirmPurchase() {
        guard selectedOption != nil, !isBusy else { return }

        feedback = nil
        activeOperation = .purchasing
        Task { @MainActor in
            let purchased = await purchaseManager.purchase(selectedPeriod)
            activeOperation = nil

            if purchased {
                dismiss()
                return
            }

            if let message = purchaseManager.errorMessage {
                feedback = Feedback(message: message, kind: .error)
                return
            }

            #if os(macOS)
                externalCheckoutOpened = true
                feedback = Feedback(
                    message: "Finish checkout in your browser, then come back and check your purchase.",
                    kind: .info
                )
            #endif
        }
    }

    private func restorePurchases() {
        guard !isBusy else { return }

        feedback = nil
        activeOperation = .restoring
        Task { @MainActor in
            let restored = await purchaseManager.restorePurchases()
            activeOperation = nil

            if restored {
                feedback = Feedback(message: "Your purchases have been restored.", kind: .success)
                try? await Task.sleep(nanoseconds: 450_000_000)
                dismiss()
            } else {
                feedback = Feedback(
                    message: purchaseManager.errorMessage ?? "No active purchase was found for this account.",
                    kind: .error
                )
            }
        }
    }

    #if os(macOS)
        private func checkExternalPurchase() {
            guard !isBusy else { return }

            feedback = nil
            activeOperation = .checkingPurchase
            Task { @MainActor in
                await AuthManager.shared.refreshUser()
                activeOperation = nil

                if AuthManager.shared.currentUser?.subscriptionTier.isPaid == true {
                    feedback = Feedback(message: "Your Pro access is ready.", kind: .success)
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    dismiss()
                } else {
                    feedback = Feedback(
                        message: "We haven’t confirmed your purchase yet. If you just paid, wait a moment and check again.",
                        kind: .info
                    )
                }
            }
        }
    #endif

    private enum Operation: Equatable {
        case purchasing
        case restoring
        case checkingPurchase
    }

    fileprivate struct Feedback: Equatable {
        enum Kind: Equatable {
            case info
            case success
            case error

            var icon: String {
                switch self {
                case .info: return "info.circle.fill"
                case .success: return "checkmark.circle.fill"
                case .error: return "exclamationmark.triangle.fill"
                }
            }

            var color: Color {
                switch self {
                case .info: return .dsPrimary
                case .success: return .green
                case .error: return .dsDestructive
                }
            }

            var accessibilityPrefix: String {
                switch self {
                case .info: return "Information"
                case .success: return "Success"
                case .error: return "Error"
                }
            }
        }

        let message: String
        let kind: Kind
    }

    #if DEBUG
        fileprivate init(
            previewOptions: [RevenueCatPurchaseOption],
            loadErrorMessage: String? = nil,
            feedback: Feedback? = nil
        ) {
            loadsLiveOptions = false
            _availableOptions = State(initialValue: previewOptions)
            _selectedPeriod = State(initialValue: previewOptions.first?.period ?? .annual)
            _isLoading = State(initialValue: false)
            _loadErrorMessage = State(initialValue: loadErrorMessage)
            _feedback = State(initialValue: feedback)
        }
    #endif
}

private struct PaywallBenefitRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.dsPrimary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.dsPrimary.opacity(0.12)))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.dsForeground)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Color.dsMutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct FeedbackView: View {
    let feedback: RevenueCatPaywallView.Feedback

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: feedback.kind.icon)
                .foregroundStyle(feedback.kind.color)
                .accessibilityHidden(true)

            Text(feedback.message)
                .font(.callout)
                .foregroundStyle(Color.dsForeground)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: DSCornerRadius.medium, style: .continuous)
                .fill(feedback.kind.color.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DSCornerRadius.medium, style: .continuous)
                .stroke(feedback.kind.color.opacity(0.22), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(feedback.kind.accessibilityPrefix): \(feedback.message)")
    }
}

private struct PurchaseOptionButton: View {
    let option: RevenueCatPurchaseOption
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.dsPrimary : Color.dsMutedForeground)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(option.period.displayName)
                        .font(.headline)
                        .foregroundStyle(Color.dsForeground)
                    Text(option.detailText)
                        .font(.subheadline)
                        .foregroundStyle(Color.dsMutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DSCornerRadius.medium, style: .continuous)
                    .fill(isSelected ? Color.dsPrimary.opacity(0.12) : Color.dsCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DSCornerRadius.medium, style: .continuous)
                    .stroke(isSelected ? Color.dsPrimary : Color.dsBorder, lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: DSCornerRadius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(option.period.displayName), \(option.detailText)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Selects this plan")
    }
}

private struct PaywallPresentationModifier: ViewModifier {
    let isBusy: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
            if #available(iOS 16.0, *) {
                content
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .interactiveDismissDisabled(isBusy)
            } else {
                content
                    .interactiveDismissDisabled(isBusy)
            }
        #else
            content
                .interactiveDismissDisabled(isBusy)
        #endif
    }
}

#if DEBUG
    #Preview("Paywall · Loaded") {
        RevenueCatPaywallView(
            previewOptions: [
                RevenueCatPurchaseOption(period: .annual, price: "$79.99"),
                RevenueCatPurchaseOption(period: .monthly, price: "$11.99"),
                RevenueCatPurchaseOption(period: .lifetime, price: "$199.99"),
            ]
        )
    }

    #Preview("Paywall · Error") {
        RevenueCatPaywallView(
            previewOptions: [],
            loadErrorMessage: "Purchase options are not available right now.",
            feedback: .init(message: "Please check your connection and try again.", kind: .error)
        )
    }
#endif
