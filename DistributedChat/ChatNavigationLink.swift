//
//  ChatNavigationLink.swift
//  DistributedChat
//
//  Created by Bri on 7/20/22.
//

import SwiftUI

struct ChatNavigationLink: View {
    @EnvironmentObject var appState: AppState
    @StateObject var chatObserver: ChatObserver
    let chatId: UUID
    let chat: Chat
    
    @State var lastMessageText: String?
    
    init(chatId: UUID) {
        self.chatId = chatId
        let observer = ChatObserver(chatId: chatId)
        _chatObserver = StateObject(wrappedValue: observer)
        chat = Chat(chatId: chatId, observer: observer, actorSystem: localNetworkSystem)
    }
    
    var body: some View {
        NavigationLink {
            ChatView(chatId: chatId, chat: chat)
                .environmentObject(chatObserver)
        } label: {
            VStack {
                if let lastMessage = chatObserver.messages.last {
                    Text(lastMessage.username + ": ").bold()
                    Text(lastMessage.text)
                } else {
                    Text("No messages yet...")
                }
            }
        }
    }
}
