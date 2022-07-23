//
//  DistributedActorReceptionist.swift
//  DistributedChatShared
//
//  Created by Bri on 7/19/22.
//

import Distributed

protocol DistributedActorReceptionist<ActorSystem>: DistributedActor {
    
    /// Check in a distributed actor with this receptionist, making it available
    /// for listings on other peers. Tags are used to separate actors into groups
    /// of interest, e.g. by "team" they are playing for.
    ///
    /// It should be automatically removed as the actor terminates.
    nonisolated func checkIn<Act>(_ actor: Act, tag: String)
    where Act: DistributedActor, Act: Codable, Act.ActorSystem == ActorSystem
    
    /// Obtain an async sequence which will be updated as actors are discovered
    /// for the given type and tag. Existing actors are immediately emitted into
    /// the stream as it is kicked off.
    ///
    /// This stream never completes, unless the underlying actor system is shut down.
    /// Cancelling the stream will remove the subscription
    nonisolated func listing<Act>(of type: Act.Type, tag: String, file: String, line: Int, function: String)
    async -> AsyncCompactMapSequence<AsyncStream<any DistributedActor>, Act>
    where Act: DistributedActor, Act.ActorSystem == ActorSystem
}
