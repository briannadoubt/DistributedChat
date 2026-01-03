/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Actor system which enables distributed actors to communicate over local network, e.g. on the same Wi-Fi network.
*/


import Foundation
import Distributed
import os
import Network

@available(iOS 16.0, *)
final public class LocalNetworkActorSystem: DistributedActorSystem,
    @unchecked /* state protected with locks */ Sendable {

    public typealias ActorID = ActorIdentity
    public typealias InvocationEncoder = LocalNetworkCallEncoder
    public typealias InvocationDecoder = LocalNetworkCallDecoder
    public typealias SerializationRequirement = any Codable
    public typealias ResultHandler = BonjourResultHandler

    let nodeName: String
    let serviceName: String = "_distributedChat._tcp"

    private let lock = NSLock()

    private var managedActors: [ActorID: any DistributedActor] = [:]

    // Mapping from ActorID to the node name that owns it (for proper routing)
    private var actorToNodeMapping: [ActorID: String] = [:]

    private let nwListener: NWListener
    private let browser: Browser

    // Use dictionary keyed by node name for deduplication
    private var peersByNodeName: [String: Peer] = [:]
    var peers: [Peer] { Array(peersByNodeName.values) }

    private var _receptionist: LocalNetworkReceptionist!

    // === Handle replies
    public typealias CallID = UUID
    private let replyLock = NSLock()
    private var inFlightCalls: [CallID: CheckedContinuation<Data, Error>] = [:]

    // Timeout for in-flight calls (in seconds)
    private let callTimeout: TimeInterval = 30.0

    var _onPeersChanged: ([Peer]) -> Void = { _ in }

    public var receptionist: LocalNetworkReceptionist {
        self._receptionist!
    }

    public init() {
        let nodeID = Int.random(in: 0..<Int.max)
        let nodeName = "peer_\(nodeID)"
        self.nodeName = nodeName

        self.nwListener = try! Self.makeNWListener(nodeName: nodeName, serviceName: serviceName)
        self.browser = Browser(nodeName: nodeName, serviceName: serviceName)

        // peersByNodeName is already initialized as empty dictionary

        // Initialize "system actors"
        self._receptionist = LocalNetworkReceptionist(actorSystem: self)

        self.startNetworking()
    }

    private static func makeNWListener(nodeName: String, serviceName: String) throws -> NWListener {

        return try NWListener(using: NetworkServiceConstants.networkParameters)
    }

    /// Start the server-side component accepting incoming connections.
    private func startNetworking() {
        // === Kick off the NWListener
        let txtRecord = NWTXTRecord([
            NetworkServiceConstants.txtRecordInstanceIDKey: self.nodeName
        ])

        // The name is the unique thing, identifying a node in the peer to peer network
        nwListener.service = NWListener.Service(name: self.nodeName, type: self.serviceName, txtRecord: txtRecord)

        nwListener.newConnectionHandler = { (connection: NWConnection) in
            // Extract node name from endpoint for cleanup on disconnect
            var peerNodeName: String?
            if case NWEndpoint.service(let endpointName, _, _, _) = connection.endpoint {
                peerNodeName = endpointName
            }

            let con = Connection(
                connection: connection,
                deliverMessage: { data, nwMessage in
                    self.decodeAndDeliver(data: data, nwMessage: nwMessage, from: connection)
                },
                onDisconnect: { [weak self] in
                    if let nodeName = peerNodeName {
                        self?.removePeer(nodeName: nodeName)
                    }
                }
            )
            _ = self.addPeer(connection: con, from: "listener")

            connection.start(queue: .main)
        }
        nwListener.start(queue: .main)

        // Kick of the browser for discovery
        browser.start { result in
            self.lock.lock()
            defer {
                self.lock.unlock()
            }

            // Extract node name from endpoint for cleanup on disconnect
            var peerNodeName: String?
            if case NWEndpoint.service(let endpointName, _, _, _) = result.endpoint {
                peerNodeName = endpointName
            }

            // -----
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = true
            tcpOptions.keepaliveIdle = 2

            let parameters = NWParameters(tls: nil, tcp: tcpOptions)
            parameters.includePeerToPeer = true

            // add the protocol framing
            let framerOptions = NWProtocolFramer.Options(definition: WireProtocol.definition)
            parameters.defaultProtocolStack.applicationProtocols.insert(framerOptions, at: 0)

            let nwConnection = NWConnection(to: result.endpoint, using: parameters)
            // -----

            let connection = Connection(
                connection: nwConnection,
                deliverMessage: { data, nwMessage in
                    self.decodeAndDeliver(data: data, nwMessage: nwMessage, from: nwConnection)
                },
                onDisconnect: { [weak self] in
                    if let nodeName = peerNodeName {
                        self?.removePeer(nodeName: nodeName)
                    }
                }
            )

            _ = self.addPeer(connection: connection, from: "browser")
        }
    }

    private func addPeer(connection: Connection, from: String) -> Peer? {
        var peerNodeName: String?

        if case NWEndpoint.service(let endpointName, let type, let domain, let interface) = connection.connection.endpoint {
            log("peer", "Adding peer from \(from): type=\(type), domain=\(domain), interface=\(String(describing: interface))")

            // Don't connect to ourselves
            if self.nodeName == endpointName {
                log("peer", "Ignoring self connection: \(endpointName)")
                return nil
            }

            // Only accept valid peer names
            guard endpointName.starts(with: "peer_") else {
                log("peer", "Ignoring non-peer endpoint: \(endpointName)")
                return nil
            }

            peerNodeName = endpointName
        }

        guard let nodeName = peerNodeName else {
            log("peer", "Could not determine node name for connection")
            return nil
        }

        // Deduplication: If we already have a peer with this node name, don't add another
        if peersByNodeName[nodeName] != nil {
            log("peer", "Already connected to node: \(nodeName), ignoring duplicate")
            return nil
        }

        let peer = Peer(connection: connection, nodeName: nodeName)
        self.peersByNodeName[nodeName] = peer

        log("peer", "Added peer: \(nodeName) (total peers: \(peersByNodeName.count))")
        self._onPeersChanged(self.peers)

        return peer
    }

    /// Remove a peer by node name (called when connection fails)
    func removePeer(nodeName: String) {
        self.lock.lock()
        defer { self.lock.unlock() }

        if let _ = peersByNodeName.removeValue(forKey: nodeName) {
            log("peer", "Removed peer: \(nodeName) (remaining peers: \(peersByNodeName.count))")
            self._onPeersChanged(self.peers)
        }
    }

    /// Register that an actor ID belongs to a specific node
    func registerActorNode(_ actorID: ActorID, nodeName: String) {
        self.lock.lock()
        defer { self.lock.unlock() }
        actorToNodeMapping[actorID] = nodeName
        log("routing", "Registered actor \(actorID) -> node \(nodeName)")
    }

    /// Receive inbound message `Data` and continue to decode, and invoke the local target.
    func decodeAndDeliver(data: Data?, nwMessage: NWProtocolFramer.Message, from connection: NWConnection) {
        // log("receive-decode-deliver", "On connection [\(connection)]")
        guard let payload = data else {
            // log("receive-decode-deliver", "[error] On connection [\(connection)], no payload!")
            return
        }
        let decoder = JSONDecoder()
        decoder.userInfo[.actorSystemKey] = self

        log("receive-decode-deliver", "Start decoding, on connection [\(connection)], data: \(String(data: payload, encoding: .utf8)!)")

        do {
            switch nwMessage.wireMessageType {
            case .invalid:
                log("receive-decode-deliver", "[error] Unknown message type! Data: \(payload))")
            case .remoteCall:
                let callEnvelope = try decoder.decode(RemoteCallEnvelope.self, from: payload)
                self.receiveInboundCall(envelope: callEnvelope)
            case .reply:
                let replyEnvelope = try decoder.decode(ReplyEnvelope.self, from: payload)
                self.receiveInboundReply(envelope: replyEnvelope)
            }
        } catch {
            log("receive-decode-deliver",
                "[error] Failed decoding: \(String(data: payload, encoding: .utf8)!)")
        }
    }

    func receiveInboundCall(envelope: RemoteCallEnvelope) {
        Task {
            guard let anyRecipient = resolveAny(id: envelope.recipient, resolveReceptionist: true) else {
                log("deadLetter", "[warn] \(#function) failed to resolve \(envelope.recipient)")
                return
            }
            let target = RemoteCallTarget(envelope.invocationTarget)
            let handler = Self.ResultHandler(callID: envelope.callID, system: self)

            do {
                var decoder = Self.InvocationDecoder(system: self, envelope: envelope)
                func doExecuteDistributedTarget<Act: DistributedActor>(recipient: Act) async throws {
                    try await executeDistributedTarget(
                        on: recipient,
                        target: target,
                        invocationDecoder: &decoder,
                        handler: handler)
                }

                // As implicit opening of existential becomes part of the language,
                // this underscored feature is no longer necessary. Please refer to
                // SE-352 Implicitly Opened Existentials:
                // https://github.com/apple/swift-evolution/blob/main/proposals/0352-implicit-open-existentials.md
                try await _openExistential(anyRecipient, do: doExecuteDistributedTarget)
            } catch {
                log("inbound", "[error] failed to executeDistributedTarget [\(target)] on [\(anyRecipient)], error: \(error)")
                try! await handler.onThrow(error: error)
            }
        }
    }

    func receiveInboundReply(envelope: ReplyEnvelope) {
        log("receive-reply", "Receive reply: \(envelope)")
        self.replyLock.lock()
        guard let callContinuation = self.inFlightCalls.removeValue(forKey: envelope.callID) else {
            self.replyLock.unlock()
            return
        }
        self.replyLock.unlock()

        callContinuation.resume(returning: envelope.value)
    }

    func resolveAny(id: ActorID, resolveReceptionist: Bool = false) -> (any DistributedActor)? {
        self.lock.lock()
        defer { lock.unlock() }

        if resolveReceptionist && id == ActorID(id: "receptionist") {
            return self.receptionist
        }

        return managedActors[id]
    }

    public func resolve<Act>(id: ActorID, as actorType: Act.Type) throws -> Act?
        where Act: DistributedActor,
        Act.ID == ActorID {
        self.lock.lock()
        defer {
            lock.unlock()
        }

        if actorType == LocalNetworkReceptionist.self {
            return nil
        }

        guard let found = managedActors[id] else {
            return nil // definitely remote, we don't know about this ActorID
        }

        guard let wellTyped = found as? Act else {
            throw LocalNetworkActorSystemError.resolveFailedToMatchActorType(found: type(of: found), expected: Act.self)
        }

        return wellTyped
    }

    public func assignID<Act>(_ actorType: Act.Type) -> ActorID
        where Act: DistributedActor,
        Act.ID == ActorID {

        if Act.self == LocalNetworkReceptionist.self {
            return .init(id: "receptionist")
        }

        let uuid = UUID().uuidString
        let typeFullName = "\(Act.self)"
        guard typeFullName.split(separator: ".").last != nil else {
            return .init(id: uuid)
        }

        return .init(id: "\(uuid)")
    }

    public func actorReady<Act>(_ actor: Act) where Act: DistributedActor, ActorID == Act.ID {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }

        self.managedActors[actor.id] = actor
    }

    public func resignID(_ id: ActorID) {
        lock.lock()
        defer {
            lock.unlock()
        }

        self.managedActors.removeValue(forKey: id)
    }

    public func makeInvocationEncoder() -> InvocationEncoder {
        .init()
    }

}

// ==== ----------------------------------------------------------------------------------------------------------------
// - MARK: RemoteCall implementations

@available(iOS 16.0, *)
extension LocalNetworkActorSystem {

    public func remoteCall<Act, Err, Res>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder,
        throwing: Err.Type,
        returning: Res.Type
    ) async throws -> Res
        where Act: DistributedActor,
        Act.ID == ActorID,
        Err: Error,
        Res: Codable {
        log("remoteCall", "remoteCall [\(target)] on remote \(actor.id)")

        // Try to find the specific peer for this actor
        let targetPeer = selectPeer(for: actor.id)

        self.lock.lock()
        let allPeers = Array(peersByNodeName.values)
        self.lock.unlock()

        guard !allPeers.isEmpty else {
            log("remoteCall", "No peers")
            throw LocalNetworkActorSystemError.noPeers
        }

        let replyData = try await withCallIDContinuation(recipient: actor) { callID in
            if let peer = targetPeer {
                // Route to specific peer that owns this actor
                log("remoteCall", "Routing to specific peer: \(peer.nodeName)")
                self.sendRemoteCall(to: actor, target: target, invocation: invocation, callID: callID, peer: peer)
            } else {
                // Fallback: broadcast to all peers (for receptionist or unknown actors)
                // This should only happen during initial discovery
                log("remoteCall", "Broadcasting to all \(allPeers.count) peers (no specific routing)")
                for peer in allPeers {
                    self.sendRemoteCall(to: actor, target: target, invocation: invocation, callID: callID, peer: peer)
                }
            }
        }

        let decoder = JSONDecoder()
        decoder.userInfo[.actorSystemKey] = self

        do {
            return try decoder.decode(Res.self, from: replyData)
        } catch {
            throw LocalNetworkActorSystemError.failedDecodingResponse(data: replyData, error: error)
        }
    }

    public func remoteCallVoid<Act, Err>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder,
        throwing: Err.Type
    ) async throws
        where Act: DistributedActor,
        Act.ID == ActorID,
        Err: Error {
        log("system", "remoteCallVoid [\(target)] on remote \(actor.id)")

        // Try to find the specific peer for this actor
        let targetPeer = selectPeer(for: actor.id)

        self.lock.lock()
        let allPeers = Array(peersByNodeName.values)
        self.lock.unlock()

        guard !allPeers.isEmpty else {
            log("remoteCall", "No peers available")
            return
        }

        _ = try await withCallIDContinuation(recipient: actor) { callID in
            if let peer = targetPeer {
                // Route to specific peer that owns this actor
                log("remoteCallVoid", "Routing to specific peer: \(peer.nodeName)")
                self.sendRemoteCall(to: actor, target: target, invocation: invocation, callID: callID, peer: peer)
            } else {
                // Fallback: broadcast to all peers (for receptionist or unknown actors)
                log("remoteCallVoid", "Broadcasting to all \(allPeers.count) peers")
                for peer in allPeers {
                    self.sendRemoteCall(to: actor, target: target, invocation: invocation, callID: callID, peer: peer)
                }
            }
        }
    }

    private func sendRemoteCall<Act>(
        to actor: Act,
        target: RemoteCallTarget,
        invocation: InvocationEncoder,
        callID: CallID,
        peer: Peer) where Act: DistributedActor, Act.ID == ActorID {
        Task {
            let encoder = JSONEncoder()

            let callEnvelope = RemoteCallEnvelope(
                callID: callID,
                recipient: actor.id,
                invocationTarget: target.identifier,
                genericSubs: invocation.genericSubs,
                args: invocation.argumentData
            )
            let payload = try encoder.encode(callEnvelope)

            print("[remoteCall] Send to [\(actor.id)] message: \(String(data: payload, encoding: .utf8)!)")
            peer.connection.sendRemoteCall(payload)

            // This must be resumed by an incoming rely resuming the continuation stored for this 'callID'
        }
    }

    private func withCallIDContinuation<Act>(recipient: Act, body: (CallID) -> Void) async throws -> Data
        where Act: DistributedActor {

        let callID = UUID()

        // Use withThrowingTaskGroup for timeout handling
        return try await withThrowingTaskGroup(of: Data.self) { group in
            // Add the main task that waits for the reply
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    self.replyLock.lock()
                    self.inFlightCalls[callID] = continuation
                    self.replyLock.unlock()

                    body(callID)
                }
            }

            // Add a timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(self.callTimeout * 1_000_000_000))
                throw LocalNetworkActorSystemError.callTimeout(callID: callID)
            }

            // Wait for the first task to complete (either reply or timeout)
            guard let result = try await group.next() else {
                throw LocalNetworkActorSystemError.callTimeout(callID: callID)
            }

            // Cancel remaining tasks
            group.cancelAll()

            // Clean up the in-flight call
            self.replyLock.lock()
            self.inFlightCalls.removeValue(forKey: callID)
            self.replyLock.unlock()

            return result
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// - MARK: Reply handling

@available(iOS 16.0, *)
extension LocalNetworkActorSystem {
    func sendReply(_ envelope: ReplyEnvelope, to peerNodeName: String? = nil) throws {
        self.lock.lock()
        let peersToSend: [Peer]
        if let nodeName = peerNodeName, let peer = peersByNodeName[nodeName] {
            peersToSend = [peer]
        } else {
            // Fallback: send to all peers if we don't know the source
            peersToSend = Array(peersByNodeName.values)
        }
        self.lock.unlock()

        let encoder = JSONEncoder()
        let data = try encoder.encode(envelope)

        for peer in peersToSend {
            log("reply", "Sending reply for [\(envelope.callID)] to \(peer.nodeName)")
            peer.connection.sendReply(data)
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// - MARK: Other

@available(iOS 16.0, *)
extension LocalNetworkActorSystem {
    func selectPeer(for id: ActorID) -> Peer? {
        self.lock.lock()
        defer { self.lock.unlock() }

        // Look up which node owns this actor
        if let nodeName = actorToNodeMapping[id] {
            return peersByNodeName[nodeName]
        }

        // Fallback: if we don't know the mapping yet, return nil
        // The caller should handle this by broadcasting or failing gracefully
        return nil
    }

    func selectPeersForBroadcast() -> [Peer] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return Array(peersByNodeName.values)
    }
}

@available(iOS 16.0, *)
extension LocalNetworkActorSystem {
    func onPeersChanged(_ callback: @escaping @Sendable ([Peer]) -> Void) {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }

        self._onPeersChanged = callback
    }
}

@available(iOS 16.0, *)
extension Logger {
    static let server = os.Logger(subsystem: "com.example.apple.swift.distributed", category: "server")
}

@available(iOS 16.0, *)
public struct BonjourResultHandler: Distributed.DistributedTargetInvocationResultHandler {
    public typealias SerializationRequirement = Codable

    let callID: LocalNetworkActorSystem.CallID
    let system: LocalNetworkActorSystem

    public func onReturn<Success: SerializationRequirement>(value: Success) async throws {
        let encoder = JSONEncoder()
        let returnValue = try encoder.encode(value)
        let envelope = ReplyEnvelope(callID: self.callID, sender: nil, value: returnValue)
        try system.sendReply(envelope)
    }

    public func onReturnVoid() async throws {
        let envelope = ReplyEnvelope(callID: self.callID, sender: nil, value: "".data(using: .utf8)!)
        try system.sendReply(envelope)
    }

    public func onThrow<Err: Error>(error: Err) async throws {
        log("handler", "onThrow: \(error)")
    }
}

public enum LocalNetworkActorSystemError: Error, DistributedActorSystemError {
    case resolveFailedToMatchActorType(found: Any.Type, expected: Any.Type)
    case noPeers
    case notEnoughArgumentsInEnvelope(expected: Any.Type)
    case failedDecodingResponse(data: Data, error: Error)
    case callTimeout(callID: UUID)
    case connectionFailed(nodeName: String)
}

// ==== ----------------------------------------------------------------------------------------------------------------

typealias ReceiveData = (Data) throws -> Void

enum NetworkServiceConstants {
    static let txtRecordInstanceIDKey = "instanceID"

    static var networkParameters: NWParameters {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 2

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.includePeerToPeer = true // Bonjour

        // add the protocol framing
        let framerOptions = NWProtocolFramer.Options(definition: WireProtocol.definition)
        parameters.defaultProtocolStack.applicationProtocols.insert(framerOptions, at: 0)

        return parameters
    }
}

@available(iOS 16.0, *)
struct Peer: Sendable {
    let connection: Connection
    let nodeName: String

    init(connection: Connection, nodeName: String) {
        self.connection = connection
        self.nodeName = nodeName
    }
}

@available(iOS 16.0, *)
struct RemoteCallEnvelope: Sendable, Codable {
    let callID: LocalNetworkActorSystem.CallID
    let recipient: LocalNetworkActorSystem.ActorID
    let invocationTarget: String
    let genericSubs: [String]
    let args: [Data]
}

@available(iOS 16.0, *)
struct ReplyEnvelope: Sendable, Codable {
    let callID: LocalNetworkActorSystem.CallID
    let sender: LocalNetworkActorSystem.ActorID?
    let value: Data
}
