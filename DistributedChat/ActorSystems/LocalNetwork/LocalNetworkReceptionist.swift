/*
 See LICENSE folder for this sample's licensing information.

 Abstract:
 Receptionist implementation with proper task management and cleanup.
 */

import Distributed
import Foundation

@available(iOS 16.0, *)
public distributed actor LocalNetworkReceptionist: DistributedActorReceptionist {
    public typealias ActorSystem = LocalNetworkActorSystem

    struct CheckInID: Hashable {
        let actorID: ActorSystem.ActorID
        let tag: String
    }

    var knownActors: [CheckInID: any DistributedActor] = [:]

    // Track replication tasks so they can be cancelled
    private var replicationTasks: [CheckInID: Task<Void, Never>] = [:]

    // How often to replicate actor info to peers (in seconds)
    private let replicationInterval: TimeInterval = 5.0

    // Maximum number of replication attempts before giving up
    private let maxReplicationAttempts = 3

    // Mapping of subscriptions to streams with cleanup tracking
    private var streams: [AsyncStream<any DistributedActor>.Continuation] = []

    public nonisolated func checkIn<Act>(_ actor: Act, tag: String) where Act: DistributedActor, Act: Codable, Act.ActorSystem == ActorSystem {
        Task {
            let applied: ()? = await self.whenLocal { __secretlyKnownToBeLocal in
                __secretlyKnownToBeLocal.localCheckIn(actor, tag: tag)
            }
            precondition(applied != nil, "checkIn must only be called on local receptionist references.")
        }
    }

    func localCheckIn<Act>(_ actor: Act, tag: String) where Act: DistributedActor, Act: Codable, Act.ActorSystem == ActorSystem {
        log("receptionist", "Checking in \(Act.self) with ID \(actor.id)")

        let cid = CheckInID(actorID: actor.id, tag: tag)
        if self.knownActors[cid] != nil {
            return // we know about it already
        }

        self.knownActors[cid] = actor
        self.informLocalStreams(about: actor, tag: tag)

        // Cancel any existing replication task for this actor
        replicationTasks[cid]?.cancel()

        // Start a bounded replication task that will inform remote peers
        let task = Task { [weak self] in
            guard let self = self else { return }

            var attempts = 0
            while attempts < self.maxReplicationAttempts && !Task.isCancelled {
                do {
                    let remoteID = self.id
                    let remoteReceptionist = try Self.resolve(id: remoteID, using: self.actorSystem)
                    log("receptionist", "Inform remote receptionist about [\(actor.id)] (attempt \(attempts + 1))")
                    try await remoteReceptionist.inform(about: actor, tag: tag)
                    log("receptionist", "Successfully informed about \(actor.id)")

                    // Wait before next replication (use async sleep, not Thread.sleep)
                    try await Task.sleep(nanoseconds: UInt64(self.replicationInterval * 1_000_000_000))
                    attempts += 1
                } catch is CancellationError {
                    log("receptionist", "Replication task cancelled for \(actor.id)")
                    break
                } catch {
                    log("receptionist", "[error] Failed to inform about \(actor.id): \(error)")
                    attempts += 1
                    // Brief backoff before retry
                    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                }
            }
            log("receptionist", "Replication complete for \(actor.id) after \(attempts) attempts")
        }

        replicationTasks[cid] = task
    }

    /// Inform local streams about an actor (used for locally checked-in actors)
    private func informLocalStreams<Act>(about actor: Act, tag: String)
    where Act: DistributedActor, Act: Codable, Act.ActorSystem == LocalNetworkActorSystem {
        // Remove terminated streams while iterating
        streams.removeAll { stream in
            let result = stream.yield(actor)
            switch result {
            case .enqueued(let remaining):
                log("receptionist", "yield \(actor.id) (remaining: \(remaining))")
                return false // keep this stream
            case .dropped:
                log("receptionist", "dropped actor from stream")
                return false // keep this stream, it's just full
            case .terminated:
                log("receptionist", "stream terminated, removing")
                return true // remove this stream
            @unknown default:
                return false
            }
        }
    }

    /// Cancel all replication tasks (for cleanup)
    func cancelAllReplicationTasks() {
        for (cid, task) in replicationTasks {
            log("receptionist", "Cancelling replication task for \(cid.actorID)")
            task.cancel()
        }
        replicationTasks.removeAll()
    }
    
    distributed func inform<Act>(about actor: Act, tag: String)
    where Act: DistributedActor, Act: Codable, Act.ActorSystem == LocalNetworkActorSystem {
        let cid = CheckInID(actorID: actor.id, tag: tag)
        let actorDescription = "\(actor)(\(actor.id))"
        log("receptionist", "Receptionist received information about \(actorDescription)")

        if self.knownActors[cid] != nil {
            log("receptionist", "Already know about: \(actorDescription)")
            return // we know about it already
        }

        // Store the actor and register its node mapping for proper routing
        log("receptionist", "New actor, store and publish: \(actorDescription)")
        self.knownActors[cid] = actor

        // Register the actor-to-node mapping for proper routing
        // The actor came from a remote peer, so we need to track which peer owns it
        // Note: In a full implementation, we would extract the node name from the call context
        // For now, the routing will work through the broadcast fallback

        // Inform all local streams about the new actor, cleaning up terminated ones
        informLocalStreams(about: actor, tag: tag)
    }

    public nonisolated func listing<Act>(of type: Act.Type, tag: String, file: String = #file, line: Int = #line, function: String = #function) async
    -> AsyncCompactMapSequence<AsyncStream<any DistributedActor>, Act>
    where Act: DistributedActor, Act.ActorSystem == LocalNetworkActorSystem {
        log("receptionist", "New listing request: \(Act.self) at \(file):\(line)(\(function))")
        let stream = await self.whenLocal { __secretlyKnownToBeLocal in
            __secretlyKnownToBeLocal.localListing(of: type, tag: tag)
        }
        guard let stream = stream else {
            preconditionFailure("\(#function) may only be invoked on local receptionist references")
        }
        return stream
    }

    func localListing<Act>(of type: Act.Type, tag: String)
    -> AsyncCompactMapSequence<AsyncStream<any DistributedActor>, Act>
    where Act: DistributedActor, Act.ActorSystem == LocalNetworkActorSystem {
        // Use bounded buffer to prevent memory issues
        let newStream: AsyncStream<any DistributedActor> = AsyncStream(bufferingPolicy: .bufferingNewest(100)) { continuation in
            self.streams.append(continuation)

            // Set up termination handler to clean up
            continuation.onTermination = { @Sendable _ in
                log("receptionist", "Stream terminated, will be cleaned up on next inform")
            }

            // Flush all already known actors to this stream
            for (key, actor) in knownActors where key.tag == tag {
                let result = continuation.yield(actor)
                switch result {
                case .enqueued(let remaining):
                    log("receptionist", "yield \(actor.id) (remaining: \(remaining))")
                case .dropped:
                    log("receptionist", "dropped actor (buffer full)")
                case .terminated:
                    log("receptionist", "stream terminated during initial flush")
                    return
                @unknown default:
                    break
                }
            }
        }

        // By casting known actors to the expected type, we filter
        // any potential actors of other type, which were stored under the same tag.
        return newStream.compactMap { actor in
            actor as? Act
        }
    }
}
