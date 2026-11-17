import SwiftUI
import AVFoundation
import Speech
import QuillCore

/// Records a voice note, then writes it out as text on the device.
struct VoiceNoteSheet: View {
    /// The transcript, and the recording when it should be attached.
    let finish: (String, Attachment?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var recorder = VoiceRecorder()
    @State private var transcribing = false
    @State private var failure: String?
    @AppStorage("attachVoiceRecordings") private var attachAudio = false

    var body: some View {
        VStack(spacing: 20) {
            if let failure {
                Label(failure, systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            } else if transcribing {
                ProgressView("Transcribing")
            } else {
                LevelMeter(levels: recorder.levels)
                    .frame(height: 56)
                Text(Duration.seconds(recorder.elapsed), format: .time(pattern: .minuteSecond))
                    .font(.title2.monospacedDigit())
                    .contentTransition(.numericText())
            }
            Toggle("Attach Recording", isOn: $attachAudio)
                .disabled(transcribing)
            HStack(spacing: 12) {
                Button("Cancel", role: .cancel) { recorder.discard(); dismiss() }
                    .secondaryAction()
                Button { Task { await stop() } } label: {
                    Label("Done", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .prominentAction()
                .disabled(!recorder.recording || transcribing)
                .accessibilityIdentifier("voice.done")
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .interactiveDismissDisabled(transcribing)
        .task {
            do { try await recorder.start() } catch { failure = error.localizedDescription }
        }
        .onDisappear { recorder.discard() }
        .sensoryFeedback(.start, trigger: recorder.recording) { _, new in new }
    }

    private func stop() async {
        guard let file = recorder.stop() else { return }
        withAnimation(.snappy) { transcribing = true }
        defer { recorder.discard() }
        do {
            let text = try await Transcriber.transcribe(file)
            let audio = attachAudio ? (try? Data(contentsOf: file)).map {
                Attachment(data: $0, filename: "voice-\(UUID().uuidString.prefix(8)).m4a", mimeType: "audio/mp4")
            } : nil
            guard !text.isEmpty || audio != nil else { throw QuillError("No speech was heard.") }
            finish(text, audio)
            dismiss()
        } catch {
            withAnimation(.snappy) { transcribing = false; failure = error.localizedDescription }
        }
    }
}

/// A few bars that follow the microphone level.
private struct LevelMeter: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .fill(.tint)
                    .frame(width: 5, height: max(5, CGFloat(levels[index]) * 56))
            }
        }
        .animation(.linear(duration: 0.08), value: levels)
        .accessibilityHidden(true)
    }
}

/// Records the microphone to an AAC file and reports its level as it goes.
@MainActor @Observable
final class VoiceRecorder {
    private(set) var recording = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var levels = [Float](repeating: 0, count: 24)
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var meter: Timer?
    private let file = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")

    func start() async throws {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw QuillError("Allow microphone access in Settings to record voice notes.")
        }
        let session = AVAudioSession.sharedInstance()
        // The spoken-audio mode is for playback; with the record category it fails with OSStatus -50.
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        let recorder = try AVAudioRecorder(url: file, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else { throw QuillError("Recording couldn’t start.") }
        self.recorder = recorder
        recording = true
        meter = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    private func sample() {
        guard let recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        // Decibels from -60 to 0, as 0 to 1.
        let level = max(0, min(1, (recorder.averagePower(forChannel: 0) + 60) / 60))
        levels = Array(levels.dropFirst()) + [level]
        elapsed = recorder.currentTime
    }

    /// Ends the recording and returns its file.
    func stop() -> URL? {
        guard let recorder, recording else { return nil }
        recorder.stop(); meter?.invalidate(); recording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return file
    }

    /// Stops and deletes the recording.
    func discard() {
        _ = stop()
        recorder = nil
        try? FileManager.default.removeItem(at: file)
    }
}

/// Speech to text that stays on the device.
enum Transcriber {
    static func transcribe(_ file: URL) async throws -> String {
        if #available(iOS 26.0, *), SpeechTranscriber.isAvailable,
           let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) {
            return try await analyze(file, locale: locale)
        }
        return try await recognize(file)
    }

    @available(iOS 26.0, *)
    private static func analyze(_ file: URL, locale: Locale) async throws -> String {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        // The language model downloads once, the first time it is needed.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        async let text = transcriber.results.reduce(into: "") { text, result in text += String(result.text.characters) }
        if let end = try await analyzer.analyzeSequence(from: AVAudioFile(forReading: file)) {
            try await analyzer.finalizeAndFinish(through: end)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Before iOS 26: the older recognizer, kept on the device when it can be.
    private static func recognize(_ file: URL) async throws -> String {
        let status = await withCheckedContinuation { done in SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0) } }
        guard status == .authorized else { throw QuillError("Allow speech recognition in Settings to transcribe voice notes.") }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { throw QuillError("Transcription isn’t available for your language.") }
        let request = SFSpeechURLRecognitionRequest(url: file)
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.addsPunctuation = true
        return try await withCheckedThrowingContinuation { done in
            var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !resumed else { return }
                if let error { resumed = true; done.resume(throwing: error) }
                else if let result, result.isFinal { resumed = true; done.resume(returning: result.bestTranscription.formattedString) }
            }
        }
    }
}

/// A recording in the composer's attachment strip.
struct AudioTile: View {
    let remove: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "waveform").font(.title2).foregroundStyle(.tint)
            Text("Recording").font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: 96, height: 96)
        .background(Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .overlay(alignment: .topTrailing) {
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(.black.opacity(0.6), in: Circle())
                    .frame(width: 40, height: 40, alignment: .topTrailing)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Remove Recording")
        }
    }
}
