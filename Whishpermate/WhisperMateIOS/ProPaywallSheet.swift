import RevenueCat
import RevenueCatUI
import SwiftUI

/// The RevenueCat paywall for the current offering, as designed in the RevenueCat dashboard.
struct ProPaywallSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var purchasesManager = PurchasesManager.shared

    var body: some View {
        PaywallView(displayCloseButton: true)
            .onPurchaseCompleted { customerInfo in
                purchasesManager.apply(customerInfo)
                dismiss()
            }
            .onRestoreCompleted { customerInfo in
                purchasesManager.apply(customerInfo)
                if purchasesManager.isProActive {
                    dismiss()
                }
            }
    }
}

extension View {
    /// Presents the Pro paywall in a sheet.
    func proPaywall(isPresented: Binding<Bool>) -> some View {
        sheet(isPresented: isPresented) {
            ProPaywallSheet()
        }
    }
}
