import CoreMedia
import NaturalLanguage
@preconcurrency import Speech

/// Capture buffers are retained, and both the writer and recognizer only read them.
struct MicrophoneSpeechSample: @unchecked Sendable {
    let buffer: CMSampleBuffer
}

enum StudioPrompterSpeech {
    enum Update { case sessionStarted, words(String), unavailable(String) }
    private enum Event: Sendable { case words(String), ended(normally: Bool) }

    static func language(for script: String) -> Locale {
        let preferred = Locale(identifier: Locale.preferredLanguages.first ?? "zh-CN")
        guard let language = NLLanguageRecognizer.dominantLanguage(for: String(script.prefix(1200))) else {
            return preferred
        }
        if language == .simplifiedChinese { return Locale(identifier: "zh-CN") }
        if language == .traditionalChinese { return Locale(identifier: "zh-TW") }
        if preferred.language.languageCode?.identifier == language.rawValue { return preferred }
        return Locale(identifier: language.rawValue)
    }

    @MainActor
    static func follow(_ microphone: MicrophoneRecorder, locale: Locale, update: (Update) -> Void) async {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
            update(.unavailable("本机暂不支持此稿件语言的跟读，可手动翻行"))
            return
        }
        let permission = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { @Sendable state in continuation.resume(returning: state) }
        }
        guard !Task.isCancelled else { return }
        guard permission == .authorized else {
            update(.unavailable("语音识别未授权，可手动翻行"))
            return
        }

        var failures = 0
        while !Task.isCancelled {
            guard recognizer.isAvailable else { break }
            update(.sessionStarted)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            request.taskHint = .dictation
            let (events, sink) = AsyncStream<Event>.makeStream()
            let recognition = recognizer.recognitionTask(with: request) { @Sendable result, error in
                if let result { sink.yield(.words(result.bestTranscription.formattedString)) }
                if error != nil || result?.isFinal == true {
                    sink.yield(.ended(normally: error == nil || (error as NSError?)?.code == 1110))
                    sink.finish()
                }
            }
            let samples = microphone.speechSamples()
            let feeder = Task.detached(priority: .utility) {
                for await sample in samples {
                    if Task.isCancelled { break }
                    request.appendAudioSampleBuffer(sample.buffer)
                }
                request.endAudio()
            }
            for await event in events {
                guard !Task.isCancelled else { break }
                switch event {
                case let .words(text) where !text.isEmpty:
                    update(.words(text))
                    failures = 0
                case .ended(normally: false): failures += 1
                default: break
                }
            }
            feeder.cancel()
            await feeder.value
            recognition.cancel()
            guard !Task.isCancelled else { break }
            guard failures < 3 else { break }
            try? await Task.sleep(for: .milliseconds(failures == 0 ? 100 : 700))
        }
        if !Task.isCancelled { update(.unavailable("跟读暂不可用，可手动翻行")) }
    }
}
