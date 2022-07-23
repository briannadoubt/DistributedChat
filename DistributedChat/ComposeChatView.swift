//
//  UsernameView.swift
//  DistributedChat
//
//  Created by Bri on 7/13/22.
//

import SwiftUI

typealias Username = String

struct ComposeChatView: View {
    @EnvironmentObject var appState: AppState
    @SceneStorage("username") var username = ""
    @State var isShowingChat = false
    let chatId = UUID()
    var body: some View {
        Form {
            Section {
                TextField("Username", text: $username)
            }
            Section {
                Button("Start Chat") {
                    appState.username = username
                    appState.chats.append(chatId)
                }
                .disabled(username.isEmpty)
            }
        }
    }
}

struct UsernameView_Previews: PreviewProvider {
    static var previews: some View {
        ComposeChatView()
    }
}
