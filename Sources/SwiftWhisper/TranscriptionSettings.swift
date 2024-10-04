//
//  TranscriptionSettings.swift
//  SwiftWhisper
//
//  Created by Norikazu Muramoto on 2024/10/04.
//

import Foundation

public struct TranscriptionSettings {
    
    public var silenceThreshold: Double
    public var silenceDurationThreshold: TimeInterval
    public var remainingAudioAfterPurge: TimeInterval
    public var sampleResetThreshold: TimeInterval
    public var remainingAudioAfterReset: TimeInterval
    public var requiredSegmentsForConfirmation: Int
    public var temperatureStart: Double
    public var fallbackCount: Double
    public var compressionCheckWindow: Double
    public var sampleLength: Double
    public var enableSpecialCharacters: Bool

    public init(
        silenceThreshold: Double = 0.3,
        silenceDurationThreshold: TimeInterval = 0.4,
        remainingAudioAfterPurge: TimeInterval = 0.38,
        sampleResetThreshold: TimeInterval = 3.0,
        remainingAudioAfterReset: TimeInterval = 1.0,
        requiredSegmentsForConfirmation: Int = 4,
        temperatureStart: Double = 0.0,
        fallbackCount: Double = 5.0,
        compressionCheckWindow: Double = 60.0,
        sampleLength: Double = 224.0,
        enableSpecialCharacters: Bool = false
    ) {
        self.silenceThreshold = silenceThreshold
        self.silenceDurationThreshold = silenceDurationThreshold
        self.remainingAudioAfterPurge = remainingAudioAfterPurge
        self.sampleResetThreshold = sampleResetThreshold
        self.remainingAudioAfterReset = remainingAudioAfterReset
        self.requiredSegmentsForConfirmation = requiredSegmentsForConfirmation
        self.temperatureStart = temperatureStart
        self.fallbackCount = fallbackCount
        self.compressionCheckWindow = compressionCheckWindow
        self.sampleLength = sampleLength
        self.enableSpecialCharacters = enableSpecialCharacters
    }
}
