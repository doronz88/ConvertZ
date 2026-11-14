import XCTest
@testable import ConvertZCore

final class UnitTests: XCTestCase {
    let phoneVFR = MediaInfo(formatName: "matroska,webm", duration: 10,
                             video: .init(index: 0, codec: "hevc", width: 1921, height: 1080, pixelFormat: "yuv420p10le",
                                          realFrameRate: 120, averageFrameRate: 29.71, fieldOrder: "progressive",
                                          colorTransfer: "smpte2084"),
                             audio: [.init(index: 1, codec: "opus", sampleRate: 48000, channels: 2)])
    let clean = MediaInfo(formatName: "mov,mp4,m4a,3gp,3g2,mj2", duration: 10,
                          video: .init(index: 0, codec: "h264", width: 1920, height: 1080, pixelFormat: "yuv420p",
                                       realFrameRate: 30, averageFrameRate: 30),
                          audio: [.init(index: 1, codec: "aac", sampleRate: 48000, channels: 2)])
    let song = MediaInfo(formatName: "flac", duration: 200, audio: [.init(index: 0, codec: "flac", sampleRate: 96000, channels: 6)])

    func testFrameRateSnapping() {
        XCTAssertEqual(FrameRate.target(average: 29.71, real: 120), "30000/1001")
        XCTAssertEqual(FrameRate.target(average: 23.98, real: 23.98), "24000/1001")
        XCTAssertEqual(FrameRate.target(average: 25, real: 25), "25")
        XCTAssertEqual(FrameRate.target(average: 12, real: 12), "12")
        XCTAssertEqual(FrameRate.target(average: 118.2, real: 240), "120")
        XCTAssertEqual(FrameRate.target(average: 57.3, real: 60), "57.3")
        XCTAssertEqual(FrameRate.target(average: nil, real: 90000), "30")
        XCTAssertEqual(FrameRate.target(average: nil, real: 50), "50")
    }

    func testFrameTiming() {
        let steady = (0..<100).map { (Double($0) / 29.97 * 1000).rounded() / 1000 } // 1 ms rounding, as in MKV
        XCTAssertEqual(FrameTiming(timestamps: steady.shuffled())?.variable, false)
        XCTAssertEqual(FrameTiming(timestamps: steady)?.framesPerSecond ?? 0, 29.97, accuracy: 0.05)
        let dropped = steady.enumerated().filter { $0.offset < 30 || $0.offset % 3 == 0 }.map(\.element)
        XCTAssertEqual(FrameTiming(timestamps: dropped)?.variable, true)
        XCTAssertNil(FrameTiming(timestamps: [0, 1]))
    }

    func testParseProbeJSON() throws {
        let json = """
        {"streams":[
          {"index":0,"codec_name":"mjpeg","codec_type":"video","width":500,"height":500,"disposition":{"attached_pic":1}},
          {"index":1,"codec_name":"hevc","codec_type":"video","width":3840,"height":2160,"pix_fmt":"yuv420p10le",
           "r_frame_rate":"60/1","avg_frame_rate":"30000/1001","field_order":"progressive","disposition":{"attached_pic":0}},
          {"index":2,"codec_name":"aac","codec_type":"audio","sample_rate":"44100","channels":2},
          {"index":3,"codec_name":"mov_text","codec_type":"subtitle"}],
         "format":{"format_name":"mov,mp4,m4a,3gp,3g2,mj2","duration":"12.5"}}
        """
        let info = try MediaInfo.parse(json: Data(json.utf8))
        XCTAssertEqual(info.video?.index, 1)
        XCTAssertEqual(info.video?.bitDepth, 10)
        XCTAssertEqual(info.video?.isVariableFrameRate, true)
        XCTAssertEqual(info.audio.count, 1)
        XCTAssertEqual(info.duration, 12.5)
        XCTAssertEqual(info.summary, "HEVC 10-bit · 3840×2160 · 29.97 fps (variable) · AAC 44.1 kHz")
        XCTAssertThrowsError(try MediaInfo.parse(json: Data("{}".utf8)))
        XCTAssertThrowsError(try MediaInfo.parse(json: Data(#"{"streams":[],"format":{}}"#.utf8)))
    }

    func testDiagnosis() {
        let issues = Diagnosis.issues(for: phoneVFR).joined(separator: "\n")
        for needle in ["MKV", "Variable frame rate", "HDR", "Odd pixel", "Opus"] { XCTAssertTrue(issues.contains(needle), needle) }
        XCTAssertEqual(Diagnosis.issues(for: clean), [])
        XCTAssertEqual(Diagnosis.issues(for: song), [])
        var hi10 = clean
        hi10.video?.pixelFormat = "yuv422p10le"
        XCTAssertEqual(Diagnosis.issues(for: hi10).count, 1)
    }

    func testPremiereArguments() throws {
        let a = try CommandBuilder.arguments(preset: .premiereMP4, options: Options(), info: phoneVFR, input: "in.mkv", output: "out.mp4")
        XCTAssertEqual(a, ["-hide_banner", "-nostdin", "-y", "-i", "in.mkv", "-map", "0:0", "-map", "0:a?", "-sn", "-dn",
                           "-map_metadata", "0", "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2,fps=30000/1001,format=yuv420p",
                           "-c:v", "libx264", "-preset", "medium", "-crf", "16", "-profile:v", "high", "-pix_fmt", "yuv420p",
                           "-c:a", "aac", "-b:a", "320k", "-ar", "48000", "-movflags", "+faststart",
                           "-progress", "pipe:1", "-nostats", "out.mp4"])
    }

    func testOptionsAffectArguments() throws {
        var o = Options()
        o.encoder = .fast; o.maxHeight = 720; o.frameRate = "25"
        var interlaced = clean
        interlaced.video?.fieldOrder = "tt"
        interlaced.audio = []
        let a = try CommandBuilder.arguments(preset: .premiereMP4, options: o, info: interlaced, input: "i", output: "o.mp4")
        XCTAssertTrue(a.contains("h264_videotoolbox"))
        XCTAssertFalse(a.contains("aac"))
        XCTAssertEqual(a[a.firstIndex(of: "-vf")! + 1],
                       "bwdif=mode=send_frame:parity=auto:deint=all,scale=-2:'trunc(min(ih,720)/2)*2':flags=lanczos,fps=25,format=yuv420p")
    }

    func testAudioArguments() throws {
        let mp3 = try CommandBuilder.arguments(preset: .mp3, options: Options(), info: song, input: "i", output: "o.mp3")
        XCTAssertTrue(mp3.contains("libmp3lame") && mp3.contains("320k") && mp3.contains("-ac") && mp3.contains("-vn"))
        var o = Options(); o.wavBitDepth = 24; o.wavSampleRate = 44100
        let wav = try CommandBuilder.arguments(preset: .wav, options: o, info: clean, input: "i", output: "o.wav")
        XCTAssertTrue(wav.contains("pcm_s24le") && wav.contains("44100") && wav.contains("0:1"))
    }

    func testKeepsCompatibleStreams() throws {
        // OBS-style recording: fine H.264 and AAC, but in MKV. Nothing needs re-encoding.
        var obs = clean
        obs.formatName = "matroska,webm"
        XCTAssertTrue(CommandBuilder.keepsVideo(preset: .premiereMP4, options: Options(), info: obs))
        let a = try CommandBuilder.arguments(preset: .premiereMP4, options: Options(), info: obs, input: "i", output: "o.mp4")
        XCTAssertTrue(a.contains("-c:v") && a[a.firstIndex(of: "-c:v")! + 1] == "copy")
        XCTAssertEqual(a[a.firstIndex(of: "-c:a")! + 1], "copy")
        XCTAssertFalse(a.contains("-vf"))

        // Same video with Opus audio: copy the video, convert only the audio.
        obs.audio = [.init(index: 1, codec: "opus", sampleRate: 48000, channels: 6)]
        let b = try CommandBuilder.arguments(preset: .premiereMP4, options: Options(), info: obs, input: "i", output: "o.mp4")
        XCTAssertEqual(b[b.firstIndex(of: "-c:v")! + 1], "copy")
        XCTAssertEqual(b[b.firstIndex(of: "-c:a")! + 1], "aac")
        XCTAssertEqual(b[b.firstIndex(of: "-b:a")! + 1], "960k")

        // Not kept: a file with no visible problem (its fault is hidden), a variable frame rate, a requested
        // change, or the option switched off.
        XCTAssertFalse(CommandBuilder.keepsVideo(preset: .premiereMP4, options: Options(), info: clean))
        XCTAssertFalse(CommandBuilder.keepsVideo(preset: .premiereMP4, options: Options(), info: phoneVFR))
        var measured = obs; measured.video?.measuredVariable = true
        XCTAssertFalse(CommandBuilder.keepsVideo(preset: .premiereMP4, options: Options(), info: measured))
        var o = Options(); o.frameRate = "25"
        XCTAssertFalse(CommandBuilder.keepsVideo(preset: .premiereMP4, options: o, info: obs))
        o = Options(); o.maxHeight = 720
        XCTAssertFalse(CommandBuilder.keepsVideo(preset: .premiereMP4, options: o, info: obs))
        o = Options(); o.keepCompatibleStreams = false
        XCTAssertFalse(CommandBuilder.keepsVideo(preset: .premiereMP4, options: o, info: obs))
        XCTAssertFalse(CommandBuilder.keepsVideo(preset: .hevcMP4, options: Options(), info: obs))
    }

    func testAudioKeepsQuality() throws {
        let aacFile = MediaInfo(formatName: "aac", duration: 5, audio: [.init(index: 0, codec: "aac", sampleRate: 44100, channels: 2)])
        let m4a = try CommandBuilder.arguments(preset: .m4a, options: Options(), info: aacFile, input: "i", output: "o.m4a")
        XCTAssertEqual(m4a[m4a.firstIndex(of: "-c:a")! + 1], "copy")
        var hires = song
        hires.audio[0].bitsPerSample = 24
        let wav = try CommandBuilder.arguments(preset: .wav, options: Options(), info: hires, input: "i", output: "o.wav")
        XCTAssertTrue(wav.contains("pcm_s24le"))
        XCTAssertFalse(wav.contains("-ar"), "sample rate is left as the source's")
        let fromLossy = try CommandBuilder.arguments(preset: .wav, options: Options(), info: aacFile, input: "i", output: "o.wav")
        XCTAssertTrue(fromLossy.contains("pcm_s16le"))
    }

    func testWrongKindOfFile() {
        XCTAssertThrowsError(try CommandBuilder.arguments(preset: .premiereMP4, options: Options(), info: song, input: "i", output: "o")) {
            XCTAssertEqual($0 as? CommandBuilder.BuildError, .noVideo)
        }
        var silent = clean; silent.audio = []
        XCTAssertThrowsError(try CommandBuilder.arguments(preset: .wav, options: Options(), info: silent, input: "i", output: "o")) {
            XCTAssertEqual($0 as? CommandBuilder.BuildError, .noAudio)
        }
    }

    func testEveryPresetBuilds() throws {
        for preset in Preset.allCases {
            let info = preset.isAudio ? song : clean
            let a = try CommandBuilder.arguments(preset: preset, options: Options(), info: info, input: "i", output: "o." + preset.fileExtension)
            XCTAssertEqual(a.last, "o." + preset.fileExtension)
        }
    }

    func testProgressParser() {
        var p = ProgressParser()
        XCTAssertFalse(p.feed(Data("frame=10\nout_time_us=15".utf8)))
        XCTAssertTrue(p.feed(Data("00000\nspeed=2.0x\nprogress=continue\n".utf8)))
        XCTAssertEqual(p.seconds, 1.5)
        XCTAssertFalse(p.finished)
        _ = p.feed(Data("out_time_us=N/A\nprogress=end\n".utf8))
        XCTAssertEqual(p.seconds, 1.5)
        XCTAssertTrue(p.finished)
    }

    func testOutputNaming() {
        let folder = URL(fileURLWithPath: "/tmp/x")
        let src = folder.appendingPathComponent("clip.mp4")
        let none: (URL) -> Bool = { _ in false }
        XCTAssertEqual(OutputNaming.destination(source: src, folder: folder, fileExtension: "mp3", exists: none).lastPathComponent, "clip.mp3")
        XCTAssertEqual(OutputNaming.destination(source: src, folder: folder, fileExtension: "mp4", exists: none).lastPathComponent, "clip converted.mp4")
        let taken: Set<String> = ["clip converted.mp4", "clip converted (1).mp4"]
        let url = OutputNaming.destination(source: src, folder: folder, fileExtension: "mp4") { taken.contains($0.lastPathComponent) }
        XCTAssertEqual(url.lastPathComponent, "clip converted (2).mp4")
        XCTAssertEqual(OutputNaming.partial(for: url).lastPathComponent, ".clip converted (2).convertz-partial.mp4")
    }

    func testErrorMapping() {
        XCTAssertEqual(ErrorMapper.reason(log: "av_interleaved_write_frame(): No space left on device"), "The disk is full")
        XCTAssertTrue(ErrorMapper.reason(log: "Could not find tag for codec vp9 in stream #0").contains("Premiere-safe"))
        XCTAssertEqual(ErrorMapper.reason(log: "???"), "ffmpeg could not convert this file")
    }

    func testShellCommandQuoting() {
        XCTAssertEqual(CommandBuilder.shellCommand(["-i", "my file's.mov", "-vf", "fps=30"]), "ffmpeg -i 'my file'\\''s.mov' -vf fps=30")
    }
}
