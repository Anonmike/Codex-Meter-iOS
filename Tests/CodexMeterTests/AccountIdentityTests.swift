import CodexMeterCore
import Foundation
import TestSupport
import XCTest

final class AccountIdentityTests: XCTestCase {
    func testBusinessMembersWithSameWorkspaceAndEmailHaveIndependentIdentities() {
        let a = tokens("user-a")
        let b = tokens("user-b")
        XCTAssertEqual(a.accountId, b.accountId)
        XCTAssertEqual(a.email, b.email)
        XCTAssertNotEqual(a.localAccountId, b.localAccountId)
        XCTAssertEqual(a.localAccountId, tokens("user-a").localAccountId)
        XCTAssertNotEqual(a.localAccountId, tokens("user-a", workspace: "other-workspace").localAccountId)
    }

    func testIdentityFramingCannotCollideOnDelimiters() {
        let a = AccountIdentity(issuer: "a", subject: "b:c", workspaceId: "d")
        let b = AccountIdentity(issuer: "a:b", subject: "c", workspaceId: "d")
        XCTAssertNotEqual(a.localAccountId, b.localAccountId)
    }

    func testReconnectUpdatesOnlySameMember() throws {
        let storage = MemoryCredentials()
        let repository = AccountCredentialRepository(storage: storage)
        let a = try repository.connect(tokens("user-a"))
        let b = try repository.connect(tokens("user-b"))
        let reconnected = try repository.connect(tokens("user-a", suffix: "-reconnected"))
        XCTAssertEqual(reconnected.localAccountId, a.localAccountId)
        XCTAssertEqual(repository.loadAll().count, 2)
        XCTAssertEqual(repository.load(localAccountId: b.localAccountId), b)
        XCTAssertEqual(try storage.items().count, 2)
    }

    func testRefreshAndLogoutAreIndependentAndCannotResurrectAnAccount() throws {
        let repository = AccountCredentialRepository(storage: MemoryCredentials())
        let a = try repository.connect(tokens("user-a"))
        let b = try repository.connect(tokens("user-b"))
        let updated = tokens("user-a", suffix: "-refreshed")
        try repository.replace(updated, ifCurrent: a)
        XCTAssertEqual(repository.load(localAccountId: b.localAccountId), b)
        XCTAssertThrowsError(try repository.replace(tokens("user-b"), ifCurrent: updated))
        try repository.remove(localAccountId: a.localAccountId)
        XCTAssertThrowsError(try repository.replace(tokens("user-a", suffix: "-late"), ifCurrent: updated))
        XCTAssertNil(repository.load(localAccountId: a.localAccountId))
        XCTAssertEqual(repository.loadAll(), [b])
    }

    func testStaleRefreshCannotReplaceReconnectedCredentials() throws {
        let repository = AccountCredentialRepository(storage: MemoryCredentials())
        let previous = try repository.connect(tokens())
        let connected = try repository.connect(tokens(suffix: "-new-login"))
        XCTAssertThrowsError(try repository.replace(tokens(suffix: "-late-refresh"), ifCurrent: previous))
        XCTAssertEqual(repository.loadAll(), [connected])
    }

    func testV2MigrationPreservesCredentialsLocalIDsAndOriginalWorkspace() throws {
        let storage = MemoryCredentials()
        let a = tokens()
        let legacy = try legacyData(a)
        let source = AccountCredentialRepository.legacyPrefix + a.accountId
        try storage.write(legacy, for: source)
        let repository = AccountCredentialRepository(storage: storage)
        let migrated = try XCTUnwrap(repository.loadAll().first)
        XCTAssertEqual(migrated.localAccountId, a.accountId)
        XCTAssertEqual(migrated.accountId, a.accountId)
        XCTAssertEqual(migrated.accessToken, a.accessToken)
        XCTAssertNil(migrated.identity)
        XCTAssertNil(try storage.items()[source])
        XCTAssertNotNil(try storage.items()[AccountCredentialRepository.prefix + a.accountId])
        let b = try repository.connect(tokens("user-b"))
        XCTAssertNotEqual(migrated.localAccountId, b.localAccountId)
        XCTAssertEqual(repository.loadAll().count, 2)
        let reconnected = try repository.connect(a, matchingLegacy: [migrated])
        XCTAssertEqual(reconnected.localAccountId, migrated.localAccountId)
        XCTAssertEqual(repository.loadAll().count, 2)
    }

    func testV1MigrationRetainsGlobalCacheOwnershipAndIsIdempotent() throws {
        let storage = MemoryCredentials()
        try storage.write(legacyData(tokens()), for: AccountCredentialRepository.legacyAccount)
        let repository = AccountCredentialRepository(storage: storage)
        let first = repository.loadAll()
        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(first[0].ownsLegacyGlobalCache)
        XCTAssertEqual(first, repository.loadAll())
        XCTAssertNil(try storage.items()[AccountCredentialRepository.legacyAccount])
    }

    func testMigrationDoesNotDeleteSourceOnWriteOrReadBackFailure() throws {
        for corrupt in [false, true] {
            let storage = MemoryCredentials()
            let key = AccountCredentialRepository.legacyPrefix + "business-workspace"
            let original = try legacyData(tokens())
            try storage.write(original, for: key)
            storage.failWrites = !corrupt
            storage.corruptWrites = corrupt
            let repository = AccountCredentialRepository(storage: storage)
            XCTAssertEqual(repository.loadAll().count, 1)
            XCTAssertEqual(try storage.items()[key], original)
        }
    }

    func testInterruptedMigrationRetainsSourceAndRetriesWithoutDuplicates() throws {
        let storage = MemoryCredentials()
        let key = AccountCredentialRepository.legacyPrefix + "business-workspace"
        try storage.write(legacyData(tokens()), for: key)
        storage.failDeletes = true
        let repository = AccountCredentialRepository(storage: storage)
        XCTAssertEqual(repository.loadAll().count, 1)
        XCTAssertNotNil(try storage.items()[key])
        storage.failDeletes = false
        XCTAssertEqual(repository.loadAll().count, 1)
        XCTAssertNil(try storage.items()[key])
        try repository.remove(localAccountId: "business-workspace")
        XCTAssertTrue(repository.loadAll().isEmpty)
    }

    func testMigrationNeverOverwritesNewerDestination() throws {
        let storage = MemoryCredentials()
        let old = try legacyData(tokens())
        let new = tokens(suffix: "-new", localID: "business-workspace")
        let key = AccountCredentialRepository.legacyPrefix + "business-workspace"
        try storage.write(old, for: key)
        try storage.write(JSONEncoder().encode(new), for: AccountCredentialRepository.prefix + new.localAccountId)
        let repository = AccountCredentialRepository(storage: storage)
        XCTAssertEqual(repository.loadAll(), [new])
        XCTAssertEqual(try storage.items()[key], old)
    }
}

final class IDTokenValidatorTests: XCTestCase {
    func testValidatesSignedMemberAndWorkspace() throws {
        let signer = try TestSigner()
        let a = try IDTokenValidator.validate(signer.token(), jwks: signer.jwks)
        let b = try IDTokenValidator.validate(signer.token(subject: "user-b"), jwks: signer.jwks)
        XCTAssertEqual(a.identity.workspaceId, b.identity.workspaceId)
        XCTAssertNotEqual(a.identity.localAccountId, b.identity.localAccountId)
    }

    func testRejectsUnsignedTamperedAndIncorrectlySignedTokens() throws {
        let signer = try TestSigner()
        let token = try signer.token()
        var parts = token.split(separator: ".").map(String.init)
        parts[1] = TestSigner.base64(Data("{\"sub\":\"user-b\"}".utf8))
        XCTAssertThrowsError(try IDTokenValidator.validate(parts.joined(separator: "."), jwks: signer.jwks))
        XCTAssertThrowsError(try IDTokenValidator.validate(signer.token(headerOverrides: ["alg": "none"]), jwks: signer.jwks))
        XCTAssertThrowsError(try IDTokenValidator.validate(token, jwks: TestSigner().jwks))
        XCTAssertThrowsError(try IDTokenValidator.validate(token, jwks: Data("{\"keys\":[]}".utf8)))
    }

    func testRejectsWrongIssuerAudienceExpiredMissingSubjectAndAmbiguousWorkspace() throws {
        let signer = try TestSigner()
        let cases: [[String: Any]] = [
            ["iss": "https://attacker.invalid"], ["aud": "different-client"],
            ["aud": [IDTokenValidator.clientID, "other"]],
            ["exp": Date().timeIntervalSince1970 - 1], ["sub": ""],
            ["iat": Date().timeIntervalSince1970 + 600], ["exp": true],
            ["chatgpt_account_id": "different-workspace"],
            ["https://api.openai.com/auth": [:], "organizations": [["id": "unselected-workspace"]]]
        ]
        for claims in cases {
            XCTAssertThrowsError(try IDTokenValidator.validate(signer.token(overrides: claims), jwks: signer.jwks))
        }
    }

    func testRequiresBrowserNonceAndAuthorizedParty() throws {
        let signer = try TestSigner()
        XCTAssertThrowsError(try IDTokenValidator.validate(signer.token(), jwks: signer.jwks, nonce: "expected"))
        XCTAssertThrowsError(try IDTokenValidator.validate(signer.token(overrides: ["nonce": "wrong"]), jwks: signer.jwks, nonce: "expected"))
        let signed = try signer.token(overrides: ["nonce": "expected", "aud": [IDTokenValidator.clientID, "other"], "azp": IDTokenValidator.clientID])
        XCTAssertNoThrow(try IDTokenValidator.validate(signed, jwks: signer.jwks, nonce: "expected"))
    }

    func testHistoricalBindingDoesNotAcceptExpiredTokenForLogin() throws {
        let signer = try TestSigner()
        let expired = try signer.token(now: Date().addingTimeInterval(-7_200))
        XCTAssertThrowsError(try IDTokenValidator.validate(expired, jwks: signer.jwks))
        XCTAssertEqual(try IDTokenValidator.legacyBinding(expired, jwks: signer.jwks).subject, "user-a")
        XCTAssertThrowsError(try IDTokenValidator.legacyBinding(expired, jwks: TestSigner().jwks))
    }
}
