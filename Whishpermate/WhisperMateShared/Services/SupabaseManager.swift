//
//  SupabaseManager.swift
//  WhisperMate
//
//  Created by WhisperMate on 2025-01-24.
//

import Auth
import Foundation
import Security
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

    var hasStoredSession: Bool {
        defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix(keyPrefix) }
    }
}

/// Keychain access for the Supabase session.
///
/// The session lives in the data protection keychain, not the login keychain. Login keychain
/// items carry an ACL bound to the exact binary that created them, so every app update — the
/// binary is re-signed each release — makes the stored session unreadable: macOS puts up a
/// SecurityAgent prompt, and a dismissed prompt reads as "no session", i.e. the user is silently
/// signed out after updating and relaunching. Data protection items are scoped to the team's
/// keychain access group instead and survive updates without prompting.
///
/// Calls are explicit `SecItem` calls so failures land in the log instead of being swallowed.
enum AuthKeychain {
    static let service = "com.whispermate.supabase.auth"

    /// Cleared permanently if the data protection keychain is unavailable to this build (an
    /// unsigned binary, or one missing the keychain-access-groups entitlement), so the app
    /// degrades to the login keychain rather than losing auth outright.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var useDataProtection = true

    private static var dataProtectionEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return useDataProtection
    }

    private static func disableDataProtection() {
        lock.lock()
        defer { lock.unlock() }
        guard useDataProtection else { return }
        useDataProtection = false
        DebugLog.warning("Data protection keychain unavailable; using login keychain", context: "AuthKeychain")
    }

    private static func baseQuery(_ key: String? = nil, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let key {
            query[kSecAttrAccount as String] = key
        }
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    /// Runs `operation` against the data protection keychain, falling back to the login keychain
    /// when the entitlement is missing.
    private static func perform(_ operation: (Bool) -> OSStatus) -> OSStatus {
        guard dataProtectionEnabled else { return operation(false) }

        let status = operation(true)
        switch status {
        case errSecMissingEntitlement, errSecParam:
            // Not entitled for the data protection keychain; stop trying it.
            disableDataProtection()
        case errSecItemNotFound:
            // An unentitled build sees an empty data protection keychain rather than an error,
            // so a miss still has to be checked against the login keychain.
            break
        default:
            return status
        }
        return operation(false)
    }

    static func store(key: String, value: Data) -> OSStatus {
        perform { dataProtection in
            var addQuery = baseQuery(key, dataProtection: dataProtection)
            addQuery[kSecValueData as String] = value
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecDuplicateItem else { return addStatus }

            let matchQuery = baseQuery(key, dataProtection: dataProtection)
            let updateStatus = SecItemUpdate(
                matchQuery as CFDictionary,
                [kSecValueData as String: value] as CFDictionary
            )
            guard updateStatus != errSecSuccess else { return updateStatus }

            // The existing item is unreadable by this build. Replace it outright so the new
            // session is not lost on quit.
            DebugLog.warning("Keychain update failed (\(updateStatus)); replacing item", context: "AuthKeychain")
            SecItemDelete(matchQuery as CFDictionary)
            return SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    static func retrieve(key: String) -> (data: Data?, status: OSStatus) {
        var result: Data?
        let status = perform { dataProtection in
            var query = baseQuery(key, dataProtection: dataProtection)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var item: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            result = item as? Data
            return status
        }
        return (result, status)
    }

    /// Moves a session written by an older build into the data protection keychain.
    static func migrateLoginKeychainItem(key: String) -> Data? {
        guard dataProtectionEnabled else { return nil }

        var query = baseQuery(key, dataProtection: false)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else {
            return nil
        }

        DebugLog.info("Migrating session out of the login keychain", context: "AuthKeychain")
        if store(key: key, value: data) == errSecSuccess {
            SecItemDelete(baseQuery(key, dataProtection: false) as CFDictionary)
        }
        return data
    }

    @discardableResult
    static func remove(key: String) -> OSStatus {
        SecItemDelete(baseQuery(key, dataProtection: false) as CFDictionary)
        return perform { dataProtection in
            SecItemDelete(baseQuery(key, dataProtection: dataProtection) as CFDictionary)
        }
    }

    /// True when any session item is present, regardless of whether it can be decoded.
    static func hasStoredSession() -> Bool {
        for dataProtection in [dataProtectionEnabled, false] {
            var query = baseQuery(dataProtection: dataProtection)
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
                return true
            }
        }
        return false
    }
}

/// Keychain-backed auth storage with a UserDefaults fallback for migrating existing sessions.
final class PersistentAuthLocalStorage: AuthLocalStorage, @unchecked Sendable {
    private enum Keys {
        static let didAttemptLoginKeychainMigration = "didAttemptLoginKeychainAuthMigration"
    }

    private let legacy = UserDefaultsAuthLocalStorage()

    func store(key: String, value: Data) throws {
        let status = AuthKeychain.store(key: key, value: value)
        if status == errSecSuccess {
            try? legacy.remove(key: key)
            return
        }

        // Keep the session somewhere durable rather than dropping it: a memory-only session
        // is exactly the "signed out after restart" failure we are guarding against.
        DebugLog.error("Keychain store failed (\(status)); falling back to defaults", context: "AuthStorage")
        try legacy.store(key: key, value: value)
    }

    func retrieve(key: String) throws -> Data? {
        let (data, status) = AuthKeychain.retrieve(key: key)
        if let data {
            return data
        }
        if status != errSecItemNotFound {
            DebugLog.error("Keychain retrieve failed (\(status))", context: "AuthStorage")
        }
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed {
            // The item cannot be read by this binary at all, and leaving it in place would keep
            // every later write on the failing update path. Drop it so the next sign-in stores
            // a session this build owns.
            AuthKeychain.remove(key: key)
        }

        // Reading a login keychain item can put up a SecurityAgent prompt, so try the one-time
        // migration once and never nag again if the user dismissed it.
        if !AppDefaults.shared.bool(forKey: Keys.didAttemptLoginKeychainMigration) {
            AppDefaults.shared.set(true, forKey: Keys.didAttemptLoginKeychainMigration)
            if let migrated = AuthKeychain.migrateLoginKeychainItem(key: key) {
                return migrated
            }
        }

        guard let legacyValue = try legacy.retrieve(key: key) else { return nil }

        if AuthKeychain.store(key: key, value: legacyValue) == errSecSuccess {
            try? legacy.remove(key: key)
        }
        return legacyValue
    }

    func remove(key: String) throws {
        AuthKeychain.remove(key: key)
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

    // MARK: - Public API

    /// Whether a session was previously persisted, so callers can tell "never signed in" apart
    /// from "signed in, but the session could not be restored yet".
    public var hasPersistedSession: Bool {
        AuthKeychain.hasStoredSession() || UserDefaultsAuthLocalStorage().hasStoredSession
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

    /// Foundation upper-cases `uuidString`, but user ids are stored lower-cased.
    /// Postgres compared UUIDs case-insensitively; the backend stores them as
    /// text, so send the canonical form rather than relying on the server to
    /// normalise it.
    private func profileFilterID(_ id: UUID) -> String {
        id.uuidString.lowercased()
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
            .eq("user_id", value: profileFilterID(session.user.id))
            .execute()
            .value

        guard let user = response.first else {
            throw NSError(domain: "SupabaseManager", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "User not found in database",
            ])
        }

        return user
    }

    public func updateUserWordCount(wordsToAdd: Int) async throws -> User {
        let client = try requireClient()
        // First, fetch current user
        let currentUser = try await fetchUser()
        let newTotal = currentUser.monthlyWordCount + wordsToAdd

        // Create update payload
        struct UserUpdate: Encodable {
            let monthly_word_count: Int
            let updated_at: String
        }

        let updatePayload = UserUpdate(
            monthly_word_count: newTotal,
            updated_at: ISO8601DateFormatter().string(from: Date())
        )

        // Update in database
        let response: [User] = try await client
            .from("profiles")
            .update(updatePayload)
            .eq("user_id", value: profileFilterID(currentUser.userId))
            .select()
            .execute()
            .value

        guard let updatedUser = response.first else {
            throw NSError(domain: "SupabaseManager", code: 500, userInfo: [
                NSLocalizedDescriptionKey: "Failed to update user word count",
            ])
        }

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
            .eq("user_id", value: profileFilterID(currentUser.userId))
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

    public func ensureReferralCode() async throws -> User {
        let client = try requireClient()

        struct EmptyPayload: Encodable {}

        let updatedUser: User = try await client.rpc(
            "ensure_referral_code",
            params: EmptyPayload()
        )
        .execute()
        .value

        return updatedUser
    }

    public func redeemReferralCode(_ code: String) async throws -> User {
        let client = try requireClient()

        struct RedeemPayload: Encodable {
            let code: String
        }

        let updatedUser: User = try await client.rpc(
            "redeem_referral_code",
            params: RedeemPayload(code: code.trimmingCharacters(in: .whitespacesAndNewlines))
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
