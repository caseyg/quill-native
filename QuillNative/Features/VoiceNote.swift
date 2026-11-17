import SwiftUI
import AVFoundation
import Speech
import QuillCore

/// Records a voice note and writes it out as text on the device while you speak.
struct VoiceNoteSheet: View {
    /// The transcript, and the recording when it should be attached.
    let finish: (String, Attachment?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var recorder = VoiceRecorder()
    @State private var finishing = false
    @State private var failure: String?
    @AppStorage("attachVoiceRecordings") private var attachAudio = false

    var body: some View {
        VStack(spacing: 16) {
            if let failure {
                Label(failure, systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxHeight: .infinity)
            } else {
                HStack(spacing: 12) {
                    LevelMeter(levels: recorder.levels).frame(height: 32)
                    Spacer(minLength: 0)
                    Text(Duration.seconds(recorder.elapsed), format: .time(pattern: .minuteSecond))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                transcript
            }
            Toggle("Attach Recording", isOn: $attachAudio)
                .disabled(finishing)
            HStack(spacing: 12) {
                Button("Cancel", role: .cancel) { recorder.discard(); dismiss() }
                    .secondaryAction()
                Button { Task { await stop() } } label: {
                    Group {
                        if finishing { ProgressView() } else { Label("Done", systemImage: "stop.fill") }
                    }
                    .frame(maxWidth: .infinity)
                }
                .prominentAction()
                .disabled(!recorder.recording || finishing)
                .accessibilityIdentifier("voice.done")
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .interactiveDismissDisabled(finishing)
        .task {
            do { try await recorder.start() } catch { failure = error.localizedDescription }
        }
        .onDisappear { recorder.discard() }
        .sensoryFeedback(.start, trigger: recorder.recording) { _, new in new }
    }

    /// Settled words in full, and the transcriber's current guess dimmed, following the newest line.
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Group {
                    if recorder.settled.isEmpty && recorder.guess.isEmpty {
                        Text(recorder.recording ? "Listening…" : "Getting ready…").foregroundStyle(.tertiary)
                    } else {
                        Text(recorder.settled) + Text(recorder.guess).foregroundStyle(.secondary)
                    }
                }
                .font(.title3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id("end")
                .accessibilityIdentifier("voice.transcript")
            }
            .frame(maxHeight: .infinity)
            .onChange(of: recorder.settled + recorder.guess) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    private func stop() async {
        withAnimation(.snappy) { finishing = true }
        defer { recorder.discard() }
        do {
            let (text, file) = try await recorder.stop()
            let audio = attachAudio ? (try? Data(contentsOf: file)).map {
                Attachment(data: $0, filename: "voice-\(UUID().uuidString.prefix(8)).m4a", mimeType: "audio/mp4")
            } : nil
            guard !text.isEmpty || audio != nil else { throw QuillError("No speech was heard.") }
            finish(text, audio)
            dismiss()
        } catch {
            withAnimation(.snappy) { finishing = false; failure = error.localizedDescription }
        }
    }
}

/// A few bars that follow the microphone level.
private struct LevelMeter: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .fill(.tint)
                    .frame(width: 4, height: max(4, CGFloat(levels[index]) * 32))
            }
        }
        .animation(.linear(duration: 0.08), value: levels)
        .accessibilityHidden(true)
    }
}

/// Streams the microphone to an AAC file and to the transcriber at once.
@MainActor @Observable
final class VoiceRecorder {
    private(set) var recording = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var levels = [Float](repeating: 0, count: 20)
    /// Words the transcriber has settled on, and its guess at what is being said now.
    private(set) var settled = ""
    private(set) var guess = ""
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var transcriber: LiveTranscriber?
    @ObservationIgnored private var clock: Timer?
    private let file = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")

    func start() async throws {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw QuillError("Allow microphone access in Settings to record voice notes.")
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw QuillError("No microphone is available.") }
        let transcriber = try await LiveTranscriber.make(inputFormat: format) { [weak self] settled, guess in
            Task { @MainActor in self?.settled = settled; self?.guess = guess }
        }
        self.transcriber = transcriber
        let writer = try AVAudioFile(forWriting: file, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: VoiceRecorder.tap(writer: writer, transcriber: transcriber) { [weak self] level in
            Task { @MainActor in self?.levels = Array((self?.levels ?? []).dropFirst()) + [level] }
        })
        engine.prepare()
        try engine.start()
        recording = true
        let began = Date()
        clock = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.elapsed = Date().timeIntervalSince(began) }
        }
    }

    /// Runs on the audio thread, so it is built away from the main actor.
    nonisolated private static func tap(writer: AVAudioFile, transcriber: LiveTranscriber, level: @escaping @Sendable (Float) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            try? writer.write(from: buffer)
            transcriber.append(buffer)
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum: Float = 0
            for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
            let decibels = 10 * log10(max(sum / Float(buffer.frameLength), 1e-9))
            // Decibels from -60 to 0, as 0 to 1.
            level(max(0, min(1, (decibels + 60) / 60)))
        }
    }

    /// Ends the recording, waits for the last words, and returns the text and the audio file.
    func stop() async throws -> (String, URL) {
        halt()
        try await transcriber?.finish()
        let text = (settled + guess).trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, file)
    }

    private func halt() {
        guard recording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        clock?.invalidate()
        recording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Stops and deletes the recording.
    func discard() {
        halt()
        transcriber?.cancel(); transcriber = nil
        try? FileManager.default.removeItem(at: file)
    }
}

/// Speech to text on the device, fed audio as it is recorded.
class LiveTranscriber: @unchecked Sendable {
    /// Text that won't change, and the current guess that may.
    typealias Update = @Sendable (_ settled: String, _ guess: String) -> Void

    static func make(inputFormat: AVAudioFormat, update: @escaping Update) async throws -> LiveTranscriber {
        if #available(iOS 26.0, *), let analyzer = try await AnalyzerTranscriber(inputFormat: inputFormat, update: update) {
            return analyzer
        }
        return try await RecognizerTranscriber(update: update)
    }

    func append(_ buffer: AVAudioPCMBuffer) {}
    func finish() async throws {}
    func cancel() {}
}

/// iOS 26 and later: SpeechAnalyzer with volatile results, so a guess shows before the words settle.
@available(iOS 26.0, *)
private final class AnalyzerTranscriber: LiveTranscriber, @unchecked Sendable {
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let format: AVAudioFormat
    private let converter: AVAudioConverter?
    private let reading: Task<Void, Error>

    init?(inputFormat: AVAudioFormat, update: @escaping Update) async throws {
        guard SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else { return nil }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        // The language model downloads once, the first time it is needed.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: inputFormat) else { return nil }
        self.format = format
        converter = format == inputFormat ? nil : AVAudioConverter(from: inputFormat, to: format)
        analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        input = continuation
        reading = Task {
            var settled = ""
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                if result.isFinal { settled += text; update(settled, "") } else { update(settled, text) }
            }
        }
        super.init()
        try await analyzer.start(inputSequence: stream)
    }

    override func append(_ buffer: AVAudioPCMBuffer) {
        guard let converted = convert(buffer) else { return }
        input.yield(AnalyzerInput(buffer: converted))
    }

    override func finish() async throws {
        input.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        try await reading.value
    }

    override func cancel() {
        input.finish()
        reading.cancel()
        Task { [analyzer] in await analyzer.cancelAndFinishNow() }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else { return buffer }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData
            return buffer
        }
        return error == nil ? output : nil
    }
}

/// Before iOS 26: the older recognizer with partial results, kept on the device when it can be.
private final class RecognizerTranscriber: LiveTranscriber, @unchecked Sendable {
    private let request = SFSpeechAudioBufferRecognitionRequest()
    private var task: SFSpeechRecognitionTask?
    private let ended: AsyncStream<Void>

    init(update: @escaping Update) async throws {
        let status = await withCheckedContinuation { done in SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0) } }
        guard status == .authorized else { throw QuillError("Allow speech recognition in Settings to transcribe voice notes.") }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { throw QuillError("Transcription isn’t available for your language.") }
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.addsPunctuation = true
        let (ended, signal) = AsyncStream<Void>.makeStream()
        self.ended = ended
        super.init()
        task = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                let text = result.bestTranscription.formattedString
                if result.isFinal { update(text, ""); signal.finish() } else { update("", text) }
            }
            if error != nil { signal.finish() }
        }
    }

    override func append(_ buffer: AVAudioPCMBuffer) { request.append(buffer) }

    override func finish() async throws {
        request.endAudio()
        for await _ in ended {}
    }

    override func cancel() { task?.cancel() }
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
