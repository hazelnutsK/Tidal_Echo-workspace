import AVFoundation
import Foundation

@MainActor
final class VoicePlaybackCenter: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = VoicePlaybackCenter()

    @Published private(set) var currentID: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var progressTask: Task<Void, Never>?

    func toggle(id: String, request: URLRequest) async {
        if currentID == id, let player {
            if player.isPlaying {
                player.pause()
                isPlaying = false
                progressTask?.cancel()
            } else {
                player.play()
                isPlaying = true
                startProgressUpdates()
            }
            return
        }

        isLoading = true
        currentID = id
        defer { isLoading = false }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw APIError.invalidResponse
            }
            try play(data: data, id: id)
        } catch {
            reset()
        }
    }

    func play(data: Data, id: String) throws {
        stop()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
        let next = try AVAudioPlayer(data: data)
        next.delegate = self
        next.prepareToPlay()
        player = next
        currentID = id
        duration = next.duration
        progress = 0
        isPlaying = next.play()
        startProgressUpdates()
    }

    func stop() {
        player?.stop()
        reset()
    }

    func seek(id: String, toProgress value: Double) {
        guard currentID == id, let player, player.duration > 0 else { return }
        let nextProgress = min(1, max(0, value))
        player.currentTime = player.duration * nextProgress
        progress = nextProgress
        duration = player.duration
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        reset()
    }

    private func startProgressUpdates() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let player = self.player else { return }
                self.progress = player.duration > 0 ? player.currentTime / player.duration : 0
                self.duration = player.duration
                if !player.isPlaying { return }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func reset() {
        progressTask?.cancel()
        progressTask = nil
        player = nil
        currentID = nil
        isPlaying = false
        isLoading = false
        progress = 0
        duration = 0
    }
}

struct VoiceRecordingResult {
    let data: Data
    let duration: TimeInterval
    let name: String
    let mime: String
}

@MainActor
final class VoiceRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var hasRecording = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var level: Double = 0

    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private var meterTask: Task<Void, Never>?
    private let maximumDuration: TimeInterval = 300

    func start() async throws {
        guard !isRecording else { return }
        let session = AVAudioSession.sharedInstance()
        let allowed = await withCheckedContinuation { continuation in
            session.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard allowed else { throw APIError.server("请先在系统设置里允许 Tidal Echo 使用麦克风") }

        VoicePlaybackCenter.shared.stop()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 24_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let next = try AVAudioRecorder(url: url, settings: settings)
        next.delegate = self
        next.isMeteringEnabled = true
        guard next.prepareToRecord(), next.record() else { throw APIError.server("录音启动失败") }
        recorder = next
        fileURL = url
        duration = 0
        level = 0
        hasRecording = false
        isRecording = true
        startMeter()
    }

    func finish() {
        guard isRecording else { return }
        let finalDuration = max(duration, recorder?.currentTime ?? 0)
        recorder?.stop()
        meterTask?.cancel()
        meterTask = nil
        duration = finalDuration
        recorder = nil
        isRecording = false
        hasRecording = fileURL != nil && duration >= 0.8
        level = 0
        if !hasRecording { cancel() }
    }

    func result() throws -> VoiceRecordingResult {
        if isRecording { finish() }
        guard hasRecording, let fileURL else { throw APIError.server("录音太短了") }
        return VoiceRecordingResult(
            data: try Data(contentsOf: fileURL),
            duration: duration,
            name: "voice-\(Int(Date().timeIntervalSince1970)).m4a",
            mime: "audio/mp4"
        )
    }

    func cancel() {
        recorder?.stop()
        recorder = nil
        meterTask?.cancel()
        meterTask = nil
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
        isRecording = false
        hasRecording = false
        duration = 0
        level = 0
    }

    func markSent() {
        cancel()
    }

    private func startMeter() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let recorder = self.recorder, self.isRecording else { return }
                recorder.updateMeters()
                let power = recorder.averagePower(forChannel: 0)
                self.level = max(0.04, min(1, pow(10, Double(power) / 38)))
                self.duration = recorder.currentTime
                if self.duration >= self.maximumDuration {
                    self.finish()
                    return
                }
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
        }
    }
}
