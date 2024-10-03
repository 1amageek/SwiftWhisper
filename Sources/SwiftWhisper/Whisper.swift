//
//  Whisper.swift
//  WhisperAX
//
//  Created by Norikazu Muramoto on 2024/10/03.
//



@preconcurrency import WhisperKit
import AVFoundation
import CoreML
import Combine


@Observable
@MainActor
public class Whisper: @unchecked Sendable {
    
    public static let defaultModel: String = "openai_whisper-small"
    
    var whisperKit: WhisperKit? = nil
#if os(macOS)
    var audioDevices: [AudioDevice]? = nil
#endif
    var isRecording: Bool = false
    var isTranscribing: Bool = false
    var currentText: String = ""
    var currentChunks: [Int: (chunkText: [String], fallbacks: Int)] = [:]
    var modelStorage: String = "huggingface/models/argmaxinc/whisperkit-coreml"
    
    
    // MARK: Model management
    
    public var modelState: ModelState = .unloaded
    public var localModels: [String] = []
    public var localModelPath: String = ""
    public var availableModels: [String] = []
    public var availableLanguages: [String] = []
    public var disabledModels: [String] = WhisperKit.recommendedModels().disabled
    
    // MARK: Settings
    
    public var selectedAudioInput: String = "No Audio Input"
    public var selectedModel: String = WhisperKit.recommendedModels().default
    public var selectedTab: String = "Transcribe"
    public var selectedLanguage: String {
        get { UserDefaults.standard.string(forKey: "selectedLanguage") ?? "english" }
        set { UserDefaults.standard.set(newValue, forKey: "selectedLanguage") }
    }
    public var repoName: String = "argmaxinc/whisperkit-coreml"
    public var enableSpecialCharacters: Bool = false
    public var enableDecoderPreview: Bool = true
    public var temperatureStart: Double = 0
    public var fallbackCount: Double = 5
    public var compressionCheckWindow: Double = 60
    public var sampleLength: Double = 224
    public var silenceThreshold: Double = 0.3
    public var tokenConfirmationsNeeded: Double = 2
    public var encoderComputeUnits: MLComputeUnits = .cpuAndNeuralEngine
    public var decoderComputeUnits: MLComputeUnits = .cpuAndNeuralEngine
    
    
    // MARK: Standard properties
    
    public var loadingProgressValue: Float = 0.0
    public var specializationProgressRatio: Float = 0.7
    public var firstTokenTime: TimeInterval = 0
    public var pipelineStart: TimeInterval = 0
    public var effectiveRealTimeFactor: TimeInterval = 0
    public var effectiveSpeedFactor: TimeInterval = 0
    public var totalInferenceTime: TimeInterval = 0
    public var tokensPerSecond: TimeInterval = 0
    public var currentLag: TimeInterval = 0
    public var currentFallbacks: Int = 0
    public var currentEncodingLoops: Int = 0
    public var currentDecodingLoops: Int = 0
    public var lastBufferSize: Int = 0
    public var lastConfirmedSegmentEndSeconds: Float = 0
    public var requiredSegmentsForConfirmation: Int = 4
    public var bufferEnergy: [Float] = []
    public var bufferSeconds: Double = 0
    public var unconfirmedSegments: [TranscriptionSegment] = []
    
    // MARK: Recoding setting
    
    private let silenceDurationThreshold: TimeInterval = 0.4
    private let remainingAudioAfterPurge: TimeInterval = 0.38
    private let sampleResetThreshold: TimeInterval = 3.0
    private let remainingAudioAfterReset: TimeInterval = 1.0
    
    private var transcriptionTask: Task<Void, Never>? = nil
    
    let taskSleepDuration: UInt64 = 100_000_000
    
    public init() { }
    
    func getComputeOptions() -> ModelComputeOptions {
        return ModelComputeOptions(audioEncoderCompute: encoderComputeUnits, textDecoderCompute: decoderComputeUnits)
    }
    
    // MARK: Views
    
    func resetState() {
        isRecording = false
        isTranscribing = false
        whisperKit?.audioProcessor.stopRecording()
        currentText = ""
        currentChunks = [:]
        
        pipelineStart = Double.greatestFiniteMagnitude
        firstTokenTime = Double.greatestFiniteMagnitude
        effectiveRealTimeFactor = 0
        effectiveSpeedFactor = 0
        totalInferenceTime = 0
        tokensPerSecond = 0
        currentLag = 0
        currentFallbacks = 0
        currentEncodingLoops = 0
        currentDecodingLoops = 0
        lastBufferSize = 0
        lastConfirmedSegmentEndSeconds = 0
        requiredSegmentsForConfirmation = 2
        bufferEnergy = []
        bufferSeconds = 0
        unconfirmedSegments = []
    }
    
    // MARK: - Logic
    
    private var loadSubject = PassthroughSubject<Progress, Never>()
    private var loadTask: Task<Void, Never>?
    
    public func prepare(model: String = Whisper.defaultModel, progress: @escaping (Progress) -> Void) async throws {
        let overallProgress = Progress(totalUnitCount: 100)
        progress(overallProgress)
        
        // モデル情報のフェッチ
        overallProgress.completedUnitCount = 0
        progress(overallProgress)
        do {
            try await fetchModels()
        } catch {
            throw WhisperManagerError.preparationFailed("Failed to fetch models: \(error.localizedDescription)")
        }
        
        overallProgress.completedUnitCount = 20
        progress(overallProgress)
        
        // 指定されたモデルが利用可能かチェック
        guard availableModels.contains(model) else {
            throw WhisperManagerError.modelNotFound
        }
        
        // モデルのロード
        for try await loadProgress in loadModel(model) {
            overallProgress.completedUnitCount = 20 + Int64(loadProgress.fractionCompleted * 80)
            progress(overallProgress)
        }
        
        overallProgress.completedUnitCount = 100
        progress(overallProgress)
    }
    
    private func fetchModels() async throws {
        availableModels = [selectedModel]
        
        // First check what's already downloaded
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let modelPath = documents.appendingPathComponent(modelStorage).path
            
            // Check if the directory exists
            if FileManager.default.fileExists(atPath: modelPath) {
                localModelPath = modelPath
                do {
                    let downloadedModels = try FileManager.default.contentsOfDirectory(atPath: modelPath)
                    for model in downloadedModels where !localModels.contains(model) {
                        localModels.append(model)
                    }
                } catch {
                    print("Error enumerating files at \(modelPath): \(error.localizedDescription)")
                }
            }
        }
        
        localModels = WhisperKit.formatModelFiles(localModels)
        for model in localModels {
            if !availableModels.contains(model),
               !disabledModels.contains(model)
            {
                availableModels.append(model)
            }
        }
        
        print("Found locally: \(localModels)")
        print("Previously selected model: \(selectedModel)")
        
        // 非同期で remote models を取得
        let remoteModels = try await WhisperKit.fetchAvailableModels(from: repoName)
        for model in remoteModels {
            if !availableModels.contains(model),
               !disabledModels.contains(model)
            {
                availableModels.append(model)
            }
        }
    }
    
    private func loadModel(_ model: String, redownload: Bool = false) -> AsyncThrowingStream<Progress, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let progress = Progress(totalUnitCount: 100)
                    
                    // WhisperKit の初期化
                    self.whisperKit = try await WhisperKit(
                        computeOptions: getComputeOptions(),
                        verbose: false,
                        logLevel: .none,
                        prewarm: false,
                        load: false,
                        download: false
                    )
                    guard self.whisperKit != nil else {
                        throw WhisperManagerError.invalidState("WhisperKit initialization failed")
                    }
                    progress.completedUnitCount = 10
                    continuation.yield(progress)
                    
                    // モデルフォルダの取得またはダウンロード
                    var folder: URL?
                    if localModels.contains(model) && !redownload {
                        folder = URL(fileURLWithPath: localModelPath).appendingPathComponent(model)
                        progress.completedUnitCount = 30
                        continuation.yield(progress)
                    } else {
                        do {
                            let downloadProgress = Progress(totalUnitCount: 100)
                            progress.addChild(downloadProgress, withPendingUnitCount: downloadProgress.totalUnitCount)
                            folder = try await WhisperKit.download(variant: model, from: repoName) { @Sendable in
                                downloadProgress.completedUnitCount = $0.completedUnitCount
                                continuation.yield(progress)
                            }
                        } catch {
                            throw WhisperManagerError.modelLoadFailed
                        }
                    }
                    
                    guard let modelFolder = folder else {
                        throw WhisperManagerError.modelLoadFailed
                    }
                    
                    self.whisperKit?.modelFolder = modelFolder
                    
                    // モデルのプリウォーミング
                    await MainActor.run {
                        self.modelState = .prewarming
                    }
                    
                    progress.completedUnitCount = 40
                    continuation.yield(progress)
                    
                    do {
                        try await self.whisperKit?.prewarmModels()
                    } catch {
                        throw WhisperManagerError.modelLoadFailed
                    }
                    
                    progress.completedUnitCount = 60
                    continuation.yield(progress)
                    
                    // モデルのロード
                    await MainActor.run {
                        self.modelState = .loading
                    }
                    
                    try await self.whisperKit?.loadModels()
                    
                    // 完了後の処理
                    await MainActor.run {
                        if !self.localModels.contains(model) {
                            self.localModels.append(model)
                        }
                        self.availableLanguages = Constants.languages.map { $0.key }.sorted()
                        self.modelState = self.whisperKit?.modelState ?? .unloaded
                    }
                    
                    progress.completedUnitCount = 100
                    continuation.yield(progress)
                    continuation.finish()
                } catch {
                    if let managerError = error as? WhisperManagerError {
                        continuation.finish(throwing: managerError)
                    } else {
                        continuation.finish(throwing: WhisperManagerError.modelLoadFailed)
                    }
                }
            }
        }
    }
    
    public func deleteModel() {
        if localModels.contains(selectedModel) {
            let modelFolder = URL(fileURLWithPath: localModelPath).appendingPathComponent(selectedModel)
            
            do {
                try FileManager.default.removeItem(at: modelFolder)
                
                if let index = localModels.firstIndex(of: selectedModel) {
                    localModels.remove(at: index)
                }
                
                modelState = .unloaded
            } catch {
                print("Error deleting model: \(error)")
            }
        }
    }
    
    private func updateProgressBar(targetProgress: Float, maxTime: TimeInterval) async {
        let initialProgress = loadingProgressValue
        let decayConstant = -log(1 - targetProgress) / Float(maxTime)
        
        let startTime = Date()
        
        while true {
            let elapsedTime = Date().timeIntervalSince(startTime)
            
            // Break down the calculation
            let decayFactor = exp(-decayConstant * Float(elapsedTime))
            let progressIncrement = (1 - initialProgress) * (1 - decayFactor)
            let currentProgress = initialProgress + progressIncrement
            
            await MainActor.run {
                loadingProgressValue = currentProgress
            }
            
            if currentProgress >= targetProgress {
                break
            }
            
            do {
                try await Task.sleep(nanoseconds: taskSleepDuration)
            } catch {
                break
            }
        }
    }
    
    func toggleRecording() {
        isRecording.toggle()
        
        if isRecording {
            resetState()
            _startRecording()
        } else {
            _stopRecording()
        }
    }
    
    private var isListening: Bool = false
    
    private var messageSubject = PassthroughSubject<WhisperMessage, Never>()
    
    private var listeningTask: Task<Void, Never>?
    
    public func listen() -> AsyncStream<WhisperMessage> {
        AsyncStream { continuation in
            guard !isListening else {
                continuation.finish()
                return
            }
            
            isListening = true
            startRecording()
            
            let task = Task {
                for await message in messageSubject.values {
                    continuation.yield(message)
                    if Task.isCancelled {
                        break
                    }
                }
                continuation.finish()
            }
            
            continuation.onTermination = { _ in
                task.cancel()
                Task { @MainActor in
                    self.stopListening()
                }
            }
        }
    }
    
    public func stopListening() {
        guard isListening else { return }
        isListening = false
        stopRecording()
        messageSubject.send(completion: .finished)
    }
    
    private func startRecording() {
        guard !isRecording else { return }
        resetState()
        _startRecording()
    }
    
    private func stopRecording() {
        _stopRecording()
    }
    
    private func _startRecording() {
        if let audioProcessor = whisperKit?.audioProcessor {
            Task(priority: .userInitiated) {
                guard await AudioProcessor.requestRecordPermission() else {
                    print("Microphone access was not granted.")
                    return
                }
                
                var deviceId: DeviceID?
#if os(macOS)
                if self.selectedAudioInput != "No Audio Input",
                   let devices = self.audioDevices,
                   let device = devices.first(where: { $0.name == selectedAudioInput })
                {
                    deviceId = device.id
                }
                
                // There is no built-in microphone
                if deviceId == nil {
                    throw WhisperError.microphoneUnavailable()
                }
#endif
                
                try? audioProcessor.startRecordingLive(inputDeviceID: deviceId) { _ in
                    DispatchQueue.main.async {
                        self.bufferEnergy = self.whisperKit?.audioProcessor.relativeEnergy ?? []
                        self.bufferSeconds = Double(self.whisperKit?.audioProcessor.audioSamples.count ?? 0) / Double(WhisperKit.sampleRate)
                    }
                }
                
                // Delay the timer start by 1 second
                isRecording = true
                isTranscribing = true
                realtimeLoop()
            }
        }
    }
    
    private func _stopRecording() {
        isRecording = false
        stopRealtimeTranscription()
        if let audioProcessor = whisperKit?.audioProcessor {
            audioProcessor.stopRecording()
        }
    }
    
    // MARK: - Transcribe Logic
    
    private func transcribeAudioSamples(_ samples: [Float]) async throws -> TranscriptionResult? {
        guard let whisperKit = whisperKit else { return nil }
        
        let languageCode = Constants.languages[selectedLanguage, default: Constants.defaultLanguageCode]
        let seekClip: [Float] = [lastConfirmedSegmentEndSeconds]
        
        let options = DecodingOptions(
            verbose: true,
            task: .transcribe,
            language: languageCode,
            temperature: Float(temperatureStart),
            temperatureFallbackCount: Int(fallbackCount),
            sampleLength: Int(sampleLength),
            usePrefillPrompt: true,
            usePrefillCache: true,
            skipSpecialTokens: !enableSpecialCharacters,
            withoutTimestamps: true,
            wordTimestamps: true,
            clipTimestamps: seekClip,
            chunkingStrategy: .vad
        )
        
        let capturedCompressionCheckWindow = Int(compressionCheckWindow)
        let capturedLogProbThreshold = options.logProbThreshold!
        let capturedCompressionRatioThreshold = options.compressionRatioThreshold!
        
        // Early stopping checks
        let decodingCallback: ((TranscriptionProgress) -> Bool?) = { @Sendable (progress: TranscriptionProgress) in
            DispatchQueue.main.async {
                let fallbacks = Int(progress.timings.totalDecodingFallbacks)
                let chunkId = 0
                // First check if this is a new window for the same chunk, append if so
                var updatedChunk = (chunkText: [progress.text], fallbacks: fallbacks)
                if var currentChunk = self.currentChunks[chunkId], let previousChunkText = currentChunk.chunkText.last {
                    if progress.text.count >= previousChunkText.count {
                        // This is the same window of an existing chunk, so we just update the last value
                        currentChunk.chunkText[currentChunk.chunkText.endIndex - 1] = progress.text
                        updatedChunk = currentChunk
                    } else {
                        // This is either a new window or a fallback (only in streaming mode)
                        if fallbacks == currentChunk.fallbacks {
                            // New window (since fallbacks havent changed)
                            updatedChunk.chunkText = [updatedChunk.chunkText.first ?? "" + progress.text]
                        } else {
                            // Fallback, overwrite the previous bad text
                            updatedChunk.chunkText[currentChunk.chunkText.endIndex - 1] = progress.text
                            updatedChunk.fallbacks = fallbacks
                            print("Fallback occured: \(fallbacks)")
                        }
                    }
                }
                
                // Set the new text for the chunk
                self.currentChunks[chunkId] = updatedChunk
                let joinedChunks = self.currentChunks.sorted { $0.key < $1.key }.flatMap { $0.value.chunkText }.joined(separator: "\n")
                
                self.currentText = joinedChunks
                self.currentFallbacks = fallbacks
                self.currentDecodingLoops += 1
            }
            
            // Check early stopping
            let currentTokens = progress.tokens
            let checkWindow = Int(capturedCompressionCheckWindow)
            if currentTokens.count > checkWindow {
                let checkTokens: [Int] = currentTokens.suffix(checkWindow)
                let compressionRatio = compressionRatio(of: checkTokens)
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
        let mergedResults = mergeTranscriptionResults(transcriptionResults)
        return mergedResults
    }
    
    // MARK: Streaming Logic
    
    private func realtimeLoop() {
        transcriptionTask = Task {
            while isRecording && isTranscribing {
                do {
                    try await transcribeCurrentBuffer()
                } catch {
                    print("Error: \(error.localizedDescription)")
                    break
                }
            }
        }
    }
    
    private func stopRealtimeTranscription() {
        isTranscribing = false
        transcriptionTask?.cancel()
    }
    
    private func transcribeCurrentBuffer() async throws {
        guard let whisperKit = whisperKit else { return }
        
        // Retrieve the current audio buffer from the audio processor
        let currentBuffer = whisperKit.audioProcessor.audioSamples
        // Calculate the size and duration of the next buffer segment
        let nextBufferSize = currentBuffer.count - lastBufferSize
        let nextBufferSeconds = Float(nextBufferSize) / Float(WhisperKit.sampleRate)
        
        // Only run the transcribe if the next buffer has at least 1 second of audio
        guard nextBufferSeconds > 1.0 else {
            await MainActor.run {
                if currentText == "" {
                    currentText = "listening..."
                }
            }
            try await Task.sleep(nanoseconds: taskSleepDuration) // sleep for 100ms for next buffer
            return
        }
        
        let voiceDetected = AudioProcessor.isVoiceDetected(
            in: whisperKit.audioProcessor.relativeEnergy,
            nextBufferInSeconds: nextBufferSeconds,
            silenceThreshold: Float(silenceThreshold)
        )
        // Only run the transcribe if the next buffer has voice
        guard voiceDetected else {
            await MainActor.run {
                if currentText == "" {
                    currentText = "Waiting for speech..."
                }
            }
            
            if nextBufferSeconds > Float(silenceDurationThreshold) {
                if let lastConfirmedSegment = unconfirmedSegments.last {
                    lastConfirmedSegmentEndSeconds = lastConfirmedSegment.end
                    print("Last confirmed segment end: \(lastConfirmedSegmentEndSeconds)")
                    let message = WhisperMessage(from: lastConfirmedSegment)
                    messageSubject.send(message)
                    unconfirmedSegments = []
                    whisperKit.audioProcessor.purgeAudioSamples(keepingLast: Int(remainingAudioAfterPurge * Double(WhisperKit.sampleRate)))
                    lastBufferSize = whisperKit.audioProcessor.audioSamples.count
                } else if nextBufferSeconds > Float(sampleResetThreshold) {
                    unconfirmedSegments = []
                    whisperKit.audioProcessor.purgeAudioSamples(keepingLast: Int(remainingAudioAfterReset * Double(WhisperKit.sampleRate)))
                    lastBufferSize = whisperKit.audioProcessor.audioSamples.count
                    lastConfirmedSegmentEndSeconds = 0
                }
            }
            // Sleep for 100ms and check the next buffer
            try await Task.sleep(nanoseconds: taskSleepDuration)
            return
        }
        
        // Store this for next iterations VAD
        lastBufferSize = currentBuffer.count
        
        // Run realtime transcribe using timestamp tokens directly
        let transcription = try await transcribeAudioSamples(Array(currentBuffer))
        
        // We need to run this next part on the main thread
        await MainActor.run {
            currentText = ""
            guard let segments = transcription?.segments else {
                return
            }
            
            self.tokensPerSecond = transcription?.timings.tokensPerSecond ?? 0
            self.firstTokenTime = transcription?.timings.firstTokenTime ?? 0
            self.pipelineStart = transcription?.timings.pipelineStart ?? 0
            self.currentLag = transcription?.timings.decodingLoop ?? 0
            self.currentEncodingLoops += Int(transcription?.timings.totalEncodingRuns ?? 0)
            
            let totalAudio = Double(currentBuffer.count) / Double(WhisperKit.sampleRate)
            self.totalInferenceTime += transcription?.timings.fullPipeline ?? 0
            self.effectiveRealTimeFactor = Double(totalInferenceTime) / totalAudio
            self.effectiveSpeedFactor = totalAudio / Double(totalInferenceTime)
            
            // Logic for moving segments to confirmedSegments
            if segments.count > requiredSegmentsForConfirmation {
                // Calculate the number of segments to confirm
                let numberOfSegmentsToConfirm = segments.count - requiredSegmentsForConfirmation
                
                // Confirm the required number of segments
                let confirmedSegmentsArray = Array(segments.prefix(numberOfSegmentsToConfirm))
                let remainingSegments = Array(segments.suffix(requiredSegmentsForConfirmation))
                
                // Update lastConfirmedSegmentEnd based on the last confirmed segment
                if let lastConfirmedSegment = confirmedSegmentsArray.last, lastConfirmedSegment.end > lastConfirmedSegmentEndSeconds {
                    lastConfirmedSegmentEndSeconds = lastConfirmedSegment.end
                    print("Last confirmed segment end: \(lastConfirmedSegmentEndSeconds)")
                    
                    // Add confirmed segments to the confirmedSegments array
                    for segment in confirmedSegmentsArray {
                        let message = WhisperMessage(from: segment)
                        messageSubject.send(message)
                    }
                }
                
                // Update transcriptions to reflect the remaining segments
                self.unconfirmedSegments = remainingSegments
            } else {
                // Handle the case where segments are fewer or equal to required
                self.unconfirmedSegments = segments
            }
            
        }
    }
}

extension WhisperKit: @unchecked @retroactive Sendable { }

extension ModelComputeOptions: @unchecked @retroactive Sendable { }

extension TranscriptionResult: @unchecked @retroactive Sendable { }


public enum WhisperManagerError: Error {
    case preparationFailed(String)
    case modelNotFound
    case modelLoadFailed
    case transcriptionFailed
    case invalidState(String)
}

extension WhisperManagerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .preparationFailed(let reason):
            return "Preparation failed: \(reason)"
        case .modelNotFound:
            return "The specified model was not found."
        case .modelLoadFailed:
            return "Failed to load the model."
        case .transcriptionFailed:
            return "Transcription process failed."
        case .invalidState(let message):
            return "Invalid state: \(message)"
        }
    }
}
