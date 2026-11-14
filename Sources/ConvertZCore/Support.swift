import Foundation

/// Parses ffmpeg's `-progress pipe:1` key=value stream.
public struct ProgressParser {
    private var buffer = Data()
    public private(set) var seconds: Double = 0
    public private(set) var finished = false

    public init() {}

    /// Feeds a chunk of stdout. Returns true when the encoded position changed.
    public mutating func feed(_ chunk: Data) -> Bool {
        buffer.append(chunk)
        var changed = false
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch parts[0] {
            case "out_time_us", "out_time_ms": // both are microseconds, despite the name
                if let us = Double(value), us >= 0 { seconds = us / 1_000_000; changed = true }
            case "progress":
                if value == "end" { finished = true }
            default:
                break
            }
        }
        return changed
    }
}

public enum OutputNaming {
    /// Where the converted file goes. Never the source itself and never an existing file.
    public static func destination(source: URL, folder: URL, fileExtension: String,
                                   exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let stem = source.deletingPathExtension().lastPathComponent
        func candidate(_ name: String) -> URL { folder.appendingPathComponent(name + "." + fileExtension) }
        var base = stem
        if candidate(base).standardizedFileURL.path == source.standardizedFileURL.path { base = stem + " converted" }
        var url = candidate(base)
        var n = 1
        while exists(url) {
            url = candidate("\(base) (\(n))")
            n += 1
        }
        return url
    }

    /// Hidden in-progress file next to the destination; renamed onto it on success.
    public static func partial(for destination: URL) -> URL {
        let stem = destination.deletingPathExtension().lastPathComponent
        return destination.deletingLastPathComponent()
            .appendingPathComponent(".\(stem).convertz-partial.\(destination.pathExtension)")
    }
}

public enum ErrorMapper {
    /// A short human reason for a failed ffmpeg run, from its log.
    public static func reason(log: String) -> String {
        let l = log.lowercased()
        let table: [(String, String)] = [
            ("no space left on device", "The disk is full"),
            ("permission denied", "No permission to write to the destination folder"),
            ("operation not permitted", "macOS blocked access to this file or folder"),
            ("read-only file system", "The destination is read-only"),
            ("moov atom not found", "The file is incomplete or damaged (missing index)"),
            ("invalid data found when processing input", "The file is damaged or not a media file"),
            ("could not find tag for codec", "These streams can't be stored in this format without re-encoding. Try Premiere-safe MP4"),
            ("not currently supported in container", "These streams can't be stored in this format without re-encoding. Try Premiere-safe MP4"),
            ("codec not supported", "These streams can't be stored in this format without re-encoding. Try Premiere-safe MP4"),
            ("does not contain any stream", "Nothing in this file can be converted to that format"),
            ("matches no streams", "Nothing in this file can be converted to that format"),
            ("decoder not found", "ffmpeg has no decoder for this file's codec"),
            ("error while opening encoder", "The encoder rejected this video (unusual size or format)"),
            ("no such file or directory", "The file was moved or deleted"),
        ]
        for (needle, message) in table where l.contains(needle) { return message }
        return "ffmpeg could not convert this file"
    }
}

public enum FFmpegLocator {
    /// Finds ffmpeg and ffprobe: an override directory, the app bundle, then Homebrew.
    public static func locate() -> (ffmpeg: URL, ffprobe: URL)? {
        var dirs: [URL] = []
        if let override = ProcessInfo.processInfo.environment["CONVERTZ_FFMPEG_DIR"] {
            dirs.append(URL(fileURLWithPath: override))
        }
        dirs.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers"))
        dirs.append(URL(fileURLWithPath: "/opt/homebrew/bin"))
        dirs.append(URL(fileURLWithPath: "/usr/local/bin"))
        let fm = FileManager.default
        for dir in dirs {
            let ffmpeg = dir.appendingPathComponent("ffmpeg"), ffprobe = dir.appendingPathComponent("ffprobe")
            if fm.isExecutableFile(atPath: ffmpeg.path), fm.isExecutableFile(atPath: ffprobe.path) {
                return (ffmpeg, ffprobe)
            }
        }
        return nil
    }
}

public enum Prober {
    /// Runs ffprobe synchronously. Call off the main thread.
    public static func probe(_ file: URL, ffprobe: URL) throws -> MediaInfo {
        let process = Process()
        process.executableURL = ffprobe
        process.arguments = ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", file.path]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw MediaInfo.ParseError.notMedia }
        var info = try MediaInfo.parse(json: data)
        if let video = info.video, let timing = measureTiming(file, stream: video.index, ffprobe: ffprobe) {
            info.video?.measuredVariable = timing.variable
            // MKV/WebM headers carry a nominal rate, not the real average, so trust the measurement there.
            if info.formatName.contains("matroska") || info.formatName.contains("webm") || video.averageFrameRate == nil {
                info.video?.averageFrameRate = timing.framesPerSecond
            }
        }
        return info
    }

    /// Reads the frame timestamps of the first 30 seconds (packet headers only, so it is quick).
    static func measureTiming(_ file: URL, stream: Int, ffprobe: URL) -> FrameTiming? {
        let process = Process()
        process.executableURL = ffprobe
        process.arguments = ["-v", "error", "-select_streams", "\(stream)", "-read_intervals", "%+30",
                             "-show_entries", "packet=pts_time", "-of", "csv=p=0", file.path]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let times = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
            .compactMap { Double($0.trimmingCharacters(in: CharacterSet(charactersIn: ", "))) }
        return FrameTiming(timestamps: times)
    }
}

/// Whether frames are evenly spaced, judged from their timestamps.
public struct FrameTiming: Equatable {
    public let variable: Bool
    public let framesPerSecond: Double

    public init?(timestamps: [Double]) {
        let sorted = timestamps.sorted()
        guard sorted.count >= 10, let first = sorted.first, let last = sorted.last, last > first else { return nil }
        let gaps = zip(sorted.dropFirst(), sorted).map { $0 - $1 }.sorted()
        let median = gaps[gaps.count / 2]
        guard median > 0 else { return nil }
        // Timestamps are rounded (to 1 ms in MKV), so allow some jitter before calling a gap irregular.
        let tolerance = max(median * 0.25, 0.0021)
        let irregular = gaps.filter { abs($0 - median) > tolerance }.count
        variable = Double(irregular) / Double(gaps.count) > 0.02
        framesPerSecond = Double(sorted.count - 1) / (last - first)
    }
}
