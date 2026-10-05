import SwiftUI
import UIKit

@MainActor final class FileLogState: ObservableObject {
    static let shared = FileLogState()
    @Published var page = LogFilePage(lines: [], start: 0, total: 0, generation: 0)
    @Published var severity = "all"
    @Published var source = "all"
    @Published var query = ""
    @Published var follow = true
    @Published var showContext = false
    @Published var anchor: Int?
    @Published var error: String?
    @Published var newLines = 0
    @Published var searching = false
    @Published var progress = 0.0
    @Published var hits: [(line: Int, text: String)] = []
    @Published var searchNotice: String?
    private var loading = false
    private var searchTask: Task<Void, Never>?
    private var searchID = UUID()

    func load(start: Int? = nil, latest: Bool = false) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let next = try await AppLogPersister.shared.historyPage(start: latest ? nil : start ?? page.start, generation: page.generation)
            let replaced = next.generation != page.generation
            page = next; error = nil; newLines = 0
            if latest {
                follow = true
                anchor = next.lines.enumerated().last(where: { matches($0.element) }).map { next.start + $0.offset }
            }
            else { follow = false; anchor = next.start }
            if replaced { hits = []; searchNotice = AppLanguage.localized("logs.fileChanged") }
        } catch { self.error = error.localizedDescription }
    }
    func refresh() async {
        guard !loading else { return }
        if follow { await load(latest: true); return }
        loading = true
        defer { loading = false }
        do {
            let latest = try await AppLogPersister.shared.historyPage()
            if latest.generation != page.generation {
                page = latest; anchor = latest.start; hits = []
                searchNotice = AppLanguage.localized("logs.fileChanged")
            }
            newLines = max(0, latest.total - page.total)
        } catch { self.error = error.localizedDescription }
    }
    func matches(_ text: String) -> Bool {
        showContext || LogPresentation(text).matches(text, severityFilter: severity, sourceFilter: source, query: query)
    }
    func cancelSearch() { searchID = UUID(); searchTask?.cancel(); searchTask = nil; searching = false }
    func searchFile() {
        cancelSearch(); hits = []; progress = 0; searchNotice = nil; searching = true
        let query = query, severity = severity, source = source
        let token = searchID
        searchTask = Task {
            defer { if searchID == token { searching = false } }
            do {
                let initial = try await AppLogPersister.shared.historyPage(start: 0)
                let total = initial.total, generation = initial.generation
                var offset = 0
                while offset < total {
                    try Task.checkCancellation()
                    let chunk = try await AppLogPersister.shared.historyPage(start: offset, generation: generation)
                    try Task.checkCancellation()
                    guard chunk.generation == generation else {
                        hits = []; searchNotice = AppLanguage.localized("logs.fileChanged"); return
                    }
                    for (index, text) in chunk.lines.enumerated() where offset + index < total {
                        if LogPresentation(text).matches(text, severityFilter: severity, sourceFilter: source, query: query) {
                            hits.append((offset + index, text))
                            if hits.count >= 500 { searchNotice = AppLanguage.localized("logs.searchLimit"); return }
                        }
                    }
                    offset += 200; progress = min(1, Double(offset) / Double(max(1, total)))
                }
                progress = 1
                searchNotice = AppLanguage.localized("logs.searchDone") + " \(hits.count)"
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct FileLogView: View {
    @StateObject private var state = FileLogState.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("logMode", store: userDefaults) private var logMode = 1
    @State private var showSettings = false
    @State private var confirmClear = false
    @State private var showSearch = false

    private var visible: [(line: Int, text: String)] {
        state.page.lines.enumerated().compactMap { index, text in
            state.matches(text) ? (state.page.start + index, text) : nil
        }
    }
    var body: some View {
        VStack(spacing: 8) {
            VStack(spacing: 8) {
                Picker(AppLanguage.localized("main.log_mode"), selection: $logMode) {
                    Text(AppLanguage.localized("logs.app")).tag(1)
                    Text(AppLanguage.localized("logs.external")).tag(0)
                    Text(AppLanguage.localized("logs.both")).tag(2)
                }.pickerStyle(.segmented)
                .onChange(of: logMode) { value in
                    LPConfig.shared.logMode = value
                    CFNotificationCenterPostNotification(cfCenter, CFNotificationName("logMode" as CFString), nil, nil, true)
                }
                TextField(AppLanguage.localized("logs.search"), text: $state.query)
                    .textFieldStyle(.roundedBorder).autocorrectionDisabled().textInputAutocapitalization(.never)
                HStack {
                    Picker(AppLanguage.localized("logs.level"), selection: $state.severity) {
                        Text(AppLanguage.localized("logs.all")).tag("all")
                        Text(AppLanguage.localized("logs.issues")).tag("issues")
                        ForEach(LogSeverity.allCases, id: \.rawValue) { Text(AppLanguage.localized($0.titleKey)).tag($0.rawValue) }
                    }
                    Picker(AppLanguage.localized("logs.source"), selection: $state.source) {
                        Text(AppLanguage.localized("logs.all")).tag("all")
                        ForEach(LogPresentation.sources, id: \.self) { Text($0).tag($0) }
                    }
                    Spacer()
                    Menu {
                        Button(AppLanguage.localized("logs.copy")) { UIPasteboard.general.string = visible.map(\.text).joined(separator: "\n") }
                        Button(AppLanguage.localized("main.settings")) { showSettings = true }
                        Button(AppLanguage.localized("logs.clear"), role: .destructive) { confirmClear = true }
                        Button(AppLanguage.localized("logs.clearOverlay")) {
                            LPConfig.shared.isReconnecting = false; LPConfig.shared.reconnectStatus = ""
                            PIPService.shared.clearAdOverlay()
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }.pickerStyle(.menu)
                if state.showContext {
                    Button(AppLanguage.localized("logs.resumeFilters")) { state.showContext = false }
                }
                HStack {
                    Button(AppLanguage.localized("logs.older")) { Task { await state.load(start: max(0, state.page.start - 200)) } }
                        .disabled(state.page.start == 0)
                    Button(AppLanguage.localized("logs.newer")) { Task { await state.load(start: state.page.start + 200) } }
                        .disabled(state.page.start + 200 >= state.page.total)
                    Spacer()
                    Button(AppLanguage.localized("logs.latest")) { Task { await state.load(latest: true) } }
                }
                HStack {
                    Text("log.txt · \(state.page.total == 0 ? 0 : state.page.start + 1)–\(min(state.page.total, state.page.start + 200)) / \(state.page.total)")
                    Spacer()
                    Button(AppLanguage.localized("logs.searchFile")) { state.searchFile(); showSearch = true }
                }.font(.caption)
                Text(AppLanguage.localized(state.follow ? "logs.following" : "logs.history") + (state.newLines > 0 ? " (+\(state.newLines))" : ""))
                    .font(.caption).foregroundStyle(.secondary)
                if let error = state.error { Text(error).font(.caption).foregroundStyle(.red) }
                if let notice = state.searchNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            }.padding(.horizontal)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(visible, id: \.line) { item in
                        row(item.text, line: item.line).id(item.line)
                    }
                }.scrollTargetLayout().padding()
            }
            .scrollPosition(id: $state.anchor)
            .simultaneousGesture(DragGesture().onChanged { _ in state.follow = false })
        }
        .sheet(isPresented: $showSettings) { LogSettingsView() }
        .sheet(isPresented: $showSearch, onDismiss: { state.cancelSearch() }) {
            NavigationStack {
                List {
                    if state.searching { ProgressView(value: state.progress) }
                    if let notice = state.searchNotice { Text(notice) }
                    ForEach(state.hits, id: \.line) { hit in
                        Button {
                            state.cancelSearch(); state.showContext = true; state.follow = false; showSearch = false
                            Task { await state.load(start: max(0, hit.line - 10)) }
                        } label: { Text("\(hit.line + 1): \(hit.text)").lineLimit(4) }
                    }
                }
                .navigationTitle(AppLanguage.localized("logs.searchFile"))
                .toolbar { Button(AppLanguage.localized("logs.close")) { showSearch = false } }
            }
        }
        .confirmationDialog(AppLanguage.localized("logs.clearConfirm"), isPresented: $confirmClear, titleVisibility: .visible) {
            Button(AppLanguage.localized("logs.clear"), role: .destructive) {
                state.cancelSearch(); AppLogPersister.shared.clear()
                Task { await state.load(latest: true) }
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await state.refresh()
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            }
        }
        .onDisappear { state.cancelSearch() }
    }
    private func row(_ text: String, line: Int) -> some View {
        let meta = LogPresentation(text)
        let color: Color = meta.severity == .error ? .red : meta.severity == .warning ? .orange : meta.severity == .success ? .green : .primary
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(line + 1) · \(meta.severity.marker) \(AppLanguage.localized(meta.severity.titleKey)) · \(meta.source)")
                .font(.caption).foregroundStyle(color)
            Text(text).font(.system(.caption, design: .monospaced)).foregroundStyle(color).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
