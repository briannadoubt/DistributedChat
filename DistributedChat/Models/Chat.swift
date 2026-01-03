//
//  Chat.swift
//  DistributedChatShared
//
//  Created by Bri on 7/19/22.
//

import Foundation
import Distributed

public distributed actor Chat: Codable, Identifiable {
    
    public var messages: [Message] = []
    
    distributed func getMessages() -> [Message] {
        return messages
    }
    
    public typealias ActorSystem = LocalNetworkActorSystem
    public let observer: ChatObserver
    let chatId: UUID
    
    public init(chatId: UUID, observer: ChatObserver, actorSystem: LocalNetworkActorSystem) {
        self.chatId = chatId
        self.actorSystem = actorSystem
        self.observer = observer
    }
    
    distributed func getChatId() -> UUID {
        return chatId
    }
    
    distributed func send(_ message: Message) {
        Task {
            do {
                // observer.send() handles both local storage AND broadcasting to all peers
                // No need to also loop through otherChats here - that was causing double-sends
                try await observer.send(message: message, to: self)
            } catch {
                log("Chat", "[error] Failed to send message: \(error)")
            }
        }
    }
    
    distributed func recieve(message: Message, on chat: Chat) async throws {
        try await observer.recieve(message: message, on: chat)
    }
    
    distributed func start(newChat: Chat) async throws {
        try await observer.foundPeer(theirChat: newChat, myChat: self, informOtherChats: false)
    }
}
