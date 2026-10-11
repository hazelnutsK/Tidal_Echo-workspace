import AVFoundation
import Speech
import SwiftUI

struct VoiceCallView: View {
    @ObservedObject var model: AppModel
    @StateObject private var call = VoiceCallController()
    @Environment(\.dismiss) private var dismiss

    private var palette: EchoPalette { model.theme.palette }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [palette.backgroundTop, palette.backgroundBottom, palette.accent.opacity(0.18)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Button {
                        Task {
                            await call.end()
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 42, height: 42)
                            .background(.thinMaterial, in: Circle())
                    }
                    Spacer()
                    Text("语音通话")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Color.clear.frame(width: 42, height: 42)
                }
                .padding(.horizontal, 18)

                Spacer(minLength: 34)

                ZStack {
                    CallWaveRing(level: call.level, speaking: call.phase == .speaking, color: palette.accent)
                        .frame(width: 220, height: 220)
                    Group {
                        if let image = model.aiAvatarImage {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            Image(systemName: "sparkles")
                                .font(.system(size: 48, weight: .light))
                                .foregroundStyle(palette.accent)
                                .background(palette.aiBubble)
                        }
                    }
                    .frame(width: 126, height: 126)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.55), lineWidth: 1))
                    .shadow(color: palette.accent.opacity(0.18), radius: 24)
                }

                Text(model.peerDisplayName)
                    .font(.system(size: 27, weight: .semibold, design: .serif))
                    .padding(.top, 20)
                Text(call.timerText)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(palette.secondaryText)
                    .padding(.top, 5)

                HStack(spacing: 7) {
                    Circle()
                        .fill(call.phase.color)
                        .frame(width: 7, height: 7)
                    Text(call.phase.title.replacingOccurrences(of: "小克", with: model.peerDisplayName))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(palette.secondaryText)
                }
                .padding(.top, 12)

                VStack(spacing: 10) {
                    if !call.aiCaption.isEmpty {
                        Text(call.aiCaption)
                            .font(model.chatFont.font(size: 18 * model.fontScale, weight: model.chatWeight.echoFontWeight))
                            .lineSpacing(5)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .transition(.opacity)
                    } else {
                        Text(call.liveTranscript.isEmpty ? "我在听，你慢慢说" : "你：\(call.liveTranscript)")
                            .font(.system(size: 15))
                            .foregroundStyle(call.liveTranscript.isEmpty ? palette.secondaryText : palette.text)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(minHeight: 92, alignment: .top)
                .padding(.horizontal, 32)
                .padding(.top, 24)

                if let error = call.errorText {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                }

                Spacer()

                HStack(spacing: 38) {
                    CallControlButton(
                        title: call.isMuted ? "取消静音" : "静音",
                        icon: call.isMuted ? "mic.slash.fill" : "mic.fill",
                        active: call.isMuted,
                        color: palette.accent
                    ) { call.toggleMute() }

                    Button {
                        Task {
                            await call.end()
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "phone.down.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 66, height: 66)
                            .background(Color.red.opacity(0.9), in: Circle())
                            .shadow(color: Color.red.opacity(0.28), radius: 15, y: 8)
                    }

                    CallControlButton(
                        title: "扬声器",
                        icon: call.usesSpeaker ? "speaker.wave.3.fill" : "speaker.wave.1",
                        active: call.usesSpeaker,
                        color: palette.accent
                    ) { call.toggleSpeaker() }
                }
                .padding(.bottom, 32)
            }
            .foregroundStyle(palette.text)
        }
        .interactiveDismissDisabled()
        .task { await call.start(model: model) }
        .onChange(of: model.messages.count) { _ in call.consume(messages: model.messages) }
        .onDisappear {
            NativeCallCoordinator.shared.finishCurrentCall()
            Task { await call.end() }
        }
    }
}

private struct CallControlButton: View {
    let title: String
    let icon: String
    let active: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(active ? Color.white : Color.primary)
                    .frame(width: 54, height: 54)
                    .background(active ? color : Color.white.opacity(0.58), in: Circle())
                Text(title).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 68)
        }
        .buttonStyle(.plain)
    }
}

private struct CallWaveRing: View {
    let level: Double
    let speaking: Bool
    let color: Color
    @State private var pulse = false

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .stroke(color.opacity(ringOpacity(index)), lineWidth: 2)
                    .scaleEffect(ringScale(index))
            }
            HStack(spacing: 4) {
                ForEach(0..<17, id: \.self) { index in
                    Capsule()
                        .fill(color.opacity(0.50))
                        .frame(width: 3, height: barHeight(index))
                }
            }
            .opacity(speaking || level > 0.08 ? 0.85 : 0.25)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.25).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    private func ringOpacity(_ index: Int) -> Double {
        0.20 - Double(index) * 0.045
    }

    private func ringScale(_ index: Int) -> Double {
        let base = 0.70 + Double(index) * 0.14
        return base + (pulse ? 0.06 : 0) + level * 0.05
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let base = CGFloat(12 + ((index * 11) % 32))
        return base * CGFloat(0.55 + level * 0.8)
    }
}

@MainActor
private final class VoiceCallController: NSObject, ObservableObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    enum Phase: Equatable {
        case connecting
        case listening
        case sending
        case speaking
        case muted
        case ended

        var title: String {
            switch self {
            case .connecting: return "正在连接…"
            case .listening: return "正在听 · 停顿后自动分段发送"
            case .sending: return "已送出，等小克回答"
            case .speaking: return "小克正在说"
            case .muted: return "已静音"
            case .ended: return "通话结束"
            }
        }

        var color: Color {
            switch self {
            case .listening: return .green
            case .speaking: return .purple
            case .muted: return .orange
            case .ended: return .secondary
            default: return .blue
            }
        }
    }

    @Published private(set) var phase: Phase = .connecting
    @Published private(set) var liveTranscript = ""
    @Published private(set) var aiCaption = ""
    @Published private(set) var level: Double = 0
    @Published private(set) var elapsed = 0
    @Published private(set) var isMuted = false
    @Published private(set) var usesSpeaker = true
    @Published private(set) var errorText: String?

    var timerText: String { String(format: "%02d:%02d", elapsed / 60, elapsed % 60) }

    private weak var model: AppModel?
    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var tapInstalled = false
    private var silenceTask: Task<Void, Never>?
    private var elapsedTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var pendingTranscript = ""
    private var isActive = false
    private var isStoppingInput = false
    private var callID = ""
    private var initialMessageID = 0
    private var handledMessageIDs: Set<Int> = []

    private var fallbackRecorder: AVAudioRecorder?
    private var fallbackURL: URL?
    private var fallbackTask: Task<Void, Never>?
    private var usesAudioSegments = false

    // 这一句话的录音：转写在手机上做，音频跟着转写一起上传——
    // 她的气泡上会长出语音条，服务器那边的耳朵也听得见她是怎么说的。
    private var utteranceFile: AVAudioFile?
    private var utteranceURL: URL?

    private var responseQueue: [(Int, String)] = []
    private var queueTask: Task<Void, Never>?
    private var player: AVAudioPlayer?
    private var playerContinuation: CheckedContinuation<Void, Never>?
    private let systemSpeaker = AVSpeechSynthesizer()
    private var speechContinuation: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        systemSpeaker.delegate = self
    }

    func start(model: AppModel) async {
        guard !isActive else { return }
        self.model = model
        phase = .connecting
        errorText = nil

        let microphoneAllowed = await requestMicrophonePermission()
        guard microphoneAllowed else {
            errorText = "麦克风权限没有打开，请到系统设置里允许 Tidal Echo 使用麦克风。"
            phase = .ended
            return
        }

        do {
            try await configureSession()
            callID = "ios-call-\(UUID().uuidString.lowercased())"
            initialMessageID = model.messages.map(\.id).filter { $0 > 0 }.max() ?? 0
            isActive = true
            try await model.postCallEvent("start", callID: callID)
            startElapsedTimer()

            let speechAllowed = await requestSpeechPermission()
            usesAudioSegments = !speechAllowed || recognizer?.isAvailable != true
            if usesAudioSegments {
                errorText = "实时转写不可用，已改为每 5 秒发送一段录音。"
                try startFallbackSegment()
            } else {
                try startRecognition()
            }
            phase = .listening
        } catch {
            errorText = error.localizedDescription
            phase = .ended
            isActive = false
        }
    }

    func end() async {
        guard isActive else { return }
        isActive = false
        silenceTask?.cancel()
        restartTask?.cancel()
        elapsedTask?.cancel()
        queueTask?.cancel()
        responseQueue.removeAll()

        let finalText = pendingTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingTranscript = ""
        stopInput(discardFallback: false)
        stopSpeechOutput()
        if !finalText.isEmpty, let model {
            _ = try? await model.sendCallTranscript(finalText, callID: callID)
        }
        if let model { try? await model.postCallEvent("end", callID: callID) }
        phase = .ended
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func consume(messages: [ChatMessage]) {
        guard isActive else { return }
        let fresh = messages
            .filter {
                $0.id > initialMessageID && $0.author == .ai &&
                ($0.kind == "reply" || $0.kind == "voice") &&
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !handledMessageIDs.contains($0.id)
            }
            .sorted { $0.id < $1.id }
        guard !fresh.isEmpty else { return }
        for message in fresh {
            handledMessageIDs.insert(message.id)
            responseQueue.append((message.id, message.text))
        }
        drainResponseQueueIfNeeded()
    }

    func toggleMute() {
        guard isActive else { return }
        isMuted.toggle()
        if isMuted {
            stopInput(discardFallback: true)
            phase = .muted
            liveTranscript = ""
        } else if phase != .speaking {
            do {
                if usesAudioSegments { try startFallbackSegment() }
                else { try startRecognition() }
                phase = .listening
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    func toggleSpeaker() {
        usesSpeaker.toggle()
        do {
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(usesSpeaker ? .speaker : .none)
        } catch {
            errorText = "音频输出切换失败：\(error.localizedDescription)"
        }
    }

    private func configureSession() async throws {
        let session = AVAudioSession.sharedInstance()
        for attempt in 0..<4 {
            do {
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
                try session.setActive(true)
                try session.overrideOutputAudioPort(.speaker)
                return
            } catch {
                guard attempt < 3 else { throw error }
                // A full-screen CallKit answer can release its audio session a
                // fraction later than its UI. Give that handoff time to settle.
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }
    }

    private func requestSpeechPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func startElapsedTimer() {
        elapsed = 0
        elapsedTask?.cancel()
        elapsedTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.isActive else { return }
                self.elapsed += 1
            }
        }
    }

    private func startRecognition() throws {
        guard isActive, !isMuted, phase != .speaking, let recognizer else { return }
        stopRecognition()
        isStoppingInput = false
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        recognitionRequest = request

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.isActive, !self.isStoppingInput else { return }
                if let result {
                    let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        self.pendingTranscript = text
                        self.liveTranscript = text
                        self.armSilenceCommit()
                    }
                    if result.isFinal { self.commitTranscript() }
                } else if error != nil {
                    self.restartRecognitionSoon()
                }
            }
        }

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw APIError.server("没有读到麦克风音频") }
        startUtteranceClip(format: format)
        // 录音文件在闭包里强持有：tap 摘掉之前它不会被释放，
        // 音频线程正在写的时候主线程置 nil 也不会写到已经析构的对象上。
        let clipFile = utteranceFile
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
            try? clipFile?.write(from: buffer)
            guard let channel = buffer.floatChannelData?.pointee else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }
            var sum: Float = 0
            for index in stride(from: 0, to: frames, by: 8) { sum += channel[index] * channel[index] }
            let rms = sqrt(sum / Float(max(1, frames / 8)))
            Task { @MainActor [weak self] in self?.level = min(1, Double(rms) * 9) }
        }
        tapInstalled = true
        audioEngine.prepare()
        try audioEngine.start()
        phase = .listening
    }

    private struct CallClip {
        let data: Data
        let name: String
        let mime: String
    }

    private func startUtteranceClip(format: AVAudioFormat) {
        discardUtteranceClip()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("call-say-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 32_000
        ]
        // 录不成也不能影响通话本身——转写照走，只是这句没有声音留下来。
        utteranceFile = try? AVAudioFile(forWriting: url, settings: settings)
        utteranceURL = utteranceFile == nil ? nil : url
    }

    /// 收走这一句的录音（要在 tap 停掉之后调，文件才是完整的）。
    private func takeUtteranceClip() -> CallClip? {
        utteranceFile = nil                       // 释放 = 收尾落盘
        guard let url = utteranceURL else { return nil }
        utteranceURL = nil
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url), data.count > 2_000 else { return nil }
        return CallClip(
            data: data,
            name: "call-\(Int(Date().timeIntervalSince1970)).m4a",
            mime: "audio/mp4"
        )
    }

    private func discardUtteranceClip() {
        utteranceFile = nil
        if let utteranceURL { try? FileManager.default.removeItem(at: utteranceURL) }
        utteranceURL = nil
    }

    private func armSilenceCommit() {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_250_000_000)
            guard !Task.isCancelled, let self else { return }
            self.commitTranscript()
        }
    }

    private func commitTranscript() {
        let text = pendingTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, isActive else { return }
        pendingTranscript = ""
        liveTranscript = ""
        silenceTask?.cancel()
        stopRecognition()
        let clip = takeUtteranceClip()      // 停了 tap 才收，不然文件是半截的
        phase = .sending

        if !isMuted {
            restartTask?.cancel()
            restartTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 180_000_000)
                guard let self, self.isActive, self.phase != .speaking else { return }
                try? self.startRecognition()
            }
        }
        if let model {
            Task {
                do {
                    if let clip {
                        _ = try await model.sendCallUtterance(
                            text: text, data: clip.data, name: clip.name,
                            mime: clip.mime, callID: callID
                        )
                    } else {
                        _ = try await model.sendCallTranscript(text, callID: callID)
                    }
                } catch {
                    self.errorText = "这一段没有送出去：\(error.localizedDescription)"
                }
            }
        }
    }

    private func restartRecognitionSoon() {
        guard isActive, !isMuted, phase != .speaking else { return }
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard let self, self.isActive, !self.isMuted, self.phase != .speaking else { return }
            try? self.startRecognition()
        }
    }

    private func stopRecognition() {
        isStoppingInput = true
        if audioEngine.isRunning { audioEngine.stop() }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        level = 0
    }

    private func startFallbackSegment() throws {
        guard isActive, !isMuted, phase != .speaking else { return }
        stopFallback(discard: true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("call-segment-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 24_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 40_000,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
        let next = try AVAudioRecorder(url: url, settings: settings)
        next.isMeteringEnabled = true
        guard next.prepareToRecord(), next.record() else { throw APIError.server("分段录音启动失败") }
        fallbackRecorder = next
        fallbackURL = url
        phase = .listening
        fallbackTask = Task { [weak self] in
            for _ in 0..<50 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, let recorder = self.fallbackRecorder, self.isActive else { return }
                recorder.updateMeters()
                self.level = max(0.04, min(1, pow(10, Double(recorder.averagePower(forChannel: 0)) / 38)))
            }
            guard let self, self.isActive else { return }
            self.finishFallbackAndUpload()
        }
    }

    private func finishFallbackAndUpload() {
        guard let recorder = fallbackRecorder, let url = fallbackURL else { return }
        let duration = recorder.currentTime
        recorder.stop()
        fallbackRecorder = nil
        fallbackURL = nil
        fallbackTask?.cancel()
        fallbackTask = nil
        level = 0
        let data = try? Data(contentsOf: url)
        try? FileManager.default.removeItem(at: url)
        if isActive, !isMuted, phase != .speaking { try? startFallbackSegment() }
        guard duration >= 0.8, let data, !data.isEmpty, let model else { return }
        phase = .sending
        Task {
            do {
                _ = try await model.sendCallAudioSegment(
                    data: data,
                    name: "call-\(Int(Date().timeIntervalSince1970)).m4a",
                    mime: "audio/mp4",
                    callID: callID
                )
            } catch {
                self.errorText = "一段录音上传失败：\(error.localizedDescription)"
            }
        }
    }

    private func stopFallback(discard: Bool) {
        fallbackTask?.cancel()
        fallbackTask = nil
        fallbackRecorder?.stop()
        fallbackRecorder = nil
        if let fallbackURL {
            if !discard, let data = try? Data(contentsOf: fallbackURL), !data.isEmpty, let model {
                Task {
                    _ = try? await model.sendCallAudioSegment(
                        data: data,
                        name: "call-last.m4a",
                        mime: "audio/mp4",
                        callID: callID
                    )
                }
            }
            try? FileManager.default.removeItem(at: fallbackURL)
        }
        fallbackURL = nil
        level = 0
    }

    private func stopInput(discardFallback: Bool) {
        stopRecognition()
        discardUtteranceClip()
        stopFallback(discard: discardFallback)
    }

    /// 我说完话之后重新开耳朵。
    /// ⚠️ 必须先把 phase 从 .speaking 落回来再启动——startRecognition/startFallbackSegment
    /// 自己带着 `phase != .speaking` 的守卫，先启动后改 phase 会被那个守卫原地挡掉，
    /// 于是她说完第一句、我回完一句之后，麦克风就再也没开过（"只能说一句话"）。
    private func resumeListeningAfterSpeaking() {
        guard isActive, !isMuted, phase == .speaking || phase == .sending else { return }
        phase = .listening
        do {
            if usesAudioSegments { try startFallbackSegment() }
            else { try startRecognition() }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func drainResponseQueueIfNeeded() {
        guard queueTask == nil else { return }
        queueTask = Task { [weak self] in
            guard let self else { return }
            while self.isActive, !self.responseQueue.isEmpty {
                let item = self.responseQueue.removeFirst()
                await self.speak(text: item.1, messageID: item.0)
            }
            self.queueTask = nil
            self.resumeListeningAfterSpeaking()   // 我说完了，把耳朵还给她
        }
    }

    private func speak(text: String, messageID: Int) async {
        guard isActive, let model else { return }
        stopInput(discardFallback: true)
        phase = .speaking
        liveTranscript = ""
        aiCaption = text
        level = 0.78
        do {
            let data = try await model.synthesizeSpeech(text: text, messageID: messageID, persist: true)
            try await configureSession()
            await play(data: data)
        } catch {
            await speakWithSystemVoice(text)
        }
        level = 0
        aiCaption = ""
        // 这里不开麦：队列里可能还有下一条要念（会把我自己的声音录进去）。
        // 全部念完之后由 drainResponseQueueIfNeeded 统一把耳朵还给她。
    }

    private func play(data: Data) async {
        await withCheckedContinuation { continuation in
            do {
                let next = try AVAudioPlayer(data: data)
                next.delegate = self
                next.prepareToPlay()
                player = next
                playerContinuation = continuation
                if !next.play() {
                    playerContinuation = nil
                    continuation.resume()
                }
            } catch {
                continuation.resume()
            }
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        self.player = nil
        playerContinuation?.resume()
        playerContinuation = nil
    }

    private func speakWithSystemVoice(_ text: String) async {
        await withCheckedContinuation { continuation in
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
            utterance.rate = 0.48
            speechContinuation = continuation
            systemSpeaker.speak(utterance)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        speechContinuation?.resume()
        speechContinuation = nil
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        speechContinuation?.resume()
        speechContinuation = nil
    }

    private func stopSpeechOutput() {
        player?.stop()
        player = nil
        playerContinuation?.resume()
        playerContinuation = nil
        if systemSpeaker.isSpeaking { systemSpeaker.stopSpeaking(at: .immediate) }
        speechContinuation?.resume()
        speechContinuation = nil
    }
}
