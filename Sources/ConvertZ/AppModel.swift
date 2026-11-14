import AppKit
import ConvertZCore
import Observation
import UserNotifications

@Observable
final class Job: Identifiable {
    enum State: Equatable {
        case probing, waiting, converting, done
        case failed(String), skipped(String), cancelled
    }

    let id = UUID()
    let url: URL
    var info: MediaInfo?
    var issues: [String] = []
    var state: State = .probing
    var fraction: Double = 0
    var secondsLeft: Double?
    var output: URL?
    var log = ""

    init(url: URL) { self.url = url }

    var canRetry: Bool {
        switch state {
        case .failed, .skipped, .cancelled: return info != nil
        default: return false
        }
    }
}

enum Destination: Equatable {
    case sameFolder
    case folder(URL)
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var jobs: [Job] = []
    var preset: Preset { didSet { UserDefaults.standard.set(preset.rawValue, forKey: "preset") } }
    var options: Options {
        didSet { if let data = try? JSONEncoder().encode(options) { UserDefaults.standard.set(data, forKey: "options") } }
    }
    var destination: Destination {
        didSet {
            if case .folder(let url) = destination { UserDefaults.standard.set(url.path, forKey: "folder") }
            else { UserDefaults.standard.removeObject(forKey: "folder") }
        }
    }
    private(set) var isRunning = false
    let tools = FFmpegLocator.locate()

    private var runner: ConversionRunner?
    private var currentPartial: URL?
    private var stopRequested = false
    private var activity: NSObjectProtocol?
    private var startedAt = Date()

    static let mediaExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "webm", "avi", "wmv", "flv", "mts", "m2ts", "ts", "mpg", "mpeg", "3gp", "mxf",
        "ogv", "vob", "gif", "mp3", "wav", "m4a", "aac", "flac", "ogg", "opus", "wma", "aiff", "aif", "caf", "ac3", "mka",
    ]

    private init() {
        let defaults = UserDefaults.standard
        preset = defaults.string(forKey: "preset").flatMap(Preset.init(rawValue:)) ?? .premiereMP4
        options = defaults.data(forKey: "options").flatMap { try? JSONDecoder().decode(Options.self, from: $0) } ?? Options()
        if let path = defaults.string(forKey: "folder"), FileManager.default.fileExists(atPath: path) {
            destination = .folder(URL(fileURLWithPath: path))
        } else {
            destination = .sameFolder
        }
    }

    // MARK: Adding files

    func add(_ urls: [URL]) {
        var files: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                           options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let item = walker?.nextObject() as? URL {
                    if Self.mediaExtensions.contains(item.pathExtension.lowercased()) { files.append(item) }
                }
            } else {
                files.append(url)
            }
        }
        let known = Set(jobs.map { $0.url.standardizedFileURL.path })
        for file in files.sorted(by: { $0.path < $1.path }) where !known.contains(file.standardizedFileURL.path) {
            let job = Job(url: file)
            jobs.append(job)
            probe(job)
        }
    }

    private func probe(_ job: Job) {
        guard let tools else {
            job.state = .failed("ffmpeg is missing from the app. Reinstall ConvertZ")
            return
        }
        let url = job.url
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Prober.probe(url, ffprobe: tools.ffprobe) }
            DispatchQueue.main.async {
                switch result {
                case .success(let info):
                    job.info = info
                    job.issues = Diagnosis.issues(for: info)
                    job.state = .waiting
                    if self.isRunning, self.runner == nil { self.runNext() }
                case .failure:
                    job.state = .failed("Not a media file ffmpeg understands")
                    if self.isRunning, self.runner == nil { self.runNext() }
                }
            }
        }
    }

    func remove(_ job: Job) {
        guard job.state != .converting else { return }
        jobs.removeAll { $0.id == job.id }
    }

    func clearFinished() {
        jobs.removeAll { $0.state == .done }
    }

    func clearAll() {
        jobs.removeAll { $0.state != .converting }
    }

    // MARK: Queue

    var canConvert: Bool {
        !isRunning && jobs.contains { $0.state == .waiting || $0.state == .probing || $0.canRetry }
    }

    func convert() {
        guard !isRunning else { return }
        for job in jobs where job.canRetry {
            job.state = .waiting
            job.fraction = 0
            job.log = ""
        }
        isRunning = true
        stopRequested = false
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                         reason: "Converting media")
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        runNext()
    }

    func cancel() {
        stopRequested = true
        if let runner { runner.cancel() } else { finishQueue() }
    }

    /// Stops ffmpeg and removes its partial file, synchronously. Used when quitting.
    func shutdown() {
        runner?.cancelAndWait()
        if let currentPartial { try? FileManager.default.removeItem(at: currentPartial) }
    }

    private func runNext() {
        guard !stopRequested else { finishQueue(); return }
        if let job = jobs.first(where: { $0.state == .waiting }) {
            start(job, options: options)
        } else if !jobs.contains(where: { $0.state == .probing }) {
            finishQueue()
        }
    }

    private func finishQueue() {
        runner = nil
        currentPartial = nil
        isRunning = false
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        updateDock()
        if !NSApp.isActive, !stopRequested, Bundle.main.bundleIdentifier != nil {
            let done = jobs.filter { $0.state == .done }.count
            let failed = jobs.filter { if case .failed = $0.state { return true } else { return false } }.count
            let content = UNMutableNotificationContent()
            content.title = "ConvertZ finished"
            content.body = failed == 0 ? "\(done) file\(done == 1 ? "" : "s") converted."
                                       : "\(done) converted, \(failed) failed."
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    private func start(_ job: Job, options: Options, isRetry: Bool = false) {
        guard let tools, let info = job.info else { job.state = .failed("Could not read this file"); runNext(); return }
        let preset = self.preset
        let fm = FileManager.default

        let folder: URL
        switch destination {
        case .sameFolder: folder = job.url.deletingLastPathComponent()
        case .folder(let url): folder = url
        }
        guard fm.isWritableFile(atPath: folder.path) else {
            job.state = .failed("Can't write to “\(folder.lastPathComponent)”. Choose another folder under Save to")
            runNext(); return
        }
        if let free = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           free < Self.estimatedBytes(preset: preset, options: options, info: info, source: job.url) {
            job.state = .failed("Not enough free disk space in “\(folder.lastPathComponent)”")
            runNext(); return
        }

        let final = OutputNaming.destination(source: job.url, folder: folder, fileExtension: preset.fileExtension)
        let partial = OutputNaming.partial(for: final)
        let arguments: [String]
        do {
            arguments = try CommandBuilder.arguments(preset: preset, options: options, info: info,
                                                     input: job.url.path, output: partial.path)
        } catch {
            job.state = .skipped(error.localizedDescription)
            runNext(); return
        }

        job.state = .converting
        job.fraction = 0
        job.secondsLeft = nil
        job.output = nil
        startedAt = Date()
        currentPartial = partial
        let runner = ConversionRunner(ffmpeg: tools.ffmpeg, arguments: arguments)
        self.runner = runner
        let duration = info.duration ?? 0

        runner.start(onProgress: { [weak self] seconds in
            guard let self, duration > 0 else { return }
            job.fraction = min(max(seconds / duration, 0), 1)
            let elapsed = Date().timeIntervalSince(self.startedAt)
            job.secondsLeft = job.fraction > 0.02 && elapsed > 2 ? elapsed / job.fraction * (1 - job.fraction) : nil
            self.updateDock()
        }, completion: { [weak self] outcome in
            guard let self else { return }
            self.runner = nil
            job.log = CommandBuilder.shellCommand(arguments) + "\n\n" + outcome.log
            if outcome.cancelled {
                try? fm.removeItem(at: partial)
                job.state = .cancelled
                self.finishQueue()
            } else if outcome.exitCode != 0 {
                try? fm.removeItem(at: partial)
                if let safer = Self.saferOptions(options, preset: preset) {
                    self.start(job, options: safer, isRetry: true)
                } else {
                    job.state = .failed(ErrorMapper.reason(log: outcome.log))
                    self.runNext()
                }
            } else {
                self.verify(job, partial: partial, final: final, preset: preset, options: options, sourceDuration: info.duration, ffprobe: tools.ffprobe)
            }
        })
    }

    /// ffmpeg exiting cleanly is not enough: the output must probe as valid media of about the right length.
    /// What to try next when a conversion fails: first stop copying streams, then drop the hardware encoder.
    /// Re-encoding in software accepts anything, so it is the last resort.
    static func saferOptions(_ options: Options, preset: Preset) -> Options? {
        var next = options
        if options.keepCompatibleStreams, preset.canKeepStreams {
            next.keepCompatibleStreams = false
        } else if options.encoder == .fast, preset.hasEncoderChoice {
            next.encoder = .best
        } else {
            return nil
        }
        return next
    }

    private func verify(_ job: Job, partial: URL, final: URL, preset: Preset, options: Options, sourceDuration: Double?, ffprobe: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            let probed = try? Prober.probe(partial, ffprobe: ffprobe)
            DispatchQueue.main.async {
                let fm = FileManager.default
                var problem: String?
                if let probed {
                    if preset != .gif, let src = sourceDuration, src > 0, let out = probed.duration,
                       abs(out - src) > max(1.5, src * 0.03) {
                        problem = "The converted file came out the wrong length (\(Int(out)) s instead of \(Int(src)) s)"
                    }
                } else {
                    problem = "The converted file could not be read back"
                }
                if problem == nil {
                    do {
                        // Another file may have taken the name while this one was converting.
                        let target = fm.fileExists(atPath: final.path)
                            ? OutputNaming.destination(source: job.url, folder: final.deletingLastPathComponent(), fileExtension: final.pathExtension)
                            : final
                        try fm.moveItem(at: partial, to: target)
                        job.output = target
                        job.fraction = 1
                        job.state = .done
                    } catch {
                        problem = "Could not save the converted file: \(error.localizedDescription)"
                    }
                }
                if let problem {
                    try? fm.removeItem(at: partial)
                    if let safer = Self.saferOptions(options, preset: preset) {
                        self.start(job, options: safer, isRetry: true)
                        return
                    }
                    job.state = .failed(problem)
                }
                self.currentPartial = nil
                self.runNext()
            }
        }
    }

    static func estimatedBytes(preset: Preset, options: Options, info: MediaInfo, source: URL) -> Int64 {
        let margin: Int64 = 100_000_000
        let sourceSize = Int64((try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let seconds = info.duration ?? 0
        switch preset {
        case .rewrapMP4:
            return sourceSize + margin
        case .prores:
            guard let v = info.video else { return margin }
            let fps = v.averageFrameRate ?? 30
            let scale = Double(v.width * v.height) / (1920 * 1080) * fps / 30
            return Int64(options.proresProfile.megabitsAt1080p30 * scale * 125_000 * seconds) + margin
        case .wav:
            let channels = info.audio.first?.channels ?? 2
            return Int64(Double(options.wavSampleRate * channels * options.wavBitDepth / 8) * seconds) + margin
        default:
            return margin
        }
    }

    private func updateDock() {
        guard isRunning else { NSApp.dockTile.badgeLabel = nil; return }
        let total = jobs.filter { $0.state != .probing }.count
        guard total > 0 else { return }
        let finished = jobs.filter { [.done, .cancelled].contains($0.state) || !$0.canRetry && $0.state != .waiting && $0.state != .converting && $0.state != .probing }.count
        let current = jobs.first { $0.state == .converting }?.fraction ?? 0
        let percent = Int((Double(finished) + current) / Double(total) * 100)
        NSApp.dockTile.badgeLabel = "\(min(percent, 99))%"
    }

    /// The command for the first file in the list, for display.
    var sampleCommand: String? {
        guard let job = jobs.first(where: { $0.info != nil }), let info = job.info else { return nil }
        let out = "output." + preset.fileExtension
        guard let args = try? CommandBuilder.arguments(preset: preset, options: options, info: info,
                                                       input: job.url.lastPathComponent, output: out) else { return nil }
        return CommandBuilder.shellCommand(args)
    }
}
