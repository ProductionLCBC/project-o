import AppKit
import XCTest
@testable import OAppUI

/// Spec 10 §4, "One main window" — the app's views live in a package target,
/// so `swift test` builds them and lays them out offscreen with no app
/// running (Area 13 plan: the Xcode project is a shell).
@MainActor
final class EntryTests: XCTestCase {
    func test_theDelegateOpensOneMainWindowInTheDarkAppearance() throws {
        let delegate = AppDelegate()
        delegate.openMainWindow(show: false)
        let window = try XCTUnwrap(delegate.mainWindow)
        XCTAssertEqual(window.appearance?.name, .darkAqua, "Spec 10 §4: dark only in v1")
        XCTAssertEqual(window.title, "Project O")
        delegate.openMainWindow(show: false)
        XCTAssertTrue(delegate.mainWindow === window, "one main window, however often it is asked for")
    }
}
