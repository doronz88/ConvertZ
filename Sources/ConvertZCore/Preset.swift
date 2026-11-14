import Foundation

public enum Preset: String, CaseIterable, Codable, Identifiable, Sendable {
    case premiereMP4, prores, rewrapMP4, hevcMP4, webm, gif
    case mp3, wav, m4a, flac

    public var id: String { rawValue }

    public static let video: [Preset] = [.premiereMP4, .prores, .rewrapMP4, .hevcMP4, .webm, .gif]
    public static let audio: [Preset] = [.mp3, .wav, .m4a, .flac]

    public var title: String {
        switch self {
        case .premiereMP4: return "Premiere-safe MP4"
        case .prores: return "ProRes MOV (editing)"
        case .rewrapMP4: return "Rewrap to MP4 (no re-encode)"
        case .hevcMP4: return "H.265 MP4 (small)"
        case .webm: return "WebM"
        case .gif: return "GIF"
        case .mp3: return "MP3"
        case .wav: return "WAV"
        case .m4a: return "M4A (AAC)"
        case .flac: return "FLAC"
        }
    }

    public var blurb: String {
        switch self {
        case .premiereMP4: return "H.264 with a constant frame rate and AAC audio. Fixes files Premiere refuses to import."
        case .prores: return "Large files that edit smoothly. Constant frame rate, uncompressed audio."
        case .rewrapMP4: return "Instant and lossless: moves the same video and audio into an MP4. Fails if they don't fit in MP4."
        case .hevcMP4: return "Small files for sharing. Not ideal for editing."
        case .webm: return "VP9 video and Opus audio, for the web."
        case .gif: return "Animated GIF, 15 fps, up to 640 px wide, no sound."
        case .mp3: return "Constant-bitrate MP3."
        case .wav: return "Uncompressed audio. The safest audio format for Premiere."
        case .m4a: return "AAC audio at 256 kbps."
        case .flac: return "Lossless compressed audio."
        }
    }

    public var fileExtension: String {
        switch self {
        case .premiereMP4, .rewrapMP4, .hevcMP4: return "mp4"
        case .prores: return "mov"
        case .webm: return "webm"
        case .gif: return "gif"
        case .mp3: return "mp3"
        case .wav: return "wav"
        case .m4a: return "m4a"
        case .flac: return "flac"
        }
    }

    public var isAudio: Bool { Preset.audio.contains(self) }

    /// Presets where the Quality / Encoder / Resolution / Frame rate options apply.
    public var hasQuality: Bool { self == .premiereMP4 || self == .hevcMP4 || self == .webm }
    public var hasEncoderChoice: Bool { self == .premiereMP4 || self == .hevcMP4 }
    public var hasVideoShape: Bool { [.premiereMP4, .prores, .hevcMP4, .webm].contains(self) }
    /// Presets that can pass a stream through untouched when it is already in the target format.
    public var canKeepStreams: Bool { [.premiereMP4, .mp3, .m4a].contains(self) }
}

public enum Quality: String, CaseIterable, Codable, Identifiable, Sendable {
    case high, medium, small
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .high: return "High"
        case .medium: return "Medium"
        case .small: return "Small file"
        }
    }
}

public enum Encoder: String, CaseIterable, Codable, Identifiable, Sendable {
    case best, fast
    public var id: String { rawValue }
    public var title: String { self == .best ? "Best quality" : "Fast (hardware)" }
}

public enum ProResProfile: String, CaseIterable, Codable, Identifiable, Sendable {
    case proxy, lt, standard, hq
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .proxy: return "Proxy"
        case .lt: return "LT"
        case .standard: return "422"
        case .hq: return "422 HQ"
        }
    }
    var ffmpegProfile: String {
        switch self {
        case .proxy: return "0"
        case .lt: return "1"
        case .standard: return "2"
        case .hq: return "3"
        }
    }
    /// Approximate megabits per second at 1920×1080, 30 fps, for disk-space estimates.
    public var megabitsAt1080p30: Double {
        switch self {
        case .proxy: return 45
        case .lt: return 102
        case .standard: return 147
        case .hq: return 220
        }
    }
}

public struct Options: Codable, Equatable, Sendable {
    public var quality: Quality = .high
    public var encoder: Encoder = .best
    /// nil keeps the source resolution; otherwise the output is scaled down to at most this height.
    public var maxHeight: Int?
    /// nil picks a constant rate from the source; otherwise an ffmpeg rate such as "30000/1001".
    public var frameRate: String?
    public var proresProfile: ProResProfile = .standard
    public var mp3Bitrate: Int = 320
    /// 0 keeps the source's depth (24-bit for lossless sources deeper than 16 bits, otherwise 16-bit).
    public var wavBitDepth: Int = 0
    /// 0 keeps the source's sample rate.
    public var wavSampleRate: Int = 0
    /// Copy video or audio untouched when it is already in the target format, instead of re-encoding it.
    public var keepCompatibleStreams: Bool = true

    public init() {}

    public static let frameRateChoices: [(title: String, value: String?)] = [
        ("Match source", nil), ("23.976", "24000/1001"), ("24", "24"), ("25", "25"), ("29.97", "30000/1001"),
        ("30", "30"), ("50", "50"), ("59.94", "60000/1001"), ("60", "60"),
    ]
    public static let heightChoices: [(title: String, value: Int?)] = [
        ("Keep original", nil), ("Up to 4K (2160p)", 2160), ("Up to 1080p", 1080), ("Up to 720p", 720),
    ]
}
