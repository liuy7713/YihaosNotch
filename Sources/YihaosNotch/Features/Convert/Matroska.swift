import Foundation

/// Just enough of Matroska (MKV), which macOS can't open, to copy its video and sound
/// into an MP4: the tracks, and where each frame is in the file and when it plays.
/// The file is memory-mapped, so even a long film isn't read into memory; only the
/// frame list is kept (a few dozen bytes per frame).
struct Matroska {
    struct Track {
        enum Kind { case video, audio, other }
        var number: UInt64 = 0
        var kind: Kind = .other
        var codec = ""
        var codecPrivate: Data?
        var width = 0
        var height = 0
        var sampleRate: Double = 8000
        var channels = 1
        var bitDepth = 0
        /// Nanoseconds per frame, when the file says.
        var defaultDuration: UInt64 = 0
        /// Bytes mkvmerge removed from the start of every frame ("header stripping").
        var strippedHeader: Data?
        /// Frames compressed (zlib, bzip, LZO) or encrypted in a way this reader
        /// doesn't undo.
        var compressed = false
        /// The track players pick by default, and whether it's switched on at all.
        var isDefault = true
        var isEnabled = true
        var encrypted = false
    }

    struct Frame {
        let track: UInt64
        let offset: Int
        let size: Int
        /// Presentation time in nanoseconds.
        let time: Int64
        let keyframe: Bool
    }

    enum Failure: Error { case notMatroska, truncated }

    let data: Data
    private(set) var tracks: [Track] = []
    /// In the order they're stored (decode order).
    private(set) var frames: [Frame] = []
    private var timestampScale: UInt64 = 1_000_000

    init(url: URL) throws {
        data = try Data(contentsOf: url, options: .alwaysMapped)
        try data.withUnsafeBytes { raw in
            var reader = Reader(bytes: raw)
            try parse(&reader)
        }
        guard !tracks.isEmpty else { throw Failure.notMatroska }
    }

    func bytes(of frame: Frame) -> Data {
        let body = data.subdata(in: frame.offset..<(frame.offset + frame.size))
        guard let header = tracks.first(where: { $0.number == frame.track })?.strippedHeader else { return body }
        return header + body
    }

    // MARK: Element IDs

    private enum ID {
        static let ebml: UInt32 = 0x1A45DFA3
        static let segment: UInt32 = 0x18538067
        static let info: UInt32 = 0x1549A966
        static let timestampScale: UInt32 = 0x2AD7B1
        static let tracks: UInt32 = 0x1654AE6B
        static let trackEntry: UInt32 = 0xAE
        static let trackNumber: UInt32 = 0xD7
        static let trackType: UInt32 = 0x83
        static let codecID: UInt32 = 0x86
        static let codecPrivate: UInt32 = 0x63A2
        static let defaultDuration: UInt32 = 0x23E383
        static let video: UInt32 = 0xE0
        static let pixelWidth: UInt32 = 0xB0
        static let pixelHeight: UInt32 = 0xBA
        static let audio: UInt32 = 0xE1
        static let samplingFrequency: UInt32 = 0xB5
        static let channels: UInt32 = 0x9F
        static let bitDepth: UInt32 = 0x6264
        static let contentEncodings: UInt32 = 0x6D80
        static let contentEncoding: UInt32 = 0x6240
        static let contentCompression: UInt32 = 0x5034
        static let contentCompAlgo: UInt32 = 0x4254
        static let contentCompSettings: UInt32 = 0x4255
        static let contentEncryption: UInt32 = 0x5035
        static let flagDefault: UInt32 = 0x88
        static let flagEnabled: UInt32 = 0xB9
        static let cluster: UInt32 = 0x1F43B675
        static let clusterTimestamp: UInt32 = 0xE7
        static let simpleBlock: UInt32 = 0xA3
        static let blockGroup: UInt32 = 0xA0
        static let block: UInt32 = 0xA1
        static let referenceBlock: UInt32 = 0xFB
        /// Elements that sit directly in the segment: one of these ends a cluster whose
        /// size wasn't written (a live recording).
        static let topLevel: Set<UInt32> = [cluster, info, tracks, 0x114D9B74, 0x1C53BB6B, 0x1043A770,
                                            0x1254C367, 0x1941A469]
    }

    // MARK: Parsing

    private mutating func parse(_ reader: inout Reader) throws {
        while reader.position < reader.count {
            guard case let (id, size)? = reader.header() else { break }
            if id == ID.segment {
                let end = size.map { min(reader.position + $0, reader.count) } ?? reader.count
                try parseSegment(&reader, end: end)
                reader.position = end
            } else if id == ID.ebml, let size {
                reader.position += size
            } else {
                throw Failure.notMatroska
            }
        }
    }

    private mutating func parseSegment(_ reader: inout Reader, end: Int) throws {
        while reader.position < end {
            guard case let (id, size)? = reader.header() else { return }
            let start = reader.position
            switch id {
            case ID.info:
                let stop = start + (size ?? 0)
                while reader.position < stop, case let (child, length)? = reader.header(), let length {
                    if child == ID.timestampScale { timestampScale = min(max(reader.uint(length), 1), 1_000_000_000) } else {
                        reader.position += length
                    }
                }
            case ID.tracks:
                try parseTracks(&reader, end: start + (size ?? 0))
            case ID.cluster:
                parseCluster(&reader, end: size.map { start + $0 } ?? end, sized: size != nil)
                continue
            default:
                // Seek index, cues, tags, chapters, attachments: not needed.
                guard let size else { return }
                reader.position = start + size
                continue
            }
            reader.position = start + (size ?? 0)
        }
    }

    private mutating func parseTracks(_ reader: inout Reader, end: Int) throws {
        while reader.position < end, case let (id, size)? = reader.header(), let size {
            let stop = reader.position + size
            if id == ID.trackEntry {
                var track = Track()
                while reader.position < stop, case let (field, length)? = reader.header(), let length {
                    let next = reader.position + length
                    switch field {
                    case ID.trackNumber: track.number = reader.uint(length)
                    case ID.trackType:
                        switch reader.uint(length) {
                        case 1: track.kind = .video
                        case 2: track.kind = .audio
                        default: track.kind = .other
                        }
                    case ID.codecID: track.codec = reader.string(length)
                    case ID.codecPrivate: track.codecPrivate = reader.data(length)
                    case ID.flagDefault: track.isDefault = reader.uint(length) != 0
                    case ID.flagEnabled: track.isEnabled = reader.uint(length) != 0
                    case ID.defaultDuration: track.defaultDuration = min(reader.uint(length), 10_000_000_000)
                    case ID.video:
                        while reader.position < next, case let (v, l)? = reader.header(), let l {
                            // Damaged files can say anything: sizes are kept to what
                            // a video can be.
                            if v == ID.pixelWidth { track.width = Int(min(reader.uint(l), 16_384)) } else if v == ID.pixelHeight {
                                track.height = Int(min(reader.uint(l), 16_384))
                            } else { reader.position += l }
                        }
                    case ID.audio:
                        while reader.position < next, case let (a, l)? = reader.header(), let l {
                            switch a {
                            case ID.samplingFrequency: track.sampleRate = reader.float(l)
                            case ID.channels: track.channels = Int(min(reader.uint(l), 64))
                            case ID.bitDepth: track.bitDepth = Int(min(reader.uint(l), 64))
                            default: reader.position += l
                            }
                        }
                    case ID.contentEncodings:
                        parseEncodings(&reader, end: next, into: &track, depth: 0)
                    default: break
                    }
                    reader.position = next
                }
                tracks.append(track)
            }
            reader.position = stop
        }
    }

    private func parseEncodings(_ reader: inout Reader, end: Int, into track: inout Track, depth: Int) {
        // Real files nest two levels; a damaged one could nest until the stack ran out.
        guard depth < 4 else {
            track.compressed = true
            return
        }
        while reader.position < end, case let (id, size)? = reader.header(), let size {
            let stop = reader.position + size
            if id == ID.contentEncryption {
                track.compressed = true
                track.encrypted = true
            } else if id == ID.contentEncoding || id == ID.contentCompression {
                parseEncodings(&reader, end: stop, into: &track, depth: depth + 1)
                if id == ID.contentCompression, track.strippedHeader == nil { track.compressed = true }
            } else if id == ID.contentCompAlgo {
                // 3 is header stripping, which is easy to undo; the rest aren't supported.
                if reader.uint(size) == 3 { track.compressed = false } else { track.compressed = true }
            } else if id == ID.contentCompSettings {
                track.strippedHeader = reader.data(size)
            }
            reader.position = stop
        }
        if track.strippedHeader != nil, !track.encrypted { track.compressed = false }
    }

    private mutating func parseCluster(_ reader: inout Reader, end: Int, sized: Bool) {
        var clusterTime: Int64 = 0
        while reader.position < end {
            let mark = reader.position
            guard case let (id, size)? = reader.header() else { reader.position = end; return }
            if !sized, ID.topLevel.contains(id) {
                reader.position = mark
                return
            }
            guard let size else { reader.position = end; return }
            let start = reader.position
            switch id {
            case ID.clusterTimestamp:
                clusterTime = Int64(clamping: reader.uint(size))
            case ID.simpleBlock:
                parseBlock(&reader, start: start, size: size, clusterTime: clusterTime, keyframe: nil)
            case ID.blockGroup:
                var block: (Int, Int)?
                var referenced = false
                while reader.position < start + size, case let (child, length)? = reader.header(), let length {
                    if child == ID.block { block = (reader.position, length) }
                    if child == ID.referenceBlock { referenced = true }
                    reader.position += length
                }
                if let block {
                    reader.position = block.0
                    parseBlock(&reader, start: block.0, size: block.1, clusterTime: clusterTime, keyframe: !referenced)
                }
            default:
                break
            }
            reader.position = start + size
        }
    }

    /// A block holds one frame, or several "laced" together (common for sound).
    private mutating func parseBlock(_ reader: inout Reader, start: Int, size: Int, clusterTime: Int64,
                                     keyframe: Bool?) {
        let end = start + size
        guard let track = reader.vint(), reader.position + 3 <= end else { return }
        let relative = Int64(Int16(bitPattern: UInt16(reader.byte()) << 8 | UInt16(reader.byte())))
        let flags = reader.byte()
        let isKey = keyframe ?? (flags & 0x80 != 0)
        let (sum, overflowed) = clusterTime.addingReportingOverflow(relative)
        let (time, overflow) = sum.multipliedReportingOverflow(by: Int64(timestampScale))
        // Times beyond about 36 years are damage; keeping them out means every
        // difference between two frames' times fits.
        guard !overflowed, !overflow, abs(time) < 1 << 60 else { return }
        let lacing = (flags >> 1) & 0x3

        var sizes: [Int] = []
        if lacing != 0 {
            let count = Int(reader.byte()) + 1
            switch lacing {
            case 1: // Xiph
                for _ in 0..<(count - 1) {
                    var length = 0
                    var byte: UInt8 = 255
                    while byte == 255, reader.position < end {
                        byte = reader.byte()
                        length += Int(byte)
                    }
                    sizes.append(length)
                }
            case 3: // EBML
                guard let first = reader.vint(), first <= UInt64(size) else { return }
                var previous = Int(first)
                sizes.append(previous)
                for _ in 0..<max(count - 2, 0) {
                    guard case let (raw, length)? = reader.vintWithLength() else { return }
                    let delta = Int(raw) - ((1 << (7 * length - 1)) - 1)
                    previous += delta
                    // Each step is checked, so the sizes can't run away.
                    guard previous >= 0, previous <= size else { return }
                    sizes.append(previous)
                }
            default: // fixed
                let each = (end - reader.position) / count
                sizes = Array(repeating: each, count: count - 1)
            }
            guard sizes.allSatisfy({ $0 >= 0 && $0 <= size }) else { return }
            sizes.append(end - reader.position - sizes.reduce(0, +))
        } else {
            sizes = [end - reader.position]
        }

        let info = tracks.first { $0.number == track }
        let step = Int64(clamping: info?.defaultDuration ?? 0)
        var offset = reader.position
        for (index, length) in sizes.enumerated() where length > 0 && offset + length <= end {
            frames.append(Frame(track: track, offset: offset, size: length, time: time &+ step &* Int64(index),
                                keyframe: isKey))
            offset += length
        }
    }
}

/// Reads EBML: big-endian numbers whose first byte says how long they are.
private struct Reader {
    let bytes: UnsafeRawBufferPointer
    var position = 0
    var count: Int { bytes.count }

    mutating func byte() -> UInt8 {
        guard position < count else { return 0 }
        defer { position += 1 }
        return bytes[position]
    }

    /// An element's ID and size; nil size means "unknown" (written while recording).
    mutating func header() -> (UInt32, Int?)? {
        guard position < count else { return nil }
        let first = bytes[position]
        let length = first.leadingZeroBitCount + 1
        guard length <= 4, position + length <= count else { return nil }
        var id: UInt32 = 0
        for _ in 0..<length { id = id << 8 | UInt32(byte()) }
        guard case let (size, sizeLength)? = vintWithLength() else { return nil }
        let unknown = size == (UInt64(1) << (7 * UInt64(sizeLength))) - 1
        guard !unknown else { return (id, nil) }
        guard size <= UInt64(count - position) else { return (id, count - position) }
        return (id, Int(size))
    }

    mutating func vint() -> UInt64? { vintWithLength()?.0 }

    mutating func vintWithLength() -> (UInt64, Int)? {
        guard position < count else { return nil }
        let first = bytes[position]
        guard first != 0 else { return nil }
        let length = first.leadingZeroBitCount + 1
        guard position + length <= count else { return nil }
        var value = UInt64(byte() & (0xFF >> length))
        for _ in 1..<length { value = value << 8 | UInt64(byte()) }
        return (value, length)
    }

    mutating func uint(_ length: Int) -> UInt64 {
        var value: UInt64 = 0
        for _ in 0..<min(length, 8) { value = value << 8 | UInt64(byte()) }
        if length > 8 { position += length - 8 }
        return value
    }

    mutating func float(_ length: Int) -> Double {
        let bits = uint(length)
        switch length {
        case 4: return Double(Float(bitPattern: UInt32(truncatingIfNeeded: bits)))
        case 8: return Double(bitPattern: bits)
        default: return 0
        }
    }

    mutating func string(_ length: Int) -> String {
        let data = self.data(length)
        return String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
    }

    mutating func data(_ length: Int) -> Data {
        let end = min(position + length, count)
        defer { position = end }
        return Data(bytes[position..<end])
    }
}
