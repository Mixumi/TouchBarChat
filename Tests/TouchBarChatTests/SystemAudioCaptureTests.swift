import AVFAudio
import CoreMedia
import Testing

@testable import TouchBarChat

struct SystemAudioCaptureTests {
    @Test(arguments: [1, 2])
    func copiesPlanarPCMFramesIntoIndependentStorage(channelCount: AVAudioChannelCount) throws {
        try assertCopy(channelCount: channelCount, interleaved: false)
    }

    @Test
    func copiesInterleavedStereoFramesIntoIndependentStorage() throws {
        try assertCopy(channelCount: 2, interleaved: true)
    }

    @Test
    func measuresFloat32MonoPeak() throws {
        let buffer = try makeZeroedPCMBuffer(commonFormat: .pcmFormatFloat32)
        let samples = try #require(buffer.floatChannelData)
        samples[0][0] = 0.125
        samples[0][3] = -0.625

        #expect(SystemAudioCapture.peakAmplitude(of: buffer) == 0.625)
    }

    @Test
    func measuresInterleavedFloat32StereoPeakAcrossBothChannels() throws {
        let buffer = try makeZeroedPCMBuffer(
            commonFormat: .pcmFormatFloat32,
            channelCount: 2,
            interleaved: true
        )
        let channels = try #require(buffer.floatChannelData)
        #expect(buffer.stride == 2)
        channels[0][1 * buffer.stride] = 0.25
        channels[1][3 * buffer.stride] = -0.75

        #expect(SystemAudioCapture.peakAmplitude(of: buffer) == 0.75)
    }

    @Test
    func measuresInt16Peak() throws {
        let buffer = try makeZeroedPCMBuffer(commonFormat: .pcmFormatInt16)
        let samples = try #require(buffer.int16ChannelData)
        samples[0][0] = 8_192
        samples[0][3] = -16_384

        #expect(SystemAudioCapture.peakAmplitude(of: buffer) == 0.5)
    }

    @Test
    func measuresInt32Peak() throws {
        let buffer = try makeZeroedPCMBuffer(commonFormat: .pcmFormatInt32)
        let samples = try #require(buffer.int32ChannelData)
        samples[0][0] = 536_870_912
        samples[0][3] = -1_073_741_824

        #expect(SystemAudioCapture.peakAmplitude(of: buffer) == 0.5)
    }

    @Test
    func reportsZeroForAllZeroPCM() throws {
        let buffer = try makeZeroedPCMBuffer(commonFormat: .pcmFormatFloat32)

        #expect(SystemAudioCapture.peakAmplitude(of: buffer) == 0)
    }

    private func makeZeroedPCMBuffer(
        commonFormat: AVAudioCommonFormat,
        channelCount: AVAudioChannelCount = 1,
        interleaved: Bool = false
    ) throws -> AVAudioPCMBuffer {
        let format = try #require(
            AVAudioFormat(
                commonFormat: commonFormat,
                sampleRate: 48_000,
                channels: channelCount,
                interleaved: interleaved
            ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for audioBuffer in audioBuffers {
            let data = try #require(audioBuffer.mData)
            memset(data, 0, Int(audioBuffer.mDataByteSize))
        }
        return buffer
    }

    private func assertCopy(
        channelCount: AVAudioChannelCount,
        interleaved: Bool
    ) throws {
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: channelCount,
                interleaved: interleaved
            )
        )
        let frameCount: AVAudioFrameCount = 64
        let sampleBuffer = try makeSampleBuffer(format: format, frameCount: frameCount)

        let copied = try #require(SystemAudioCapture.makeOwnedPCMBuffer(from: sampleBuffer))
        #expect(copied.frameLength == frameCount)
        #expect(copied.format.channelCount == channelCount)
        #expect(copied.format.sampleRate == 48_000)

        let output = UnsafeMutableAudioBufferListPointer(copied.mutableAudioBufferList)
        #expect(output.count == (interleaved ? 1 : Int(channelCount)))

        try sampleBuffer.withAudioBufferList { input, _ in
            #expect(input.count == output.count)
            for index in input.indices {
                let source = input[index]
                let destination = output[index]
                let byteCount =
                    Int(frameCount) * MemoryLayout<Float>.size
                    * (interleaved ? Int(channelCount) : 1)
                #expect(source.mDataByteSize == byteCount)
                #expect(destination.mDataByteSize == byteCount)

                let sourceData = try #require(source.mData)
                let destinationData = try #require(destination.mData)
                #expect(sourceData != destinationData)
                #expect(
                    Data(bytes: destinationData, count: byteCount)
                        == Data(bytes: sourceData, count: byteCount)
                )

                // Alter the sample buffer while it is still alive. The returned
                // AVAudioPCMBuffer must retain its original bytes.
                sourceData.storeBytes(of: UInt8(0xFF), as: UInt8.self)
                #expect(destinationData.load(as: UInt8.self) != 0xFF)
            }
        }
    }

    private func makeSampleBuffer(
        format: AVAudioFormat,
        frameCount: AVAudioFrameCount
    ) throws -> CMSampleBuffer {
        let source = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        source.frameLength = frameCount
        let buffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        for index in buffers.indices {
            let bytes = try #require(buffers[index].mData)
                .assumingMemoryBound(to: UInt8.self)
            for offset in 0..<Int(buffers[index].mDataByteSize) {
                bytes[offset] = UInt8((offset + index * 17) % 251)
            }
        }

        var streamDescription = format.streamDescription.pointee
        var formatDescription: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else {
            throw FixtureError.formatDescription(formatStatus)
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sampleSizes =
            format.isInterleaved
            ? [Int(streamDescription.mBytesPerFrame)] : []
        let createStatus = sampleSizes.withUnsafeBufferPointer { sizes in
            CMSampleBufferCreate(
                allocator: kCFAllocatorDefault,
                dataBuffer: nil,
                dataReady: false,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: formatDescription,
                sampleCount: Int(frameCount),
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: sizes.count,
                sampleSizeArray: sizes.baseAddress,
                sampleBufferOut: &sampleBuffer
            )
        }
        guard createStatus == noErr, let sampleBuffer else {
            throw FixtureError.sampleBuffer(createStatus)
        }

        let dataStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: source.audioBufferList
        )
        guard dataStatus == noErr else { throw FixtureError.audioData(dataStatus) }
        let readyStatus = CMSampleBufferSetDataReady(sampleBuffer)
        guard readyStatus == noErr else { throw FixtureError.dataReady(readyStatus) }
        return sampleBuffer
    }

    private enum FixtureError: Error {
        case formatDescription(OSStatus)
        case sampleBuffer(OSStatus)
        case audioData(OSStatus)
        case dataReady(OSStatus)
    }
}
