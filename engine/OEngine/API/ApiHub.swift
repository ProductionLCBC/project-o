// OEngine — Spec 2 §9 and Spec 10 §3, the API's hub: every connection, in one order.

import Foundation
import OCore

/// Spec 10 §3 — "A connection carries answers and events in the order the
/// engine produces them, so an answer reflects every event sent before it:
/// the app applies the events that arrive after an answer and drops those
/// that came before it."
///
/// The hub puts the engine's own publisher (Spec 2 §9) on the wire. Its one
/// rule is where things are *taken*:
///
/// - A command is handed to the engine's queue the moment it arrives, as OSC
///   does, and runs in the next build.
/// - Every other request waits for the next build to *start*, and is answered
///   when that build has finished. So a request sent after a command is
///   answered after the build that ran the command.
/// - When a build has finished, each connection is given, in this order: the
///   results of its groups that ran, the build's events for the topics it
///   subscribed to, then its answers.
///
/// So `subscribe` followed by `state` loses and doubles nothing (Spec 10
/// §18): the subscription starts after the build's events have gone, and the
/// answer placed after it reflects exactly that build.
///
/// `ping` goes the same way, so `pong` says the control side is alive, which
/// is what "The engine isn't responding" (Spec 10 §2) is about.
public final class ApiHub: @unchecked Sendable {
    /// Spec 2 §9 — "The envelope carries `"api": 1`".
    public static let apiVersion = 1

    /// Spec 10 §2 — what `hello` names: "its version, the API version, its
    /// process id, the machine, the run and the Mach service".
    public struct Identity: Sendable {
        public var engine: String
        public var pid: Int32
        public var machine: UUID
        public var run: UUID
        public var mach: String

        public init(engine: String = OCore.appVersion, pid: Int32 = getpid(), machine: UUID, run: UUID, mach: String) {
            self.engine = engine
            self.pid = pid
            self.machine = machine
            self.run = run
            self.mach = mach
        }
    }

    /// Spec 10 §3 — "The app names each command's source, `ui`, `key` or
    /// `commandbar` (Spec 2 §5), and the engine takes it from this socket
    /// only".
    static let localSources: [String: SourceKind] = ["ui": .ui, "key": .key, "commandbar": .commandbar]

    /// Spec 10 §3 — the requests "the local socket takes ... On the LAN they
    /// are rejected with `localOnly`."
    static let localOnly: Set<String> = ["ping", "stop", "releaseScreen", "passcode", "unlock", "resetPasscode", "token", "newToken"]

    /// Spec 10 §12 — the requests Area 18 builds; until then the local socket refuses them.
    static let later: Set<String> = ["passcode", "unlock", "resetPasscode", "token", "newToken"]

    struct Request {
        var connection: ApiConnection
        var id: JSONValue
        var type: String
        var members: [String: JSONValue]
        /// An answer worked out as the request arrived (a command that didn't parse), kept in its place in the order.
        var ready: JSONValue?
    }

    /// A group handed to the engine, waiting for its result.
    private struct Pending {
        var connection: ApiConnection
        var id: JSONValue
        var kind: SourceKind
        var sent: Int
        var single: Bool
        var batch: Batch?
        var index: Int
    }

    /// Spec 2 §9 (Area 19 reading) — `commands` with `"group": false`: each
    /// command its own group, one answer when the last has its result.
    private final class Batch {
        let connection: ApiConnection
        let id: JSONValue
        var results: [JSONValue?]

        init(connection: ApiConnection, id: JSONValue, count: Int) {
            self.connection = connection
            self.id = id
            results = Array(repeating: nil, count: count)
        }
    }

    let publisher: EnginePublisher
    let log: EngineLog
    weak var engine: Engine?

    private let lock = NSLock()
    private var connections: [Int: ApiConnection] = [:]
    private var nextConnection = 0
    private var inbox: [Request] = []
    private var sealed: [Request] = []
    private var pending: [GroupID: Pending] = [:]
    private var identity: Identity?
    /// Answers that take work are worked out here, never on the control thread.
    let workers = DispatchQueue(label: "o.engine.api.answers", qos: .userInitiated)

    /// Spec 10 §3, `stop` — what stops the engine and says what it couldn't
    /// write; the process sets it, and exits in `afterStop` once the answer
    /// has gone. Without them the hub stops its own engine and nothing exits,
    /// as the harness wants.
    public var stopEngine: (@Sendable () -> Engine.StopReport)?
    public var afterStop: (@Sendable () -> Void)?
    /// Spec 10 §3, `releaseScreen` — takes every output off the screen with
    /// this uuid and reports the outputs released; AppKit's work, so it
    /// answers through its completion from the main thread.
    public var releaseScreen: (@Sendable (String, @escaping @Sendable ([Int]) -> Void) -> Void)?

    init(publisher: EnginePublisher, log: EngineLog) {
        self.publisher = publisher
        self.log = log
        publisher.subscribeToEverything { [weak self] event in self?.publish(event) }
    }

    /// Spec 10 §2 — who this engine is, for `hello`; set before any socket opens.
    public func identify(_ identity: Identity) {
        lock.lock()
        self.identity = identity
        lock.unlock()
    }

    // MARK: - Connections

    /// A new connection over `transport`. On the local socket "the engine's
    /// first message is `hello`" (Spec 10 §2); a LAN connection must
    /// authorize first (Spec 2 §9).
    @discardableResult
    public func accept(_ transport: any ApiTransport, origin: ApiConnection.Origin, peer: String = "") -> ApiConnection {
        lock.lock()
        nextConnection += 1
        let number = nextConnection
        let connection = ApiConnection(id: number, origin: origin, client: "\(origin.rawValue) \(number)\(peer.isEmpty ? "" : " " + peer)",
                                       transport: transport, log: log, onClose: { [weak self] closed in self?.forget(closed) })
        connections[number] = connection
        let identity = self.identity
        lock.unlock()
        if origin == .local { connection.send(Self.hello(identity)) }
        return connection
    }

    /// Spec 10 §2 — `{ "type": "hello", "api": 1, "engine": "0.4.0", "pid":
    /// 4182, "machine": "7a7a…", "run": "51e2…", "mach":
    /// "org.lcbc.projecto.engine.51e2…" }`.
    static func hello(_ identity: Identity?) -> JSONValue {
        var fields: [String: JSONValue] = ["type": .string("hello"), "api": .number(Double(apiVersion)), "engine": .string(identity?.engine ?? OCore.appVersion),
                                           "pid": .number(Double(identity?.pid ?? getpid()))]
        if let identity {
            fields["machine"] = .string(identity.machine.uuidString.lowercased())
            fields["run"] = .string(identity.run.uuidString.lowercased())
            fields["mach"] = .string(identity.mach)
        }
        return .object(fields)
    }

    private func forget(_ connection: ApiConnection) {
        lock.lock()
        connections.removeValue(forKey: connection.id)
        inbox.removeAll { $0.connection === connection }
        sealed.removeAll { $0.connection === connection }
        pending = pending.filter { $0.value.connection !== connection }
        lock.unlock()
    }

    /// The connections open now, in the order they came.
    public var openConnections: [ApiConnection] {
        lock.lock()
        defer { lock.unlock() }
        return connections.keys.sorted().compactMap { connections[$0] }
    }

    /// Closes every connection, as the engine stops.
    public func closeAll() {
        for connection in openConnections { connection.close() }
    }

    // MARK: - Taking requests (a connection's reader thread)

    /// One line from a client. A command goes to the engine's queue at once;
    /// anything else waits for the next build to start.
    public func receive(_ line: Data, from connection: ApiConnection) {
        guard let value = try? JSONValue.parse(line), let members = value.objectValue else {
            place(Request(connection: connection, id: .null, type: "", members: [:],
                          ready: Self.rejected(.null, Rejection(reason: .malformed, message: "a request is one JSON object on a line"))))
            return
        }
        let id = members["id"] ?? .null
        let type = members["type"]?.stringValue ?? ""
        // Spec 2 §9 — "the first message on a connection must be `{"type": "auth", "token": "..."}` or the socket
        // closes." Nothing else is taken from a LAN connection until then: not a command, which would otherwise be
        // on its way to the engine's queue already, and not a request.
        if connection.origin == .lan, !isAuthorized(connection) {
            guard type == "auth" else {
                connection.close()
                return
            }
            authorize(connection, id: id, offered: members["token"]?.stringValue)
            return
        }
        switch type {
        case "command", "commands":
            if let refusal = submit(members, id: id, type: type, from: connection) {
                place(Request(connection: connection, id: id, type: type, members: members, ready: Self.rejected(id, refusal)))
            }
        default:
            place(Request(connection: connection, id: id, type: type, members: members, ready: nil))
        }
    }

    private func place(_ request: Request) {
        lock.lock()
        inbox.append(request)
        lock.unlock()
    }

    /// Spec 2 §9 — `command`, and `commands` with its `group`. The group is
    /// handed to the engine now and lands on the next frame boundary (Spec 2
    /// §8); its result is this request's answer. A refusal here is one the
    /// request itself earns, before anything is queued.
    private func submit(_ members: [String: JSONValue], id: JSONValue, type: String, from connection: ApiConnection) -> Rejection? {
        // Spec 10 §2 — "The app names each command's source ... and the engine takes it from this socket only; a LAN
        // client's commands are always `api`."
        let kind: SourceKind
        if connection.origin == .lan {
            kind = .api
        } else if let named = members["source"] {
            guard let name = named.stringValue, let known = Self.localSources[name] else {
                return Rejection(reason: .badValue, message: "source is ui, key or commandbar")
            }
            kind = known
        } else {
            kind = .ui
        }
        let objects: [JSONValue]
        if type == "command" {
            guard let one = members["command"] else { return Rejection(reason: .missingArgument, message: "a command request carries its command") }
            objects = [one]
        } else {
            guard let many = members["commands"]?.arrayValue, !many.isEmpty else {
                return Rejection(reason: .missingArgument, message: "a commands request carries at least one command")
            }
            objects = many
        }
        var commands: [GuardedCommand] = []
        for (index, object) in objects.enumerated() {
            guard let command = try? JSONCoding.decode(GuardedCommand.self, from: object) else {
                return Rejection(reason: .malformed, message: "command \(index + 1) of \(objects.count) isn't a command object", index: index)
            }
            commands.append(command)
        }
        guard let engine else { return Rejection(reason: .conflict, message: "the engine is stopping") }
        let source = CommandSource(kind: kind)
        // Spec 2 §9 (Area 19 reading) — `commands` is one group unless it says `"group": false`.
        let together = type == "command" || members["group"]?.boolValue != false
        if together {
            let group = CommandGroup(id: GroupID.random(), source: source, commands: commands, client: connection.client)
            lock.lock()
            pending[group.id] = Pending(connection: connection, id: id, kind: kind, sent: commands.count, single: type == "command", batch: nil, index: 0)
            lock.unlock()
            engine.enqueue(group)
        } else {
            let batch = Batch(connection: connection, id: id, count: commands.count)
            let groups = commands.map { CommandGroup(id: GroupID.random(), source: source, commands: [$0], client: connection.client) }
            lock.lock()
            for (index, group) in groups.enumerated() {
                pending[group.id] = Pending(connection: connection, id: id, kind: kind, sent: 1, single: true, batch: batch, index: index)
            }
            lock.unlock()
            for group in groups { engine.enqueue(group) }
        }
        return nil
    }

    // MARK: - The build boundary (the control side)

    /// A build is about to start: the requests that have arrived are the ones
    /// it answers. Anything arriving from here on waits for the next.
    func buildWillStart() {
        lock.lock()
        sealed += inbox
        inbox = []
        lock.unlock()
    }

    /// The build has run: each group it finished answers the request that
    /// sent it. Before the build's events, so a client sees its own result
    /// first (Spec 10 §3).
    func deliverResults(_ control: ControlLoop) {
        guard !control.lastRejected.isEmpty || !control.lastResults.isEmpty else { return }
        var outgoing: [(ApiConnection, JSONValue)] = []
        lock.lock()
        for rejected in control.lastRejected {
            guard let waiting = pending.removeValue(forKey: rejected.id) else { continue }
            if let message = settle(waiting, Self.rejectedFields(rejected.rejection)) { outgoing.append((waiting.connection, message)) }
        }
        for result in control.lastResults {
            guard let waiting = pending.removeValue(forKey: result.id) else { continue }
            let fields = ApiResults.fields(of: result, sentBy: waiting.kind, commands: waiting.sent, single: waiting.single)
            if let message = settle(waiting, fields) { outgoing.append((waiting.connection, message)) }
        }
        lock.unlock()
        for (connection, message) in outgoing { connection.send(message) }
    }

    /// With the lock held: the message a settled group sends now, or nil
    /// while its batch still waits for others.
    private func settle(_ waiting: Pending, _ fields: [String: JSONValue]) -> JSONValue? {
        guard let batch = waiting.batch else {
            var message = fields
            message["id"] = waiting.id
            message["type"] = .string("result")
            return .object(message)
        }
        batch.results[waiting.index] = .object(fields)
        guard !batch.results.contains(where: { $0 == nil }) else { return nil }
        let results = batch.results.compactMap { $0 }
        let last = results.reversed().compactMap { $0.objectValue?["seq"] }.first
        var message: [String: JSONValue] = ["id": batch.id, "type": .string("result"), "result": .string("ok"), "results": .array(results)]
        if let last { message["seq"] = last }
        return .object(message)
    }

    /// The build's events have gone: now the requests it took, in the order
    /// they came.
    func takeRequests(_ engine: Engine, snapshot: ApiSnapshot) {
        lock.lock()
        let requests = sealed
        sealed = []
        lock.unlock()
        for request in requests where !request.connection.isClosed { answer(request, engine: engine, snapshot: snapshot) }
    }

    private func answer(_ request: Request, engine: Engine, snapshot: ApiSnapshot) {
        let connection = request.connection
        if let ready = request.ready {
            connection.send(ready)
            return
        }
        if connection.origin == .lan, Self.localOnly.contains(request.type) {
            connection.send(Self.rejected(request.id, Rejection(reason: .localOnly, message: "\(request.type) is taken on the engine's local socket only")))
            return
        }
        switch request.type {
        case "ping":
            connection.send(.object(["id": request.id, "type": .string("pong")]))
        case "subscribe":
            subscribe(request)
        case "query":
            query(request, engine: engine, snapshot: snapshot)
        case "note":
            // Spec 9 §2 — "the engine stamps `ts`, `seq` and the client's source".
            connection.send(publisher.request(.object(request.members), source: CommandSource(kind: sourceKind(of: request)), client: connection.client))
        case "stop":
            stop(request, engine: engine)
        case "releaseScreen":
            release(request, engine: engine)
        case "auth":
            // Spec 10 §2 — "No token is sent" on the local socket; a LAN connection that is here has given its own already.
            connection.send(Self.rejected(request.id, Rejection(reason: .badValue, message: connection.origin == .local
                                                                    ? "the local socket takes no token" : "this connection is already authorized")))
        case let type where Self.later.contains(type):
            connection.send(Self.rejected(request.id, Rejection(reason: .notInV1, message: "\(type) comes with the operator lock (Area 18)")))
        default:
            connection.send(Self.rejected(request.id, Rejection(reason: .badValue, message: "there is no \(request.type) request")))
        }
    }

    /// The source a request's sender has: named on the local socket (`ui`
    /// when it names none or one the socket doesn't know), always `api` on
    /// the LAN.
    private func sourceKind(of request: Request) -> SourceKind {
        guard request.connection.origin == .local else { return .api }
        return request.members["source"]?.stringValue.flatMap { Self.localSources[$0] } ?? .ui
    }

    // MARK: - Subscriptions and events

    /// Spec 2 §9 — `{ "id": 19, "type": "subscribe", "topics": [...] }`. The
    /// subscription starts here, after this build's events: the next build's
    /// are the first it sees. A topic that keeps a current value sends it now
    /// (Spec 9 §5, §7; Spec 10 §3: `engine` and `devices` "on subscribe").
    private func subscribe(_ request: Request) {
        guard let names = request.members["topics"]?.arrayValue?.compactMap(\.stringValue), !names.isEmpty else {
            request.connection.send(Self.rejected(request.id, Rejection(reason: .missingArgument, message: "subscribe names its topics")))
            return
        }
        let stacks = request.members["stacks"]?.arrayValue?.compactMap(\.intValue) ?? []
        lock.lock()
        let added = Set(names).subtracting(request.connection.topics)
        request.connection.topics.formUnion(names)
        request.connection.previewStacks.formUnion(stacks)
        lock.unlock()
        request.connection.send(.object(["id": request.id, "type": .string("result"), "result": .string("ok")]))
        for topic in added.sorted() {
            if let current = publisher.current(topic) { request.connection.send(current) }
        }
    }

    /// One event from the engine's publisher, on the publishing thread: to
    /// every connection subscribed to its topic, as the same bytes.
    private func publish(_ event: JSONValue) {
        guard let topic = event.objectValue?["topic"]?.stringValue else { return }
        lock.lock()
        let targets = connections.keys.sorted().compactMap { connections[$0] }.filter { $0.topics.contains(topic) }
        lock.unlock()
        guard !targets.isEmpty else { return }
        let line = Data(JSONCanonical.line(event).utf8)
        for connection in targets { connection.send(line: line) }
    }

    /// Spec 10 §3, `preview` — "a JPEG of each stack the client names when it
    /// subscribes": the connections subscribed to `preview`, by the stacks
    /// they named.
    func previewSubscribers() -> [Int: [ApiConnection]] {
        lock.lock()
        defer { lock.unlock() }
        var wanted: [Int: [ApiConnection]] = [:]
        for key in connections.keys.sorted() {
            guard let connection = connections[key], connection.topics.contains("preview") else { continue }
            for stack in connection.previewStacks { wanted[stack, default: []].append(connection) }
        }
        return wanted
    }

    /// The connections subscribed to `topic` now.
    func subscribers(of topic: String) -> [ApiConnection] {
        lock.lock()
        defer { lock.unlock() }
        return connections.keys.sorted().compactMap { connections[$0] }.filter { $0.topics.contains(topic) }
    }

    // MARK: - Queries

    /// Spec 2 §9 — "A query is answered with its request's `id` as `{"id": …,
    /// "type": "answer", …}` ... and refused with the rejected result". The
    /// answer's place is taken now, in order; its content is worked out off
    /// the control thread and fills the place.
    private func query(_ request: Request, engine: Engine, snapshot: ApiSnapshot) {
        let connection = request.connection
        let id = request.id
        let members = request.members
        let what = members["what"]?.stringValue ?? ""
        // Spec 10 §3 — "`render` answers with a file on this Mac, so on the LAN it is `localOnly`"; both are Area 14's.
        if what == "render" || what == "uses" {
            let rejection = what == "render" && connection.origin == .lan
                ? Rejection(reason: .localOnly, message: "render answers with a file on the engine's Mac")
                : Rejection(reason: .notInV1, message: "the \(what) query comes with edit mode (Area 14)")
            connection.send(Self.rejected(id, rejection))
            return
        }
        let place = connection.reserve()
        let publisher = self.publisher
        let machineRoot = engine.machineRoot
        let lister = engine.deviceLister
        let thumbnails = engine.thumbnails
        workers.async {
            let outcome: Result<[String: JSONValue], Rejection>?
            switch what {
            case _ where ApiQueries.fromSnapshot.contains(what):
                outcome = ApiQueries.answer(what, members, in: snapshot, machineRoot: machineRoot)
            case "devices":
                outcome = lister.map { .success(ApiQueries.devices($0)) } ?? .failure(Rejection(reason: .conflict, message: "this engine lists no devices"))
            case "fonts":
                outcome = .success(ApiQueries.fonts())
            case "thumbnails":
                outcome = ApiQueries.thumbnails(members, in: snapshot, service: thumbnails, machineRoot: machineRoot)
            default:
                // Spec 9 §6 — `versions` and `snapshots` read files, where the area that built them answers them.
                outcome = nil
            }
            switch outcome {
            case .success(var fields)?:
                fields["id"] = id
                fields["type"] = .string("answer")
                connection.fill(place, with: .object(fields))
            case .failure(let rejection)?:
                connection.fill(place, with: Self.rejected(id, rejection))
            case nil:
                connection.fill(place, with: publisher.query(.object(members)))
            }
        }
    }

    /// Spec 10 §2 — the LAN listener's state and client count, and whether the Keychain could be read, as the
    /// `engine` topic reports them.
    public var lan: LanStanding {
        get {
            lock.lock()
            defer { lock.unlock() }
            var standing = lanStanding
            // "client count": the LAN connections that have signed in.
            standing.clients = connections.values.filter { $0.origin == .lan && $0.authorized }.count
            return standing
        }
        set {
            lock.lock()
            lanStanding = newValue
            lock.unlock()
        }
    }
    private var lanStanding = LanStanding()

    // MARK: - The local requests

    /// Spec 10 §3 — `stop`: "Stops the engine on request (Spec 9 §4)",
    /// answered "`ok` with `unsaved`, the documents it couldn't write (Spec 9
    /// §7), before it exits". The stop joins the control thread, so it runs
    /// on a thread of its own; the answer is placed when it returns and has
    /// gone before the process exits.
    private func stop(_ request: Request, engine: Engine) {
        let stopEngine = self.stopEngine
        let afterStop = self.afterStop
        let connection = request.connection
        let id = request.id
        let thread = Thread { [weak engine] in
            let report = stopEngine?() ?? engine?.stop() ?? Engine.StopReport()
            connection.send(.object(["id": id, "type": .string("result"), "result": .string("ok"),
                                     "unsaved": .array(report.unsaved.map(JSONValue.string))]))
            connection.drain(seconds: 2)
            afterStop?()
        }
        thread.name = "o.engine.api.stop"
        thread.start()
    }

    /// Spec 10 §9 — `releaseScreen`: "the engine closes those outputs'
    /// windows, reports them `released` (§3) and logs a `screenReleased`
    /// note". The answer's place is taken now; the windows are AppKit's, so
    /// the work and the answer come from the main thread.
    private func release(_ request: Request, engine: Engine) {
        guard let device = request.members["screen"]?.stringValue, let uuid = DetectedScreen.uuid(ofDevice: device) else {
            request.connection.send(Self.rejected(request.id, Rejection(reason: .badValue, message: "releaseScreen names its screen as \"screen\": \"display:<uuid>\"")))
            return
        }
        guard let releaseScreen else {
            request.connection.send(Self.rejected(request.id, Rejection(reason: .conflict, message: "this engine has no screens to release")))
            return
        }
        let place = request.connection.reserve()
        let connection = request.connection
        let id = request.id
        let source = CommandSource(kind: sourceKind(of: request))
        let control = engine.control
        releaseScreen(uuid) { outputs in
            // Spec 9 §2 as Spec 10 adds — "the notes its local requests write, with the requester's source".
            let numbers = outputs.map { JSONValue.number(Double($0)) }
            _ = control.commandLog.note(["event": .string("screenReleased"), "screen": .string(DetectedScreen.devicePrefix + uuid), "outputs": .array(numbers)],
                                        text: outputs.isEmpty ? "Released a screen with no outputs on it" : "Took output \(outputs.map(String.init).joined(separator: ", ")) off its screen",
                                        source: source, ts: control.variables.timestamp())
            connection.fill(place, with: .object(["id": id, "type": .string("result"), "result": .string("ok"), "outputs": .array(numbers)]))
        }
    }

    // MARK: - The LAN's token (Spec 2 §9)

    /// What a LAN connection's `auth` is checked against; nil until the token is read. Under the lock.
    private var token: String?

    /// Spec 10 §2 — the token, once the Keychain has given it: from then on a LAN client can sign in.
    public func setToken(_ token: String?) {
        lock.lock()
        self.token = token
        lock.unlock()
    }

    func isAuthorized(_ connection: ApiConnection) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return connection.authorized
    }

    /// Spec 2 §9 — "the first message on a connection must be `{"type":
    /// "auth", "token": "..."}` or the socket closes." Checked as it
    /// arrives, on the connection's own thread: it reads nothing of the
    /// engine's, and what the client sends next must find it authorized.
    private func authorize(_ connection: ApiConnection, id: JSONValue, offered: String?) {
        lock.lock()
        let expected = token
        lock.unlock()
        guard let expected, let offered, Self.same(offered, expected) else {
            connection.close()
            return
        }
        lock.lock()
        connection.authorized = true
        lock.unlock()
        // "The envelope carries `"api": 1` in the auth reply".
        connection.send(.object(["id": id, "type": .string("result"), "result": .string("ok"),
                                 "api": .number(Double(Self.apiVersion)), "engine": .string(OCore.appVersion)]))
    }

    /// Two strings compared in time that doesn't depend on where they differ.
    static func same(_ a: String, _ b: String) -> Bool {
        let left = Array(a.utf8), right = Array(b.utf8)
        var difference = UInt8(left.count == right.count ? 0 : 1)
        for index in 0..<max(left.count, right.count) {
            difference |= (index < left.count ? left[index] : 0) ^ (index < right.count ? right[index] : 0)
        }
        return difference == 0
    }

    // MARK: - Shapes

    /// Spec 10 §3 — `{ "id": 53, "type": "result", "result": "rejected",
    /// "reason": "badPasscode: the passcode is wrong" }`.
    static func rejected(_ id: JSONValue, _ rejection: Rejection) -> JSONValue {
        var fields = rejectedFields(rejection)
        fields["id"] = id
        fields["type"] = .string("result")
        return .object(fields)
    }

    static func rejectedFields(_ rejection: Rejection) -> [String: JSONValue] {
        ["result": .string("rejected"), "reason": .string("\(rejection.reason.rawValue): \(rejection.message)")]
    }
}
