import AVFoundation
import Foundation

/// One audio session and one `AVAudioEngine` for both directions.
///
/// The computer's sound is played through the same voice-processing unit that
/// captures this device's microphone, so the speaker output is the echo
/// canceller's reference and the meeting's far end does not hear itself.
/// Two separate engines cannot provide that reference, and iOS sometimes
/// refuses to activate the session for the second one (`!act`, 561015905),
/// which is what made the microphone die mid-meeting.
///
/// When the microphone is off the session switches to `.playback`, so media
/// audio keeps its full quality; it switches to `.playAndRecord`/`.voiceChat`
/// only while the sender says a meeting on this screen needs the microphone.
final class AudioHub {
    /// 20 ms blocks at 48 kHz, mono s16, little-endian.
    var onMicPcm: ((Data) -> Void)?
    /// (running, reason): reason empty on success, "denied"/"unavailable".
    var onMicState: ((Bool, String) -> Void)?

    private let queue = DispatchQueue(label: "com.opendisplay.audio", qos: .userInteractive)
    // Rebuilt on every mode switch: an engine that has run voice processing
    // cannot reliably start again in .playback (kAUStartIO, 2003329396).
    private var engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                           sampleRate: 48_000,
                                           channels: 2,
                                           interleaved: true)!
    private let micFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                          sampleRate: 48_000,
                                          channels: 1,
                                          interleaved: true)!
    private var micConverter: AVAudioConverter?
    private var micDesired = false
    private var micRunning = false
    private var micRetries = 0
    private var playbackWanted = false
    private var voiceActive = false
    private var paused = false
    private var pendingFrames = 0
    private var startFailures = 0
    private var lastStartAttempt: TimeInterval = 0
    private var lastConfigured: TimeInterval = 0
    private var observers: [NSObjectProtocol] = []

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        #if os(iOS)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange,
                                           object: nil,
                                           queue: nil) { [weak self] note in
            guard let self, (note.object as? AVAudioEngine) === self.engine else { return }
            self.queue.async { self.handleConfigurationChange() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                           object: nil,
                                           queue: nil) { [weak self] _ in
            self?.queue.async { self?.handleMediaServicesReset() }
        })
        #endif
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Playback

    /// Called from the network queue: hand the frame over, never block it.
    func play(pcm: Data) {
        queue.async { [weak self] in
            self?.playOnQueue(pcm)
        }
    }

    private func playOnQueue(_ pcm: Data) {
        let frames = pcm.count / 4                 // 2 channels × 2 bytes
        guard frames > 0 else { return }
        playbackWanted = true
        guard ensureEngine() else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: playFormat,
                                            frameCapacity: AVAudioFrameCount(frames)),
              let dst = buffer.int16ChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                memcpy(dst, base, pcm.count)
            }
        }

        pendingFrames += frames
        player.scheduleBuffer(buffer, completionCallbackType: .dataRendered) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.pendingFrames = max(0, self.pendingFrames - frames)
            }
        }

        // A stalled link can deliver a burst; drop the queue rather than let
        // latency grow without bound. 300 ms is well past normal jitter.
        if pendingFrames > 48_000 * 3 / 10 {
            player.stop()
            pendingFrames = 0
            player.play()
        }
    }

    private func ensureEngine() -> Bool {
        if engine.isRunning {
            if !player.isPlaying { player.play() }
            return true
        }
        let now = Date().timeIntervalSince1970
        // Throttle by rate, not by total count: a mic that failed three times
        // must still revive when the consumer returns minutes later.
        if startFailures >= 3 && now - lastStartAttempt < 1 {
            return false
        }
        if startFailures >= 3 { startFailures = 0 } // a fresh attempt each epoch
        lastStartAttempt = now
        do {
            try applyMode(voice: micRunning)
            startFailures = 0
            return true
        } catch {
            startFailures += 1
            if startFailures <= 3 {
                Log.info("audio: engine start failed (\(startFailures)): \(error)")
            }
            return false
        }
    }

    // MARK: - Microphone

    /// The sender asks for the microphone only while an app on this screen is
    /// actually recording through the virtual microphone.
    func setMicEnabled(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            if enabled {
                self.startMicOnQueue()
            } else {
                self.stopMicOnQueue(keepDesired: false)
            }
        }
    }

    /// Background/foreground: stop capturing without forgetting that the
    /// sender still wants the microphone.
    func setPaused(_ paused: Bool) {
        queue.async { [weak self] in
            guard let self, paused != self.paused else { return }
            self.paused = paused
            if paused {
                self.stopMicOnQueue(keepDesired: true)
            } else if self.micDesired {
                self.startMicOnQueue()
            }
        }
    }

    private func startMicOnQueue() {
        micDesired = true
        guard !paused, !micRunning else { return }
        #if os(iOS)
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            break
        case .undetermined:
            AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
                guard let self else { return }
                self.queue.async {
                    if granted {
                        self.startMicOnQueue()
                    } else {
                        self.micDesired = false
                        self.onMicState?(false, "denied")
                    }
                }
            }
            return
        default:
            micDesired = false
            onMicState?(false, "denied")
            return
        }
        #endif
        do {
            try applyMode(voice: true)
            micRunning = true
            micRetries = 0
            Log.info("mic: capturing with voice processing")
            onMicState?(true, "")
        } catch {
            micRunning = false
            Log.info("mic: start failed: \(error)")
            // A partly configured voice mode (category set, tap installed,
            // engine not running) must be unwound before returning to playback.
            #if os(iOS)
            let input = engine.inputNode
            input.removeTap(onBus: 0)
            try? input.setVoiceProcessingEnabled(false)
            #endif
            voiceActive = false
            // Keep playback alive and keep trying: the sender only sends the
            // enable flag on transitions, so if the consumer comes back after
            // a stop (meeting closed, then the mic-test pressed), nobody
            // re-sends it — the engine must revive on its own. Retries are
            // capped in rate, not in count (one attempt every 5 s).
            micRetries += 1
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.micDesired, !self.micRunning, !self.paused else { return }
                Log.info("mic: retrying capture (attempt \(self.micRetries))")
                self.startMicOnQueue()
            }
            try? applyMode(voice: false)
        }
    }

    private func stopMicOnQueue(keepDesired: Bool) {
        if !keepDesired { micDesired = false }
        guard micRunning else { return }
        micRunning = false
        do {
            try applyMode(voice: false)
            Log.info("mic: stopped")
        } catch {
            Log.info("mic: stop failed: \(error)")
            engine.stop()
            // Leave voiceActive set: the next start will run the full
            // voice-unit teardown instead of assuming playback mode is live.
        }
        onMicState?(false, "")
    }

    private func handleMic(_ buffer: AVAudioPCMBuffer) {
        guard micRunning, let converter = micConverter else { return }
        let ratio = micFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: micFormat, frameCapacity: capacity) else {
            return
        }
        var supplied = false
        var conversionError: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        converter.convert(to: out, error: &conversionError, withInputFrom: inputBlock)
        if conversionError != nil { return }
        guard out.frameLength > 0, let samples = out.int16ChannelData?[0] else { return }
        onMicPcm?(Data(bytes: samples, count: Int(out.frameLength) * 2))
    }

    // MARK: - Session and engine

    /// Stop the engine, switch the session's mode, install or remove the mic
    /// tap, then start again. Everything happens on the audio queue.
    /// Rebuild the engine for the requested direction. A fresh AVAudioEngine
    /// is the only reliable reset: an engine that has run voice processing
    /// keeps a stale voice I/O unit, and starting it again in `.playback`
    /// fails with CoreAudio's kAUStartIO (2003329396).
    private func applyMode(voice: Bool) throws {
        let old = engine
        // Our own category switches also announce a configuration change;
        // record the time before touching anything so the observer ignores it.
        lastConfigured = Date().timeIntervalSince1970
        old.stop()
        player.stop()
        pendingFrames = 0
        if voiceActive {
            old.inputNode.removeTap(onBus: 0)
            try? old.inputNode.setVoiceProcessingEnabled(false)
        }
        old.detach(player)
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // Release the voice-processing I/O unit before switching categories.
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        try session.setCategory(voice ? .playAndRecord : .playback,
                                mode: voice ? .voiceChat : .default,
                                options: voice ? [.defaultToSpeaker] : [.mixWithOthers])
        try session.setActive(true)
        #endif
        let fresh = AVAudioEngine()
        fresh.attach(player)
        fresh.connect(player, to: fresh.mainMixerNode, format: playFormat)
        #if os(iOS)
        if voice {
            let input = fresh.inputNode
            try input.setVoiceProcessingEnabled(true)
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw NSError(domain: "OpenDisplay", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "no microphone input"])
            }
            micConverter = AVAudioConverter(from: inputFormat, to: micFormat)
            input.installTap(onBus: 0, bufferSize: 960, format: inputFormat) { [weak self] buffer, _ in
                self?.handleMic(buffer)
            }
            Log.info("audio: voice processing (echo cancellation) on")
        }
        #endif
        engine = fresh
        fresh.prepare()
        try fresh.start()
        voiceActive = voice
        player.play()
        #if os(iOS)
        Log.info("audio: engine running (\(voice ? "voice" : "playback"), output volume \(session.outputVolume))")
        #else
        Log.info("audio: engine running (\(voice ? "voice" : "playback"))")
        #endif
    }

    private func handleConfigurationChange() {
        // Our own category switches also announce a configuration change.
        guard Date().timeIntervalSince1970 - lastConfigured > 1 else { return }
        guard voiceActive || micRunning || playbackWanted else { return }
        Log.info("audio: engine configuration changed; restarting")
        do {
            try applyMode(voice: micRunning)
        } catch {
            Log.info("audio: restart failed: \(error)")
            voiceActive = false
            micRunning = false
            if micDesired { startMicOnQueue() }
        }
    }

    private func handleMediaServicesReset() {
        Log.info("audio: media services reset")
        voiceActive = false
        micRunning = false
        micConverter = nil
        startFailures = 0
        if micDesired {
            startMicOnQueue()
        } else if playbackWanted {
            _ = ensureEngine()
        }
    }

    /// Disconnect: no microphone, no playback, and let other apps have the
    /// audio route back.
    func stopAll() {
        queue.async { [weak self] in
            guard let self else { return }
            self.micDesired = false
            self.micRunning = false
            self.playbackWanted = false
            self.paused = false
            self.pendingFrames = 0
            if self.voiceActive {
                let input = self.engine.inputNode
                input.removeTap(onBus: 0)
                try? input.setVoiceProcessingEnabled(false)
                self.voiceActive = false
            }
            self.player.stop()
            self.engine.stop()
            self.micConverter = nil
            #if os(iOS)
            try? AVAudioSession.sharedInstance()
                .setActive(false, options: .notifyOthersOnDeactivation)
            #endif
        }
    }
}
