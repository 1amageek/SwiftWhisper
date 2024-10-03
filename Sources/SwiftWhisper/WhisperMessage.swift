//
//  WhisperMessage.swift
//  SwiftWhisper
//
//  Created by Norikazu Muramoto on 2024/10/03.
//

import Foundation
import WhisperKit

public struct WhisperMessage: Identifiable, Sendable, Hashable {
    public let id: String
    public let text: String
    public let confidence: Float
    public let startTime: Float
    public let endTime: Float
    public let words: [WordInfo]
    public let createdAt: Date
    
    public struct WordInfo: Hashable, Sendable {
        public let word: String
        public let start: Float
        public let end: Float
        public let probability: Float
    }
}

extension WhisperMessage {
    
    init(from segment: TranscriptionSegment) {
        self.id = UUID().uuidString
        self.text = segment.text
        self.confidence = segment.avgLogprob
        self.startTime = segment.start
        self.endTime = segment.end
        self.createdAt = Date()        
        if let words = segment.words {
            self.words = words.map { WordInfo(word: $0.word, start: $0.start, end: $0.end, probability: $0.probability) }
        } else {
            self.words = []
        }
    }
}
