
# 🎙️ Whisper.swift

Whisper.swift is a Swift class that utilizes WhisperKit for speech recognition and transcription. This class provides functionality for real-time audio input processing, model management, and transcription setting adjustments. ✨

## 🌟 Key Features

1. **Speech Recognition** 🗣️: Recognizes speech in real-time and converts it to text.
2. **Model Management** 🧠: Manages local and remote speech recognition models.
3. **Customizable Settings** ⚙️: Allows customization of various parameters such as audio input, model selection, and language settings.
4. **Real-time Processing** ⚡: Continuously processes streaming audio input and converts it to text.
5. **Performance Monitoring** 📊: Tracks performance metrics such as processing time and token generation speed.

## 🧩 Main Components

- `WhisperKit` 🎯: The core component for speech recognition
- `AudioProcessor` 🎚️: Responsible for processing audio input
- `ModelState` 🔄: Manages the state of the model (unloaded, downloading, loaded, etc.)
- `TranscriptionResult` 📝: Holds the transcription results

## 🚀 Usage

1. **Initialization** 🎬:
   ```swift
   let whisper = Whisper()
   ```

2. **Loading a Model** 📥:
   ```swift
   whisper.loadModel("modelName")
   ```

3. **Starting/Stopping Recording** ⏯️:
   ```swift
   whisper.toggleRecording()
   ```

4. **Adjusting Settings** 🛠️:
   ```swift
   whisper.selectedLanguage = "english"
   whisper.enableTimestamps = true
   ```

5. **Retrieving Transcription Results** 📊:
   ```swift
   let currentText = whisper.currentText
   ```

## 🔑 Key Methods

- `fetchModels()` 🔍: Fetches available models
- `loadModel(_:redownload:)` 📥: Loads a specified model
- `startRecording()` 🎙️: Starts audio recording
- `stopRecording()` 🛑: Stops audio recording
- `transcribeAudioSamples(_:)` 🔄: Transcribes audio samples
- `realtimeLoop()` 🔁: Initiates the real-time transcription loop

## 📝 Notes

- This class is marked with `@Observable` and `@MainActor`, making it suitable for use with SwiftUI. 🎨
- The accuracy and speed of speech recognition heavily depend on the selected model and settings. 🎯
- For real-time processing, it's crucial to properly adjust buffer size and silence detection thresholds. 🔧

## 🔗 Dependencies

- WhisperKit 🧠
- AVFoundation 🎵
- CoreML 🤖

This class allows for easy integration of advanced speech recognition capabilities into your application. 🚀✨

Happy coding! 💻🎉
