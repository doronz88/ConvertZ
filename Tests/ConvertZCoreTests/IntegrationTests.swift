import XCTest
@testable import ConvertZCore

/// Runs the real ffmpeg on small generated clips and checks what comes out. Skipped when ffmpeg is unavailable.
final class IntegrationTests: XCTestCase {
    static var tools: (ffmpeg: URL, ffprobe: URL)?
    static var dir: URL!

    override class func setUp() {
        tools = FFmpegLocator.locate()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("convertz-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override class func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func tools() throws -> (ffmpeg: URL, ffprobe: URL) {
        try XCTUnwrap(Self.tools.map { $0 } ?? { throw XCTSkip("ffmpeg not found") }())
    }

    @discardableResult
    private func ffmpeg(_ args: [String]) throws -> (status: Int32, log: String) {
        let p = Process()
        p.executableURL = try tools().ffmpeg
        p.arguments = args
        let err = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let log = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (p.terminationStatus, log)
    }

    private func make(_ name: String, _ args: [String]) throws -> URL {
        let url = Self.dir.appendingPathComponent(name)
        let result = try ffmpeg(["-hide_banner", "-y"] + args + [url.path])
        XCTAssertEqual(result.status, 0, "generating \(name): \(result.log.suffix(600))")
        return url
    }

    private func convert(_ source: URL, _ preset: Preset, _ options: Options = Options()) throws -> MediaInfo {
        let info = try Prober.probe(source, ffprobe: try tools().ffprobe)
        let out = OutputNaming.destination(source: source, folder: Self.dir, fileExtension: preset.fileExtension)
        let args = try CommandBuilder.arguments(preset: preset, options: options, info: info, input: source.path, output: out.path)
        let result = try ffmpeg(args)
        XCTAssertEqual(result.status, 0, "\(preset) on \(source.lastPathComponent): \(result.log.suffix(800))")
        return try Prober.probe(out, ffprobe: try tools().ffprobe)
    }

    private let tone = ["-f", "lavfi", "-i", "sine=frequency=440:duration=3"]

    func testNastyMKVBecomesPremiereSafe() throws {
        // Variable frame rate, 10-bit HEVC, odd width, Opus audio, in MKV.
        let src = try make("nasty.mkv", ["-f", "lavfi", "-i", "testsrc2=size=321x240:rate=30:duration=3"] + tone + [
            "-vf", "select='lt(n,20)+not(mod(n,3))'", "-fps_mode", "vfr",
            "-c:v", "libx265", "-pix_fmt", "yuv420p10le", "-c:a", "libopus"])
        let before = try Prober.probe(src, ffprobe: try tools().ffprobe)
        XCTAssertEqual(before.video?.isVariableFrameRate, true, "variable frame rate must be detected even in MKV")
        XCTAssertTrue(Diagnosis.issues(for: before).contains { $0.contains("Variable frame rate") })

        let after = try convert(src, .premiereMP4)
        let v = try XCTUnwrap(after.video)
        XCTAssertEqual(v.codec, "h264")
        XCTAssertEqual(v.pixelFormat, "yuv420p")
        XCTAssertEqual(v.width % 2, 0)
        XCTAssertFalse(v.isVariableFrameRate)
        XCTAssertEqual(after.audio.first?.codec, "aac")
        XCTAssertEqual(after.audio.first?.sampleRate, 48000)
        XCTAssertTrue(after.formatName.contains("mp4"))
        XCTAssertEqual(after.duration ?? 0, 3, accuracy: 0.5)
        XCTAssertEqual(Diagnosis.issues(for: after), [])
    }

    func testFastEncoderAndDownscale() throws {
        let src = try make("big.mp4", ["-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=30000/1001:duration=2",
                                        "-c:v", "libx264", "-preset", "ultrafast"])
        var o = Options(); o.maxHeight = 720
        // CI machines are virtual and have no hardware encoder.
        if ProcessInfo.processInfo.environment["CI"] == nil { o.encoder = .fast }
        let after = try convert(src, .premiereMP4, o)
        XCTAssertEqual(after.video?.height, 720)
        XCTAssertEqual(after.video?.width, 1280)
        XCTAssertEqual(after.video?.averageFrameRate ?? 0, 29.97, accuracy: 0.01)
        XCTAssertTrue(after.audio.isEmpty)
    }

    func testOtherVideoPresets() throws {
        let src = try make("plain.mp4", ["-f", "lavfi", "-i", "testsrc2=size=320x240:rate=25:duration=2"] + tone + [
            "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", "-shortest"])
        XCTAssertEqual(try convert(src, .prores).video?.codec, "prores")
        XCTAssertEqual(try convert(src, .hevcMP4).video?.codec, "hevc")
        XCTAssertEqual(try convert(src, .webm).video?.codec, "vp9")
        XCTAssertEqual(try convert(src, .gif).video?.codec, "gif")
        let rewrapped = try convert(src, .rewrapMP4)
        XCTAssertEqual(rewrapped.video?.codec, "h264")
        XCTAssertEqual(rewrapped.audio.first?.codec, "aac")
    }

    func testCompatibleVideoIsCopiedNotReencoded() throws {
        // An OBS-style MKV: good H.264, but Opus audio in a container Premiere can't open.
        let src = try make("obs.mkv", ["-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30:duration=3"] + tone + [
            "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-c:a", "libopus"])
        let before = try Prober.probe(src, ffprobe: try tools().ffprobe)
        XCTAssertEqual(before.video?.isVariableFrameRate, false)
        XCTAssertTrue(CommandBuilder.keepsVideo(preset: .premiereMP4, options: Options(), info: before))
        let after = try convert(src, .premiereMP4)
        XCTAssertEqual(after.video?.codec, "h264")
        XCTAssertEqual(after.audio.first?.codec, "aac")
        XCTAssertEqual(Diagnosis.issues(for: after), [])
        XCTAssertEqual(after.duration ?? 0, 3, accuracy: 0.3)
        // Bit-for-bit copy: the video stream's checksum is unchanged.
        func videoHash(_ url: URL) throws -> String {
            let p = Process()
            p.executableURL = try tools().ffmpeg
            p.arguments = ["-v", "error", "-i", url.path, "-map", "0:v:0", "-c", "copy", "-f", "hash", "-"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try p.run()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let out = Self.dir.appendingPathComponent("obs.mp4")
        XCTAssertFalse(try videoHash(src).isEmpty)
        XCTAssertEqual(try videoHash(src), try videoHash(out))
    }

    func testAudioPresets() throws {
        let src = try make("song.flac", ["-f", "lavfi", "-i", "sine=frequency=440:duration=2:sample_rate=44100"])
        XCTAssertEqual(try convert(src, .mp3).audio.first?.codec, "mp3")
        let wav = try convert(src, .wav)
        XCTAssertEqual(wav.audio.first?.codec, "pcm_s16le")
        XCTAssertEqual(wav.audio.first?.sampleRate, 44100, "WAV keeps the source's sample rate")
        XCTAssertEqual(try convert(src, .m4a).audio.first?.codec, "aac")
        // Audio out of a video file.
        let video = try make("withsound.mkv", ["-f", "lavfi", "-i", "testsrc2=size=320x240:rate=25:duration=2"] + tone + [
            "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "libopus", "-shortest"])
        let fromVideo = try convert(video, .flac)
        XCTAssertNil(fromVideo.video)
        XCTAssertEqual(fromVideo.audio.first?.codec, "flac")
    }

    func testRunnerReportsProgressAndCancels() throws {
        let src = try make("long.mp4", ["-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30:duration=20",
                                         "-c:v", "libx264", "-preset", "ultrafast"])
        let info = try Prober.probe(src, ffprobe: try tools().ffprobe)
        let out = Self.dir.appendingPathComponent("cancelled.mp4")
        let args = try CommandBuilder.arguments(preset: .premiereMP4, options: Options(), info: info, input: src.path, output: out.path)
        let runner = ConversionRunner(ffmpeg: try tools().ffmpeg, arguments: args)
        let done = expectation(description: "finished")
        var sawProgress = false
        var outcome: ConversionRunner.Outcome?
        runner.start(onProgress: { seconds in
            if seconds > 0, !sawProgress { sawProgress = true; runner.cancel() }
        }, completion: { outcome = $0; done.fulfill() })
        wait(for: [done], timeout: 60)
        XCTAssertTrue(sawProgress)
        XCTAssertEqual(outcome?.cancelled, true)
        XCTAssertEqual(outcome?.succeeded, false)
    }

    func testRunnerFailureGivesReadableReason() throws {
        let junk = Self.dir.appendingPathComponent("junk.mp4")
        try Data("this is not a video".utf8).write(to: junk)
        XCTAssertThrowsError(try Prober.probe(junk, ffprobe: try tools().ffprobe))
        let runner = ConversionRunner(ffmpeg: try tools().ffmpeg, arguments: ["-hide_banner", "-i", junk.path, Self.dir.appendingPathComponent("x.mp4").path])
        let done = expectation(description: "finished")
        var outcome: ConversionRunner.Outcome?
        runner.start(onProgress: { _ in }, completion: { outcome = $0; done.fulfill() })
        wait(for: [done], timeout: 30)
        XCTAssertEqual(outcome?.succeeded, false)
        // A junk .mp4 is reported as missing its index; either way it must not fall through to the generic reason.
        XCTAssertEqual(ErrorMapper.reason(log: outcome?.log ?? ""), "The file is incomplete or damaged (missing index)")
    }
}
