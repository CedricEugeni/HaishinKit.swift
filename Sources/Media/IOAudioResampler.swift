import Accelerate
import AVFoundation

private let kIOAudioResampler_frameCapacity: AVAudioFrameCount = 1024
private let kIOAudioResampler_presentationTimeStamp: CMTime = .zero

protocol IOAudioResamplerDelegate: AnyObject {
    func resampler(_ resampler: IOAudioResampler<Self>, didOutput audioFormat: AVAudioFormat)
    func resampler(_ resampler: IOAudioResampler<Self>, didOutput audioPCMBuffer: AVAudioPCMBuffer, presentationTimeStamp: CMTime)
    func resampler(_ resampler: IOAudioResampler<Self>, errorOccurred error: AudioCodec.Error)
}

final class IOAudioResampler<T: IOAudioResamplerDelegate> {
    var settings: AudioCodecSettings = .default {
        didSet {
            guard var inSourceFormat, settings.invalidateConverter(oldValue) else {
                return
            }
            setUp(&inSourceFormat)
        }
    }
    weak var delegate: T?

    var outputFormat: AVAudioFormat? {
        return audioConverter?.outputFormat
    }

    private var inSourceFormat: AudioStreamBasicDescription? {
        didSet {
            guard var inSourceFormat, inSourceFormat != oldValue else {
                return
            }
            setUp(&inSourceFormat)
        }
    }
    private var sampleRate: Int32 = 0
    private var ringBuffer: IOAudioRingBuffer?
    private var inputBuffer: AVAudioPCMBuffer?
    private var outputBuffer: AVAudioPCMBuffer?
    private var audioConverter: AVAudioConverter? {
        didSet {
            guard let audioConverter else {
                return
            }
            audioConverter.channelMap = settings.makeChannelMap(Int(audioConverter.inputFormat.channelCount))
            audioConverter.primeMethod = .normal
            delegate?.resampler(self, didOutput: audioConverter.outputFormat)
        }
    }
    private var presentationTimeStamp: CMTime = kIOAudioResampler_presentationTimeStamp

    func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        inSourceFormat = sampleBuffer.formatDescription?.audioStreamBasicDescription
        guard let inputBuffer, let outputBuffer, let ringBuffer else {
            return
        }
        ringBuffer.appendSampleBuffer(sampleBuffer)
        var status: AVAudioConverterOutputStatus? = .endOfStream
        repeat {
            var error: NSError?
            status = audioConverter?.convert(to: outputBuffer, error: &error) { inNumberFrames, status in
                if inNumberFrames <= ringBuffer.counts {
                    _ = ringBuffer.render(inNumberFrames, ioData: inputBuffer.mutableAudioBufferList)
                    inputBuffer.frameLength = inNumberFrames
                    status.pointee = .haveData
                    return inputBuffer
                } else {
                    status.pointee = .noDataNow
                    return nil
                }
            }
            switch status {
            case .haveData:
                if presentationTimeStamp == .zero {
                    presentationTimeStamp = CMTime(seconds: sampleBuffer.presentationTimeStamp.seconds, preferredTimescale: sampleRate)
                }
                delegate?.resampler(self, didOutput: outputBuffer, presentationTimeStamp: presentationTimeStamp)
                self.presentationTimeStamp = CMTimeAdd(presentationTimeStamp, .init(value: 1024, timescale: sampleRate))

//                let printBuffer = UnsafeBufferPointer(start: outputBuffer.int16ChannelData?.pointee, count: Int(outputBuffer.frameLength))
//                let array = Array<Int16>(printBuffer)
//                debugPrint(array)
            case .error:
                if let error {
                    delegate?.resampler(self, errorOccurred: .failedToConvert(error: error))
                }
            default:
                break
            }
        } while(status == .haveData)
    }

    private func setUp(_ inSourceFormat: inout AudioStreamBasicDescription) {
        let inputFormat = AVAudioFormatFactory.makeAudioFormat(&inSourceFormat)
        let outputFormat = settings.makeOutputFormat(inputFormat) ?? inputFormat

//        debugPrint("++++++++++++++++++")
//        debugPrint("mChannelsPerFrame \(inSourceFormat.mChannelsPerFrame) \n| mSampleRate \(inSourceFormat.mSampleRate) \n| mFormatID \(inSourceFormat.mFormatID) \n| mBitsPerChannel \(inSourceFormat.mBitsPerChannel) \n| mBytesPerFrame \(inSourceFormat.mBytesPerFrame)  \n| mFormatFlags \(inSourceFormat.mFormatFlags) \n| mBytesPerPacket \(inSourceFormat.mBytesPerPacket) \n| mFramesPerPacket \(inSourceFormat.mFramesPerPacket) \n| mReserved \(inSourceFormat.mReserved)")
//        let iformat = inputFormat?.streamDescription.pointee
//        debugPrint("mChannelsPerFrame \(iformat!.mChannelsPerFrame) \n| mSampleRate \(iformat!.mSampleRate) \n| mFormatID \(iformat!.mFormatID) \n| mBitsPerChannel \(iformat!.mBitsPerChannel) \n| mBytesPerFrame \(iformat!.mBytesPerFrame)  \n| mFormatFlags \(iformat!.mFormatFlags) \n| mBytesPerPacket \(iformat!.mBytesPerPacket) \n| mFramesPerPacket \(iformat!.mFramesPerPacket) \n| mReserved \(iformat!.mReserved)")
//        let oformat = outputFormat!.streamDescription.pointee
//        debugPrint("mChannelsPerFrame \(oformat.mChannelsPerFrame) \n| mSampleRate \(oformat.mSampleRate) \n| mFormatID \(oformat.mFormatID) \n| mBitsPerChannel \(oformat.mBitsPerChannel) \n| mBytesPerFrame \(oformat.mBytesPerFrame)  \n| mFormatFlags \(oformat.mFormatFlags) \n| mBytesPerPacket \(oformat.mBytesPerPacket) \n| mFramesPerPacket \(oformat.mFramesPerPacket) \n| mReserved \(oformat.mReserved)")
//        debugPrint(inputFormat)
//        debugPrint(outputFormat)
//        debugPrint("++++++++++++++++++")

        ringBuffer = .init(&inSourceFormat)
        if let inputFormat {
            inputBuffer = .init(pcmFormat: inputFormat, frameCapacity: 1024 * 4)
        }
        if let outputFormat {
            outputBuffer = .init(pcmFormat: outputFormat, frameCapacity: kIOAudioResampler_frameCapacity)
        }
        if let inputFormat, let outputFormat {
            if logger.isEnabledFor(level: .info) {
                logger.info("inputFormat:", inputFormat, ",outputFormat:", outputFormat)
            }
            sampleRate = Int32(outputFormat.sampleRate)
            presentationTimeStamp = .zero
            audioConverter = .init(from: inputFormat, to: outputFormat)
        } else {
            delegate?.resampler(self, errorOccurred: .failedToCreate(from: inputFormat, to: outputFormat))
        }
    }
}
