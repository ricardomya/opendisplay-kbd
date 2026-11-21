import AVFoundation
import Foundation
import VideoToolbox

/// Captures this device's camera, hardware-encodes H.264 with a low-latency
/// rate control and emits `ODCM` payloads (32-byte header + Annex B access
/// unit) for the Windows sender's virtual camera.
///
/// Local extension, mirroring AudioHub's playback role: the sender asks with
/// `cameraConfig`, this streams `ODCM` frames back on the same TCP session,
/// and `cameraState` reports why nothing arrives when it cannot.
final class CameraSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    struct Config {
        var width: Int32 = 1280
        var height: Int32 = 720
        var fps: Int32 = 30
        var bitrate: Int = 2_500_000
        var position: AVCaptureDevice.Position = .front
        var mirror: Bool = false
    }

    /// Delivery queue for encoded frames: one whole access unit per call.
    var onFrame: ((Data, Bool) -> Void)?
    /// (enabled, reason): reason is empty on success, or "denied"/"no camera".
    var onState: ((Bool, String) -> Void)?

    private let queue = DispatchQueue(label: "com.opendisplay.camera", qos: .userInteractive)
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()

    private var encoder: VTCompressionSession?
    private var config = Config()
    private var running = false
    private var wantsKeyframe = true
    private var sequence: UInt32 = 0
    private var lastKeyframeAt = CMTime.invalid
    private var droppedTooLarge = 0

    // MARK: - Public

    func start(_ config: Config) {
        queue.async { self.startOnQueue(config) }
    }

    func stop() {
        queue.async { self.stopOnQueue() }
    }

    func requestKeyframe() {
        queue.async { self.wantsKeyframe = true }
    }

    // MARK: - Session setup (camera queue)

    private func startOnQueue(_ config: Config) {
        guard !running else {
            self.config = config
            return
        }
        self.config = config

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setUpAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                self.queue.async {
                    if granted {
                        self.setUpAndRun()
                    } else {
                        self.onState?(false, "denied")
                    }
                }
            }
        default:
            onState?(false, "denied")
        }
    }

    private func setUpAndRun() {
        guard !running else { return }
        guard configureSession() else { return }
        guard let encoder = makeEncoder() else {
            onState?(false, "encoder")
            return
        }
        self.encoder = encoder
        lastKeyframeAt = .invalid
        wantsKeyframe = true
        session.startRunning()   // blocking; this is the camera queue
        running = true
        Log.info("camera: capturing \(config.width)x\(config.height)@\(config.fps) \(config.position == .front ? "front" : "back")")
        onState?(true, "")
    }

    private func configureSession() -> Bool {
        if !session.inputs.isEmpty {
            session.inputs.forEach { session.removeInput($0) }
        }
        // The output is a single instance kept across starts; leaving it
        // attached makes canAddOutput fail on the second start after an
        // on-demand stop ("no camera", and the sender then serves a green
        // frame). Detach whatever a previous start left behind.
        if !session.outputs.isEmpty {
            session.outputs.forEach { session.removeOutput($0) }
        }

        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .builtInTrueDepthCamera]
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types,
                                                         mediaType: .video,
                                                         position: config.position)
        guard let device = discovery.devices.first else {
            Log.info("camera: no device for position \(config.position.rawValue)")
            onState?(false, "no camera")
            return false
        }
        guard let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            onState?(false, "no camera")
            return false
        }
        session.addInput(input)

        if session.canSetSessionPreset(.inputPriority) {
            session.sessionPreset = .inputPriority
        }

        // Pick the requested size (or the closest one that can do 30 fps).
        let wanted = CMVideoDimensions(width: config.width, height: config.height)
        var best: AVCaptureDevice.Format?
        var bestScore = Int.max
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let canDoFps = format.videoSupportedFrameRateRanges.contains {
                $0.maxFrameRate >= Double(config.fps)
            }
            guard canDoFps else { continue }
            let score = abs(Int(dims.width) - Int(wanted.width))
                + abs(Int(dims.height) - Int(wanted.height))
            if score < bestScore {
                best = format
                bestScore = score
            }
        }
        if let best, (try? device.lockForConfiguration()) != nil {
            device.activeFormat = best
            let frameDuration = CMTime(value: 1, timescale: config.fps)
            if let range = best.videoSupportedFrameRateRanges.first,
               range.minFrameRate <= Double(config.fps), range.maxFrameRate >= Double(config.fps) {
                device.activeVideoMinFrameDuration = frameDuration
                device.activeVideoMaxFrameDuration = frameDuration
            }
            device.unlockForConfiguration()
            let dims = CMVideoFormatDescriptionGetDimensions(best.formatDescription)
            config.width = dims.width
            config.height = dims.height
        }

        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) {
            session.addOutput(output)
        } else {
            onState?(false, "no camera")
            return false
        }

        // AudioHub owns the app's audio session; capture must not rewrite it.
        session.automaticallyConfiguresApplicationAudioSession = false

        if let connection = output.connection(with: .video) {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = config.mirror
            #if os(iOS)
            if #available(iOS 17.0, *) {
                let coordinator = AVCaptureDevice.RotationCoordinator(device: device,
                                                                      previewLayer: nil)
                let angle = coordinator.videoRotationAngleForHorizonLevelCapture
                if connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
            }
            #endif
        }
        return true
    }

    private func makeEncoder() -> VTCompressionSession? {
        let specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
        ]
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: config.width,
            height: config.height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: cameraEncodeCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session)
        guard status == noErr, let session else {
            Log.info("camera: VTCompressionSessionCreate failed (\(status))")
            return nil
        }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime,
                             value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering,
                             value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: NSNumber(value: config.fps))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: NSNumber(value: config.bitrate))
        // Hard cap: ~1.6x the average over one second, so a burst can never
        // approach the wire's 1 MiB per-frame limit.
        let cap = NSNumber(value: Int(Double(config.bitrate) / 8.0 * 1.6))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                             value: [cap, NSNumber(value: 1)] as CFArray)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: NSNumber(value: config.fps * 2))
        VTCompressionSessionPrepareToEncodeFrames(session)
        return session
    }

    private func stopOnQueue() {
        guard running || encoder != nil else { return }
        running = false
        if session.isRunning {
            session.stopRunning()
        }
        if let encoder {
            VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(encoder)
        }
        encoder = nil
        lastKeyframeAt = .invalid
        Log.info("camera: stopped")
    }

    // MARK: - Capture

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard running, let encoder,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if lastKeyframeAt.isValid {
            let since = CMTimeGetSeconds(CMTimeSubtract(pts, lastKeyframeAt))
            if since.isFinite && since >= 2.0 {
                wantsKeyframe = true
            }
        }
        var properties: CFDictionary?
        if wantsKeyframe {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            wantsKeyframe = false
        }
        VTCompressionSessionEncodeFrame(encoder,
                                        imageBuffer: imageBuffer,
                                        presentationTimeStamp: pts,
                                        duration: .invalid,
                                        frameProperties: properties,
                                        sourceFrameRefcon: nil,
                                        infoFlagsOut: nil)
    }

    // MARK: - Encoded output (VideoToolbox thread)

    fileprivate func handleEncoded(_ sampleBuffer: CMSampleBuffer) {
        guard running else { return }
        let keyframe = !isNotSync(sampleBuffer)
        guard let payload = annexBPayload(sampleBuffer, keyframe: keyframe) else { return }
        if keyframe {
            lastKeyframeAt = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        }

        var frame = ODCMHeader(keyframe: keyframe,
                               sequence: sequence,
                               timestampMs: UInt64(Date().timeIntervalSince1970 * 1000),
                               payloadLength: UInt32(payload.count))
        sequence &+= 1
        let total = 32 + payload.count
        guard total <= 1_048_575 else {
            droppedTooLarge += 1
            if droppedTooLarge == 1 || droppedTooLarge % 30 == 0 {
                Log.info("camera: frame too large for the wire (\(total) bytes, \(droppedTooLarge) dropped)")
            }
            return
        }
        var data = frame.bytes
        data.append(payload)
        onFrame?(data, keyframe)
    }

    private func isNotSync(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                       createIfNecessary: false)
                as? [[String: Any]],
              let first = attachments.first else { return false }
        return first[kCMSampleAttachmentKey_NotSync as String] as? Bool ?? false
    }

    /// AVCC (length-prefixed NAL units) to Annex B, with SPS/PPS repeated in
    /// front of every IDR so a decoder that joined late can start.
    private func annexBPayload(_ sampleBuffer: CMSampleBuffer, keyframe: Bool) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(block,
                                                 atOffset: 0,
                                                 lengthAtOffsetOut: nil,
                                                 totalLengthOut: &length,
                                                 dataPointerOut: &pointer)
        guard status == kCMBlockBufferNoErr, let pointer else { return nil }

        var out = Data()
        if keyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            for index in 0..<2 {
                var parameter: UnsafePointer<UInt8>?
                var size = 0
                var count = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format,
                    parameterSetIndex: index,
                    parameterSetPointerOut: &parameter,
                    parameterSetSizeOut: &size,
                    parameterSetCountOut: &count,
                    nalUnitHeaderLengthOut: nil) == noErr,
                   let parameter, size > 0 {
                    out.append(contentsOf: [0, 0, 0, 1])
                    out.append(parameter, count: size)
                }
            }
        }

        var offset = 0
        while offset + 4 <= length {
            let raw = UnsafeRawPointer(pointer).loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            let nalLength = UInt32(bigEndian: raw)
            offset += 4
            let size = Int(nalLength)
            guard size > 0, offset + size <= length else { return nil }
            out.append(contentsOf: [0, 0, 0, 1])
            let bytes = UnsafeRawPointer(pointer + offset).assumingMemoryBound(to: UInt8.self)
            out.append(bytes, count: size)
            offset += size
        }
        return out.isEmpty ? nil : out
    }
}

/// 32-byte big-endian `ODCM` header (PROTOCOL.md local camera extension).
private struct ODCMHeader {
    let keyframe: Bool
    let sequence: UInt32
    let timestampMs: UInt64
    let payloadLength: UInt32

    var bytes: Data {
        var data = Data(capacity: 32)
        data.append(contentsOf: [0x4F, 0x44, 0x43, 0x4D]) // ODCM
        data.append(1)                                    // version
        data.append(1)                                    // codec: H.264 Annex B
        data.append(keyframe ? 0x01 : 0x00)               // flags
        data.append(0)                                    // reserved
        appendBE(&data, UInt32(1))                        // streamId
        appendBE(&data, sequence)
        appendBE(&data, UInt16(0))                        // chunkIndex
        appendBE(&data, UInt16(1))                        // chunkCount
        appendBE(&data, payloadLength)
        appendBE(&data, timestampMs)
        return data
    }

    private func appendBE(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value >> 8))
        data.append(UInt8(value & 0xFF))
    }

    private func appendBE(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private func appendBE(_ data: inout Data, _ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }
}

private let cameraEncodeCallback: VTCompressionOutputCallback = {
    refcon, _, status, _, sampleBuffer in
    guard status == noErr, let sampleBuffer, let refcon else { return }
    let source = Unmanaged<CameraSource>.fromOpaque(refcon).takeUnretainedValue()
    source.handleEncoded(sampleBuffer)
}
