//
//  Whisper.swift
//  WhisperAX
//
//  Created by Norikazu Muramoto on 2024/10/03.
//



@preconcurrency import WhisperKit
import AVFoundation
import CoreML


@Observable
@MainActor
public class Whisper: @unchecked Sendable {
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
    public var enableTimestamps: Bool = true
    public var enablePromptPrefill: Bool = true
    public var enableCachePrefill: Bool = true
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
    public var confirmedSegments: [TranscriptionSegment] = []
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
        confirmedSegments = []
        unconfirmedSegments = []
    }
    
    // MARK: - Logic
    
    func fetchModels() {
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
        
        Task {
            let remoteModels = try await WhisperKit.fetchAvailableModels(from: repoName)
            for model in remoteModels {
                if !availableModels.contains(model),
                   !disabledModels.contains(model)
                {
                    availableModels.append(model)
                }
            }
        }
    }
    
    func loadModel(_ model: String, redownload: Bool = false) {
        print("Selected Model: \(UserDefaults.standard.string(forKey: "selectedModel") ?? "nil")")
        print("""
            Computing Options:
            - Mel Spectrogram:  \(getComputeOptions().melCompute.description)
            - Audio Encoder:    \(getComputeOptions().audioEncoderCompute.description)
            - Text Decoder:     \(getComputeOptions().textDecoderCompute.description)
            - Prefill Data:     \(getComputeOptions().prefillCompute.description)
        """)
        
        self.whisperKit = nil
        Task {
            self.whisperKit = try await WhisperKit(
                computeOptions: getComputeOptions(),
                verbose: true,
                logLevel: .debug,
                prewarm: false,
                load: false,
                download: false
            )
            guard let whisperKit = self.whisperKit else {
                return
            }
            
            var folder: URL?
            
            // Check if the model is available locally
            if localModels.contains(model) && !redownload {
                // Get local model folder URL from localModels
                // TODO: Make this configurable in the UI
                folder = URL(fileURLWithPath: localModelPath).appendingPathComponent(model)
            } else {
                // Download the model
                folder = try await WhisperKit.download(variant: model, from: repoName, progressCallback: { @Sendable progress in
                    DispatchQueue.main.async {
                        self.loadingProgressValue = Float(progress.fractionCompleted) * self.specializationProgressRatio
                        self.modelState = .downloading
                    }
                })
            }
            
            await MainActor.run {
                loadingProgressValue = specializationProgressRatio
                modelState = .downloaded
            }
            
            if let modelFolder = folder {
                whisperKit.modelFolder = modelFolder
                
                await MainActor.run {
                    // Set the loading progress to 90% of the way after prewarm
                    loadingProgressValue = specializationProgressRatio
                    modelState = .prewarming
                }
                
                let progressBarTask = Task {
                    await updateProgressBar(targetProgress: 0.9, maxTime: 240)
                }
                
                // Prewarm models
                do {
                    try await whisperKit.prewarmModels()
                    progressBarTask.cancel()
                } catch {
                    print("Error prewarming models, retrying: \(error.localizedDescription)")
                    progressBarTask.cancel()
                    if !redownload {
                        loadModel(model, redownload: true)
                        return
                    } else {
                        // Redownloading failed, error out
                        modelState = .unloaded
                        return
                    }
                }
                
                await MainActor.run {
                    // Set the loading progress to 90% of the way after prewarm
                    loadingProgressValue = specializationProgressRatio + 0.9 * (1 - specializationProgressRatio)
                    modelState = .loading
                }
                
                try await whisperKit.loadModels()
                
                await MainActor.run {
                    if !localModels.contains(model) {
                        localModels.append(model)
                    }
                    
                    availableLanguages = Constants.languages.map { $0.key }.sorted()
                    loadingProgressValue = 1.0
                    modelState = whisperKit.modelState
                }
            }
        }
    }
    
    func deleteModel() {
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
    
    func updateProgressBar(targetProgress: Float, maxTime: TimeInterval) async {
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
            startRecording()
        } else {
            stopRecording()
        }
    }
    
    func startRecording() {
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
    
    func stopRecording() {
        isRecording = false
        stopRealtimeTranscription()
        if let audioProcessor = whisperKit?.audioProcessor {
            audioProcessor.stopRecording()
        }
    }
    
    // MARK: - Transcribe Logic
    
    func transcribeAudioSamples(_ samples: [Float]) async throws -> TranscriptionResult? {
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
            usePrefillPrompt: enablePromptPrefill,
            usePrefillCache: enableCachePrefill,
            skipSpecialTokens: !enableSpecialCharacters,
            withoutTimestamps: !enableTimestamps,
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
    
    func realtimeLoop() {
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
    
    func stopRealtimeTranscription() {
        isTranscribing = false
        transcriptionTask?.cancel()
    }
    
    func transcribeCurrentBuffer() async throws {
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
                    confirmedSegments.append(contentsOf: unconfirmedSegments)
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
                        if !self.confirmedSegments.contains(segment: segment) {
                            self.confirmedSegments.append(segment)
                        }
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
