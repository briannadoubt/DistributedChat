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

    // Track message IDs to prevent duplicates
    private var seenMessageIds: Set<UUID> = []
    private let messageIdLock = NSLock()

    public init(chatId: UUID, otherChats: [Chat] = [], messages: [Message] = [], chatError: Error? = nil) {
        self.chatId = chatId
        self.otherChats = otherChats
        self.messages = messages
        self.chatError = chatError
    }

    public func send(message: Message, to chat: Chat) async throws {
        // Add message locally first
        try await self.add(message: message, to: chat)

        // Send to all connected peers
        // Use TaskGroup to send in parallel and handle failures gracefully
        await withTaskGroup(of: Void.self) { group in
            for peerChat in self.otherChats {
                group.addTask {
                    do {
                        try await peerChat.recieve(message: message, on: peerChat)
                    } catch {
                        log("Chat", "[error] Failed to send to peer: \(error)")
                    }
                }
            }
        }
    }

    @MainActor func add(message: Message, to chat: Chat) async throws {
        // Deduplicate messages using message ID
        messageIdLock.lock()
        let isNew = seenMessageIds.insert(message.id).inserted
        messageIdLock.unlock()

        guard isNew else {
            log("Chat", "Ignoring duplicate message: \(message.id)")
            return
        }

        log("Chat", "Adding new message to chat")
        withAnimation {
            messages.append(message)
        }
    }

    func recieve(message: Message, on chat: Chat) async throws {
        log("Chat", "Receiving new message: \(message.id)")
        try await add(message: message, to: chat)
    }

    func foundPeer(theirChat: Chat, myChat: Chat, informOtherChats: Bool) async throws {
        // Check for duplicates before adding
        let isDuplicate = await MainActor.run {
            otherChats.contains(theirChat)
        }

        if isDuplicate {
            log("Chat", "Peer already known, ignoring duplicate")
            return
        }

        await self.add(otherChat: theirChat)

        if informOtherChats {
            log("Chat", "Informing other chats of new peer")
            // Use TaskGroup for parallel execution
            await withTaskGroup(of: Void.self) { group in
                for chat in self.otherChats {
                    group.addTask {
                        do {
                            try await chat.start(newChat: myChat)
                        } catch {
                            log("Chat", "[error] Failed to inform peer of new chat: \(error)")
                        }
                    }
                }
            }
        }
    }

    @MainActor func add(otherChat: Chat) {
        if self.otherChats.contains(otherChat) { return }
        log("Chat", "Adding new peer chat")
        withAnimation {
            self.otherChats.insert(otherChat, at: 0)
        }
    }
}
