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
                try await observer.send(message: message, to: self)
                for chat in observer.otherChats {
                    try await chat.recieve(message: message, on: chat)
                }
            } catch {
                print(error)
                
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
