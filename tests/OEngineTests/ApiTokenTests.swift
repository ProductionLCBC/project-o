import XCTest
import OCore
@testable import OEngine

/// Spec 10 §12 — "two generic-password items under the service "Project O",
/// with the machine's uuid in their account names, holding ... the API token
/// (32 random bytes, base64url)"; "It makes the token at first launch".
/// Spec 10 §2 — "makes the token if there is none". Spec 10 §18, Area 19,
/// the LAN and the Keychain. The Keychain here is the harness's, in memory:
/// the tests never touch the real one.
final class ApiTokenTests: XCTestCase {
    let machine = UUID(uuidString: "7A7A0000-0000-4000-8000-000000000001") ?? UUID()

    func test_aTokenIsThirtyTwoRandomBytesInBase64url() throws {
        let token = ApiToken.make()
        XCTAssertEqual(token.count, 43, "32 bytes in base64 without padding")
        XCTAssertTrue(token.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }, "base64url's alphabet only: \(token)")
        // It decodes back to 32 bytes.
        let standard = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="
        XCTAssertEqual(Data(base64Encoded: standard)?.count, 32)
        XCTAssertNotEqual(ApiToken.make(), token, "a new one every time")
        XCTAssertEqual(ApiToken.base64url(Data([0xFB, 0xFF, 0xFE])), "-__-", "+ and / become - and _")
        XCTAssertEqual(ApiToken.base64url(Data([0xFF])), "_w", "and the padding goes")
    }

    func test_theItemIsNamedForTheMachineUnderTheServiceProjectO() {
        XCTAssertEqual(SecretAccount.service, "Project O")
        XCTAssertEqual(SecretAccount.token(machine: machine), "api-token.7a7a0000-0000-4000-8000-000000000001", "the machine's uuid in the account name")
    }

    func test_theFirstLaunchMakesTheTokenAndTheNextReadsTheSameOne() throws {
        let store = MemorySecretStore()
        let first = ApiToken.load(from: store, machine: machine)
        guard case .made(let token) = first else { return XCTFail("the first launch makes it: \(first)") }
        XCTAssertEqual(store.item(SecretAccount.token(machine: machine)), Data(token.utf8), "written to the machine's item")
        XCTAssertEqual(store.writes, 1)
        XCTAssertEqual(ApiToken.load(from: store, machine: machine), .read(token), "the next launch reads it")
        XCTAssertEqual(store.writes, 1, "and writes nothing")
        // Another machine on the same Mac has an item of its own.
        let other = ApiToken.load(from: store, machine: UUID())
        XCTAssertNotEqual(other.token, token)
    }

    func test_aKeychainThatCannotBeReadGivesNoTokenAndIsNotWritten() {
        let store = MemorySecretStore()
        store.unreadable = "the user denied access"
        XCTAssertEqual(ApiToken.load(from: store, machine: machine), .unreadable("the user denied access"))
        XCTAssertEqual(store.writes, 0, "nothing is made over an item that may be there")
        XCTAssertNil(ApiToken.load(from: store, machine: machine).token)
    }

    func test_aNewTokenThatCannotBeWrittenIsNotUsed() {
        let store = MemorySecretStore()
        store.acceptsWrites = false
        let outcome = ApiToken.load(from: store, machine: machine)
        guard case .unreadable = outcome else { return XCTFail("a token only this run would know: \(outcome)") }
        XCTAssertNil(outcome.token)
    }

    /// Area 19 reading — whatever text the item holds is the token; an item
    /// that isn't text is not replaced, which is New Token…'s to do.
    func test_whateverTextTheItemHoldsIsTheTokenAndAnythingElseIsLeftAlone() {
        let account = SecretAccount.token(machine: machine)
        let byHand = MemorySecretStore([account: Data("a token set by hand".utf8)])
        XCTAssertEqual(ApiToken.load(from: byHand, machine: machine), .read("a token set by hand"))
        for bad in [Data(), Data([0xFF, 0xFE, 0xFD])] {
            let store = MemorySecretStore([account: bad])
            guard case .unreadable = ApiToken.load(from: store, machine: machine) else { return XCTFail("not a token") }
            XCTAssertEqual(store.item(account), bad, "left as it was")
            XCTAssertEqual(store.writes, 0)
        }
    }
}
