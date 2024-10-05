import Foundation
import WhisperKit
import Combine
import CoreML

actor RealtimeTranscriptionManager {
    private let whisperKit: WhisperKit
    private var settings: TranscriptionSettings
    
    private var lastBufferSize: Int = 0
    private var lastConfirmedSegmentEndSeconds: Float = 0
    private var unconfirmedSegments: [TranscriptionSegment] = []
    private var currentChunks: [Int: (chunkText: [String], fallbacks: Int)] = [:]
    
    // Transcription statistics
    private var tokensPerSecond: TimeInterval = 0
    private var firstTokenTime: TimeInterval = 0
    private var pipelineStart: TimeInterval = 0
    private var currentLag: TimeInterval = 0
    private var currentEncodingLoops: Int = 0
    private var totalInferenceTime: TimeInterval = 0
    private var effectiveRealTimeFactor: TimeInterval = 0
    private var effectiveSpeedFactor: TimeInterval = 0
    
    var language: String
    
    init(whisperKit: WhisperKit,
         language: String,
         settings: TranscriptionSettings = TranscriptionSettings()) {
        self.whisperKit = whisperKit
        self.language = language
        self.settings = settings
    }
    
    func transcribeCurrentBuffer() async throws -> WhisperMessage? {
        let currentBuffer = whisperKit.audioProcessor.audioSamples
        let nextBufferSize = currentBuffer.count - lastBufferSize
        let nextBufferSeconds = Float(nextBufferSize) / Float(WhisperKit.sampleRate)        
        guard nextBufferSeconds > 1.0 else {
            try await Task.sleep(nanoseconds: 100_000_000)
            return nil
        }
        let relativeEnergy = whisperKit.audioProcessor.relativeEnergy
        let voiceDetected = AudioProcessor.isVoiceDetected(
            in: relativeEnergy,
            nextBufferInSeconds: nextBufferSeconds,
            silenceThreshold: Float(settings.silenceThreshold)
        )
        
        if !voiceDetected {
            return handleSilence(nextBufferSeconds: nextBufferSeconds)
        }
        
        lastBufferSize = currentBuffer.count
        let transcription = try await transcribeAudioSamples(Array(currentBuffer))
        return processTranscriptionResult(transcription)
    }
    
    private func handleSilence(nextBufferSeconds: Float) -> WhisperMessage? {
        if nextBufferSeconds > Float(settings.silenceDurationThreshold) {
            return handleLongSilence(nextBufferSeconds: nextBufferSeconds)
        }
        return nil
    }
    
    private func handleLongSilence(nextBufferSeconds: Float) -> WhisperMessage? {
        if let lastConfirmedSegment = unconfirmedSegments.last {
            lastConfirmedSegmentEndSeconds = lastConfirmedSegment.end
            unconfirmedSegments = []
            whisperKit.audioProcessor.purgeAudioSamples(keepingLast: Int(settings.remainingAudioAfterPurge * Double(WhisperKit.sampleRate)))
            lastBufferSize = whisperKit.audioProcessor.audioSamples.count
            return WhisperMessage(from: lastConfirmedSegment)
        } else if nextBufferSeconds > Float(settings.sampleResetThreshold) {
            unconfirmedSegments = []
            whisperKit.audioProcessor.purgeAudioSamples(keepingLast: Int(settings.remainingAudioAfterReset * Double(WhisperKit.sampleRate)))
            lastBufferSize = whisperKit.audioProcessor.audioSamples.count
            lastConfirmedSegmentEndSeconds = 0
        }
        return nil
    }
    
    private func transcribeAudioSamples(_ samples: [Float]) async throws -> TranscriptionResult? {
        let languageCode = Constants.languages[language, default: Constants.defaultLanguageCode]
        let seekClip: [Float] = [lastConfirmedSegmentEndSeconds]
        
        let options = DecodingOptions(
            verbose: true,
            task: .transcribe,
            language: languageCode,
            temperature: Float(settings.temperatureStart),
            temperatureFallbackCount: Int(settings.fallbackCount),
            sampleLength: Int(settings.sampleLength),
            usePrefillPrompt: true,
            usePrefillCache: true,
            skipSpecialTokens: !settings.enableSpecialCharacters,
            withoutTimestamps: true,
            wordTimestamps: true,
            clipTimestamps: seekClip,
            chunkingStrategy: .vad
        )
        
        let capturedCompressionCheckWindow = Int(settings.compressionCheckWindow)
        let capturedLogProbThreshold = options.logProbThreshold!
        let capturedCompressionRatioThreshold = options.compressionRatioThreshold!
        
        let decodingCallback: ((TranscriptionProgress) -> Bool?) = { (progress: TranscriptionProgress) in
            let currentTokens = progress.tokens
            let checkWindow = Int(capturedCompressionCheckWindow)
            if currentTokens.count > checkWindow {
                let checkTokens: [Int] = Array(currentTokens.suffix(checkWindow))
                let compressionRatio = Self.compressionRatio(of: checkTokens)
                if compressionRatio > capturedCompressionRatioThreshold {
                    Logging.debug("Early stopping due to compression threshold")
                    return false
                }
            }
            if progress.avgLogprob! < capturedLogProbThreshold {
                Logging.debug("Early stopping due to logprob threshold")
                return false
            }
            return nil
        }
        
        let transcriptionResults: [TranscriptionResult] = try await whisperKit.transcribe(
            audioArray: samples,
            decodeOptions: options,
            callback: decodingCallback
        )
        return mergeTranscriptionResults(transcriptionResults)
    }
    
    private func processTranscriptionResult(_ transcription: TranscriptionResult?) -> WhisperMessage? {
        guard let segments = transcription?.segments else { return nil }
        
        if segments.count > settings.requiredSegmentsForConfirmation {
            let numberOfSegmentsToConfirm = segments.count - settings.requiredSegmentsForConfirmation
            let confirmedSegmentsArray = Array(segments.prefix(numberOfSegmentsToConfirm))
            let remainingSegments = Array(segments.suffix(settings.requiredSegmentsForConfirmation))
            if let lastConfirmedSegment = confirmedSegmentsArray.last, lastConfirmedSegment.end > lastConfirmedSegmentEndSeconds {
                lastConfirmedSegmentEndSeconds = lastConfirmedSegment.end
                for segment in confirmedSegmentsArray {
                    return WhisperMessage(from: segment)
                }
            }
            unconfirmedSegments = remainingSegments
        } else {
            unconfirmedSegments = segments
        }
        updateTranscriptionStatistics(transcription)
        return nil
    }
    
    private func updateTranscriptionStatistics(_ transcription: TranscriptionResult?) {
        tokensPerSecond = transcription?.timings.tokensPerSecond ?? 0
        firstTokenTime = transcription?.timings.firstTokenTime ?? 0
        pipelineStart = transcription?.timings.pipelineStart ?? 0
        currentLag = transcription?.timings.decodingLoop ?? 0
        currentEncodingLoops += Int(transcription?.timings.totalEncodingRuns ?? 0)
        
        let totalAudio = Double(whisperKit.audioProcessor.audioSamples.count) / Double(WhisperKit.sampleRate)
        totalInferenceTime += transcription?.timings.fullPipeline ?? 0
        effectiveRealTimeFactor = Double(totalInferenceTime) / totalAudio
        effectiveSpeedFactor = totalAudio / Double(totalInferenceTime)
    }
    
    nonisolated private static func compressionRatio(of array: [Int]) -> Float {
        let dataBuffer = array.compactMap { Int32($0) }
        let data = dataBuffer.withUnsafeBufferPointer { Data(buffer: $0) }
        
        do {
            let compressedData = try (data as NSData).compressed(using: .zlib)
            return Float(data.count) / Float(compressedData.length)
        } catch {
            Logging.debug("Compression error: \(error.localizedDescription)")
            return Float.infinity
        }
    }
    
    func getTranscriptionStatistics() -> TranscriptionStatistics {
        return TranscriptionStatistics(
            tokensPerSecond: tokensPerSecond,
            firstTokenTime: firstTokenTime,
            pipelineStart: pipelineStart,
            currentLag: currentLag,
            currentEncodingLoops: currentEncodingLoops,
            totalInferenceTime: totalInferenceTime,
            effectiveRealTimeFactor: effectiveRealTimeFactor,
            effectiveSpeedFactor: effectiveSpeedFactor
        )
    }
}

struct TranscriptionStatistics {
    var tokensPerSecond: TimeInterval
    var firstTokenTime: TimeInterval
    var pipelineStart: TimeInterval
    var currentLag: TimeInterval
    var currentEncodingLoops: Int
    var totalInferenceTime: TimeInterval
    var effectiveRealTimeFactor: TimeInterval
    var effectiveSpeedFactor: TimeInterval
}
