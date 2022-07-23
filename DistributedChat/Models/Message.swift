//
//  Message.swift
//  DistributedChatServer
//
//  Created by Bri on 7/19/22.
//

import Foundation

public struct Message: Identifiable, Equatable, Codable, Hashable {
    public init(id: UUID, text: String, username: String) {
        self.id = id
        self.text = text
        self.username = username
    }
    public let id: UUID
    public let text: String
    public let username: String
}
