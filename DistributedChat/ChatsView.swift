//
//  ChatsView.swift
//  DistributedChat
//
//  Created by Bri on 7/21/22.
//

import SwiftUI
#if !os(macOS)
import CodeScanner
#endif

struct ChatsView: View {
    @EnvironmentObject var appState: AppState
    @State var showingScanner = false
    var body: some View {
        NavigationView {
            List {
                ForEach(appState.chats, id: \.uuidString) { chatId in
                    ChatNavigationLink(chatId: chatId)
                }
            }
            .navigationTitle("Distributed Chats")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        appState.chats.append(UUID())
                    } label: {
                        Image(systemName: "plus")
                    }
                }
#if !os(macOS)
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        withAnimation {
                            showingScanner = true
                        }
                    } label: {
                        Label("Scan Chat", systemImage: "qrcode.viewfinder")
                    }
                }
#endif
            }
        }
#if !os(macOS)
        .sheet(isPresented: $showingScanner) {
            CodeScannerView(codeTypes: [.qr], simulatedData: "distributedChat://chat?chatId=\(UUID().uuidString)") { result in
                switch result {
                case .success(let result):
                    guard
                        let url = URL(string: result.string),
                        let chatId = url.chatId
                    else { return }
                    print("Scanned chatId:", chatId)
                    appState.chats.append(chatId)
                    showingScanner = false
                case .failure(let error):
                    print("Scanning failed: \(error.localizedDescription)")
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button("Cancel") {
                    showingScanner = false
                }
            }
        }
#endif
        .onOpenURL { url in
            if let chatId = url.chatId {
                withAnimation {
                    appState.chats.append(chatId)
                }
            }
        }
    }
}

//struct ChatsView_Previews: PreviewProvider {
//    static var previews: some View {
//        ChatsView()
//    }
//}
