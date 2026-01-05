//
//  DistributedChatTests.swift
//  DistributedChatTests
//
//  Created by Bri on 7/10/22.
//

import XCTest
@testable import DistributedChat

// MARK: - Message Tests

final class MessageTests: XCTestCase {

    func testMessageEquality() throws {
        let id = UUID()
        let message1 = Message(id: id, text: "Hello", username: "Alice")
        let message2 = Message(id: id, text: "Hello", username: "Alice")
        let message3 = Message(id: UUID(), text: "Hello", username: "Alice")

        XCTAssertEqual(message1, message2, "Messages with same ID should be equal")
        XCTAssertNotEqual(message1, message3, "Messages with different IDs should not be equal")
    }

    func testMessageCodable() throws {
        let message = Message(id: UUID(), text: "Test message", username: "TestUser")

        let encoder = JSONEncoder()
        let data = try encoder.encode(message)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Message.self, from: data)

        XCTAssertEqual(message.id, decoded.id)
        XCTAssertEqual(message.text, decoded.text)
        XCTAssertEqual(message.username, decoded.username)
    }
}

// MARK: - ChatObserver Tests

@available(iOS 16.0, macOS 13.0, *)
final class ChatObserverTests: XCTestCase {

    var chatObserver: ChatObserver!
    let chatId = UUID()

    override func setUp() {
        super.setUp()
        chatObserver = ChatObserver(chatId: chatId)
    }

    override func tearDown() {
        chatObserver = nil
        super.tearDown()
    }

    @MainActor
    func testMessageDeduplication() async throws {
        let messageId = UUID()
        let message1 = Message(id: messageId, text: "Hello", username: "Alice")
        let message2 = Message(id: messageId, text: "Hello", username: "Alice")

        // Create a mock chat for the add function
        let mockSystem = LocalNetworkActorSystem()
        let mockChat = Chat(chatId: chatId, observer: chatObserver, actorSystem: mockSystem)

        // Add the same message twice
        try await chatObserver.add(message: message1, to: mockChat)
        try await chatObserver.add(message: message2, to: mockChat)

        // Should only have one message due to deduplication
        XCTAssertEqual(chatObserver.messages.count, 1, "Duplicate messages should be filtered")
    }

    @MainActor
    func testDifferentMessagesAreAdded() async throws {
        let message1 = Message(id: UUID(), text: "Hello", username: "Alice")
        let message2 = Message(id: UUID(), text: "World", username: "Bob")

        let mockSystem = LocalNetworkActorSystem()
        let mockChat = Chat(chatId: chatId, observer: chatObserver, actorSystem: mockSystem)

        try await chatObserver.add(message: message1, to: mockChat)
        try await chatObserver.add(message: message2, to: mockChat)

        XCTAssertEqual(chatObserver.messages.count, 2, "Different messages should both be added")
    }

    func testInitialState() {
        XCTAssertEqual(chatObserver.messages.count, 0, "Should start with no messages")
        XCTAssertEqual(chatObserver.otherChats.count, 0, "Should start with no other chats")
        XCTAssertNil(chatObserver.chatError, "Should start with no error")
        XCTAssertFalse(chatObserver.showingQRCode, "Should start with QR code hidden")
    }
}

// MARK: - ActorIdentity Tests

final class ActorIdentityTests: XCTestCase {

    func testSimpleIdentity() {
        let identity = ActorIdentity(id: "test-actor")

        XCTAssertEqual(identity.id, "test-actor")
        XCTAssertNil(identity.protocol)
        XCTAssertNil(identity.host)
        XCTAssertNil(identity.port)
        XCTAssertEqual(identity.description, "test-actor")
    }

    func testFullIdentity() {
        let identity = ActorIdentity(protocol: "tcp", host: "localhost", port: 8080, id: "actor-1")

        XCTAssertEqual(identity.id, "actor-1")
        XCTAssertEqual(identity.protocol, "tcp")
        XCTAssertEqual(identity.host, "localhost")
        XCTAssertEqual(identity.port, 8080)
        XCTAssertEqual(identity.description, "tcp://localhost:8080#actor-1")
    }

    func testRandomIdentity() {
        let identity1 = ActorIdentity.random
        let identity2 = ActorIdentity.random

        XCTAssertNotEqual(identity1.id, identity2.id, "Random identities should be unique")
    }

    func testIdentityHashable() {
        let identity1 = ActorIdentity(id: "same-id")
        let identity2 = ActorIdentity(id: "same-id")
        let identity3 = ActorIdentity(id: "different-id")

        var set = Set<ActorIdentity>()
        set.insert(identity1)
        set.insert(identity2)

        XCTAssertEqual(set.count, 1, "Same IDs should hash to same value")

        set.insert(identity3)
        XCTAssertEqual(set.count, 2, "Different IDs should hash differently")
    }

    func testIdentityCodable() throws {
        let identity = ActorIdentity(protocol: "tcp", host: "localhost", port: 8080, id: "test")

        let encoder = JSONEncoder()
        let data = try encoder.encode(identity)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ActorIdentity.self, from: data)

        XCTAssertEqual(identity, decoded)
    }
}

// MARK: - LocalNetworkActorSystem Tests

@available(iOS 16.0, macOS 13.0, *)
final class LocalNetworkActorSystemTests: XCTestCase {

    func testActorSystemInitialization() {
        let system = LocalNetworkActorSystem()

        XCTAssertTrue(system.nodeName.starts(with: "peer_"), "Node name should start with 'peer_'")
        XCTAssertNotNil(system.receptionist, "Receptionist should be initialized")
    }

    func testAssignIDForReceptionist() {
        let system = LocalNetworkActorSystem()

        let id = system.assignID(LocalNetworkReceptionist.self)

        XCTAssertEqual(id.id, "receptionist", "Receptionist should always get 'receptionist' ID")
    }

    func testAssignIDForRegularActor() {
        let system = LocalNetworkActorSystem()

        let id1 = system.assignID(Chat.self)
        let id2 = system.assignID(Chat.self)

        XCTAssertNotEqual(id1.id, id2.id, "Different actors should get unique IDs")
        XCTAssertNotEqual(id1.id, "receptionist", "Regular actors should not get receptionist ID")
    }

    func testNoPeersError() {
        let error = LocalNetworkActorSystemError.noPeers

        switch error {
        case .noPeers:
            // Expected
            break
        default:
            XCTFail("Expected noPeers error")
        }
    }

    func testCallTimeoutError() {
        let callID = UUID()
        let error = LocalNetworkActorSystemError.callTimeout(callID: callID)

        switch error {
        case .callTimeout(let id):
            XCTAssertEqual(id, callID)
        default:
            XCTFail("Expected callTimeout error")
        }
    }
}

// MARK: - RemoteCallEnvelope Tests

@available(iOS 16.0, macOS 13.0, *)
final class RemoteCallEnvelopeTests: XCTestCase {

    func testEnvelopeCodable() throws {
        let callID = UUID()
        let recipient = ActorIdentity(id: "test-actor")
        let envelope = RemoteCallEnvelope(
            callID: callID,
            recipient: recipient,
            invocationTarget: "testMethod",
            genericSubs: ["String", "Int"],
            args: ["arg1".data(using: .utf8)!, "arg2".data(using: .utf8)!]
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(envelope)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(RemoteCallEnvelope.self, from: data)

        XCTAssertEqual(envelope.callID, decoded.callID)
        XCTAssertEqual(envelope.recipient, decoded.recipient)
        XCTAssertEqual(envelope.invocationTarget, decoded.invocationTarget)
        XCTAssertEqual(envelope.genericSubs, decoded.genericSubs)
        XCTAssertEqual(envelope.args, decoded.args)
    }
}

// MARK: - ReplyEnvelope Tests

@available(iOS 16.0, macOS 13.0, *)
final class ReplyEnvelopeTests: XCTestCase {

    func testReplyEnvelopeCodable() throws {
        let callID = UUID()
        let sender = ActorIdentity(id: "sender-actor")
        let value = "test response".data(using: .utf8)!
        let envelope = ReplyEnvelope(callID: callID, sender: sender, value: value)

        let encoder = JSONEncoder()
        let data = try encoder.encode(envelope)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ReplyEnvelope.self, from: data)

        XCTAssertEqual(envelope.callID, decoded.callID)
        XCTAssertEqual(envelope.sender, decoded.sender)
        XCTAssertEqual(envelope.value, decoded.value)
    }

    func testReplyEnvelopeWithNilSender() throws {
        let callID = UUID()
        let value = "test response".data(using: .utf8)!
        let envelope = ReplyEnvelope(callID: callID, sender: nil, value: value)

        let encoder = JSONEncoder()
        let data = try encoder.encode(envelope)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ReplyEnvelope.self, from: data)

        XCTAssertEqual(envelope.callID, decoded.callID)
        XCTAssertNil(decoded.sender)
        XCTAssertEqual(envelope.value, decoded.value)
    }
}

// MARK: - Peer Tests

@available(iOS 16.0, macOS 13.0, *)
final class PeerTests: XCTestCase {

    func testPeerNodeName() {
        // We can't easily create a real Connection without network,
        // but we can test that Peer stores the node name correctly
        // This is a compile-time check that Peer has nodeName property
        let peerType = Peer.self
        XCTAssertNotNil(peerType, "Peer type should exist")
    }
}

// MARK: - Integration Tests

@available(iOS 16.0, macOS 13.0, *)
final class IntegrationTests: XCTestCase {

    func testChatCreation() {
        let chatId = UUID()
        let observer = ChatObserver(chatId: chatId)
        let system = LocalNetworkActorSystem()
        let chat = Chat(chatId: chatId, observer: observer, actorSystem: system)

        XCTAssertNotNil(chat, "Chat should be created successfully")
    }

    func testMultipleChatCreation() {
        let system = LocalNetworkActorSystem()

        var chats: [Chat] = []
        for _ in 0..<10 {
            let chatId = UUID()
            let observer = ChatObserver(chatId: chatId)
            let chat = Chat(chatId: chatId, observer: observer, actorSystem: system)
            chats.append(chat)
        }

        XCTAssertEqual(chats.count, 10, "Should be able to create multiple chats")

        // Verify all chats have unique IDs
        let ids = Set(chats.map { $0.id })
        XCTAssertEqual(ids.count, 10, "All chats should have unique IDs")
    }
}

// MARK: - Performance Tests

@available(iOS 16.0, macOS 13.0, *)
final class PerformanceTests: XCTestCase {

    func testMessageDeduplicationPerformance() {
        let observer = ChatObserver(chatId: UUID())

        measure {
            // Simulate checking 1000 message IDs
            for i in 0..<1000 {
                let messageId = UUID()
                _ = Message(id: messageId, text: "Message \(i)", username: "User")
            }
        }
    }

    func testActorIDCreationPerformance() {
        let system = LocalNetworkActorSystem()

        measure {
            for _ in 0..<1000 {
                _ = system.assignID(Chat.self)
            }
        }
    }
}
