import CodexMeterCore
import Foundation
import TestSupport
import XCTest

final class AuthAPITests: XCTestCase, @unchecked Sendable {
    func testBothLoginFlowsValidateIdentityBeforeCredentialsAreStored() async throws {
        let signer = try TestSigner()
        let id = try signer.token(overrides: ["nonce": "browser-nonce"])
        let session = MockHTTP.session { request in
            if request.url == IDTokenValidator.jwksURL { return (200, signer.jwks) }
            XCTAssertEqual(request.url, CodexConstants.tokenURL)
            XCTAssertEqual(request.httpMethod, "POST")
            let body = String(decoding: requestBody(request), as: UTF8.self)
            XCTAssertTrue(body.contains("code_verifier=synthetic-verifier"))
            return (200, try JSONSerialization.data(withJSONObject: [
                "access_token": "synthetic-access", "refresh_token": "synthetic-refresh", "id_token": id
            ]))
        }
        let auth = AuthAPI(session: session)
        for nonce in ["browser-nonce", nil] as [String?] {
            let result = try await auth.exchange(code: "synthetic-code", redirectURI: "https://example.invalid/callback", verifier: "synthetic-verifier", nonce: nonce)
            XCTAssertEqual(result.identity?.subject, "user-a")
            XCTAssertEqual(result.accountId, "business-workspace")
            XCTAssertEqual(result.localAccountId, result.identity?.localAccountId)
        }
        session.invalidateAndCancel()
    }

    func testUnverifiableIDTokenCannotBecomeAnAccount() async throws {
        let signer = try TestSigner()
        let wrongSigner = try TestSigner()
        let forged = try wrongSigner.token()
        let session = MockHTTP.session { request in
            if request.url == IDTokenValidator.jwksURL { return (200, signer.jwks) }
            return (200, try JSONSerialization.data(withJSONObject: [
                "access_token": "synthetic-access", "refresh_token": "synthetic-refresh", "id_token": forged
            ]))
        }
        do {
            _ = try await AuthAPI(session: session).exchange(code: "code", redirectURI: "https://example.invalid", verifier: "verifier")
            XCTFail("Unvalidated identity was accepted")
        } catch {}
        session.invalidateAndCancel()
    }

    func testRefreshWithoutIDTokenRetainsValidatedIdentityAndLegacyLocalID() async throws {
        let previous = tokens(localID: "preserved-legacy-id")
        let session = MockHTTP.session { request in
            XCTAssertEqual(request.url, CodexConstants.tokenURL)
            return (200, Data("{\"access_token\":\"synthetic-new-access\"}".utf8))
        }
        let refreshed = try await AuthAPI(session: session).refresh(previous)
        XCTAssertEqual(refreshed.localAccountId, previous.localAccountId)
        XCTAssertEqual(refreshed.identity, previous.identity)
        XCTAssertEqual(refreshed.accountId, previous.accountId)
        XCTAssertEqual(refreshed.refreshToken, previous.refreshToken)
        XCTAssertEqual(refreshed.idToken, previous.idToken)
        session.invalidateAndCancel()
    }

    func testRefreshRejectsDifferentMemberOrWorkspace() async throws {
        let signer = try TestSigner()
        for replacement in [try signer.token(subject: "user-b"), try signer.token(workspace: "other-workspace")] {
            let session = MockHTTP.session { request in
                if request.url == IDTokenValidator.jwksURL { return (200, signer.jwks) }
                return (200, try JSONSerialization.data(withJSONObject: ["access_token": "synthetic-new", "id_token": replacement]))
            }
            do { _ = try await AuthAPI(session: session).refresh(tokens()); XCTFail("Changed identity accepted") }
            catch {}
            session.invalidateAndCancel()
        }
    }

    func testLegacyReconnectRequiresVerifiedHistoricalBinding() async throws {
        let signer = try TestSigner()
        let oldID = try signer.token(now: Date().addingTimeInterval(-7_200))
        let legacy = try JSONDecoder().decode(AuthTokens.self, from: legacyData(tokens(), idToken: oldID))
        let invalid = try JSONDecoder().decode(AuthTokens.self, from: legacyData(tokens("user-b"), idToken: "unvalidated.jwt.claims"))
        let session = MockHTTP.session { request in
            XCTAssertEqual(request.url, IDTokenValidator.jwksURL)
            return (200, signer.jwks)
        }
        let auth = AuthAPI(session: session)
        let aMatches = await auth.matchingLegacyAccounts(for: tokens(), existing: [legacy, invalid])
        let bMatches = await auth.matchingLegacyAccounts(for: tokens("user-b"), existing: [legacy, invalid])
        XCTAssertEqual(aMatches, [legacy])
        XCTAssertTrue(bMatches.isEmpty)
        session.invalidateAndCancel()
    }

    func testLegacyRefreshBindsSubjectWithoutChangingLocalID() async throws {
        let signer = try TestSigner()
        let oldID = try signer.token(now: Date().addingTimeInterval(-7_200))
        let previous = try JSONDecoder().decode(AuthTokens.self, from: legacyData(tokens(), idToken: oldID))
        let session = MockHTTP.session { request in
            if request.url == IDTokenValidator.jwksURL { return (200, signer.jwks) }
            return (200, Data("{\"access_token\":\"synthetic-new-access\"}".utf8))
        }
        let refreshed = try await AuthAPI(session: session).refresh(previous)
        XCTAssertEqual(refreshed.localAccountId, previous.localAccountId)
        XCTAssertEqual(refreshed.identity?.subject, "user-a")
        XCTAssertEqual(refreshed.accountId, previous.accountId)
        session.invalidateAndCancel()
    }
}
