//
//  DistributedChatApp.swift
//  DistributedChat
//
//  Created by Bri on 7/10/22.
//

import SwiftUI

// Global singleton for the distributed actor system
// This ensures all actors share the same peer connections
@available(iOS 16.0, macOS 13.0, *)
let localNetworkSystem = LocalNetworkActorSystem()

class AppState: ObservableObject {
    @Published var chats: [UUID] = []
    @Published var username: String?
}

enum LinkIdentifier: Hashable {
    case chatId
}

extension URL {
    var isDeeplink: Bool {
        return scheme == "distributedChat" // matches distributedChat://<rest-of-the-url>
    }
    var tabIdentifier: LinkIdentifier? {
        guard isDeeplink else { return nil }

        switch host {
            case "chatId": return .chatId // matches distributedChat://chatId
            default: return nil
        }
    }
    var chatId: UUID? {
        guard isDeeplink else { return nil }
        let components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        guard let chatId = components?.queryItems?.first(where: { $0.name == "chatId" })?.value else { return nil }
        return UUID(uuidString: chatId)
    }
}

@main
struct DistributedChatApp: App {
    @StateObject var appState = AppState()
    var body: some Scene {
        WindowGroup {
            ChatsView()
                .environmentObject(appState)
        }
        .commands {
            SidebarCommands()
        }
    }
}
