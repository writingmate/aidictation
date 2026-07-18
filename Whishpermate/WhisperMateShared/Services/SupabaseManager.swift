//
//  SupabaseManager.swift
//  WhisperMate
//
//  Created by WhisperMate on 2025-01-24.
//

import Auth
import Foundation
import Supabase

// MARK: - UserDefaults-based Auth Storage

/// Legacy storage used by older builds.
final class UserDefaultsAuthLocalStorage: AuthLocalStorage, @unchecked Sendable {
    private let defaults = AppDefaults.shared
    private let keyPrefix = "supabase.auth."

    func store(key: String, value: Data) throws {
        defaults.set(value, forKey: keyPrefix + key)
    }

    func retrieve(key: String) throws -> Data? {
        defaults.data(forKey: keyPrefix + key)
    }

    func remove(key: String) throws {
        defaults.removeObject(forKey: keyPrefix + key)
    }
}

/// Keychain-backed auth storage with a UserDefaults fallback for migrating existing sessions.
final class PersistentAuthLocalStorage: AuthLocalStorage, @unchecked Sendable {
    private let keychain = KeychainLocalStorage(service: "com.whispermate.supabase.auth")
    private let legacy = UserDefaultsAuthLocalStorage()

    func store(key: String, value: Data) throws {
        try keychain.store(key: key, value: value)
        try? legacy.remove(key: key)
    }

    func retrieve(key: String) throws -> Data? {
        if let value = try? keychain.retrieve(key: key) {
            return value
        }

        if let legacyValue = try legacy.retrieve(key: key) {
            try? keychain.store(key: key, value: legacyValue)
            try? legacy.remove(key: key)
            return legacyValue
        }

        return nil
    }

    func remove(key: String) throws {
        try? keychain.remove(key: key)
        try? legacy.remove(key: key)
    }
}

public class SupabaseManager {
    public static let shared = SupabaseManager()

    public let client: SupabaseClient?

    private init() {
        guard let supabaseURL = SecretsLoader.getValue(for: "SUPABASE_URL"),
              let supabaseKey = SecretsLoader.getValue(for: "SUPABASE_ANON_KEY"),
              let url = URL(string: supabaseURL)
        else {
            DebugLog.error("Missing Supabase credentials in Secrets.plist - auth features disabled", context: "SupabaseManager")
            client = nil
            return
        }

        // Configure client with implicit flow for web-based auth.
        // Store sessions in Keychain so login survives app restarts and bundle preference changes.
        client = SupabaseClient(
            supabaseURL: url,
            supabaseKey: supabaseKey,
            options: SupabaseClientOptions(
                auth: .init(
                    storage: PersistentAuthLocalStorage(),
                    flowType: .implicit
                )
            )
        )
    }

    // MARK: - Private Helpers

    private func requireClient() throws -> SupabaseClient {
        guard let client else {
            throw NSError(domain: "SupabaseManager", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Supabase not configured",
            ])
        }
        return client
    }

    // MARK: - User Management

    public func fetchUser() async throws -> User {
        let client = try requireClient()
        // Get current session
        let session = try await client.auth.session

        // Fetch user data from database
        let response: [User] = try await client
            .from("profiles")
            .select()
            .eq("user_id", value: session.user.id.uuidString)
            .execute()
            .value

        guard let user = response.first else {
            throw NSError(domain: "SupabaseManager", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "User not found in database",
            ])
        }

        return user
    }

    /// Reconciles legacy lifetime/AppSumo access into RevenueCat using the
    /// authenticated server path. The response is validated before callers
    /// treat reconciliation as successful.
    public func reconcileSubscription(expectedUserID: UUID) async throws {
        let client = try requireClient()
        let session = try await client.auth.session
        guard session.user.id == expectedUserID else {
            throw NSError(domain: "SupabaseManager", code: 409, userInfo: [
                NSLocalizedDescriptionKey: "Your login changed before access could be refreshed",
            ])
        }
        let response: SubscriptionReconciliationResponse = try await client.functions.invoke(
            "check-subscription",
            options: FunctionInvokeOptions(headers: [
                "Authorization": "Bearer \(session.accessToken)",
            ])
        )

        guard ["free", "pro", "lifetime"].contains(response.subscriptionStatus) else {
            throw NSError(domain: "SupabaseManager", code: 502, userInfo: [
                NSLocalizedDescriptionKey: "Subscription reconciliation returned an invalid status",
            ])
        }
    }

    public func updateUserWordCount(
        wordsToAdd: Int,
        expectedUserID: UUID
    ) async throws -> User {
        let client = try requireClient()
        guard wordsToAdd > 0 else {
            throw NSError(domain: "SupabaseManager", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "Word count must be greater than zero",
            ])
        }

        struct IncrementWordCountPayload: Encodable {
            let expected_user_id: UUID
            let words_to_add: Int
        }

        let updatedUser: User = try await client.rpc(
            "increment_monthly_word_count_for_session",
            params: IncrementWordCountPayload(
                expected_user_id: expectedUserID,
                words_to_add: wordsToAdd
            )
        )
        .execute()
        .value

        return updatedUser
    }

    /// Reset monthly word count and set new reset date (for monthly limit reset)
    public func resetMonthlyWordCount() async throws -> User {
        let client = try requireClient()
        let currentUser = try await fetchUser()

        // Calculate next month start
        let calendar = Calendar.current
        let now = Date()
        let components = calendar.dateComponents([.year, .month], from: now)
        let startOfMonth = calendar.date(from: components)!
        let nextMonthStart = calendar.date(byAdding: .month, value: 1, to: startOfMonth)!

        struct ResetPayload: Encodable {
            let monthly_word_count: Int
            let word_count_reset_at: String
            let updated_at: String
        }

        let formatter = ISO8601DateFormatter()
        let resetPayload = ResetPayload(
            monthly_word_count: 0,
            word_count_reset_at: formatter.string(from: nextMonthStart),
            updated_at: formatter.string(from: Date())
        )

        let response: [User] = try await client
            .from("profiles")
            .update(resetPayload)
            .eq("user_id", value: currentUser.userId.uuidString)
            .select()
            .execute()
            .value

        guard let updatedUser = response.first else {
            throw NSError(domain: "SupabaseManager", code: 500, userInfo: [
                NSLocalizedDescriptionKey: "Failed to reset word count",
            ])
        }

        DebugLog.info("Monthly word count reset for user \(updatedUser.email)", context: "SupabaseManager")
        return updatedUser
    }

    public func ensureReferralCode(expectedUserID: UUID) async throws -> User {
        let client = try requireClient()

        struct SessionIdentityPayload: Encodable {
            let expected_user_id: UUID
        }

        let updatedUser: User = try await client.rpc(
            "ensure_referral_code_for_session",
            params: SessionIdentityPayload(expected_user_id: expectedUserID)
        )
        .execute()
        .value

        return updatedUser
    }

    public func redeemReferralCode(
        _ code: String,
        expectedUserID: UUID
    ) async throws -> User {
        let client = try requireClient()

        struct RedeemPayload: Encodable {
            let code: String
            let expected_user_id: UUID
        }

        let updatedUser: User = try await client.rpc(
            "redeem_referral_code_for_session",
            params: RedeemPayload(
                code: code.trimmingCharacters(in: .whitespacesAndNewlines),
                expected_user_id: expectedUserID
            )
        )
        .execute()
        .value

        return updatedUser
    }

    // MARK: - Transcription

    public func transcribe(audioData: Data, language: String = "en") async throws -> (transcription: String, wordCount: Int, updatedUser: User) {
        // Create request payload
        struct TranscribeRequest: Encodable {
            let audio: String
            let language: String
        }

        let requestBody = TranscribeRequest(
            audio: audioData.base64EncodedString(),
            language: language
        )

        let client = try requireClient()
        let response: TranscribeResponse = try await client.functions
            .invoke("transcribe", options: FunctionInvokeOptions(
                body: requestBody
            ))

        return (response.transcription, response.wordCount, response.user)
    }
}

private struct SubscriptionReconciliationResponse: Decodable {
    let subscriptionStatus: String

    enum CodingKeys: String, CodingKey {
        case subscriptionStatus = "subscription_status"
    }
}

// MARK: - Response Models

struct TranscribeResponse: Codable {
    let transcription: String
    let wordCount: Int
    let user: User

    enum CodingKeys: String, CodingKey {
        case transcription
        case wordCount = "word_count"
        case user
    }
}
