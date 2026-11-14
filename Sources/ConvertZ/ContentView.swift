import AppKit
import ConvertZCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var showOptions = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if model.jobs.isEmpty { emptyState } else { list }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                        .padding(8)
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 620, minHeight: 440)
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    // MARK: Header

    private var header: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("Convert to").gridColumnAlignment(.trailing)
                HStack {
                    Picker("", selection: $model.preset) {
                        Section("Video") { ForEach(Preset.video) { Text($0.title).tag($0) } }
                        Section("Audio") { ForEach(Preset.audio) { Text($0.title).tag($0) } }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 280)
                    Button("Options…") { showOptions = true }
                        .popover(isPresented: $showOptions, arrowEdge: .bottom) { OptionsView(model: model) }
                    Spacer()
                }
            }
            GridRow {
                Text("")
                Text(model.preset.blurb).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            GridRow {
                Text("Save to")
                HStack {
                    Menu(destinationTitle) {
                        Button("Same folder as original") { model.destination = .sameFolder }
                        Button("Choose folder…") { chooseFolder() }
                    }
                    .frame(maxWidth: 280)
                    Spacer()
                }
            }
        }
        .padding(14)
        .disabled(model.isRunning)
    }

    private var destinationTitle: String {
        switch model.destination {
        case .sameFolder: return "Same folder as original"
        case .folder(let url): return url.lastPathComponent
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { model.destination = .folder(url) }
    }

    // MARK: List

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.doc").font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
            Text("Drop files or folders here").font(.title3)
            Text("Video or audio, any format").foregroundStyle(.secondary)
            Button("Add Files…") { addFiles() }.padding(.top, 4)
            if model.tools == nil {
                Label("ffmpeg is missing from the app. Reinstall ConvertZ.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).padding(.top, 8)
            }
        }
    }

    private var list: some View {
        List {
            ForEach(model.jobs) { job in
                JobRow(job: job)
                    .contextMenu {
                        if let out = job.output { Button("Show Converted File in Finder") { NSWorkspace.shared.activateFileViewerSelecting([out]) } }
                        Button("Show Original in Finder") { NSWorkspace.shared.activateFileViewerSelecting([job.url]) }
                        if !job.log.isEmpty { Button("Copy Log") { copy(job.log) } }
                        Divider()
                        Button("Remove from List") { model.remove(job) }.disabled(job.state == .converting)
                    }
            }
            .onDelete { offsets in offsets.map { model.jobs[$0] }.forEach(model.remove) }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Add Files…") { addFiles() }
            Button("Clear Finished") { model.clearFinished() }
                .disabled(!model.jobs.contains { $0.state == .done })
            Spacer()
            if model.isRunning {
                Button("Cancel", role: .cancel) { model.cancel() }
            }
            Button("Convert") { model.convert() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canConvert || model.tools == nil)
        }
        .padding(12)
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        if panel.runModal() == .OK { model.add(panel.urls) }
    }
}

func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

struct JobRow: View {
    let job: Job
    @State private var showIssues = false
    @State private var showLog = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: job.info?.video != nil ? "film" : (job.info != nil ? "waveform" : "doc"))
                .font(.title3).foregroundStyle(.secondary).frame(width: 24)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                if let info = job.info {
                    Text(info.summary).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    if job.issues.isEmpty {
                        if info.video != nil {
                            Label("Looks fine for Premiere", systemImage: "checkmark.circle").font(.callout).foregroundStyle(.green)
                        }
                    } else {
                        DisclosureGroup(isExpanded: $showIssues) {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(job.issues, id: \.self) { Text("• " + $0).font(.callout).foregroundStyle(.secondary) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } label: {
                            Label("\(job.issues.count) thing\(job.issues.count == 1 ? "" : "s") Premiere dislikes", systemImage: "exclamationmark.triangle.fill")
                                .font(.callout).foregroundStyle(.orange)
                        }
                    }
                }
                switch job.state {
                case .failed(let reason):
                    HStack(spacing: 8) {
                        Text(reason).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                        if !job.log.isEmpty { Button("Show Log") { showLog = true }.controlSize(.small) }
                    }
                case .skipped(let reason):
                    Text(reason).font(.callout).foregroundStyle(.secondary)
                default:
                    EmptyView()
                }
            }
            Spacer(minLength: 12)
            status.frame(width: 150, alignment: .trailing).padding(.top, 2)
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showLog) { LogView(title: job.url.lastPathComponent, log: job.log) }
    }

    @ViewBuilder private var status: some View {
        switch job.state {
        case .probing:
            ProgressView().controlSize(.small)
        case .waiting:
            Text("Waiting").foregroundStyle(.secondary)
        case .converting:
            VStack(alignment: .trailing, spacing: 3) {
                ProgressView(value: job.fraction)
                Text(progressText).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        case .done:
            Button {
                if let out = job.output { NSWorkspace.shared.activateFileViewerSelecting([out]) }
            } label: {
                Label("Done", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .buttonStyle(.plain)
            .help("Show in Finder")
        case .failed:
            Label("Failed", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        case .skipped:
            Text("Skipped").foregroundStyle(.secondary)
        case .cancelled:
            Text("Cancelled").foregroundStyle(.secondary)
        }
    }

    private var progressText: String {
        let percent = "\(Int(job.fraction * 100))%"
        guard let left = job.secondsLeft else { return percent }
        let s = Int(left.rounded())
        let time = s >= 3600 ? "\(s / 3600) h \(s % 3600 / 60) min" : s >= 60 ? "\(s / 60) min \(s % 60) s" : "\(s) s"
        return "\(percent) · \(time) left"
    }
}

struct LogView: View {
    let title: String
    let log: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ffmpeg log for \(title)").font(.headline)
            ScrollView {
                Text(log).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .border(Color(nsColor: .separatorColor))
            HStack {
                Button("Copy") { copy(log) }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 640, height: 420)
    }
}

struct OptionsView: View {
    @Bindable var model: AppModel
    @State private var showCommand = false

    var body: some View {
        let preset = model.preset
        VStack(alignment: .leading, spacing: 12) {
            Text(preset.title).font(.headline)
            Form {
                if preset.hasQuality {
                    Picker("Quality", selection: $model.options.quality) {
                        ForEach(Quality.allCases) { Text($0.title).tag($0) }
                    }
                }
                if preset.hasEncoderChoice {
                    Picker("Encoder", selection: $model.options.encoder) {
                        ForEach(Encoder.allCases) { Text($0.title).tag($0) }
                    }
                }
                if preset == .prores {
                    Picker("ProRes flavour", selection: $model.options.proresProfile) {
                        ForEach(ProResProfile.allCases) { Text($0.title).tag($0) }
                    }
                }
                if preset.hasVideoShape {
                    Picker("Resolution", selection: $model.options.maxHeight) {
                        ForEach(Options.heightChoices, id: \.title) { Text($0.title).tag($0.value) }
                    }
                    Picker("Frame rate", selection: $model.options.frameRate) {
                        ForEach(Options.frameRateChoices, id: \.title) { Text($0.title).tag($0.value) }
                    }
                }
                if preset == .mp3 {
                    Picker("Bitrate", selection: $model.options.mp3Bitrate) {
                        ForEach([192, 256, 320], id: \.self) { Text("\($0) kbps").tag($0) }
                    }
                }
                if preset == .wav {
                    Picker("Bit depth", selection: $model.options.wavBitDepth) {
                        Text("16-bit").tag(16)
                        Text("24-bit").tag(24)
                    }
                    Picker("Sample rate", selection: $model.options.wavSampleRate) {
                        Text("48 kHz").tag(48000)
                        Text("44.1 kHz").tag(44100)
                    }
                }
            }
            if !(preset.hasQuality || preset.hasVideoShape || preset == .mp3 || preset == .wav) {
                Text("This format has no options.").foregroundStyle(.secondary)
            }
            if preset.hasVideoShape {
                Text("“Match source” keeps the original frame rate but makes it constant.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("ffmpeg command", isExpanded: $showCommand) {
                VStack(alignment: .leading, spacing: 6) {
                    if let command = model.sampleCommand {
                        Text(command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Copy") { copy(command) }.controlSize(.small)
                    } else {
                        Text("Add a file this format applies to and its command appears here.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}
