//
//  Item.swift
//  SpectralPT
//
//  Created by 冉江来 on 2026/9/8.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
