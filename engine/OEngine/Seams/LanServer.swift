// OEngine — Spec 2 §9 and Spec 10 §2, the LAN's wire behind a seam.

import Foundation

/// One LAN client's WebSocket: the transport its `ApiConnection` writes to,
/// and the messages it sends.
public protocol LanPeer: ApiTransport {
    /// Where the client connects from, for the log.
    var remote: String { get }
    /// Starts reading: each text message goes to `onText`, and `onClose` runs
    /// once when the client has gone or the wire was closed.
    func read(onText: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void)
}

/// What the wire under the LAN listener reports.
public enum LanServerEvent: Sendable {
    /// The port is open and takes connections.
    case listening(port: Int)
    /// Bonjour has registered the service under this name.
    case advertised(name: String)
    /// The system refused the port or the registration for now: Spec 10 §2 —
    /// "macOS asks on behalf of the app that started the engine, may refuse
    /// Bonjour ... until someone answers".
    case refused(String)
    /// The listener failed for another reason, such as a port already in use.
    case failed(String)
    /// A client connected.
    case connection(any LanPeer)
}

/// Spec 2 §9 — "The engine listens on the LAN ... The service advertises
/// over Bonjour as `_projecto._tcp` with the machine's campus name". Spec 4
/// §14 — a seam: `NetworkLanServer` is the real one, over Network.framework;
/// `FakeLanServer` is the harness's, so the listener's rules (closed until
/// the token is read, a refusal retried) are tested without a network.
public protocol LanServer: AnyObject, Sendable {
    /// Opens a WebSocket listener on `port` (0 for any free one) and, when
    /// `serviceName` is given, advertises it as `serviceType`. Starting again
    /// replaces the listener; connections already made stay.
    func start(port: Int, serviceName: String?, serviceType: String, events: @escaping @Sendable (LanServerEvent) -> Void)
    /// Closes the listener. Connections already made stay until they are closed.
    func stop()
}
