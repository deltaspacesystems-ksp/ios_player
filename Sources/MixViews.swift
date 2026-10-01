import AVFoundation
import SwiftUI

private func labeled(_ title: String, _ value: String, _ content: some View) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        HStack { Text(title); Spacer(); Text(value).foregroundStyle(.secondary).monospacedDigit() }
        content
    }
}

// MARK: - Editor

struct MixEditorView: View {
    let mixID: UUID
    @EnvironmentObject var store: MixStore
    @EnvironmentObject var player: Player
    @EnvironmentObject var library: Library
    @EnvironmentObject var analysis: AnalysisStore
    @State private var editing: UUID?
    @State private var adding = false
    @State private var exporting = false

    private var mixIndex: Int? { store.mixes.firstIndex { $0.id == mixID } }

    var body: some View {
        if let i = mixIndex {
            content(i)
        } else {
            ContentUnavailableView("Mix not found", systemImage: "questionmark.folder")
        }
    }

    private func detail(_ it: MixItem, _ idx: Int, _ tracks: [String: Track]) -> String {
        let dur = tracks[it.trackID]?.duration ?? 0
        var s = "\(formatTime(it.inPoint)) – \(formatTime(it.outPoint ?? dur))"
        if idx > 0 { s += " · ↘ \(Int(it.overlap)) s \(it.curve.rawValue)" + (it.tempoMatch ? " · tempo" : "") }
        return s
    }

    private func content(_ i: Int) -> some View {
        let tracks = Dictionary(library.tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let mix = store.mixes[i]
        let lay = mixLayout(mix, tracks)
        let total = (lay.last?.start ?? 0) + (lay.last?.len ?? 0)
        return List {
            Section {
                TextField("Name", text: $store.mixes[i].name)
                HStack { Text("Length"); Spacer(); Text(formatTime(total)).foregroundStyle(.secondary) }
            }
            if !mix.items.isEmpty {
                Section("Timeline") {
                    MixTimeline(mix: mix, tracks: tracks, layout: lay, total: total)
                        .frame(height: 116)
                        .listRowInsets(EdgeInsets())
                }
            }
            Section("Tracks") {
                ForEach(Array(mix.items.enumerated()), id: \.element.id) { idx, it in
                    Button { editing = it.id } label: {
                        HStack(spacing: 12) {
                            ThumbView(id: it.trackID, radius: 6).frame(width: 44, height: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tracks[it.trackID]?.title ?? "Missing track").lineLimit(1)
                                Text(detail(it, idx, tracks)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "slider.horizontal.3").foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onMove { store.mixes[i].items.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { store.mixes[i].items.remove(atOffsets: $0) }
                Button("Add tracks…", systemImage: "plus") { adding = true }
            }
            Section {
                Button("Play mix", systemImage: "play.fill") { player.startMix(mix, tracks: tracks) }
                    .disabled(mix.items.isEmpty)
                Button("Auto-order by tempo & key", systemImage: "sparkles") { autoOrder(i, tracks) }
                    .disabled(mix.items.count < 3)
                Button("Export to audio file…", systemImage: "square.and.arrow.up") { exporting = true }
                    .disabled(mix.items.isEmpty)
            }
        }
        .navigationTitle(mix.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { EditButton() } }
        .sheet(isPresented: $adding) {
            TrackPicker(tracks: library.audio) { picked in
                store.mixes[i].items += picked.map { MixItem(trackID: $0.id, overlap: player.cfg.crossfade) }
            }
        }
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            if let id = editing, let j = store.mixes[i].items.firstIndex(where: { $0.id == id }) {
                let it = store.mixes[i].items[j]
                ItemEditor(item: $store.mixes[i].items[j], track: tracks[it.trackID], isFirst: j == 0,
                           analysis: analysis.results[it.trackID]) {
                    previewTransition(store.mixes[i], j, tracks)
                }
                .presentationDetents([.medium, .large])
            }
        }
        .sheet(isPresented: $exporting) { MixExportView(mix: mix, tracks: tracks) }
    }

    private func autoOrder(_ i: Int, _ tracks: [String: Track]) {
        let items = store.mixes[i].items
        let ts = items.compactMap { tracks[$0.trackID] }
        guard let first = ts.first else { return }
        let plan = DJPlanner.build(start: first, pool: ts, analysis: analysis.results, mood: .flow, length: ts.count)
        var rest = items
        var ordered: [MixItem] = []
        for t in plan {
            if let k = rest.firstIndex(where: { $0.trackID == t.id }) { ordered.append(rest.remove(at: k)) }
        }
        store.mixes[i].items = ordered + rest
    }

    private func previewTransition(_ mix: Mix, _ j: Int, _ tracks: [String: Track]) {
        guard j > 0 else { return }
        let prev = mix.items[j - 1]
        let end = prev.outPoint ?? (tracks[prev.trackID]?.duration ?? 0)
        let offset = max(prev.inPoint, end - mix.items[j].overlap - 4)
        player.startMix(mix, tracks: tracks, startAt: j - 1, offset: offset)
    }
}

// MARK: - Timeline

struct MixTimeline: View {
    let mix: Mix
    let tracks: [String: Track]
    let layout: [MixSlot]
    let total: Double
    private let pps: CGFloat = 5

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            ZStack(alignment: .topLeading) {
                ForEach(Array(mix.items.enumerated()), id: \.element.id) { i, it in
                    if layout.indices.contains(i) {
                        let seg = layout[i]
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill((tracks[it.trackID]?.tint ?? .gray).opacity(0.85))
                            .frame(width: max(10, CGFloat(seg.len) * pps), height: 48)
                            .overlay(alignment: .leading) {
                                Text(tracks[it.trackID]?.title ?? "?")
                                    .font(.caption2.bold()).foregroundStyle(.white).lineLimit(1)
                                    .padding(.horizontal, 6)
                            }
                            .offset(x: CGFloat(seg.start) * pps, y: CGFloat(i % 2) * 56)
                    }
                }
            }
            .frame(width: max(1, CGFloat(total) * pps) + 16, height: 112, alignment: .topLeading)
            .padding(.horizontal, 8)
        }
    }
}

// MARK: - Item / transition editor

struct ItemEditor: View {
    @Binding var item: MixItem
    let track: Track?
    let isFirst: Bool
    let analysis: TrackAnalysis?
    var onPreview: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var dur: Double { max(2, track?.duration ?? 2) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Track") {
                    Text(track?.title ?? "Missing track")
                    if let a = analysis {
                        Text("\(Int(a.bpm.rounded())) BPM · \(a.keyName) · energy \(Int(a.energy * 100))%")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Trim & level") {
                    labeled("Start at", formatTime(item.inPoint),
                            Slider(value: $item.inPoint, in: 0...max(1, (item.outPoint ?? dur) - 1)))
                    Toggle("Custom end", isOn: Binding(get: { item.outPoint != nil }, set: { item.outPoint = $0 ? dur : nil }))
                    if let out = item.outPoint {
                        labeled("End at", formatTime(out),
                                Slider(value: Binding(get: { out }, set: { item.outPoint = $0 }),
                                       in: (item.inPoint + 1)...max(item.inPoint + 2, dur)))
                    }
                    labeled("Gain", String(format: "%+.1f dB", item.gainDB), Slider(value: $item.gainDB, in: -12...6, step: 0.5))
                }
                if !isFirst {
                    Section("Transition from previous track") {
                        labeled("Overlap", "\(Int(item.overlap)) s", Slider(value: $item.overlap, in: 0...30, step: 1))
                        Picker("Curve", selection: $item.curve) {
                            ForEach(FadeCurve.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Toggle("Match tempo", isOn: $item.tempoMatch)
                        Button("Preview transition", systemImage: "play.circle") { onPreview() }
                    }
                }
            }
            .navigationTitle("Edit track")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

// MARK: - Track picker

struct TrackPicker: View {
    let tracks: [Track]
    var onAdd: ([Track]) -> Void
    @State private var selected: [String] = []
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var filtered: [Track] {
        query.isEmpty ? tracks : tracks.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { t in
                Button {
                    if let k = selected.firstIndex(of: t.id) { selected.remove(at: k) } else { selected.append(t.id) }
                } label: {
                    HStack {
                        TrackRow(track: t, playing: false)
                        if selected.contains(t.id) { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .searchable(text: $query)
            .navigationTitle("Add tracks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add (\(selected.count))") {
                        let byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                        onAdd(selected.compactMap { byID[$0] })
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
    }
}

// MARK: - Export

@MainActor
final class ExportModel: ObservableObject {
    @Published var progress = 0.0
    @Published var running = false
    @Published var error: String?
    @Published var finished: String?

    func run(segs: [RenderSeg], out: URL, format: ExportFormat) async {
        running = true
        progress = 0
        error = nil
        finished = nil
        let me = self
        let err: String? = await Task.detached(priority: .userInitiated) { () -> String? in
            do {
                try MixRenderer.render(segs, to: out, format: format) { p in
                    Task { @MainActor in me.progress = p }
                }
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        running = false
        if let err { error = err } else { finished = out.lastPathComponent }
    }
}

struct MixExportView: View {
    let mix: Mix
    let tracks: [String: Track]
    @EnvironmentObject var library: Library
    @StateObject private var model = ExportModel()
    @State private var format: ExportFormat = .aac
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Format", selection: $format) {
                        ForEach(ExportFormat.allCases) { Text($0.rawValue).tag($0) }
                    }
                } footer: {
                    Text("The mix is rendered to Lumen's Documents folder (visible in Files and in your library). Tempo matching is not applied in exports.")
                }
                Section {
                    if model.running {
                        ProgressView(value: model.progress)
                        Text("Rendering… \(Int(model.progress * 100))%").foregroundStyle(.secondary)
                    } else {
                        Button("Render mix", systemImage: "waveform") { start() }
                    }
                    if let f = model.finished { Label("Saved \(f)", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    if let e = model.error { Text(e).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Export mix")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Close") { dismiss() }.disabled(model.running) } }
            .interactiveDismissDisabled(model.running)
        }
        .presentationDetents([.medium])
    }

    private func start() {
        let segs: [RenderSeg] = mix.items.compactMap { it in
            guard let t = tracks[it.trackID] else { return nil }
            return RenderSeg(url: t.url, inP: it.inPoint, outP: it.outPoint ?? t.duration,
                             gain: Float(pow(10, it.gainDB / 20)), overlap: it.overlap, curve: it.curve)
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let safe = mix.name.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined(separator: "-")
        let out = docs.appendingPathComponent((safe.isEmpty ? "Mix" : safe) + "." + format.ext)
        Task {
            await model.run(segs: segs, out: out, format: format)
            if model.finished != nil { await library.reload() }
        }
    }
}
