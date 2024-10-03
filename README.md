# 🎙️ Whisper.swift

Whisper.swift is a Swift class that leverages WhisperKit for speech recognition and transcription. This class provides functionality for real-time audio input processing, model management, and transcription setting adjustments. ✨

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

2. **Preparing a Model** 📥:
   ```swift
   try await whisper.prepare(model: "modelName") { progress in
       print("Preparation progress: \(progress.fractionCompleted * 100)%")
   }
   ```

3. **Listening and Transcribing** 🎧:
   ```swift
   for try await message in whisper.listen() {
       print(message.text)
   }
   ```

4. **Stopping Transcription** 🛑:
   ```swift
   whisper.stopListening()
   ```

5. **Adjusting Settings** 🛠️:
   ```swift
   whisper.selectedLanguage = "english"
   ```

## 🔑 Key Methods

- `prepare(model:progress:)` 📥: Prepares the specified model with progress updates
- `listen()` 🎙️: Starts listening and returns an AsyncStream of WhisperMessages
- `stopListening()` 🛑: Stops the listening process
- `fetchModels()` 🔍: Fetches available models
- `deleteModel()` 🗑️: Deletes the selected model

## 📝 Notes

- This class is marked with `@Observable` and `@MainActor`, making it suitable for use with SwiftUI. 🎨
- The accuracy and speed of speech recognition heavily depend on the selected model and settings. 🎯
- For real-time processing, it's crucial to properly adjust buffer size and silence detection thresholds. 🔧

## 🔗 Dependencies

- WhisperKit 🧠
- AVFoundation 🎵
- CoreML 🤖
- Combine 🔗

This class allows for easy integration of advanced speech recognition capabilities into your application. 🚀✨

Happy coding! 💻🎉
