import Accelerate
import AVFoundation
import CoreMedia
import Foundation

final class IOAudioRingBuffer {
    private static let bufferCounts: UInt32 = 16
    private static let numSamples: UInt32 = 1024

    var counts: Int {
        if tail <= head {
            return head - tail + skip
        }
        return Int(buffer.frameLength) - tail + head + skip
    }

    private(set) var presentationTimeStamp: CMTime = .zero
    private var head = 0
    private var tail = 0
    private var skip = 0
    private var format: AVAudioFormat
    private var buffer: AVAudioPCMBuffer
    private var workingBuffer: AVAudioPCMBuffer

    init?(_ inSourceFormat: inout AudioStreamBasicDescription, bufferCounts: UInt32 = IOAudioRingBuffer.bufferCounts) {
        guard
            inSourceFormat.mFormatID == kAudioFormatLinearPCM,
            let format = AVAudioFormatFactory.makeAudioFormat(&inSourceFormat),
            let workingBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.numSamples) else {
            return nil
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.numSamples * bufferCounts) else {
            return nil
        }
        self.format = format
        self.buffer = buffer
        self.buffer.frameLength = self.buffer.frameCapacity
        self.workingBuffer = workingBuffer
    }

    func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        if presentationTimeStamp == .zero {
            presentationTimeStamp = sampleBuffer.presentationTimeStamp
        }
        if workingBuffer.frameLength < sampleBuffer.numSamples {
            if let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleBuffer.numSamples)) {
                self.workingBuffer = buffer
            }
        }
        workingBuffer.frameLength = AVAudioFrameCount(sampleBuffer.numSamples)

//        var array: [Int16] = []
//
//        if let data = sampleBuffer.dataBuffer!.data {
//            for byte in data {
//                array.append(Int16(byte))
//            }
//        }

//        debugPrint("========")
//        debugPrint(array)
//        debugPrint("numSample = \(sampleBuffer.numSamples)")
//        debugPrint("totalsamplesize = \(sampleBuffer.totalSampleSize)")
//        debugPrint("is not sync = \(sampleBuffer.isNotSync)")
//        debugPrint("dts = \(sampleBuffer.decodeTimeStamp)")
//        debugPrint("duration = \(sampleBuffer.duration)")
//        debugPrint("output duration = \(sampleBuffer.outputDuration)")
//        if let size = try? sampleBuffer.sampleSizes() {
//            debugPrint("sizes = \(size)")
//        }

        // 0 - 512 start at 511 "512 - 1"
//        var start: Int32 = 0
//        var count: Int32 = Int32(sampleBuffer.numSamples)
//
//        if count > 960 && workingBuffer.format.streamDescription.pointee.mChannelsPerFrame == 4 {
//            start = 127
//            count = Int32(sampleBuffer.numSamples) - 128
//        }
//
//        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
//            sampleBuffer,
//            at: start,
//            frameCount: count,
//            into: workingBuffer.mutableAudioBufferList
//        )
        //TODO: -
//        debugPrint("pts = \(sampleBuffer.presentationTimeStamp)")
//        debugPrint("oPTS = \(sampleBuffer.outputPresentationTimeStamp)")
//        if sampleBuffer.numSamples > 960 && workingBuffer.format.streamDescription.pointee.mChannelsPerFrame == 4 {
//            let oldPTS = sampleBuffer.presentationTimeStamp
//            let newPTS = CMTimeSubtract(oldPTS, CMTime(value: 256, timescale: oldPTS.timescale))
//
//            do {
//                try sampleBuffer.setOutputPresentationTimeStamp(newPTS)
//            } catch {
//                debugPrint("error setting PTS = \(error.localizedDescription)")
//            }
//        }
//        debugPrint("pts = \(sampleBuffer.presentationTimeStamp)")
//        debugPrint("oPTS = \(sampleBuffer.outputPresentationTimeStamp)")

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(sampleBuffer.numSamples),
            into: workingBuffer.mutableAudioBufferList
        )

//        let printBuffer = UnsafeBufferPointer(start: workingBuffer.int16ChannelData?.pointee, count: Int(workingBuffer.frameLength))
//        let pArray = Array<Int16>(printBuffer)
//        debugPrint(pArray)
//        let printBuffer = UnsafeBufferPointer(start: buffer.int16ChannelData?.pointee, count: Int(buffer.frameLength))
//        let pArray = Array<Int16>(printBuffer)
//        debugPrint(pArray)
//        debugPrint(status)
//        debugPrint("========")

        //
        if status == noErr && kLinearPCMFormatFlagIsBigEndian == ((sampleBuffer.formatDescription?.audioStreamBasicDescription?.mFormatFlags ?? 0) & kLinearPCMFormatFlagIsBigEndian) {
            if format.isInterleaved {
                switch format.commonFormat {
                case .pcmFormatInt16:
                    let length = sampleBuffer.dataBuffer?.dataLength ?? 0
                    var image = vImage_Buffer(data: workingBuffer.mutableAudioBufferList[0].mBuffers.mData, height: 1, width: vImagePixelCount(length / 2), rowBytes: length)
                    vImageByteSwap_Planar16U(&image, &image, vImage_Flags(kvImageNoFlags))
                default:
                    break
                }
            }
        }

//        skip = numSamples(sampleBuffer)
//        appendAudioPCMBuffer(workingBuffer)
        let distance = distance(sampleBuffer)
        if 0 <= distance {
            skip = distance
        }
        appendAudioPCMBuffer(workingBuffer, offset: offsetCount(sampleBuffer) / 8)
    }

    func appendAudioPCMBuffer(_ audioPCMBuffer: AVAudioPCMBuffer, offset: Int = 0) {
        let numSamples = min(Int(audioPCMBuffer.frameLength) - offset, Int(buffer.frameLength) - head)
//        let printBuffer = UnsafeBufferPointer(start: audioPCMBuffer.int16ChannelData?.pointee, count: Int(audioPCMBuffer.frameLength))
//        let array = Array<Int16>(printBuffer)
//        debugPrint(array)
//        debugPrint(offset)

        if #available(iOS 17.0, *) {
            SampleData.shared.append(numSamples)
            if SampleData.shared.audioStreamBasicDescription == nil || SampleData.shared.audioStreamBasicDescription?.mChannelsPerFrame != format.channelCount {
                SampleData.shared.audioStreamBasicDescription = format.streamDescription.pointee
            }
        }

        if format.isInterleaved {
            let channelCount = Int(format.channelCount)
            switch format.commonFormat {
            case .pcmFormatInt16:
                memcpy(buffer.int16ChannelData?[0].advanced(by: head * channelCount), audioPCMBuffer.int16ChannelData?[0].advanced(by: offset * channelCount), numSamples * channelCount * 2)
            case .pcmFormatInt32:
                memcpy(buffer.int32ChannelData?[0].advanced(by: head * channelCount), audioPCMBuffer.int32ChannelData?[0].advanced(by: offset * channelCount), numSamples * channelCount * 4)
            case .pcmFormatFloat32:
                memcpy(buffer.floatChannelData?[0].advanced(by: head * channelCount), audioPCMBuffer.floatChannelData?[0].advanced(by: offset * channelCount), numSamples * channelCount * 4)
            default:
                break
            }
        } else {
            for i in 0..<Int(format.channelCount) {
                switch format.commonFormat {
                case .pcmFormatInt16:
                    memcpy(buffer.int16ChannelData?[i].advanced(by: head), audioPCMBuffer.int16ChannelData?[i].advanced(by: offset), numSamples * 2)
                case .pcmFormatInt32:
                    memcpy(buffer.int32ChannelData?[i].advanced(by: head), audioPCMBuffer.int32ChannelData?[i].advanced(by: offset), numSamples * 4)
                case .pcmFormatFloat32:
                    memcpy(buffer.floatChannelData?[i].advanced(by: head), audioPCMBuffer.floatChannelData?[i].advanced(by: offset), numSamples * 4)
                default:
                    break
                }
            }
        }
        head += numSamples
        if head == buffer.frameLength {
            head = 0
            if 0 < Int(audioPCMBuffer.frameLength) - numSamples {
                appendAudioPCMBuffer(audioPCMBuffer, offset: numSamples)
            }
        }
    }

    func render(_ inNumberFrames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>?, offset: Int = 0) -> OSStatus {
        if 0 < skip {
            let numSamples = min(Int(inNumberFrames), skip)
            guard let bufferList = UnsafeMutableAudioBufferListPointer(ioData) else {
                return noErr
            }

            if format.isInterleaved {
                let channelCount = Int(format.channelCount)
                switch format.commonFormat {
                case .pcmFormatInt16:
                    bufferList[0].mData?.assumingMemoryBound(to: Int16.self).advanced(by: offset * channelCount).update(repeating: 0, count: numSamples)
                case .pcmFormatInt32:
                    bufferList[0].mData?.assumingMemoryBound(to: Int32.self).advanced(by: offset * channelCount).update(repeating: 0, count: numSamples)
                case .pcmFormatFloat32:
                    bufferList[0].mData?.assumingMemoryBound(to: Float32.self).advanced(by: offset * channelCount).update(repeating: 0, count: numSamples)
                default:
                    break
                }
            } else {
                for i in 0..<Int(format.channelCount) {
                    switch format.commonFormat {
                    case .pcmFormatInt16:
                        bufferList[i].mData?.assumingMemoryBound(to: Int16.self).advanced(by: offset).update(repeating: 0, count: numSamples)
                    case .pcmFormatInt32:
                        bufferList[i].mData?.assumingMemoryBound(to: Int32.self).advanced(by: offset).update(repeating: 0, count: numSamples)
                    case .pcmFormatFloat32:
                        bufferList[i].mData?.assumingMemoryBound(to: Float32.self).advanced(by: offset).update(repeating: 0, count: numSamples)
                    default:
                        break
                    }
                }
            }

            skip -= numSamples
            presentationTimeStamp = CMTimeAdd(presentationTimeStamp, CMTime(value: CMTimeValue(numSamples), timescale: presentationTimeStamp.timescale))
            
            if 0 < inNumberFrames - UInt32(numSamples) {
                return render(inNumberFrames - UInt32(numSamples), ioData: ioData, offset: numSamples)
            }

            return noErr
        }
        
        let numSamples = min(Int(inNumberFrames), Int(buffer.frameLength) - tail)
        guard let bufferList = UnsafeMutableAudioBufferListPointer(ioData), head != tail else {
            return noErr
        }

        if format.isInterleaved {
            let channelCount = Int(format.channelCount)
            switch format.commonFormat {
            case .pcmFormatInt16:
                memcpy(bufferList[0].mData?.advanced(by: offset * channelCount * 2), buffer.int16ChannelData?[0].advanced(by: tail * channelCount), numSamples * channelCount * 2)
            case .pcmFormatInt32:
                memcpy(bufferList[0].mData?.advanced(by: offset * channelCount * 4), buffer.int32ChannelData?[0].advanced(by: tail * channelCount), numSamples * channelCount * 4)
            case .pcmFormatFloat32:
                memcpy(bufferList[0].mData?.advanced(by: offset * channelCount * 4), buffer.floatChannelData?[0].advanced(by: tail * channelCount), numSamples * channelCount * 4)
            default:
                break
            }
        } else {
            for i in 0..<Int(format.channelCount) {
                switch format.commonFormat {
                case .pcmFormatInt16:
                    memcpy(bufferList[i].mData?.advanced(by: offset * 2), buffer.int16ChannelData?[i].advanced(by: tail), numSamples * 2)
                case .pcmFormatInt32:
                    memcpy(bufferList[i].mData?.advanced(by: offset * 4), buffer.int32ChannelData?[i].advanced(by: tail), numSamples * 4)
                case .pcmFormatFloat32:
                    memcpy(bufferList[i].mData?.advanced(by: offset * 4), buffer.floatChannelData?[i].advanced(by: tail), numSamples * 4)
                default:
                    break
                }
            }
        }
        
        tail += numSamples
        presentationTimeStamp = CMTimeAdd(presentationTimeStamp, CMTime(value: CMTimeValue(numSamples), timescale: presentationTimeStamp.timescale))
        
        if tail == buffer.frameLength {
            tail = 0
            if 0 < inNumberFrames - UInt32(numSamples) {
                return render(inNumberFrames - UInt32(numSamples), ioData: ioData, offset: numSamples)
            }
        }

        return noErr
    }

    private func offsetCount(_ sampleBuffer: CMSampleBuffer) -> Int {
        let data = sampleBuffer.dataBuffer?.data?.bytes ?? []
        let count = 0
        
        for i in 0..<data.count {
            guard data.count > i * 2 * 4 else { break }

            if (data[i * 2 * 4] != 0) {
                return i * 2 * 4
            }
        }

        return count
    }

//    private func numSamples(_ sampleBuffer: CMSampleBuffer) -> Int {
    private func distance(_ sampleBuffer: CMSampleBuffer) -> Int {
        // Device audioMic or ReplayKit audioMic.
        let sampleRate = Int32(format.sampleRate)
        
        if presentationTimeStamp.timescale == sampleRate {
            let presentationTimeStamp = CMTimeAdd(presentationTimeStamp, CMTime(value: CMTimeValue(counts), timescale: presentationTimeStamp.timescale))
//            return max(Int(sampleBuffer.presentationTimeStamp.value - presentationTimeStamp.value), 0)
            return Int(sampleBuffer.presentationTimeStamp.value - presentationTimeStamp.value)
        }

        return 0
    }
}
