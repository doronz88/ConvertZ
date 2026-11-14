import Foundation

/// What ffprobe reports about a file, reduced to the fields the app uses.
public struct MediaInfo: Equatable, Sendable {
    public struct Video: Equatable, Sendable {
        public var index: Int
        public var codec: String
        public var width: Int
        public var height: Int
        public var pixelFormat: String?
        public var realFrameRate: Double?
        public var averageFrameRate: Double?
        public var fieldOrder: String?
        public var colorTransfer: String?
        /// Set from actual frame timestamps when they were measured; headers alone miss variable frame rate in MKV.
        public var measuredVariable: Bool?
        /// True when that measurement read every frame of the file rather than just its first two minutes.
        public var timingCoversWholeFile = false

        public init(index: Int, codec: String, width: Int, height: Int, pixelFormat: String? = nil,
                    realFrameRate: Double? = nil, averageFrameRate: Double? = nil, fieldOrder: String? = nil,
                    colorTransfer: String? = nil) {
            self.index = index; self.codec = codec; self.width = width; self.height = height
            self.pixelFormat = pixelFormat; self.realFrameRate = realFrameRate
            self.averageFrameRate = averageFrameRate; self.fieldOrder = fieldOrder; self.colorTransfer = colorTransfer
        }

        public var bitDepth: Int {
            guard let p = pixelFormat else { return 8 }
            for depth in [16, 14, 12, 10, 9] where p.contains("p\(depth)") || p.hasSuffix("\(depth)le") || p.hasSuffix("\(depth)be") {
                return depth
            }
            return 8
        }

        /// True for 4:2:0 chroma (or unknown), false for 4:2:2 / 4:4:4 / RGB.
        public var is420: Bool {
            guard let p = pixelFormat else { return true }
            return p.contains("420") || p.hasPrefix("nv12") || p.hasPrefix("nv21") || p.hasPrefix("p010")
        }

        public var isInterlaced: Bool {
            guard let f = fieldOrder else { return false }
            return ["tt", "bb", "tb", "bt"].contains(f)
        }

        public var isHDR: Bool { colorTransfer == "smpte2084" || colorTransfer == "arib-std-b67" }

        public var isVariableFrameRate: Bool {
            if measuredVariable == true { return true }
            guard let r = realFrameRate, let a = averageFrameRate, a > 0, r > 0 else { return false }
            return abs(r - a) / a > 0.01
        }
    }

    public struct Audio: Equatable, Sendable {
        public var index: Int
        public var codec: String
        public var sampleRate: Int?
        public var channels: Int?
        /// Bits per sample for lossless sources (PCM, FLAC, ALAC); nil when unknown or lossy.
        public var bitsPerSample: Int?
        /// Codec profile as ffprobe names it, e.g. "LC" or "HE-AAC".
        public var profile: String?

        public init(index: Int, codec: String, sampleRate: Int? = nil, channels: Int? = nil, bitsPerSample: Int? = nil,
                    profile: String? = nil) {
            self.index = index; self.codec = codec; self.sampleRate = sampleRate; self.channels = channels
            self.bitsPerSample = bitsPerSample; self.profile = profile
        }

        /// Plain AAC-LC at 44.1 or 48 kHz, mono or stereo: the only AAC that is safe to hand Premiere as-is.
        public var isPremiereSafeAAC: Bool {
            codec == "aac" && profile == "LC" && [44100, 48000].contains(sampleRate ?? 0) && (1...2).contains(channels ?? 0)
        }

        public var isLossless: Bool { codec.hasPrefix("pcm_") || ["flac", "alac", "wavpack", "ape", "tta"].contains(codec) }
    }

    public var formatName: String
    /// Timestamp of the first frame; files that do not start near zero are not safe to copy streams from.
    public var startTime: Double?
    public var duration: Double?
    public var video: Video?
    public var audio: [Audio]

    public init(formatName: String, duration: Double? = nil, video: Video? = nil, audio: [Audio] = []) {
        self.formatName = formatName; self.duration = duration; self.video = video; self.audio = audio
    }

    public enum ParseError: Error { case notMedia }

    /// Parses `ffprobe -print_format json -show_format -show_streams` output.
    public static func parse(json data: Data) throws -> MediaInfo {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let format = root["format"] as? [String: Any],
              let streams = root["streams"] as? [[String: Any]] else { throw ParseError.notMedia }

        var video: Video?
        var audio: [Audio] = []
        var streamDuration: Double?
        for s in streams {
            let index = int(s["index"]) ?? 0
            let codec = s["codec_name"] as? String ?? "unknown"
            if let d = double(s["duration"]), d > 0 { streamDuration = max(streamDuration ?? 0, d) }
            switch s["codec_type"] as? String {
            case "video":
                // Cover art in audio files shows up as a video stream; it is not real video.
                let disposition = s["disposition"] as? [String: Any]
                if int(disposition?["attached_pic"]) == 1 { continue }
                guard video == nil, let w = int(s["width"]), let h = int(s["height"]), w > 0, h > 0 else { continue }
                video = Video(index: index, codec: codec, width: w, height: h,
                              pixelFormat: s["pix_fmt"] as? String,
                              realFrameRate: rate(s["r_frame_rate"]), averageFrameRate: rate(s["avg_frame_rate"]),
                              fieldOrder: s["field_order"] as? String, colorTransfer: s["color_transfer"] as? String)
            case "audio":
                var bits = int(s["bits_per_raw_sample"]) ?? 0
                if bits == 0 { bits = int(s["bits_per_sample"]) ?? 0 }
                if bits == 0, let fmt = s["sample_fmt"] as? String {
                    bits = fmt.hasPrefix("s16") ? 16 : (fmt.hasPrefix("s32") || fmt.hasPrefix("flt") || fmt.hasPrefix("dbl")) ? 24 : 0
                }
                audio.append(Audio(index: index, codec: codec, sampleRate: int(s["sample_rate"]), channels: int(s["channels"]),
                                   bitsPerSample: bits > 0 ? bits : nil, profile: s["profile"] as? String))
            default:
                break
            }
        }
        guard video != nil || !audio.isEmpty else { throw ParseError.notMedia }
        var duration = double(format["duration"])
        if duration == nil || duration! <= 0 { duration = streamDuration }
        var info = MediaInfo(formatName: format["format_name"] as? String ?? "", duration: duration, video: video, audio: audio)
        info.startTime = double(format["start_time"])
        return info
    }

    /// One-line plain description, e.g. "HEVC 10-bit · 3840×2160 · 29.97 fps (variable) · Opus 48 kHz".
    public var summary: String {
        var parts: [String] = []
        if let v = video {
            var codec = Self.displayName(v.codec)
            if v.bitDepth > 8 { codec += " \(v.bitDepth)-bit" }
            parts.append(codec)
            parts.append("\(v.width)×\(v.height)")
            if let fps = v.averageFrameRate ?? v.realFrameRate, fps > 0 {
                parts.append(Self.trim(fps) + " fps" + (v.isVariableFrameRate ? " (variable)" : ""))
            }
        }
        if let a = audio.first {
            var text = Self.displayName(a.codec)
            if let r = a.sampleRate { text += " " + Self.trim(Double(r) / 1000) + " kHz" }
            if audio.count > 1 { text += " ×\(audio.count)" }
            parts.append(text)
        } else if video != nil {
            parts.append("no audio")
        }
        return parts.joined(separator: " · ")
    }

    static func displayName(_ codec: String) -> String {
        let names = ["h264": "H.264", "hevc": "HEVC", "prores": "ProRes", "vp9": "VP9", "vp8": "VP8", "av1": "AV1",
                     "mpeg4": "MPEG-4", "mpeg2video": "MPEG-2", "aac": "AAC", "mp3": "MP3", "opus": "Opus",
                     "vorbis": "Vorbis", "flac": "FLAC", "ac3": "AC-3", "eac3": "E-AC-3", "alac": "ALAC",
                     "dnxhd": "DNxHD", "theora": "Theora", "gif": "GIF"]
        if let n = names[codec] { return n }
        if codec.hasPrefix("pcm_") { return "PCM" }
        return codec.uppercased()
    }

    static func trim(_ value: Double) -> String {
        var s = String(format: "%.2f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    private static func int(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }

    private static func double(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    /// "30000/1001" → 29.97; "0/0" → nil.
    static func rate(_ any: Any?) -> Double? {
        guard let s = any as? String else { return nil }
        let parts = s.split(separator: "/")
        guard let num = Double(parts.first ?? ""), num > 0 else { return nil }
        let den = parts.count > 1 ? (Double(parts[1]) ?? 0) : 1
        guard den > 0 else { return nil }
        return num / den
    }
}
