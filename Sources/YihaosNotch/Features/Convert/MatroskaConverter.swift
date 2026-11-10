import AVFoundation
import CoreMedia
import os

private let log = Logger(subsystem: "com.yihao.YihaosNotch", category: "Convert")

/// MKV to MP4 (or its sound to M4A) without re-encoding the picture: H.264 and HEVC
/// frames are copied as they are, so it's quick and loses nothing. AAC sound is
/// copied too; AC-3, E-AC-3, MP3, Opus, FLAC and PCM are decoded and re-encoded as
/// AAC, which plays everywhere. Other video (VP9, AV1) would need re-encoding, which
/// macOS can't do from MKV, so it's refused with a reason.
enum MatroskaConverter {
    static let videoCodecs = ["V_MPEG4/ISO/AVC", "V_MPEGH/ISO/HEVC"]

    /// Returns a note when the video came out without its sound.
    @concurrent
    static func convert(_ input: URL, to target: ConvertTarget, out: URL,
                        progress: @escaping Converters.Progress) async throws -> String? {
        let name = input.lastPathComponent
        let mkv: Matroska
        do { mkv = try Matroska(url: input) } catch { throw ConvertError.unreadable(name) }

        // A track that's declared but has no frames would leave the writer waiting
        // for it while the rest of the film piled up in memory.
        let withFrames = Set(mkv.frames.map(\.track))
        func candidates(_ kind: Matroska.Track.Kind) -> [Matroska.Track] {
            let tracks = mkv.tracks.filter { $0.kind == kind && $0.isEnabled && withFrames.contains($0.number) }
            // The file's default track first, as a player would choose.
            return tracks.filter(\.isDefault) + tracks.filter { !$0.isDefault }
        }

        let videoTrack = target == .mp4 ? candidates(.video).first : nil
        if let videoTrack, videoTrack.encrypted { throw ConvertError.failed(name) }
        if let videoTrack, !videoCodecs.contains(videoTrack.codec) || videoTrack.compressed {
            throw ConvertError.unsupportedVideo(name, codec: label(videoTrack.codec))
        }

        try? FileManager.default.removeItem(at: out)
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: out, fileType: target == .mp4 ? .mp4 : .m4a) } catch {
            throw ConvertError.failed(name)
        }

        // The picture starts at its first keyframe: frames before it (a recording cut
        // mid-way) can't be shown.
        var videoFrames = videoTrack.map { track in mkv.frames.filter { $0.track == track.number } } ?? []
        let skipped = videoFrames.firstIndex(where: \.keyframe) ?? videoFrames.count
        videoFrames.removeFirst(skipped)
        var video: VideoRoute?
        if let videoTrack {
            guard let route = VideoRoute(track: videoTrack, frames: videoFrames) else { throw ConvertError.failed(name) }
            writer.add(route.input)
            video = route
        }

        // The first sound track that macOS can actually decode: each is tried on its
        // first packets, so nothing comes out silently empty.
        var audio: AudioRoute?
        let audioTracks = candidates(.audio)
        for track in audioTracks {
            let packets = mkv.frames.lazy.filter { $0.track == track.number }
            let times = packets.map(\.time)
            // A gap in the sound (a dropped stream) must stay a gap, which copying
            // AAC as it is can't do.
            let gaps = zip(times, times.dropFirst()).contains { $1 - $0 > 250_000_000 }
            if let route = AudioRoute(track: track, writer: writer, trial: packets.prefix(24).map(mkv.bytes(of:)),
                                      reencode: gaps) {
                writer.add(route.input)
                audio = route
                break
            }
        }
        var note: String?
        if audio == nil, let first = audioTracks.first {
            if target == .m4a { throw ConvertError.unsupportedAudio(name, codec: label(first.codec, first)) }
            note = "No sound: its \(label(first.codec, first)) audio can't be converted."
        }
        if target == .m4a, audioTracks.isEmpty { throw ConvertError.noSound(name) }
        if video == nil, audio == nil { throw ConvertError.failed(name) }

        var videoSeen = 0
        let relevant = mkv.frames.filter { frame in
            if frame.track == video?.track {
                videoSeen += 1
                return videoSeen > skipped
            }
            return frame.track == audio?.track.number
        }
        guard let start = relevant.map(\.time).min() else { throw ConvertError.failed(name) }
        guard writer.startWriting() else {
            log.error("MKV writer didn't start: \(String(describing: writer.error), privacy: .private)")
            throw ConvertError.failed(name)
        }
        writer.startSession(atSourceTime: CMTime(value: start, timescale: 1_000_000_000))

        let inputs = [video?.input, audio?.input].compactMap { $0 }
        var pending: [ObjectIdentifier: Queue] = [:]
        // Each track is finished once its last frame is in and its queue is empty, so
        // the writer stops waiting for it and takes the rest of the other.
        var finished: Set<ObjectIdentifier> = []
        var allRead: Set<ObjectIdentifier> = []
        var lastFrame: [UInt64: Int] = [:]
        for (index, frame) in relevant.enumerated() { lastFrame[frame.track] = index }
        var lastAppend = ContinuousClock.now

        func enqueue(_ buffers: [CMSampleBuffer], for input: AVAssetWriterInput) {
            pending[ObjectIdentifier(input), default: Queue()].push(buffers)
        }
        func drain(_ input: AVAssetWriterInput) {
            let key = ObjectIdentifier(input)
            while input.isReadyForMoreMediaData, let buffer = pending[key]?.pop() {
                input.append(buffer)
                lastAppend = .now
            }
        }
        func finishDrained() {
            for input in inputs where allRead.contains(ObjectIdentifier(input))
                && pending[ObjectIdentifier(input)]?.isEmpty != false {
                if finished.insert(ObjectIdentifier(input)).inserted { input.markAsFinished() }
            }
        }
        func everyTrackHasQueued() -> Bool {
            inputs.allSatisfy { finished.contains(ObjectIdentifier($0)) || pending[ObjectIdentifier($0)]?.isEmpty == false }
        }
        // Stop pressed while waiting: the writer is cancelled, not left mid-file.
        func pause() async throws {
            do { try await Task.sleep(for: .milliseconds(2)) } catch {
                writer.cancelWriting()
                throw error
            }
        }
        func stalled() throws {
            if Task.isCancelled {
                writer.cancelWriting()
                throw CancellationError()
            }
            if ContinuousClock.now - lastAppend > .seconds(60) {
                writer.cancelWriting()
                log.error("MKV writer stopped taking frames")
                throw ConvertError.failed(name)
            }
        }

        var videoIndex = 0
        for (index, frame) in relevant.enumerated() {
            if Task.isCancelled {
                writer.cancelWriting()
                throw CancellationError()
            }
            if writer.status == .failed { break }
            let bytes = mkv.bytes(of: frame)
            if let video, frame.track == video.track {
                if let buffer = video.sample(bytes, index: videoIndex) { enqueue([buffer], for: video.input) }
                videoIndex += 1
                drain(video.input)
                if index == lastFrame[video.track] { allRead.insert(ObjectIdentifier(video.input)) }
            } else if let audio {
                enqueue(audio.samples(bytes, time: frame.time), for: audio.input)
                if index == lastFrame[audio.track.number] {
                    enqueue(audio.finish(), for: audio.input)
                    allRead.insert(ObjectIdentifier(audio.input))
                }
                drain(audio.input)
            }
            finishDrained()
            if index % 64 == 0 { progress(Double(index) / Double(relevant.count)) }
            // The writer interleaves the tracks, so it refuses one until the other
            // catches up. Only wait when every track has something queued; otherwise
            // the one it's waiting for is further on in the file.
            while writer.status == .writing, everyTrackHasQueued(),
                  pending.values.reduce(0, { $0 + $1.count }) > 200 {
                try await pause()
                inputs.forEach(drain)
                finishDrained()
                try stalled()
            }
        }
        // Everything is read (or the writer failed): finish each track as it empties.
        inputs.forEach { allRead.insert(ObjectIdentifier($0)) }
        while finished.count < inputs.count, writer.status == .writing {
            inputs.forEach(drain)
            finishDrained()
            if finished.count == inputs.count { break }
            try stalled()
            try await pause()
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            log.error("MKV writer failed: \(String(describing: writer.error), privacy: .private)")
            throw ConvertError.failed(name)
        }
        return note
    }

    static func label(_ codec: String, _ track: Matroska.Track? = nil) -> String {
        let name = switch codec {
        case "V_VP9": "VP9"
        case "V_VP8": "VP8"
        case "V_AV1": "AV1"
        case "V_MPEG2": "MPEG-2"
        case "V_MPEG4/ISO/ASP", "V_MS/VFW/FOURCC": "older MPEG-4"
        case "V_MPEG4/ISO/AVC": "H.264"
        case "V_MPEGH/ISO/HEVC": "HEVC"
        case "A_VORBIS": "Vorbis"
        case "A_DTS": "DTS"
        case "A_TRUEHD": "TrueHD"
        case "A_OPUS": "Opus"
        case "A_AC3": "AC-3"
        case "A_EAC3": "E-AC-3"
        case "A_MPEG/L3": "MP3"
        case "A_MPEG/L2": "MP2"
        case let codec where codec.hasPrefix("A_AAC"): "AAC"
        case let codec where codec.hasPrefix("A_PCM"): "PCM"
        default: codec.split(separator: "/").first.map { String($0.dropFirst(2)) } ?? codec
        }
        // "FLAC 5.1": surround that macOS's decoders don't take, where stereo works.
        guard let track, track.kind == .audio, track.channels > 2 else { return name }
        let surround = switch track.channels {
        case 6: "5.1"
        case 8: "7.1"
        default: "\(track.channels)-channel"
        }
        return "\(name) \(surround)"
    }
}

/// Sample buffers waiting for the writer, taken from the front without copying the
/// rest each time.
private struct Queue {
    private var items: [CMSampleBuffer] = []
    private var head = 0

    var count: Int { items.count - head }
    var isEmpty: Bool { head == items.count }

    mutating func push(_ buffers: [CMSampleBuffer]) {
        items.append(contentsOf: buffers)
    }

    mutating func pop() -> CMSampleBuffer? {
        guard head < items.count else { return nil }
        let item = items[head]
        head += 1
        if head > 512, head * 2 > items.count {
            items.removeFirst(head)
            head = 0
        }
        return item
    }
}

/// The picture, copied frame by frame. Matroska stores only when each frame is shown;
/// MP4 also wants when it's decoded, which for H.264/HEVC with B-frames is earlier.
/// Those times come from the same set of times, in order, held back by the largest
/// reordering.
private struct VideoRoute {
    let track: UInt64
    let input: AVAssetWriterInput
    let format: CMVideoFormatDescription
    let decodeTimes: [Int64]
    let presentationTimes: [Int64]
    let keyframes: [Bool]
    let duration: Int64

    init?(track: Matroska.Track, frames: [Matroska.Frame]) {
        guard let config = track.codecPrivate, track.width > 0, track.height > 0, !frames.isEmpty else { return nil }
        let hevc = track.codec == "V_MPEGH/ISO/HEVC"
        let extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: [hevc ? "hvcC" : "avcC": config],
        ]
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreate(allocator: nil,
                                             codecType: hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
                                             width: Int32(track.width), height: Int32(track.height),
                                             extensions: extensions as CFDictionary,
                                             formatDescriptionOut: &format) == noErr, let format
        else { return nil }
        self.track = track.number
        self.format = format
        input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = false

        let times = frames.map(\.time)
        let sorted = times.sorted()
        var shift: Int64 = 0
        for index in times.indices { shift = max(shift, sorted[index] - times[index]) }
        presentationTimes = times
        decodeTimes = sorted.map { $0 - shift }
        keyframes = frames.map(\.keyframe)
        if track.defaultDuration > 0 {
            duration = Int64(clamping: track.defaultDuration)
        } else if sorted.count > 1 {
            duration = max((sorted.last! - sorted.first!) / Int64(sorted.count - 1), 1)
        } else {
            duration = 33_333_333
        }
    }

    func sample(_ bytes: Data, index: Int) -> CMSampleBuffer? {
        let scale: Int32 = 1_000_000_000
        var timing = CMSampleTimingInfo(duration: CMTime(value: duration, timescale: scale),
                                        presentationTimeStamp: CMTime(value: presentationTimes[index], timescale: scale),
                                        decodeTimeStamp: CMTime(value: decodeTimes[index], timescale: scale))
        guard let block = blockBuffer(bytes) else { return nil }
        var size = bytes.count
        var buffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size,
                                        sampleBufferOut: &buffer) == noErr, let buffer
        else { return nil }
        if !keyframes[index],
           let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return buffer
    }
}

/// The sound: AAC copied as it is; anything else macOS can decode (and AAC with gaps
/// in it) turned into AAC.
private final class AudioRoute {
    let track: Matroska.Track
    let input: AVAssetWriterInput
    /// Set when the sound is copied.
    private var aacFormat: CMAudioFormatDescription?
    /// Set when it's decoded and re-encoded.
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var startTime: Int64?
    private var framesOut: Int64 = 0

    /// Nil when this track can't be converted: an unknown codec, a damaged header, or
    /// a decoder that produces nothing from `trial`, the track's first packets.
    init?(track: Matroska.Track, writer: AVAssetWriter, trial: [Data], reencode: Bool) {
        self.track = track
        // A damaged header can give any rate; nothing below can work with these.
        guard !track.compressed, track.sampleRate.isFinite, (8_000...192_000).contains(track.sampleRate),
              (1...64).contains(track.channels) else { return nil }
        let isAAC = track.codec.hasPrefix("A_AAC")
        if isAAC, !reencode {
            guard let format = Self.aacFormat(track) else { return nil }
            aacFormat = format
            input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
        } else {
            guard let source = Self.sourceFormat(track), Self.decodes(trial, source: source, track: track)
            else { return nil }
            let channels = AVAudioChannelCount(min(track.channels, 2))
            // AAC can't take high bit rates at low sample rates: those are raised.
            let rate = source.sampleRate < 32_000 ? 44_100 : min(source.sampleRate, 48_000)
            guard let output = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels),
                  let converter = Self.converter(from: source, to: output, track: track)
            else { return nil }
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: channels == 1 ? 96_000 : 192_000,
            ]
            // Settings the writer refuses would raise an exception rather than an error.
            guard writer.canApply(outputSettings: settings, forMediaType: .audio) else { return nil }
            self.converter = converter
            inputFormat = source
            outputFormat = output
            input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        }
        input.expectsMediaDataInRealTime = false
    }

    func samples(_ bytes: Data, time: Int64) -> [CMSampleBuffer] {
        if startTime == nil { startTime = time }
        if let aacFormat {
            guard let block = blockBuffer(bytes) else { return [] }
            var packet = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                      mDataByteSize: UInt32(bytes.count))
            var buffer: CMSampleBuffer?
            let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: block, formatDescription: aacFormat, sampleCount: 1,
                presentationTimeStamp: CMTime(value: time, timescale: 1_000_000_000),
                packetDescriptions: &packet, sampleBufferOut: &buffer)
            return status == noErr ? buffer.map { [$0] } ?? [] : []
        }
        // Sound missing from the file (a dropped stream) becomes silence, so what
        // follows stays in step with the picture.
        var result: [CMSampleBuffer] = []
        if let outputFormat, let startTime {
            let rate = outputFormat.sampleRate
            let expected = startTime + Int64(Double(framesOut) / rate * 1_000_000_000)
            let gap = time - expected
            if gap > 200_000_000 {
                var missing = min(Int64(Double(gap) / 1_000_000_000 * rate), Int64(rate * 600))
                while missing > 0, let silence = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                                                  frameCapacity: AVAudioFrameCount(min(missing, Int64(rate)))) {
                    silence.frameLength = silence.frameCapacity
                    missing -= Int64(silence.frameLength)
                    if let buffer = sampleBuffer(silence) { result.append(buffer) }
                }
            }
        }
        return result + decode(bytes)
    }

    /// Whatever the decoder still holds.
    func finish() -> [CMSampleBuffer] {
        converter == nil ? [] : decode(nil)
    }

    private func decode(_ bytes: Data?) -> [CMSampleBuffer] {
        guard let converter, let inputFormat, let outputFormat else { return [] }
        return Self.run(converter, bytes.flatMap { Self.packet($0, format: inputFormat) }, ended: bytes == nil,
                        into: outputFormat).compactMap(sampleBuffer)
    }

    /// Feeds one packet (or the end of the stream) through the converter.
    private static func run(_ converter: AVAudioConverter, _ packet: AVAudioBuffer?, ended: Bool,
                            into format: AVAudioFormat) -> [AVAudioPCMBuffer] {
        if packet == nil, !ended { return [] }
        let supply = Supply(packet)
        var result: [AVAudioPCMBuffer] = []
        while true {
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else { break }
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, status in
                if let next = supply.take() {
                    status.pointee = .haveData
                    return next
                }
                status.pointee = supply.ended ? .endOfStream : .noDataNow
                return nil
            }
            if out.frameLength > 0 { result.append(out) }
            if status != .haveData || out.frameLength == 0 { break }
        }
        if ended { converter.reset() }
        return result
    }

    /// Whether macOS's decoder makes sound from this track's first packets: some
    /// layouts (5.1 FLAC or Opus) are refused, or decode to nothing.
    private static func decodes(_ trial: [Data], source: AVAudioFormat, track: Matroska.Track) -> Bool {
        guard !trial.isEmpty,
              let output = AVAudioFormat(standardFormatWithSampleRate: source.sampleRate,
                                         channels: AVAudioChannelCount(min(track.channels, 2))),
              let converter = converter(from: source, to: output, track: track)
        else { return false }
        let frames = trial.reduce(0) { total, bytes in
            total + run(converter, packet(bytes, format: source), ended: false, into: output)
                .reduce(0) { $0 + Int($1.frameLength) }
        }
        return frames > 0
    }

    private static func converter(from source: AVAudioFormat, to output: AVAudioFormat,
                                  track: Matroska.Track) -> AVAudioConverter? {
        guard let converter = AVAudioConverter(from: source, to: output) else { return nil }
        converter.downmix = track.channels > 2
        if let cookie = cookie(track) { converter.magicCookie = cookie }
        return converter
    }

    private func sampleBuffer(_ pcm: AVAudioPCMBuffer) -> CMSampleBuffer? {
        let rate = Int32(pcm.format.sampleRate)
        let start = CMTime(value: startTime ?? 0, timescale: 1_000_000_000)
        let time = CMTimeAdd(start, CMTime(value: framesOut, timescale: rate))
        framesOut += Int64(pcm.frameLength)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: rate), presentationTimeStamp: time,
                                        decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
                                   refcon: nil, formatDescription: pcm.format.formatDescription,
                                   sampleCount: CMItemCount(pcm.frameLength), sampleTimingEntryCount: 1,
                                   sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                   sampleBufferOut: &buffer) == noErr, let buffer,
              CMSampleBufferSetDataBufferFromAudioBufferList(buffer, blockBufferAllocator: nil,
                                                             blockBufferMemoryAllocator: nil, flags: 0,
                                                             bufferList: pcm.audioBufferList) == noErr
        else { return nil }
        return buffer
    }

    // MARK: Formats

    private static func aacFormat(_ track: Matroska.Track) -> CMAudioFormatDescription? {
        // The ES descriptor's single length bytes hold a configuration of this size.
        guard let config = track.codecPrivate ?? audioSpecificConfig(track), config.count <= 64 else { return nil }
        var description = AudioStreamBasicDescription(
            mSampleRate: track.sampleRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: UInt32(track.channels),
            mBitsPerChannel: 0, mReserved: 0)
        let cookie = esds(config)
        var format: CMAudioFormatDescription?
        let status = cookie.withUnsafeBytes { bytes in
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
                                           magicCookieSize: bytes.count, magicCookie: bytes.baseAddress,
                                           extensions: nil, formatDescriptionOut: &format)
        }
        return status == noErr ? format : nil
    }

    private static func sourceFormat(_ track: Matroska.Track) -> AVAudioFormat? {
        let channels = AVAudioChannelCount(max(track.channels, 1))
        let layout = layout(track)
        if track.codec.hasPrefix("A_PCM/") {
            let float = track.codec == "A_PCM/FLOAT/IEEE"
            let big = track.codec == "A_PCM/INT/BIG"
            let bits = UInt32(track.bitDepth > 0 ? track.bitDepth : 16)
            guard [16, 24, 32].contains(bits) || (float && bits == 64) else { return nil }
            var flags: AudioFormatFlags = kAudioFormatFlagIsPacked
            flags |= float ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger
            if big { flags |= kAudioFormatFlagIsBigEndian }
            var description = AudioStreamBasicDescription(
                mSampleRate: track.sampleRate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
                mBytesPerPacket: bits / 8 * channels, mFramesPerPacket: 1, mBytesPerFrame: bits / 8 * channels,
                mChannelsPerFrame: channels, mBitsPerChannel: bits, mReserved: 0)
            return layout.flatMap { AVAudioFormat(streamDescription: &description, channelLayout: $0) }
                ?? AVAudioFormat(streamDescription: &description)
        }
        let (id, frames): (AudioFormatID, UInt32) = switch track.codec {
        case let codec where codec.hasPrefix("A_AAC"): (kAudioFormatMPEG4AAC, 1024)
        case "A_AC3": (kAudioFormatAC3, 1536)
        case "A_EAC3": (kAudioFormatEnhancedAC3, 1536)
        case "A_MPEG/L3": (kAudioFormatMPEGLayer3, 1152)
        case "A_MPEG/L2": (kAudioFormatMPEGLayer2, 1152)
        case "A_OPUS": (kAudioFormatOpus, 960)
        case "A_FLAC": (kAudioFormatFLAC, flacBlockSize(track))
        default: (0, 0)
        }
        guard id != 0 else { return nil }
        var description = AudioStreamBasicDescription(
            mSampleRate: track.codec == "A_OPUS" ? 48_000 : track.sampleRate, mFormatID: id, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: frames, mBytesPerFrame: 0, mChannelsPerFrame: channels,
            mBitsPerChannel: 0, mReserved: 0)
        return layout.flatMap { AVAudioFormat(streamDescription: &description, channelLayout: $0) }
            ?? AVAudioFormat(streamDescription: &description)
    }

    /// The largest block in the stream, from STREAMINFO; the decoder won't start
    /// without a packet size.
    private static func flacBlockSize(_ track: Matroska.Track) -> UInt32 {
        guard var info = track.codecPrivate.map({ Data($0) }) else { return 4096 }
        if info.starts(with: Array("fLaC".utf8)) { info = Data(info.dropFirst(4)) }
        // A 4-byte block header, then the minimum and maximum block sizes.
        guard info.count >= 8, info[0] & 0x7F == 0 else { return 4096 }
        let largest = UInt32(info[6]) << 8 | UInt32(info[7])
        return largest > 0 ? largest : 4096
    }

    /// Which speaker each channel is for, in the order the codec stores them: Opus and
    /// Vorbis put the centre second and the LFE last; the rest follow WAVE's order.
    /// Without it, more than two channels can't be mixed down to stereo (they come out
    /// silent).
    private static func layout(_ track: Matroska.Track) -> AVAudioChannelLayout? {
        let count = track.channels
        guard (3...8).contains(count) else { return nil }
        let (l, r, c) = (kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center)
        let (lfe, ls, rs) = (kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LeftSurround,
                             kAudioChannelLabel_RightSurround)
        let (cs, rls, rrs) = (kAudioChannelLabel_CenterSurround, kAudioChannelLabel_RearSurroundLeft,
                              kAudioChannelLabel_RearSurroundRight)
        let vorbis = track.codec == "A_OPUS" || track.codec == "A_VORBIS"
        let orders: [[AudioChannelLabel]] = vorbis
            ? [[l, c, r], [l, r, ls, rs], [l, c, r, ls, rs], [l, c, r, ls, rs, lfe], [l, c, r, ls, rs, cs, lfe],
               [l, c, r, ls, rs, rls, rrs, lfe]]
            : [[l, r, c], [l, r, ls, rs], [l, r, c, ls, rs], [l, r, c, lfe, ls, rs], [l, r, c, lfe, cs, ls, rs],
               [l, r, c, lfe, rls, rrs, ls, rs]]
        let labels = orders[count - 3]
        let size = MemoryLayout<AudioChannelLayout>.size
            + (labels.count - 1) * MemoryLayout<AudioChannelDescription>.stride
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioChannelLayout>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        let layout = raw.assumingMemoryBound(to: AudioChannelLayout.self)
        layout.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
        layout.pointee.mNumberChannelDescriptions = UInt32(labels.count)
        withUnsafeMutablePointer(to: &layout.pointee.mChannelDescriptions) { first in
            let descriptions = UnsafeMutableRawPointer(first).assumingMemoryBound(to: AudioChannelDescription.self)
            for (index, label) in labels.enumerated() { descriptions[index].mChannelLabel = label }
        }
        return AVAudioChannelLayout(layout: layout)
    }

    /// Decoder set-up data, in the shape Core Audio expects.
    private static func cookie(_ track: Matroska.Track) -> Data? {
        if track.codec.hasPrefix("A_AAC") {
            return (track.codecPrivate ?? audioSpecificConfig(track)).flatMap { $0.count <= 64 ? esds($0) : nil }
        }
        guard let config = track.codecPrivate else { return nil }
        switch track.codec {
        case "A_OPUS":
            return config
        case "A_FLAC":
            // Matroska keeps "fLaC" and the metadata blocks; Core Audio wants the
            // MP4 'dfLa' box's contents: version and flags, then the blocks.
            let blocks = config.starts(with: Array("fLaC".utf8)) ? config.dropFirst(4) : config[...]
            return Data([0, 0, 0, 0]) + blocks
        default:
            return nil
        }
    }

    private static func packet(_ bytes: Data, format: AVAudioFormat) -> AVAudioBuffer? {
        guard !bytes.isEmpty else { return nil }
        if format.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM {
            let frameBytes = Int(format.streamDescription.pointee.mBytesPerFrame)
            let frames = AVAudioFrameCount(bytes.count / max(frameBytes, 1))
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
            buffer.frameLength = frames
            let target = buffer.mutableAudioBufferList.pointee.mBuffers
            bytes.withUnsafeBytes { source in
                target.mData?.copyMemory(from: source.baseAddress!, byteCount: Int(frames) * frameBytes)
            }
            return buffer
        }
        let buffer = AVAudioCompressedBuffer(format: format, packetCapacity: 1, maximumPacketSize: bytes.count)
        bytes.withUnsafeBytes { source in
            buffer.data.copyMemory(from: source.baseAddress!, byteCount: bytes.count)
        }
        buffer.byteLength = UInt32(bytes.count)
        buffer.packetCount = 1
        buffer.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(bytes.count))
        return buffer
    }

    /// For old files that name the AAC profile in the codec ID instead of storing its
    /// configuration.
    private static func audioSpecificConfig(_ track: Matroska.Track) -> Data? {
        let rates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        guard let index = rates.firstIndex(of: track.sampleRate), (1...6).contains(track.channels) else { return nil }
        // Plain AAC (LC, or Main): HE-AAC's longer configuration isn't rebuilt here;
        // its core still plays.
        let objectType: UInt16 = track.codec.contains("MAIN") ? 1 : 2
        let value = objectType << 11 | UInt16(index) << 7 | UInt16(track.channels) << 3
        return Data([UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    /// An MPEG-4 ES descriptor wrapping the AAC configuration: Core Audio's form of
    /// the AAC "magic cookie".
    private static func esds(_ config: Data) -> Data {
        func descriptor(_ tag: UInt8, _ body: Data) -> Data {
            Data([tag, 0x80, 0x80, 0x80, UInt8(body.count)]) + body
        }
        let decoderConfig = Data([0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]) + descriptor(0x05, config)
        let body = Data([0, 0, 0]) + descriptor(0x04, decoderConfig) + descriptor(0x06, Data([0x02]))
        return descriptor(0x03, body)
    }
}

/// Hands the decoder one packet, then nothing (or the end of the stream).
private final class Supply: @unchecked Sendable {
    private var packet: AVAudioBuffer?
    let ended: Bool

    init(_ packet: AVAudioBuffer?) {
        self.packet = packet
        ended = packet == nil
    }

    func take() -> AVAudioBuffer? {
        defer { packet = nil }
        return packet
    }
}

private func blockBuffer(_ bytes: Data) -> CMBlockBuffer? {
    guard !bytes.isEmpty else { return nil }
    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count,
                                             blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                             dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                                             blockBufferOut: &block) == noErr, let block
    else { return nil }
    let status = bytes.withUnsafeBytes { source in
        CMBlockBufferReplaceDataBytes(with: source.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                      dataLength: bytes.count)
    }
    return status == noErr ? block : nil
}
