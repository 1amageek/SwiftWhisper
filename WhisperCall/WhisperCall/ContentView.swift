//
//  ContentView.swift
//  ibou
//
//  Created by Norikazu Muramoto on 2024/10/03.
//

import SwiftUI
import SwiftData
import SwiftWhisper
import WhisperKit

struct ContentView: View {
    
    @State var whisper = Whisper()

    var body: some View {
        audioDevicesView
        .task {
            do {
                whisper.setAudioDevice()
                whisper.setAnalyzer { buffer in
                    print(buffer.map(\.magnitude))
                }
                try await whisper.prepare { progress in
                    print(progress)
                }
                for await message in whisper.listen() {
                    print(message.text)
                }
            } catch {
                print(error.localizedDescription)
            }
            
        }
    }

    var audioDevicesView: some View {
        Group {
#if os(macOS)
            HStack {
                if let audioDevices = whisper.audioDevices, audioDevices.count > 0 {
                    @Bindable var binding = whisper
                    Picker("", selection: $binding.selectedAudioInput) {
                        ForEach(audioDevices, id: \.self) { device in
                            Text(device.name).tag(device.name)
                        }
                    }
                    .frame(width: 250)
                    .disabled(whisper.isListening)
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
}

#Preview {
    ContentView()
}
