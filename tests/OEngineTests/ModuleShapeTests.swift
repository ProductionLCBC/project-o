import XCTest
import ODeckLink
@testable import OEngine

/// Spec 4 §14 — the module builds on macOS with Metal, and the DeckLink module
/// answers (with the stub when the SDK is absent, Package.swift).
final class ModuleShapeTests: XCTestCase {
    func test_metalIsAvailableOnMacOS() {
        XCTAssertTrue(OEngine.hasMetal)
    }

    func test_deckLinkModuleAnswersEvenWithoutTheSDK() {
        var device: OpaquePointer?
        let status = odl_open("none", &device)
        if odl_sdk_available() {
            XCTAssertTrue(status == ODL_OK || status == ODL_ERR_NOT_FOUND || status == ODL_ERR_UNAVAILABLE)
        } else {
            XCTAssertEqual(status, ODL_ERR_UNAVAILABLE)
            XCTAssertNil(device)
        }
    }

    func test_commandLineRejectsUnknownCommands() {
        XCTAssertEqual(OEngineCommandLine.run(arguments: ["nonsense"]), 2)
        XCTAssertEqual(OEngineCommandLine.run(arguments: []), 2)
        XCTAssertEqual(OEngineCommandLine.run(arguments: ["version"]), 0)
    }
}
