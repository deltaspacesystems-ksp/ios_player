import SwiftUI
import VLCKit

struct SavedServer: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var url: String        // without password
    var user: String = ""
}

struct PlayRequest: Identifiable {
    let id = UUID()
    let items: [VLCItem]
    let start: Int
}

/// Discovery (Bonjour / UPnP / SMB ...) + favourites + recent streams.
@MainActor
final class NetworkStore: ObservableObject {
    struct Found: Identifiable, Hashable {
        let id: String
        let name: String
        let url: URL
    }

    @Published var servers: [SavedServer] = []
    @Published var recent: [String] = []
    @Published var found: [Found] = []
    @Published var scanning = false
    /// Passwords are kept only in memory for the running session.
    var passwords: [String: String] = [:]

    private var discoverers: [VLCMediaDiscoverer] = []
    private var pollTask: Task<Void, Never>?
    private static var fileURL: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("lumen-network.json")
    }

    private struct Disk: Codable { var servers: [SavedServer]; var recent: [String] }

    init() {
        if let d = try? Data(contentsOf: Self.fileURL), let s = try? JSONDecoder().decode(Disk.self, from: d) {
            servers = s.servers
            recent = s.recent
        }
    }

    func save() {
        if let d = try? JSONEncoder().encode(Disk(servers: servers, recent: recent)) { try? d.write(to: Self.fileURL) }
    }

    func addRecent(_ s: String) {
        recent.removeAll { $0 == s }
        recent.insert(s, at: 0)
        if recent.count > 15 { recent.removeLast() }
        save()
    }

    func startDiscovery() {
        guard discoverers.isEmpty else { return }
        scanning = true
        let list = VLCMediaDiscoverer.availableMediaDiscoverer(for: VLCMediaDiscovererCategoryType(rawValue: 1) ?? VLCMediaDiscovererCategoryType(rawValue: 0)!)
        for entry in list {
            guard let d = entry as? [String: Any], let name = d[VLCMediaDiscovererName] as? String else { continue }
            let disc = VLCMediaDiscoverer(name: name)
            let r = disc.startDiscoverer()
            Log.i("net", "Discoverer \(name) started (\(r))")
            discoverers.append(disc)
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    func stopDiscovery() {
        pollTask?.cancel()
        pollTask = nil
        for d in discoverers { d.stop() }
        discoverers.removeAll()
        scanning = false
    }

    private func poll() {
        var out: [Found] = []
        for d in discoverers {
            guard let list = d.discoveredMedia else { continue }
            for i in 0..<list.count {
                guard let m = list.media(at: UInt(i)), let u = m.url else { continue }
                let name = m.metaData.title ?? u.host ?? u.absoluteString
                out.append(Found(id: u.absoluteString, name: name, url: u))
            }
        }
        let unique = Dictionary(out.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }).values
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if unique.map(\.id) != found.map(\.id) { found = Array(unique) }
    }
}

// MARK: - Network tab

struct NetworkTab: View {
    @EnvironmentObject var net: NetworkStore
    @EnvironmentObject private var player: Player
    @State private var path = NavigationPath()
    @State private var showStream = false
    @State private var showAdd = false
    @State private var play: PlayRequest?
    @State private var login: LoginTarget?

    struct LoginTarget: Identifiable { let id = UUID(); let name: String; let url: URL }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    Button { showStream = true } label: { Label("Open Network Stream", systemImage: "link") }
                    Button { showAdd = true } label: { Label("Add server (SMB / FTP / SFTP / NFS / HTTP)", systemImage: "externaldrive.badge.plus") }
                }
                if !net.servers.isEmpty {
                    Section("Favorites") {
                        ForEach(net.servers) { s in
                            Button { connect(s) } label: {
                                Label { VStack(alignment: .leading) { Text(s.name); Text(s.url).font(.caption).foregroundStyle(.secondary) } }
                                    icon: { Image(systemName: "externaldrive.connected.to.line.below") }
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { net.servers.remove(atOffsets: $0); net.save() }
                    }
                }
                Section {
                    if net.found.isEmpty {
                        HStack {
                            if net.scanning { ProgressView() }
                            Text(net.scanning ? "Searching your network…" : "Nothing found").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(net.found) { f in
                        NavigationLink(value: BrowseTarget(title: f.name, url: f.url)) {
                            Label(f.name, systemImage: "server.rack")
                        }
                    }
                } header: { Text("Local Network") } footer: {
                    Text("Lumen asks for Local Network access the first time. Shares that need a login: use Add server.")
                }
                if !net.recent.isEmpty {
                    Section("Recent streams") {
                        ForEach(net.recent, id: \.self) { s in
                            Button { openStream(s) } label: { Text(s).lineLimit(1).font(.callout) }.buttonStyle(.plain)
                        }
                        .onDelete { net.recent.remove(atOffsets: $0); net.save() }
                    }
                }
            }
            .navigationTitle("Network")
            .navigationDestination(for: BrowseTarget.self) { t in
                NetworkBrowser(title: t.title, url: t.url, play: $play)
            }
            .sheet(isPresented: $showStream) { StreamSheet { openStream($0) } }
            .sheet(isPresented: $showAdd) { AddServerSheet() }
            .sheet(item: $login) { l in
                LoginSheet(name: l.name, url: l.url) { url in
                    net.passwords[l.url.absoluteString] = url.password
                    path.append(BrowseTarget(title: l.name, url: url))
                }
            }
            .fullScreenCover(item: $play) { r in
                VLCPlayerScreen(items: r.items, start: r.start, cfg: appCfg)
            }
            .onAppear { net.startDiscovery() }
            .onDisappear { net.stopDiscovery() }
        }
    }

    private var appCfg: Settings { player.cfg }

    private func connect(_ s: SavedServer) {
        guard var comps = URLComponents(string: s.url) else { return }
        if !s.user.isEmpty { comps.user = s.user; comps.password = net.passwords[s.url] }
        guard let u = comps.url else { return }
        if !s.user.isEmpty && net.passwords[s.url] == nil, let base = URL(string: s.url) {
            login = LoginTarget(name: s.name, url: base)
        } else {
            Log.i("net", "Connecting to \(s.url)")
            path.append(BrowseTarget(title: s.name, url: u))
        }
    }

    private func openStream(_ s: String) {
        guard let u = URL(string: s.trimmingCharacters(in: .whitespaces)), u.scheme != nil else { return }
        net.addRecent(s)
        Log.i("net", "Open stream \(u.absoluteString)")
        play = PlayRequest(items: [VLCItem(url: u, title: u.lastPathComponent.isEmpty ? (u.host ?? s) : u.lastPathComponent)], start: 0)
    }
}

struct BrowseTarget: Hashable {
    let title: String
    let url: URL
}

// MARK: - Browser (folders / files on a server)

struct NetworkBrowser: View {
    let title: String
    let url: URL
    @Binding var play: PlayRequest?
    @State private var entries: [Entry] = []
    @State private var loading = true
    @State private var failure: String?

    struct Entry: Identifiable {
        let id = UUID()
        let name: String
        let url: URL
        let isDir: Bool
    }

    var body: some View {
        List {
            if loading { HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) } }
            if let f = failure { Text(f).foregroundStyle(.orange) }
            ForEach(entries) { e in
                if e.isDir {
                    NavigationLink(value: BrowseTarget(title: e.name, url: e.url)) { Label(e.name, systemImage: "folder.fill") }
                } else {
                    Button { open(e) } label: { Label(e.name, systemImage: icon(e.url)) }.buttonStyle(.plain)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func icon(_ u: URL) -> String {
        let e = u.pathExtension.lowercased()
        if MediaExt.video.contains(e) { return "film" }
        if MediaExt.audio.contains(e) { return "music.note" }
        return "doc"
    }

    private func open(_ e: Entry) {
        let files = entries.filter { !$0.isDir && (MediaExt.audio.contains($0.url.pathExtension.lowercased()) || MediaExt.video.contains($0.url.pathExtension.lowercased())) }
        let list = files.isEmpty ? [e] : files
        let idx = list.firstIndex { $0.id == e.id } ?? 0
        play = PlayRequest(items: list.map { VLCItem(url: $0.url, title: $0.name) }, start: idx)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        Log.i("net", "Listing \(url.absoluteString.replacingOccurrences(of: #":[^:@/]*@"#, with: ":***@", options: .regularExpression))")
        guard let media = await VLCMetaParser.shared.parse(url) else {
            failure = "Couldn't read this location. Check the address, login and Local Network permission (see Logs)."
            Log.w("net", "Listing failed")
            return
        }
        guard let list = media.subitems else { return }
        var out: [Entry] = []
        for i in 0..<list.count {
            guard let m = list.media(at: UInt(i)), let u = m.url else { continue }
            let name = m.metaData.title ?? u.lastPathComponent
            out.append(Entry(name: name, url: u, isDir: m.mediaType == .directory))
        }
        entries = out.sorted {
            if $0.isDir != $1.isDir { return $0.isDir }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        if entries.isEmpty { failure = "This folder is empty (or needs a login)." }
        Log.i("net", "Listed \(entries.count) item(s)")
    }
}

// MARK: - Sheets

struct StreamSheet: View {
    var onOpen: (String) -> Void
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://, https://, rtsp://, rtmp://, mms://, udp://@…", text: $text, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("Paste", systemImage: "doc.on.clipboard") { text = UIPasteboard.general.string ?? text }
                } footer: { Text("HLS/DASH, RTSP, RTMP, HTTP(S), FTP, SMB, UDP/RTP multicast and playlists (m3u, pls) are supported.") }
            }
            .navigationTitle("Open Network Stream")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Open") { dismiss(); onOpen(text) }.disabled(text.isEmpty) }
            }
        }
        .presentationDetents([.medium])
    }
}

struct AddServerSheet: View {
    @EnvironmentObject var net: NetworkStore
    @Environment(\.dismiss) private var dismiss
    @State private var proto = "smb"
    @State private var host = ""
    @State private var port = ""
    @State private var path = ""
    @State private var user = ""
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("Protocol", selection: $proto) {
                    ForEach(["smb", "ftp", "sftp", "nfs", "http", "https"], id: \.self) { Text($0.uppercased()).tag($0) }
                }
                TextField("Name (optional)", text: $name)
                TextField("Host or IP", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Port (optional)", text: $port).keyboardType(.numberPad)
                TextField("Path / share (optional)", text: $path).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Username (optional)", text: $user).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            .navigationTitle("Add server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var u = "\(proto)://\(host)"
                        if !port.isEmpty { u += ":\(port)" }
                        u += path.isEmpty ? "/" : (path.hasPrefix("/") ? path : "/" + path)
                        net.servers.append(SavedServer(name: name.isEmpty ? host : name, url: u, user: user))
                        net.save()
                        dismiss()
                    }
                    .disabled(host.isEmpty)
                }
            }
        }
    }
}

struct LoginSheet: View {
    let name: String
    let url: URL
    var onLogin: (URL) -> Void
    @State private var user = ""
    @State private var pass = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Sign in to \(name)") {
                    TextField("Username", text: $user).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $pass)
                }
            }
            .navigationTitle("Login")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        if var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                            c.user = user
                            c.password = pass
                            if let u = c.url { dismiss(); onLogin(u) }
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
