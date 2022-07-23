//
//  Log.swift
//  DistributedChatShared
//
//  Created by Bri on 7/19/22.
//

import Foundation

/// Simplistic "fake" logging infrastructure, just so we can easily print and verify output from a simulator running app.
public func debug(_ category: String, _ message: String, file: String = #fileID, line: Int = #line, function: String = #function) {
    // ignore
}

/// Simplistic "fake" logging infrastructure, just so we can easily print and verify output from a simulator running app.
public func log(_ category: String, _ message: String, file: String = #fileID, line: Int = #line, function: String = #function) {
    print("[\(category)][\(file):\(line)](\(function)) \(message)")
}
