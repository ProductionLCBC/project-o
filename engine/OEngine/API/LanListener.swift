// OEngine — Spec 10 §2, "The LAN API": when the listener opens, and what it does while it can't.

import Foundation
import OCore

/// Spec 10 §2 — "The LAN API is Spec 2 §9's WebSocket on `apiPort`, with the
/// token and Bonjour. At launch the engine reads its two Keychain items ...
/// on a background thread, and makes the token if there is none, so a
/// Keychain prompt after an update comes when the app first starts the new
/// build, while someone is there, and never holds back the outputs (R2).
/// Until it has the token, the LAN listener stays closed and the `engine`
/// topic says so (§3)." And: "macOS ... may refuse Bonjour and OSC sends
/// until someone answers, and may ask again after an update (ADR 0007), so
/// the engine retries a refused registration or send every few seconds, and
/// the `engine` topic shows the LAN as waiting meanwhile."
///
/// The wire is a `LanServer` and the Keychain a `SecretStore`, both seams;
/// this class holds the rules between them and the API's hub. Everything it
/// keeps is touched on its own queue.
///
/// Area 19 readings: the Keychain is read once, at launch, and a refusal
/// stands until the next launch (asking again would put the prompt back in
/// front of whoever said no, mid-service); "every few seconds" is five; a
/// listener that opens but isn't advertised within those five seconds counts
/// as refused, since the system doesn't always say; a failure that isn't a
/// refusal (a port something else holds) is retried the same way and shows
/// as `closed`; and a connection that hasn't signed in after ten seconds is
/// closed, as one whose first message isn't `auth` is.
public final class LanListener: @unchecked Sendable {
    /// Spec 2 §9 — "advertises over Bonjour as `_projecto._tcp` with the machine's campus name".
    public static let serviceType = "_projecto._tcp"

    private let hub: ApiHub
    private let server: any LanServer
    private let secrets: any SecretStore
    private let machine: UUID
    private let port: Int
    private let campus: String
    private let log: EngineLog
    private let retrySeconds: Double
    private let authSeconds: Double
    private let queue = DispatchQueue(label: "o.engine.lan.listener")

    private var stopped = false
    private var generation = 0
    private var listening = false
    private var advertised = false
    private var lastTrouble: String?
    private var boundPort = 0

    public init(hub: ApiHub, server: any LanServer, secrets: any SecretStore, machine: UUID, port: Int, campus: String, log: EngineLog,
                retrySeconds: Double = 5, authSeconds: Double = 10) {
        self.hub = hub
        self.server = server
        self.secrets = secrets
        self.machine = machine
        self.port = port
        self.campus = campus
        self.log = log
        self.retrySeconds = retrySeconds
        self.authSeconds = authSeconds
    }

    /// The port the listener is open on; 0 while it isn't.
    public var openPort: Int { queue.sync { listening ? boundPort : 0 } }

    /// Starts the Keychain read on a thread of its own and returns at once;
    /// the listener opens when the token is there.
    public func start() {
        set(.closed)
        let thread = Thread { [self] in
            let outcome = ApiToken.load(from: secrets, machine: machine)
            queue.async { self.tokenRead(outcome) }
        }
        thread.name = "o.engine.keychain"
        thread.qualityOfService = .utility
        thread.start()
    }

    /// Closes the listener; the connections are the hub's to close.
    public func stop() {
        queue.sync {
            stopped = true
            generation += 1
            listening = false
            advertised = false
        }
        server.stop()
        set(.closed)
    }

    private func tokenRead(_ outcome: ApiToken.Outcome) {
        guard !stopped else { return }
        switch outcome {
        case .read(let token):
            hub.setToken(token)
            log.info("the API token was read from the Keychain")
        case .made(let token):
            hub.setToken(token)
            log.info("the API token was made and written to the Keychain")
        case .unreadable(let why):
            // Spec 10 §3 — the `keychain` badge: "an item can't be read".
            log.error("the Keychain can't be read (\(why)); the LAN listener stays closed")
            var standing = hub.lan
            standing.state = .closed
            standing.keychainUnreadable = true
            hub.lan = standing
            return
        }
        open()
    }

    private func open() {
        guard !stopped else { return }
        generation += 1
        let current = generation
        listening = false
        advertised = false
        // A machine with no campus name is still found: under the product's own.
        server.start(port: port, serviceName: campus.isEmpty ? "Project O" : campus, serviceType: Self.serviceType) { [weak self] event in
            guard let self else { return }
            self.queue.async { self.take(event, generation: current) }
        }
        retry(current)
    }

    /// In `retrySeconds`: a listener that still isn't open and advertised is started again.
    private func retry(_ current: Int) {
        queue.asyncAfter(deadline: .now() + retrySeconds) { [weak self] in
            guard let self, !self.stopped, self.generation == current, !(self.listening && self.advertised) else { return }
            if self.listening {
                self.trouble("Bonjour hasn't registered \(Self.serviceType)", waiting: true)
            }
            self.open()
        }
    }

    private func take(_ event: LanServerEvent, generation current: Int) {
        if case .connection(let peer) = event {
            accept(peer)
            return
        }
        guard !stopped, current == generation else { return }
        switch event {
        case .listening(let port):
            listening = true
            boundPort = port
        case .advertised(let name):
            advertised = true
            if listening {
                lastTrouble = nil
                log.info("the LAN API is open on port \(boundPort), advertised as \"\(name)\" (\(Self.serviceType))")
                set(.open)
            }
        case .refused(let why):
            let was = listening && advertised
            listening = false
            advertised = false
            trouble("the system refused it for now: \(why)", waiting: true)
            if was { retry(current) }
        case .failed(let why):
            let was = listening && advertised
            listening = false
            advertised = false
            trouble(why, waiting: false)
            if was { retry(current) }
        case .connection:
            break
        }
    }

    /// Says once what holds the listener back, however often it is retried.
    private func trouble(_ why: String, waiting: Bool) {
        if lastTrouble != why {
            lastTrouble = why
            log.warning("the LAN API on port \(port) isn't open: \(why); trying again every \(Int(retrySeconds)) s")
        }
        set(waiting ? .waiting : .closed)
    }

    private func set(_ state: LanStanding.State) {
        var standing = hub.lan
        guard standing.state != state else { return }
        standing.state = state
        hub.lan = standing
    }

    /// Spec 2 §9 — "the first message on a connection must be `{"type":
    /// "auth", "token": "..."}` or the socket closes": the hub checks each
    /// message as it arrives; a client that says nothing is closed here.
    private func accept(_ peer: any LanPeer) {
        guard !stopped else {
            peer.close()
            return
        }
        let hub = self.hub
        let connection = hub.accept(peer, origin: .lan, peer: peer.remote)
        peer.read(onText: { [weak connection] text in
            if let connection { hub.receive(text, from: connection) }
        }, onClose: { [weak connection] in
            connection?.close()
        })
        queue.asyncAfter(deadline: .now() + authSeconds) { [weak connection] in
            guard let connection, !connection.isClosed, !hub.isAuthorized(connection) else { return }
            connection.close()
        }
    }
}
