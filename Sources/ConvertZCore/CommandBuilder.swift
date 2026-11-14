import Foundation

public enum FrameRate {
    static let standards: [(String, Double)] = [
        ("24000/1001", 24000.0 / 1001), ("24", 24), ("25", 25), ("30000/1001", 30000.0 / 1001), ("30", 30),
        ("50", 50), ("60000/1001", 60000.0 / 1001), ("60", 60), ("100", 100), ("120", 120), ("240", 240),
    ]

    /// The constant frame rate to encode at, as an ffmpeg rate string.
    /// Snaps to a standard rate when the source's average is within 3% of one; otherwise keeps the source's own
    /// average, so a 12 fps screen recording stays 12 fps and 120 fps slow motion keeps its frames.
    public static func target(average: Double?, real: Double?) -> String {
        func usable(_ v: Double?) -> Double? {
            guard let v, v.isFinite, v >= 1, v <= 300 else { return nil }
            return v
        }
        guard let fps = usable(average) ?? usable(real) else { return "30" }
        let nearest = standards.min { abs($0.1 - fps) < abs($1.1 - fps) }!
        if abs(nearest.1 - fps) / fps <= 0.03 { return nearest.0 }
        return MediaInfo.trim((fps * 1000).rounded() / 1000)
    }
}

public enum CommandBuilder {
    public enum BuildError: Error, LocalizedError, Equatable {
        case noVideo, noAudio
        public var errorDescription: String? {
            switch self {
            case .noVideo: return "This file has no video, so it can't be converted to a video format"
            case .noAudio: return "This file has no audio, so it can't be converted to an audio format"
            }
        }
    }

    /// Arguments for ffmpeg (everything after the executable). `output` must end in the preset's extension.
    public static func arguments(preset: Preset, options: Options, info: MediaInfo, input: String,
                                 output: String) throws -> [String] {
        var a = ["-hide_banner", "-nostdin", "-y", "-i", input]

        if preset.isAudio {
            guard let audio = info.audio.first else { throw BuildError.noAudio }
            a += ["-map", "0:\(audio.index)", "-vn", "-sn", "-dn", "-map_metadata", "0"]
            let rate = audio.sampleRate ?? 48000
            switch preset {
            case .mp3:
                a += ["-c:a", "libmp3lame", "-b:a", "\(options.mp3Bitrate)k"]
                if (audio.channels ?? 2) > 2 { a += ["-ac", "2"] }
                if rate > 48000 { a += ["-ar", "48000"] }
            case .wav:
                a += ["-c:a", options.wavBitDepth == 24 ? "pcm_s24le" : "pcm_s16le", "-ar", "\(options.wavSampleRate)"]
            case .m4a:
                a += ["-c:a", "aac", "-b:a", "256k"]
                if rate > 48000 { a += ["-ar", "48000"] }
            default:
                a += ["-c:a", "flac"]
            }
            return a + tail(output)
        }

        guard let video = info.video else { throw BuildError.noVideo }
        a += ["-map", "0:\(video.index)"]
        let hasAudio = !info.audio.isEmpty

        switch preset {
        case .rewrapMP4:
            a += ["-map", "0:a?", "-sn", "-dn", "-map_metadata", "0", "-c", "copy", "-movflags", "+faststart"]

        case .gif:
            a += ["-an", "-sn", "-dn",
                  "-vf", "fps=15,scale='min(640,iw)':-2:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse",
                  "-loop", "0"]

        case .premiereMP4:
            a += ["-map", "0:a?", "-sn", "-dn", "-map_metadata", "0",
                  "-vf", filters(video, options, pixelFormat: "yuv420p")]
            if options.encoder == .fast {
                let q = [Quality.high: "70", .medium: "58", .small: "45"][options.quality]!
                a += ["-c:v", "h264_videotoolbox", "-q:v", q, "-profile:v", "high", "-allow_sw", "1"]
            } else {
                let crf = [Quality.high: "18", .medium: "22", .small: "26"][options.quality]!
                a += ["-c:v", "libx264", "-preset", "medium", "-crf", crf, "-profile:v", "high"]
            }
            a += ["-pix_fmt", "yuv420p"]
            if hasAudio { a += ["-c:a", "aac", "-b:a", "320k", "-ar", "48000"] }
            a += ["-movflags", "+faststart"]

        case .prores:
            a += ["-map", "0:a?", "-sn", "-dn", "-map_metadata", "0",
                  "-vf", filters(video, options, pixelFormat: "yuv422p10le"),
                  "-c:v", "prores_ks", "-profile:v", options.proresProfile.ffmpegProfile, "-vendor", "apl0",
                  "-pix_fmt", "yuv422p10le"]
            if hasAudio { a += ["-c:a", "pcm_s16le", "-ar", "48000"] }

        case .hevcMP4:
            a += ["-map", "0:a?", "-sn", "-dn", "-map_metadata", "0",
                  "-vf", filters(video, options, pixelFormat: "yuv420p")]
            if options.encoder == .fast {
                let q = [Quality.high: "65", .medium: "52", .small: "40"][options.quality]!
                a += ["-c:v", "hevc_videotoolbox", "-q:v", q, "-allow_sw", "1"]
            } else {
                let crf = [Quality.high: "22", .medium: "26", .small: "30"][options.quality]!
                a += ["-c:v", "libx265", "-preset", "medium", "-crf", crf]
            }
            a += ["-pix_fmt", "yuv420p", "-tag:v", "hvc1"]
            if hasAudio { a += ["-c:a", "aac", "-b:a", "192k", "-ar", "48000"] }
            a += ["-movflags", "+faststart"]

        case .webm:
            let crf = [Quality.high: "28", .medium: "33", .small: "38"][options.quality]!
            a += ["-map", "0:a?", "-sn", "-dn",
                  "-vf", filters(video, options, pixelFormat: "yuv420p"),
                  "-c:v", "libvpx-vp9", "-crf", crf, "-b:v", "0", "-row-mt", "1", "-cpu-used", "2",
                  "-pix_fmt", "yuv420p"]
            if hasAudio { a += ["-c:a", "libopus", "-b:a", "128k"] }

        default:
            break
        }
        return a + tail(output)
    }

    private static func tail(_ output: String) -> [String] {
        ["-progress", "pipe:1", "-nostats", output]
    }

    /// Deinterlace if needed, make dimensions even (optionally scaling down), force a constant frame rate,
    /// and convert to the target pixel format.
    static func filters(_ video: MediaInfo.Video, _ options: Options, pixelFormat: String) -> String {
        var chain: [String] = []
        if video.isInterlaced { chain.append("bwdif=mode=send_frame:parity=auto:deint=all") }
        if let h = options.maxHeight {
            chain.append("scale=-2:'trunc(min(ih,\(h))/2)*2'")
        } else {
            chain.append("scale=trunc(iw/2)*2:trunc(ih/2)*2")
        }
        let rate = options.frameRate ?? FrameRate.target(average: video.averageFrameRate, real: video.realFrameRate)
        chain.append("fps=\(rate)")
        chain.append("format=\(pixelFormat)")
        return chain.joined(separator: ",")
    }

    /// The command as it could be pasted into Terminal.
    public static func shellCommand(_ arguments: [String]) -> String {
        (["ffmpeg"] + arguments).map { arg in
            let safe = arg.allSatisfy { $0.isLetter || $0.isNumber || "-_./:=+,?".contains($0) }
            return safe && !arg.isEmpty ? arg : "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }
}
