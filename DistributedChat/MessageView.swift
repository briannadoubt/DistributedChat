//
//  MessageView.swift
//  Chat/Message
//
//  Created by Bri on 1/14/22.
//

import SwiftUI
public struct MessageView: View {
    
    init(username: String, withTail: Bool = false, message: Message) {
        self.username = username
        self.message = message
        self.hasTail = withTail
    }
    
    let username: String
    let message: Message
    let hasTail: Bool
    
    var tailPosition: MessageBubbleTailPosition {
        if !hasTail {
            return .none
        }
        return message.username == username ? .rightBottomTrailing : .leftBottomLeading
    }
    
    public var body: some View {
        HStack {
            if message.username == username {
                Spacer(minLength: 64)
            }
            MessageBubble(
                text: message.text,
                isSender: message.username == username,
                tailPosition: tailPosition
            )
            if message.username != username {
                Spacer(minLength: 64)
            }
        }
        .animation(.spring(), value: message.username == username)
        .transition(.move(edge: message.username == username ? .leading : .trailing).combined(with: .opacity))
        .flipsForRightToLeftLayoutDirection(true)
    }
}

// TODO: Fix Previews
struct MessageView_Previews: PreviewProvider {
    static var previews: some View {
        MessageView(username: "meowface", message: Message(id: UUID(), text: "Meow", username: "meowface"))
    }
}
