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
    public var audioDevices: [AudioDevice]? = nil
#endif
    var isRecording: Bool = false
    var isTranscribing: Bool = false

    var modelStorage: String = "huggingface/models/argmaxinc/whisperkit-coreml"
    
    public static let shared: Whisper = Whisper()
    
    
    // MARK: Model management
    
    public var modelState: ModelState = .unloaded
    public var localModels: [String] = []
    public var localModelPath: String = ""
    public var availableModels: [String] = []
    public var availableLanguages: [String] = []
    public var disabledModels: [String] = WhisperKit.recommendedModels().disabled
    
    // MARK: Settings
    
    public var selectedAudioInput: String?
    public var selectedModel: String = WhisperKit.recommendedModels().default
    public var selectedTab: String = "Transcribe"
    public var selectedLanguage: String {
        get { UserDefaults.standard.string(forKey: "selectedLanguage") ?? "english" }
        set { UserDefaults.standard.set(newValue, forKey: "selectedLanguage") }
    }
    public var repoName: String = "argmaxinc/whisperkit-coreml"

    public var enableDecoderPreview: Bool = true
    public var tokenConfirmationsNeeded: Double = 2
    public var encoderComputeUnits: MLComputeUnits = .cpuAndNeuralEngine
    public var decoderComputeUnits: MLComputeUnits = .cpuAndNeuralEngine
    
    public var setting: TranscriptionSettings = TranscriptionSettings()

    // MARK: Standard properties
    
    public var loadingProgressValue: Float = 0.0
    public var specializationProgressRatio: Float = 0.7

    public var bufferEnergy: [Float] = []
    public var bufferSeconds: Double = 0
    
    // MARK: Recoding setting

    private var transcriptionTask: Task<Void, Never>? = nil
    
    let taskSleepDuration: UInt64 = 100_000_000
    
    public init() { }
    
    func getComputeOptions() -> ModelComputeOptions {
        return ModelComputeOptions(audioEncoderCompute: encoderComputeUnits, textDecoderCompute: decoderComputeUnits)
    }
    
    // MARK: Views
    
    func resetState() {
        bufferEnergy = []
        bufferSeconds = 0
    }
    
    // MARK: - Logic
    
    private var loadSubject = PassthroughSubject<Progress, Never>()
    private var loadTask: Task<Void, Never>?
    
    public func setAudioDevice(_ audioDevice: AudioDevice? = nil) {
#if os(macOS)
        let audioDevices = AudioProcessor.getAudioDevices()
        self.audioDevices = audioDevices
        if let audioDevice,
           let selectedDevice = audioDevices.first(where: { $0.name == selectedAudioInput }) {
            self.selectedAudioInput = selectedDevice.name
        } else {
            if let audioDevice = audioDevices.first {
                self.selectedAudioInput = audioDevice.name
            }
        }
#endif
    }
    
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
    
    public typealias AudioBufferCallback = ([Float]) -> Void
    
    private var audioBufferCallback: AudioBufferCallback?
    
    public func setAnalyzer(_ callback: @escaping AudioBufferCallback) {
        self.audioBufferCallback = callback
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
    
    public private(set) var isListening: Bool = false
    
    private var messageSubject = PassthroughSubject<WhisperMessage, Never>()
    
    private var listeningTask: Task<Void, Never>?
    
    public func listen() -> AsyncStream<WhisperMessage> {
        isListening = true
        startRecording()
        return AsyncStream { continuation in
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
            let callback = self.audioBufferCallback
            Task(priority: .userInitiated) {
                guard await AudioProcessor.requestRecordPermission() else {
                    print("Microphone access was not granted.")
                    return
                }
                var deviceId: DeviceID?
#if os(macOS)
                if let selectedAudioInput = self.selectedAudioInput,
                   let devices = self.audioDevices,
                   let device = devices.first(where: { $0.name == selectedAudioInput }) {
                    deviceId = device.id
                }        

                if deviceId == nil {
                    throw WhisperError.microphoneUnavailable()
                }
#endif
                try? await audioProcessor.startRecordingLive(inputDeviceID: deviceId, callback: callback)
                await MainActor.run {
                    self.isRecording = true
                    self.isTranscribing = true
                    self.realtimeLoop()
                }
            }
        }
    }
    
    private func _stopRecording() {
        isRecording = false
        stopRealtimeTranscription()
        if let audioProcessor = whisperKit?.audioProcessor {
            Task {
                await audioProcessor.stopRecording()
            }
        }
    }
        
    // MARK: Streaming Logic
    
    private func realtimeLoop() {
        let manager = RealtimeTranscriptionManager(whisperKit: self.whisperKit!, language: self.selectedLanguage)
        transcriptionTask = Task {
            while isRecording && isTranscribing {
                do {
                    if let message = try await manager.transcribeCurrentBuffer() {
                        Task { @MainActor in
                            messageSubject.send(message)
                        }
                    }
                } catch {
                    print("Error: \(error.localizedDescription)")
                    print(error)
                    break
                }
            }
        }
    }
    
    private func stopRealtimeTranscription() {
        isTranscribing = false
        transcriptionTask?.cancel()
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
