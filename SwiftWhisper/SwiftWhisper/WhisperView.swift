//
//  WhisperView.swift
//  WhisperAX
//
//  Created by Norikazu Muramoto on 2024/10/03.
//

import SwiftUI
import WhisperKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif


struct WhisperView: View {

    @State var whisper: Whisper = Whisper()
    
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showComputeUnits: Bool = true
    @State private var showAdvancedOptions: Bool = false
    
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            VStack(alignment: .leading) {
                modelSelectorView
                    .padding(.vertical)
            }
            .navigationTitle("WhisperAX")
            .navigationSplitViewColumnWidth(min: 300, ideal: 350)
            .padding(.horizontal)
            Spacer()
        } detail: {
            VStack {
#if os(iOS)
                modelSelectorView
                    .padding()
                transcriptionView
#elseif os(macOS)
                VStack(alignment: .leading) {
                    transcriptionView
                }
                .padding()
#endif
                controlsView
            }
        }
        .onAppear {
            whisper.fetchModels()
        }
    }
    
    // MARK: - Transcription
    
    var transcriptionView: some View {
        VStack {
            if !whisper.bufferEnergy.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 1) {
                        let startIndex = max(whisper.bufferEnergy.count - 300, 0)
                        ForEach(Array(whisper.bufferEnergy.enumerated())[startIndex...], id: \.element) { _, energy in
                            ZStack {
                                RoundedRectangle(cornerRadius: 2)
                                    .frame(width: 2, height: CGFloat(energy) * 24)
                            }
                            .frame(maxHeight: 24)
                            .background(energy > Float(whisper.silenceThreshold) ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
                        }
                    }
                }
                .defaultScrollAnchor(.trailing)
                .frame(height: 24)
                .scrollIndicators(.never)
            }
            
            ScrollView {
                VStack(alignment: .leading) {
                    
                    ForEach(Array(whisper.confirmedSegments.enumerated()), id: \.element) { _, segment in
                        let timestampText = whisper.enableTimestamps ? "[\(String(format: "%.2f", segment.start)) --> \(String(format: "%.2f", segment.end))]" : ""
                        Text(timestampText + segment.text)
                            .font(.headline)
                            .fontWeight(.bold)
                            .tint(.green)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(Array(whisper.unconfirmedSegments.enumerated()), id: \.element) { _, segment in
                        let timestampText = whisper.enableTimestamps ? "[\(String(format: "%.2f", segment.start)) --> \(String(format: "%.2f", segment.end))]" : ""
                        Text(timestampText + segment.text)
                            .font(.headline)
                            .fontWeight(.bold)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if whisper.enableDecoderPreview {
                        Text("\(whisper.currentText)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    
                }
            }
            .frame(maxWidth: .infinity)
            .defaultScrollAnchor(.bottom)
            .textSelection(.enabled)
            .padding()
        }
    }
    
    // MARK: - Models
    
    var modelSelectorView: some View {
        Group {
            VStack {
                HStack {
                    Image(systemName: "circle.fill")
                        .foregroundStyle(whisper.modelState == .loaded ? .green : (whisper.modelState == .unloaded ? .red : .yellow))
                        .symbolEffect(.variableColor, isActive: whisper.modelState != .loaded && whisper.modelState != .unloaded)
                    Text(whisper.modelState.description)
                    
                    Spacer()
                    
                    if whisper.availableModels.count > 0 {
                        Picker("", selection: $whisper.selectedModel) {
                            ForEach(whisper.availableModels, id: \.self) { model in
                                HStack {
                                    let modelIcon = whisper.localModels.contains { $0 == model.description } ? "checkmark.circle" : "arrow.down.circle.dotted"
                                    Text("\(Image(systemName: modelIcon)) \(model.description.components(separatedBy: "_").dropFirst().joined(separator: " "))").tag(model.description)
                                }
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        .onChange(of: whisper.selectedModel, initial: false) { _, _ in
                            whisper.modelState = .unloaded
                        }
                    } else {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                            .scaleEffect(0.5)
                    }
                    
                    Button(action: {
                        whisper.deleteModel()
                    }, label: {
                        Image(systemName: "trash")
                    })
                    .help("Delete model")
                    .buttonStyle(BorderlessButtonStyle())
                    .disabled(whisper.localModels.count == 0)
                    .disabled(!whisper.localModels.contains(whisper.selectedModel))
                    
#if os(macOS)
                    Button(action: {
                        let folderURL = whisper.whisperKit?.modelFolder ?? (whisper.localModels.contains(whisper.selectedModel) ? URL(fileURLWithPath: whisper.localModelPath) : nil)
                        if let folder = folderURL {
                            NSWorkspace.shared.open(folder)
                        }
                    }, label: {
                        Image(systemName: "folder")
                    })
                    .buttonStyle(BorderlessButtonStyle())
#endif
                    Button(action: {
                        if let url = URL(string: "https://huggingface.co/\(whisper.repoName)") {
#if os(macOS)
                            NSWorkspace.shared.open(url)
#else
                            UIApplication.shared.open(url)
#endif
                        }
                    }, label: {
                        Image(systemName: "link.circle")
                    })
                    .buttonStyle(BorderlessButtonStyle())
                }
                
                if whisper.modelState == .unloaded {
                    Divider()
                    Button {
                        whisper.resetState()
                        whisper.loadModel(whisper.selectedModel)
                        whisper.modelState = .loading
                    } label: {
                        Text("Load Model")
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                    }
                    .buttonStyle(.borderedProminent)
                } else if whisper.loadingProgressValue < 1.0 {
                    VStack {
                        HStack {
                            ProgressView(value: whisper.loadingProgressValue, total: 1.0)
                                .progressViewStyle(LinearProgressViewStyle())
                                .frame(maxWidth: .infinity)
                            
                            Text(String(format: "%.1f%%", whisper.loadingProgressValue * 100))
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                        if whisper.modelState == .prewarming {
                            Text("Specializing \(whisper.selectedModel) for your device...\nThis can take several minutes on first load")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Controls
    
    var audioDevicesView: some View {
        Group {
#if os(macOS)
            HStack {
                if let audioDevices = whisper.audioDevices, audioDevices.count > 0 {
                    Picker("", selection: $whisper.selectedAudioInput) {
                        ForEach(audioDevices, id: \.self) { device in
                            Text(device.name).tag(device.name)
                        }
                    }
                    .frame(width: 250)
                    .disabled(whisper.isRecording)
                }
            }
            .onAppear {
                whisper.audioDevices = AudioProcessor.getAudioDevices()
                if let audioDevices = whisper.audioDevices,
                   !audioDevices.isEmpty,
                   whisper.selectedAudioInput == "No Audio Input",
                   let device = audioDevices.first
                {
                    whisper.selectedAudioInput = device.name
                }
            }
#endif
        }
    }
    
    var controlsView: some View {
        VStack {
            basicSettingsView
            VStack {
                HStack {
                    Button {
                        whisper.resetState()
                    } label: {
                        Label("Reset", systemImage: "arrow.clockwise")
                    }
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .buttonStyle(.borderless)
                    
                    Spacer()
                    
                    audioDevicesView
                    
                    Spacer()
                    
                    VStack {
                        Button {
                            showAdvancedOptions.toggle()
                        } label: {
                            Label("Settings", systemImage: "slider.horizontal.3")
                        }
                        .frame(minWidth: 0, maxWidth: .infinity)
                        .buttonStyle(.borderless)
                    }
                }
                
                ZStack {
                    Button {
                        withAnimation {
                            whisper.toggleRecording()
                        }
                    } label: {
                        Image(systemName: !whisper.isRecording ? "record.circle" : "stop.circle.fill")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 70, height: 70)
                            .padding()
                            .foregroundColor(whisper.modelState != .loaded ? .gray : .red)
                    }
                    .contentTransition(.symbolEffect(.replace))
                    .buttonStyle(BorderlessButtonStyle())
                    .disabled(whisper.modelState != .loaded)
                    .frame(minWidth: 0, maxWidth: .infinity)
                    
                    VStack {
                        Text("Encoder runs: \(whisper.currentEncodingLoops)")
                            .font(.caption)
                        Text("Decoder runs: \(whisper.currentDecodingLoops)")
                            .font(.caption)
                    }
                    .offset(x: -120, y: 0)
                    
                    if whisper.isRecording {
                        Text("\(String(format: "%.1f", whisper.bufferSeconds)) s")
                            .font(.caption)
                            .foregroundColor(.gray)
                            .offset(x: 80, y: 0)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .sheet(isPresented: $showAdvancedOptions, content: {
            advancedSettingsView
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled)
                .presentationContentInteraction(.scrolls)
        })
    }
    
    var basicSettingsView: some View {
        VStack {
            LabeledContent {
                Picker("", selection: $whisper.selectedLanguage) {
                    ForEach(whisper.availableLanguages, id: \.self) { language in
                        Text(language.description).tag(language.description)
                    }
                }
                .disabled(!(whisper.whisperKit?.modelVariant.isMultilingual ?? false))
            } label: {
                Label("Source Language", systemImage: "globe")
            }
            .padding(.horizontal)
            .padding(.top)
            
            HStack {
                Text(whisper.effectiveRealTimeFactor.formatted(.number.precision(.fractionLength(3))) + " RTF")
                    .font(.system(.body))
                    .lineLimit(1)
                Spacer()
#if os(macOS)
                Text(whisper.effectiveSpeedFactor.formatted(.number.precision(.fractionLength(1))) + " Speed Factor")
                    .font(.system(.body))
                    .lineLimit(1)
                Spacer()
#endif
                Text(whisper.tokensPerSecond.formatted(.number.precision(.fractionLength(0))) + " tok/s")
                    .font(.system(.body))
                    .lineLimit(1)
                Spacer()
                Text("First token: " + (whisper.firstTokenTime - whisper.pipelineStart).formatted(.number.precision(.fractionLength(2))) + "s")
                    .font(.system(.body))
                    .lineLimit(1)
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
    }
    
    var advancedSettingsView: some View {
#if os(iOS)
        NavigationView {
            settingsForm
                .navigationBarTitleDisplayMode(.inline)
        }
#else
        VStack {
            Text("Decoding Options")
                .font(.title2)
                .padding()
            settingsForm
                .frame(minWidth: 500, minHeight: 500)
        }
#endif
    }
    
    var settingsForm: some View {
        List {
            HStack {
                Text("Show Timestamps")
                InfoButton("Toggling this will include/exclude timestamps in both the UI and the prefill tokens.\nEither <|notimestamps|> or <|0.00|> will be forced based on this setting unless \"Prompt Prefill\" is de-selected.")
                Spacer()
                Toggle("", isOn: $whisper.enableTimestamps)
            }
            .padding(.horizontal)
            
            HStack {
                Text("Special Characters")
                InfoButton("Toggling this will include/exclude special characters in the transcription text.")
                Spacer()
                Toggle("", isOn: $whisper.enableSpecialCharacters)
            }
            .padding(.horizontal)
            
            HStack {
                Text("Show Decoder Preview")
                InfoButton("Toggling this will show a small preview of the decoder output in the UI under the transcribe. This can be useful for debugging.")
                Spacer()
                Toggle("", isOn: $whisper.enableDecoderPreview)
            }
            .padding(.horizontal)
            
            HStack {
                Text("Prompt Prefill")
                InfoButton("When Prompt Prefill is on, it will force the task, language, and timestamp tokens in the decoding loop. \nToggle it off if you'd like the model to generate those tokens itself instead.")
                Spacer()
                Toggle("", isOn: $whisper.enablePromptPrefill)
            }
            .padding(.horizontal)
            
            HStack {
                Text("Cache Prefill")
                InfoButton("When Cache Prefill is on, the decoder will try to use a lookup table of pre-computed KV caches instead of computing them during the decoding loop. \nThis allows the model to skip the compute required to force the initial prefill tokens, and can speed up inference")
                Spacer()
                Toggle("", isOn: $whisper.enableCachePrefill)
            }
            .padding(.horizontal)
            
            VStack {
                Text("Starting Temperature:")
                HStack {
                    Slider(value: $whisper.temperatureStart, in: 0...1, step: 0.1)
                    Text(whisper.temperatureStart.formatted(.number))
                    InfoButton("Controls the initial randomness of the decoding loop token selection.\nA higher temperature will result in more random choices for tokens, and can improve accuracy.")
                }
            }
            .padding(.horizontal)
            
            VStack {
                Text("Max Fallback Count:")
                HStack {
                    Slider(value: $whisper.fallbackCount, in: 0...5, step: 1)
                    Text(whisper.fallbackCount.formatted(.number))
                        .frame(width: 30)
                    InfoButton("Controls how many times the decoder will fallback to a higher temperature if any of the decoding thresholds are exceeded.\n Higher values will cause the decoder to run multiple times on the same audio, which can improve accuracy at the cost of speed.")
                }
            }
            .padding(.horizontal)
            
            VStack {
                Text("Compression Check Tokens")
                HStack {
                    Slider(value: $whisper.compressionCheckWindow, in: 0...100, step: 5)
                    Text(whisper.compressionCheckWindow.formatted(.number))
                        .frame(width: 30)
                    InfoButton("Amount of tokens to use when checking for whether the model is stuck in a repetition loop.\nRepetition is checked by using zlib compressed size of the text compared to non-compressed value.\n Lower values will catch repetitions sooner, but too low will miss repetition loops of phrases longer than the window.")
                }
            }
            .padding(.horizontal)
            
            VStack {
                Text("Max Tokens Per Loop")
                HStack {
                    Slider(value: $whisper.sampleLength, in: 0...Double(min(whisper.whisperKit?.textDecoder.kvCacheMaxSequenceLength ?? Constants.maxTokenContext, Constants.maxTokenContext)), step: 10)
                    Text(whisper.sampleLength.formatted(.number))
                        .frame(width: 30)
                    InfoButton("Maximum number of tokens to generate per loop.\nCan be lowered based on the type of speech in order to further prevent repetition loops from going too long.")
                }
            }
            .padding(.horizontal)
            
            VStack {
                Text("Silence Threshold")
                HStack {
                    Slider(value: $whisper.silenceThreshold, in: 0...1, step: 0.05)
                    Text(whisper.silenceThreshold.formatted(.number))
                        .frame(width: 30)
                    InfoButton("Relative silence threshold for the audio. \n Baseline is set by the quietest 100ms in the previous 2 seconds.")
                }
            }
            .padding(.horizontal)
            
            Section(header: Text("Experimental")) {
                
                VStack {
                    Text("Token Confirmations")
                    HStack {
                        Slider(value: $whisper.tokenConfirmationsNeeded, in: 1...10, step: 1)
                        Text(whisper.tokenConfirmationsNeeded.formatted(.number))
                            .frame(width: 30)
                        InfoButton("Controls the number of consecutive tokens required to agree between decoder loops before considering them as confirmed in the streaming process.")
                    }
                }
                .padding(.horizontal)
            }
        }
        .navigationTitle("Decoding Options")
        .toolbar(content: {
            ToolbarItem {
                Button {
                    showAdvancedOptions = false
                } label: {
                    Label("Done", systemImage: "xmark.circle.fill")
                        .foregroundColor(.primary)
                }
            }
        })
    }
    
    struct InfoButton: View {
        var infoText: String
        @State private var showInfo = false
        
        init(_ infoText: String) {
            self.infoText = infoText
        }
        
        var body: some View {
            Button(action: {
                self.showInfo = true
            }) {
                Image(systemName: "info.circle")
                    .foregroundColor(.blue)
            }
            .popover(isPresented: $showInfo) {
                Text(infoText)
                    .padding()
            }
            .buttonStyle(BorderlessButtonStyle())
        }
    }
}

#Preview {
    ContentView()
#if os(macOS)
        .frame(width: 800, height: 500)
#endif
}
