#if os(iOS)
import SwiftUI
import AVFoundation
import Domain

struct AudioRecorderSheet: View {
    let send: (Data) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var recorder: AVAudioRecorder?
    @State private var preview: AVAudioPlayer?
    @State private var previewPlaying = false
    @State private var fileURL: URL?
    @State private var elapsed = 0.0
    @State private var recording = false
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 26) {
                Image(systemName: recording ? "waveform.circle.fill" : "mic.circle.fill")
                    .font(.system(size: 72)).foregroundStyle(SpaceStyle.accent)
                    .symbolEffect(.pulse, isActive: recording)
                Text(format(elapsed)).font(.title.monospacedDigit())
                Text(recording ? "正在录音，最长 60 秒" : fileURL == nil ? "轻点开始录音" : "可以试听或发送")
                    .foregroundStyle(.secondary)
                HStack(spacing: 18) {
                    if fileURL == nil {
                        Button("开始录音", systemImage: "mic.fill") { Task { await start() } }
                            .buttonStyle(.borderedProminent)
                    } else if recording {
                        Button("停止", systemImage: "stop.fill") { stop() }.buttonStyle(.borderedProminent)
                    } else {
                        Button(previewPlaying ? "暂停" : "试听", systemImage: previewPlaying ? "pause.fill" : "play.fill") { togglePreview() }
                            .buttonStyle(.bordered)
                        Button("重录", role: .destructive) { reset() }.buttonStyle(.bordered)
                        Button("发送", systemImage: "arrow.up.circle.fill") { sendRecording() }
                            .buttonStyle(.borderedProminent).disabled(sending)
                    }
                }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
            .navigationTitle("语音消息").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
        .interactiveDismissDisabled(recording || sending)
        .task(id: recording) {
            while recording {
                elapsed = recorder?.currentTime ?? elapsed
                if elapsed >= 60 { stop(); break }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        .task(id: previewPlaying) {
            while previewPlaying {
                try? await Task.sleep(for: .milliseconds(200))
                if preview?.isPlaying != true { previewPlaying = false }
            }
        }
        .onDisappear { recorder?.stop(); preview?.stop(); cleanup() }
    }

    private func start() async {
        guard await AVAudioApplication.requestRecordPermission() else {
            error = "请在系统设置中允许“我们”使用麦克风。"; return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
            try session.setActive(true)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                           AVSampleRateKey: 24_000,
                                           AVNumberOfChannelsKey: 1,
                                           AVEncoderBitRateKey: 64_000]
            let value = try AVAudioRecorder(url: url, settings: settings)
            value.prepareToRecord(); guard value.record(forDuration: 60) else { throw SpaceError.invalidInput }
            recorder = value; fileURL = url; elapsed = 0; recording = true; error = nil
        } catch { self.error = "无法开始录音，请重试。" }
    }
    private func stop() {
        let duration = recorder?.currentTime
        recorder?.stop(); elapsed = duration ?? elapsed; recorder = nil; recording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    private func togglePreview() {
        if previewPlaying { preview?.pause(); previewPlaying = false; return }
        guard let fileURL else { return }
        do { preview = try AVAudioPlayer(contentsOf: fileURL); previewPlaying = preview?.play() == true }
        catch { self.error = "暂时无法试听。" }
    }
    private func sendRecording() {
        guard let fileURL else { return }
        sending = true
        Task {
            defer { sending = false }
            do {
                let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
                guard (1...(10 * 1024 * 1024)).contains(data.count) else { throw SpaceError.capacity }
                try await send(data); dismiss()
            } catch { self.error = "语音发送失败，录音仍然保留。" }
        }
    }
    private func reset() { preview?.stop(); preview = nil; previewPlaying = false; cleanup(); elapsed = 0; error = nil }
    private func cleanup() { if let fileURL { try? FileManager.default.removeItem(at: fileURL) }; fileURL = nil }
    private func format(_ seconds: TimeInterval) -> String { String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60) }
}

struct AudioBubble: View {
    let id: UUID
    let load: (UUID) async throws -> Data?
    let refresh: Date?
    var interrupted = false
    var progress: () async -> Double? = { nil }
    var retry: () async -> Void = {}
    @Environment(\.scenePhase) private var scenePhase
    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var transferProgress: Double?
    @State private var timedOut = false
    @State private var retryNonce = 0

    var body: some View {
        HStack(spacing: 12) {
            Button {
                if isPlaying { player?.pause(); isPlaying = false }
                else {
                    if player?.currentTime == player?.duration { player?.currentTime = 0 }
                    isPlaying = player?.play() == true
                }
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 34, height: 34).background(SpaceStyle.accent.opacity(0.16), in: Circle())
            }.disabled(player == nil)
            VStack(alignment: .leading, spacing: 5) {
                Text(player.map { format($0.duration) } ?? (timedOut || interrupted ? "语音传输中断" : "正在安全传输语音"))
                    .font(.subheadline)
                if let transferProgress, player == nil { ProgressView(value: transferProgress).frame(width: 110) }
            }
            if player == nil && (timedOut || interrupted) {
                Button("重试") { timedOut = false; retryNonce += 1; Task { await retry() } }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(12).background(SpaceStyle.softSurface, in: RoundedRectangle(cornerRadius: 18))
        .task(id: "\(scenePhase)-\(refresh?.timeIntervalSince1970 ?? 0)-\(retryNonce)") {
            guard scenePhase == .active else { return }
            for attempt in 0..<12 {
                if let data = try? await load(id), let value = try? AVAudioPlayer(data: data) {
                    player = value; timedOut = false; break
                }
                transferProgress = await progress()
                if attempt == 11 { timedOut = true; break }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .task(id: isPlaying) {
            while isPlaying {
                try? await Task.sleep(for: .milliseconds(200))
                if player?.isPlaying != true { isPlaying = false }
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { player?.pause(); isPlaying = false } }
        .onDisappear { player?.stop(); player = nil; isPlaying = false }
        .accessibilityIdentifier("chat-audio")
    }
    private func format(_ seconds: TimeInterval) -> String { String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60) }
}
#endif
