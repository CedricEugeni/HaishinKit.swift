import AVFoundation
import SwiftUI

#if canImport(SwiftPMSupport)
import SwiftPMSupport
#endif

public final class IOAudioUnit: NSObject, IOUnit {
    private static let defaultPresentationTimeStamp: CMTime = .invalid
    private static let sampleBuffersThreshold: Int = 1

    lazy var codec: AudioCodec = {
        var codec = AudioCodec()
        codec.lockQueue = lockQueue
        return codec
    }()
    let lockQueue = DispatchQueue(label: "com.haishinkit.HaishinKit.AudioIOComponent.lock")
    var soundTransform: SoundTransform = .init() {
        didSet {
            soundTransform.apply(mixer?.mediaLink.playerNode)
        }
    }
    public var muted = false
    weak var mixer: IOMixer?
    var loopback = false {
        didSet {
            if loopback {
                monitor.startRunning()
            } else {
                monitor.stopRunning()
            }
        }
    }
    private var monitor: IOAudioMonitor = .init()
    #if os(iOS) || os(macOS)
    private(set) var capture: IOAudioCaptureUnit = .init()
    #endif
    private var inSourceFormat: AudioStreamBasicDescription? {
        didSet {
            guard inSourceFormat != oldValue else {
                return
            }
            presentationTimeStamp = Self.defaultPresentationTimeStamp
            codec.inSourceFormat = inSourceFormat
            monitor.inSourceFormat = inSourceFormat
        }
    }
    private var presentationTimeStamp = IOAudioUnit.defaultPresentationTimeStamp

    #if os(iOS) || os(macOS)
    func attachAudio(_ device: AVCaptureDevice?, automaticallyConfiguresApplicationAudioSession: Bool) throws {
        guard let mixer else {
            return
        }
        mixer.session.beginConfiguration()
        defer {
            mixer.session.commitConfiguration()
        }
        guard let device else {
            try capture.attachDevice(nil, audioUnit: self)
            return
        }
        try capture.attachDevice(device, audioUnit: self)
        #if os(iOS)
        mixer.session.automaticallyConfiguresApplicationAudioSession = automaticallyConfiguresApplicationAudioSession
        #endif
    }
    #endif

    func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer), let sampleBuffer = sampleBuffer.muted(muted) else {
            return
        }
        inSourceFormat = sampleBuffer.formatDescription?.streamBasicDescription?.pointee
        // Synchronization between video and audio, need to synchronize the gaps.
        let numGapSamples = numGapSamples(sampleBuffer)
        let numSampleBuffers = Int(numGapSamples / sampleBuffer.numSamples)
        if Self.sampleBuffersThreshold <= numSampleBuffers {
            var gapPresentationTimeStamp = presentationTimeStamp
            for i in 0 ... numSampleBuffers {
                let numSamples = numSampleBuffers == i ? numGapSamples % sampleBuffer.numSamples : sampleBuffer.numSamples
                guard let gapSampleBuffer = CMAudioSampleBufferUtil.makeSampleBuffer(sampleBuffer, numSamples: numSamples, presentationTimeStamp: gapPresentationTimeStamp) else {
                    continue
                }
                mixer?.recorder.appendSampleBuffer(gapSampleBuffer)
                codec.appendSampleBuffer(gapSampleBuffer)
                gapPresentationTimeStamp = CMTimeAdd(gapPresentationTimeStamp, gapSampleBuffer.duration)
            }
        }
        monitor.appendSampleBuffer(sampleBuffer)
        mixer?.recorder.appendSampleBuffer(sampleBuffer)
        codec.appendSampleBuffer(sampleBuffer)
        presentationTimeStamp = sampleBuffer.presentationTimeStamp
    }

    func registerEffect(_ effect: AudioEffect) -> Bool {
        codec.effects.insert(effect).inserted
    }

    func unregisterEffect(_ effect: AudioEffect) -> Bool {
        codec.effects.remove(effect) != nil
    }

    private func numGapSamples(_ sampleBuffer: CMSampleBuffer) -> Int {
        guard let mSampleRate = inSourceFormat?.mSampleRate, presentationTimeStamp != Self.defaultPresentationTimeStamp else {
            return 0
        }
        let sampleRate = Int32(mSampleRate)
        // Device audioMic or ReplayKit audioMic.
        if presentationTimeStamp.timescale == sampleRate {
            return Int(sampleBuffer.presentationTimeStamp.value - presentationTimeStamp.value) - sampleBuffer.numSamples
        }
        // ReplayKit audioApp. PTS = {69426976806125/1000000000 = 69426.977}
        let diff = CMTime(seconds: sampleBuffer.presentationTimeStamp.seconds, preferredTimescale: sampleRate) - CMTime(seconds: presentationTimeStamp.seconds, preferredTimescale: sampleRate)
        return Int(diff.value) - sampleBuffer.numSamples
    }
}

extension IOAudioUnit: IOUnitEncoding {
    // MARK: IOUnitEncoding
    func startEncoding(_ delegate: any AVCodecDelegate) {
        codec.delegate = delegate
        codec.startRunning()
    }

    func stopEncoding() {
        codec.stopRunning()
        codec.delegate = nil
        inSourceFormat = nil
    }
}

extension IOAudioUnit: IOUnitDecoding {
    // MARK: IOUnitDecoding
    func startDecoding() {
        if let playerNode = mixer?.mediaLink.playerNode {
            mixer?.audioEngine?.attach(playerNode)
        }
        codec.delegate = self
        codec.startRunning()
    }

    func stopDecoding() {
        if let playerNode = mixer?.mediaLink.playerNode {
            mixer?.audioEngine?.detach(playerNode)
        }
        codec.stopRunning()
        codec.delegate = nil
        inSourceFormat = nil
    }
}

#if os(iOS) || os(macOS)
extension IOAudioUnit: AVCaptureAudioDataOutputSampleBufferDelegate {
    // MARK: AVCaptureAudioDataOutputSampleBufferDelegate
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard mixer?.useSampleBuffer(sampleBuffer: sampleBuffer, mediaType: AVMediaType.audio) == true else {
            return
        }
        appendSampleBuffer(sampleBuffer)
    }
}
#endif

extension IOAudioUnit: AudioCodecDelegate {
    // MARK: AudioConverterDelegate
    public func audioCodec(_ codec: AudioCodec, errorOccurred error: AudioCodec.Error) {
    }

    public func audioCodec(_ codec: AudioCodec, didOutput audioFormat: AVAudioFormat) {
        do {
            mixer?.audioFormat = audioFormat
            if let audioEngine = mixer?.audioEngine, audioEngine.isRunning == false {
                try audioEngine.start()
            }
        } catch {
            logger.error(error)
        }
    }

    public func audioCodec(_ codec: AudioCodec, didOutput audioBuffer: AVAudioBuffer, presentationTimeStamp: CMTime) {
        guard let audioBuffer = audioBuffer as? AVAudioPCMBuffer else {
            return
        }
        if let mixer = mixer {
            mixer.delegate?.mixer(mixer, didOutput: audioBuffer, presentationTimeStamp: presentationTimeStamp)
        }
        mixer?.mediaLink.enqueueAudio(audioBuffer)
    }
}

public struct SampleDataPoint: Identifiable {
    public let date: Date = Date()
    public let value: Int

    public var id: Int { Int(date.timeIntervalSince1970) }

    public init(value: Int) {
        self.value = value
    }
}

@available(iOS 17.0, *)
@Observable public class SampleData {
    public static let shared = SampleData()
    public var values: [SampleDataPoint] = []
    public var audioStreamBasicDescription: AudioStreamBasicDescription? = .none
    public var commonFormat: AVAudioCommonFormat? = .none
    public var interleaved: Bool = false
    var tmpValues: [SampleDataPoint] = []
    var refreshCount = 0

    public var inter: String {
        var value: String = ""

        if interleaved {
            value = "true"
        } else {
            value = "false"
        }

        return value
    }

    public init() {}

    public init(values: [SampleDataPoint]) {
        self.values = values
    }

    func append(_ value: Int) {
        let point = SampleDataPoint(value: value)
        tmpValues.append(point)
        refreshCount += 1

        if tmpValues.count > 200 {
            tmpValues.removeFirst()
        }

        if self.refreshCount > 200 {
            self.refreshCount = 0
            self.values = []
            self.values = self.tmpValues
        }
    }
}
