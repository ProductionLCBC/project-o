import Foundation
import XCTest
@testable import OEngine
@testable import OMach

/// Spec 10 §2, "The Mach channel" — "The engine registers a Mach service in
/// the user's bootstrap namespace under the name `hello` gives, with
/// `bootstrap_check_in`, or, where launchd refuses a name it hasn't seen, the
/// deprecated `bootstrap_register`, behind a seam of its own (Spec 4 §14); the
/// app looks it up. Neither needs a launchd file or an entitlement (ADR
/// 0007)." Spec 10 §18, Area 19 — "The service named in `hello` resolves on
/// the dev Mac". These are what the first stop for review keeps: the
/// registration, the lookup and one surface sent as a Mach port, in one
/// process. The lookup "from an app that didn't start the engine" needs two
/// processes and is `oengine mach-proof`'s.
final class MachServiceTests: XCTestCase {
    /// A name no launchd file declares, as the engine's is: new on every run.
    func name(_ run: UUID = UUID()) -> String { MachServiceName.engine(run: run) }

    /// The registration, or a skip where the hosted runner's session has no
    /// bootstrap namespace that takes a new name.
    func registered(_ service: BootstrapMachService, _ name: String) throws -> MachRegistration {
        do {
            return try service.register(name: name)
        } catch {
            if ProcessInfo.processInfo.environment["O_HOSTED_RUNNER"] != nil {
                throw XCTSkip("hosted runner: the bootstrap namespace refused the name (\(error)); the Mach tests run on the bench Mac")
            }
            throw error
        }
    }

    func test_theServiceNameComesFromTheRunAndFitsTheNamespace() {
        let run = UUID(uuidString: "51E2A0C4-0000-4000-8000-000000000001") ?? UUID()
        XCTAssertEqual(MachServiceName.engine(run: run), "org.lcbc.projecto.engine.51e2a0c4-0000-4000-8000-000000000001")
        XCTAssertLessThan(MachServiceName.engine(run: run).utf8.count, MachServiceName.limit, "launchd's names hold 128 bytes with their end")
    }

    func test_checkInRegistersANameLaunchdHasNotSeenAndALookupFindsIt() throws {
        let service = BootstrapMachService(calls: [.checkIn])
        let name = self.name()
        let registration = try registered(service, name)
        defer { MachPorts.destroyReceive(registration.port) }
        XCTAssertEqual(registration.call, .checkIn)
        XCTAssertEqual(registration.name, name)
        let found = try service.lookUp(name: name)
        defer { MachPorts.release(found) }
        XCTAssertNotEqual(found, MachPorts.null)
    }

    func test_theDeprecatedRegisterWorksBehindTheSameSeam() throws {
        let service = BootstrapMachService(calls: [.register])
        let name = self.name()
        let registration = try registered(service, name)
        defer { MachPorts.destroyReceive(registration.port) }
        XCTAssertEqual(registration.call, .register)
        let found = try service.lookUp(name: name)
        defer { MachPorts.release(found) }
        XCTAssertNotEqual(found, MachPorts.null)
    }

    func test_theEngineTriesCheckInFirst() throws {
        let registration = try registered(BootstrapMachService(), name())
        defer { MachPorts.destroyReceive(registration.port) }
        XCTAssertEqual(registration.call, .checkIn, "bootstrap_check_in, then the deprecated call only where launchd refuses the name")
    }

    func test_twoRunsRegisterSideBySide() throws {
        let service = BootstrapMachService()
        let first = try registered(service, name()), second = try registered(service, name())
        defer {
            MachPorts.destroyReceive(first.port)
            MachPorts.destroyReceive(second.port)
        }
        XCTAssertNotEqual(first.port, second.port)
        let a = try service.lookUp(name: first.name), b = try service.lookUp(name: second.name)
        defer {
            MachPorts.release(a)
            MachPorts.release(b)
        }
        XCTAssertNotEqual(a, b, "each run's name resolves to its own engine")
    }

    func test_aNameNobodyRegisteredIsNotFound() {
        XCTAssertThrowsError(try BootstrapMachService().lookUp(name: name())) { error in
            guard case MachServiceError.notFound = error else { return XCTFail("\(error)") }
        }
    }

    func test_aNameTooLongForTheNamespaceIsRefusedBeforeLaunchdIsAsked() {
        let long = "org.lcbc.projecto.engine." + String(repeating: "x", count: 200)
        XCTAssertThrowsError(try BootstrapMachService().register(name: long)) { error in
            XCTAssertEqual(error as? MachServiceError, .nameTooLong(long))
        }
    }

    /// Spec 10 §2 — "each stack's preview as three IOSurfaces, sent as Mach
    /// ports": one surface goes over the service's port and its pixels read
    /// back on the other side, and the message's trailer says who sent it.
    func test_aSurfaceSentAsAMachPortReadsBackItsPixels() throws {
        let service = BootstrapMachService()
        let registration = try registered(service, name())
        defer { MachPorts.destroyReceive(registration.port) }

        let served = expectation(description: "the serving side answered one connect")
        let server = Thread {
            _ = MachProof.answerOne(on: registration, timeoutMs: 5000)
            served.fulfill()
        }
        server.start()

        let result = try MachProof.lookUp(name: registration.name, service: service, timeoutMs: 5000)
        wait(for: [served], timeout: 10)
        XCTAssertEqual(result.call, .checkIn)
        XCTAssertEqual(result.width, MachProof.surfaceWidth)
        XCTAssertEqual(result.height, MachProof.surfaceHeight)
        XCTAssertEqual(result.firstPixel, MachProof.pixel, "the surface's own bytes, read through the port")
        XCTAssertEqual(result.lastPixel, MachProof.pixel)
        XCTAssertEqual(result.serverPID, getpid())
        XCTAssertEqual(result.seenPID, getpid(), "the trailer's audit token names the sender's process")
        XCTAssertEqual(result.seenUID, getuid(), "and its user, which is what the engine checks before it sends anything")
    }
}
