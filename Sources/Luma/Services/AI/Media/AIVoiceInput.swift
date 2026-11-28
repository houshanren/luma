import Foundation
import AVFoundation
import Speech
import Combine

/// 语音输入：系统 Speech 转文字，优先端侧识别；只在用户点击麦克风时录音。
@MainActor
final class AIVoiceInput: ObservableObject {
    static let shared = AIVoiceInput()

    @Published private(set) var isRecording = false
    @Published private(set) var transcript = ""
    @Published private(set) var error: String?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapInstalled = false

    private init() {}

    func start() async {
        guard !isRecording else { return }
        error = nil
        transcript = ""

        guard await requestSpeechAuthorization() else {
            error = "没有语音识别权限，请在系统设置 › 隐私与安全性 › 语音识别中允许拾光"
            return
        }
        guard await requestMicrophoneAuthorization() else {
            error = "没有麦克风权限，请在系统设置 › 隐私与安全性 › 麦克风中允许拾光"
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")),
              recognizer.isAvailable else {
            error = "当前系统语音识别不可用"
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // 优先端侧：不支持的语种 / 设备再退回系统默认路径。
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            error = "没有可用的麦克风输入"
            return
        }
        if tapInstalled {
            input.removeTap(onBus: 0)
            tapInstalled = false
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            self.error = "麦克风启动失败：\(error.localizedDescription)"
            cleanupAudio()
            return
        }

        isRecording = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.stop()
                        return
                    }
                }
                if error != nil {
                    self.stop()
                }
            }
        }
    }

    func stop() {
        guard isRecording || tapInstalled else { return }
        isRecording = false
        cleanupAudio()
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    func reset() {
        stop()
        transcript = ""
        error = nil
    }

    private func cleanupAudio() {
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }

    private func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func requestMicrophoneAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
