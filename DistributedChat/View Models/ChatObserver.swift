//
//  ChatObserver.swift
//  DistributedChatShared
//
//  Created by Bri on 7/19/22.
//

import Foundation
import SwiftUI

public final class ChatObserver: ObservableObject {
    
    let chatId: UUID
    @Published public var otherChats: [Chat] = []
    @Published public var messages: [Message] = []
    @Published public var chatError: Error?
    @Published public var showingQRCode = false
    
    public init(chatId: UUID, otherChats: [Chat] = [], messages: [Message] = [], chatError: Error? = nil) {
        self.chatId = chatId
        self.otherChats = otherChats
        self.messages = messages
        self.chatError = chatError
    }
    
    public func send(message: Message, to chat: Chat) async throws {
        try await self.add(message: message, to: chat)
        for chat in self.otherChats {
            try await chat.recieve(message: message, on: chat)
        }
    }
    
    @MainActor func add(message: Message, to chat: Chat) async throws {
        log("Chat", "Adding new message to chat")
        withAnimation {
            messages.append(message)
        }
    }
    
    func recieve(message: Message, on chat: Chat) async throws {
        log("Chat", "Recieving new message")
        try await add(message: message, to: chat)
    }
    
    func foundPeer(theirChat: Chat, myChat: Chat, informOtherChats: Bool) async throws {
        if otherChats.contains(theirChat) {
            return
        }
        Task {
            await self.add(otherChat: theirChat)
            if informOtherChats {
                log("Chat", "Informing other chats of new peer")
                for chat in self.otherChats {
                    do {
                        try await chat.start(newChat: myChat)
                    } catch {
                        print(error)
                    }
                }
            }
        }
    }
    
    @MainActor func add(otherChat: Chat) {
        if self.otherChats.contains(otherChat) { return }
        withAnimation {
            self.otherChats.insert(otherChat, at: 0)
        }
    }
}
