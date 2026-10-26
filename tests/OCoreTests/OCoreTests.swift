import XCTest
@testable import OCore

/// Smoke test: the package builds and the test target links against OCore.
/// Real tests for the projection live in ProjectionTests.swift, one per row of
/// the Spec 3 §9 table, written before the projection itself.
final class OCoreTests: XCTestCase {
    func test_schemaVersionIsOne() {
        XCTAssertEqual(OCore.schemaVersion, 1)
    }
}
