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
                if options.keepCompatibleStreams, audio.codec == "mp3" {
                    a += ["-c:a", "copy"] // already MP3: re-encoding would only lose quality
                } else {
                    a += ["-c:a", "libmp3lame", "-b:a", "\(options.mp3Bitrate)k"]
                    if (audio.channels ?? 2) > 2 { a += ["-ac", "2"] }
                    if rate > 48000 { a += ["-ar", "48000"] }
                }
            case .wav:
                var depth = options.wavBitDepth
                if depth == 0 { depth = audio.isLossless && (audio.bitsPerSample ?? 16) > 16 ? 24 : 16 }
                a += ["-c:a", depth == 24 ? "pcm_s24le" : "pcm_s16le"]
                if options.wavSampleRate != 0 { a += ["-ar", "\(options.wavSampleRate)"] }
            case .m4a:
                if options.keepCompatibleStreams, audio.codec == "aac" {
                    a += ["-c:a", "copy"]
                } else {
                    a += ["-c:a", "aac", "-b:a", "\(aacBitrate(channels: audio.channels, stereo: 256))k"]
                    if rate > 48000 { a += ["-ar", "48000"] }
                }
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
            a += ["-map", "0:a?", "-sn", "-dn", "-map_metadata", "0"]
            if keepsVideo(preset: preset, options: options, info: info) {
                a += ["-c:v", "copy"]
                if video.codec == "hevc" { a += ["-tag:v", "hvc1"] }
            } else {
                a += ["-vf", filters(video, options, pixelFormat: "yuv420p")]
                if options.encoder == .fast {
                    let q = [Quality.high: "75", .medium: "60", .small: "45"][options.quality]!
                    a += ["-c:v", "h264_videotoolbox", "-q:v", q, "-profile:v", "high", "-allow_sw", "1"]
                } else {
                    let crf = [Quality.high: "16", .medium: "20", .small: "25"][options.quality]!
                    a += ["-c:v", "libx264", "-preset", "medium", "-crf", crf, "-profile:v", "high"]
                }
                a += ["-pix_fmt", "yuv420p"]
            }
            if hasAudio {
                if options.keepCompatibleStreams, info.audio.allSatisfy({ $0.codec == "aac" }) {
                    a += ["-c:a", "copy"]
                } else {
                    let channels = info.audio.compactMap(\.channels).max()
                    a += ["-c:a", "aac", "-b:a", "\(aacBitrate(channels: channels, stereo: 320))k", "-ar", "48000"]
                }
            }
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
                let crf = [Quality.high: "20", .medium: "24", .small: "28"][options.quality]!
                a += ["-c:v", "libx265", "-preset", "medium", "-crf", crf]
            }
            a += ["-pix_fmt", "yuv420p", "-tag:v", "hvc1"]
            if hasAudio { a += ["-c:a", "aac", "-b:a", "192k", "-ar", "48000"] }
            a += ["-movflags", "+faststart"]

        case .webm:
            let crf = [Quality.high: "24", .medium: "31", .small: "37"][options.quality]!
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

    /// AAC bitrate in kbps, scaled up for surround so each channel keeps the same share.
    static func aacBitrate(channels: Int?, stereo: Int) -> Int {
        let n = max(channels ?? 2, 2)
        return stereo * n / 2
    }

    /// True when Premiere-safe MP4 can pass the video through untouched: it is already in a form Premiere reads,
    /// nothing asks for it to change, and something else about the file (container or audio) explains why it
    /// needs converting. A file with no visible problem at all is re-encoded in full, since whatever is wrong
    /// with it is hidden and a copy would carry it over.
    public static func keepsVideo(preset: Preset, options: Options, info: MediaInfo) -> Bool {
        guard preset == .premiereMP4, options.keepCompatibleStreams, let v = info.video else { return false }
        guard v.codec == "h264" ? (v.bitDepth == 8 && v.is420) : (v.codec == "hevc" && v.is420) else { return false }
        guard !v.isVariableFrameRate, !v.isInterlaced, v.width % 2 == 0, v.height % 2 == 0 else { return false }
        guard options.frameRate == nil, options.maxHeight.map({ v.height <= $0 }) ?? true else { return false }
        guard info.duration != nil else { return false }
        return !Diagnosis.issues(for: info).isEmpty
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
            chain.append("scale=-2:'trunc(min(ih,\(h))/2)*2':flags=lanczos")
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
