import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 主线程只负责可观察状态和交互；设备查询、日志解析、持久化均在后台执行。
@MainActor
final class AppModel: ObservableObject {
    @Published var devices: [DeviceInfo] = []
    @Published var apps: [AppTarget] = []
    @Published var sessions: [LogSession] = []
    @Published var selectedDeviceID = UserDefaults.standard.string(forKey: "deviceID") ?? ""
    @Published var bundleID = UserDefaults.standard.string(forKey: "bundleID") ?? "com.TangibleFuture.looiRobot"
    @Published var state = CaptureState.idle
    @Published var isDiscovering = false
    @Published var isLoadingTargets = false
    @Published var activeSessionID: String?
    @Published var selectedSessionID: String?
    @Published var rows: [LogRecord] = []
    @Published var tableVersion = 0
    @Published var lastRecordAt = Date.distantPast
    @Published var selectedIDs: Set<Int64> = []
    /// 复制使用用户选中时的正文快照，后台换页或续写不改变待复制内容。
    private var selectionSnapshot: [LogRecord] = []
    @Published var selectedRecord: LogRecord?
    @Published var totalCount = 0
    @Published var filteredCount = 0
    @Published var pageOffset = 0
    @Published var scrollTarget: Int64?
    @Published var autoScroll = true
    // 消息默认在列表完整呈现，详情栏仅在主动打开时用于 JSON 或额外信息。
    @Published var showInspector = false
    /// 全部列都允许隐藏；空集合代表全部显示，偏好跨会话与重启保留。
    @Published var hiddenColumns = Set(UserDefaults.standard.stringArray(forKey: "hiddenLogColumns") ?? [])

    func setColumn(_ column: LogColumn, visible: Bool) {
        if visible { hiddenColumns.remove(column.rawValue) } else { hiddenColumns.insert(column.rawValue) }
        UserDefaults.standard.set(hiddenColumns.sorted(), forKey: "hiddenLogColumns")
        NSLog("[Lumen] 日志列显示设置已更新：列=%@ 显示=%@", column.rawValue, visible ? "是" : "否")
    }
    @Published var showFilters = false
    @Published var fontSize: Double = UserDefaults.standard.double(forKey: "fontSize") == 0 ? 12 : UserDefaults.standard.double(forKey: "fontSize")
    @Published var filter = LogFilter() { didSet { scheduleRefresh() } }
    @Published var searchText = "" { didSet { searchIndex = -1; scheduleRefresh() } }
    @Published var searchMatches: [Int64] = []
    @Published var searchIndex = -1
    @Published var lastError: String?
    @Published var notice: String?
    @Published var isExporting = false
    @Published var isImporting = false
    /// 防止导入、创建与自动清理交错时删除尚未完成的会话。
    private var pendingSessionIDs: Set<String> = []
    @Published private(set) var deletingSessionIDs: Set<String> = []
    @Published var savedFilters: [SavedFilter] = []
    let pageSize = 2000
    let root: URL
    private var store: SessionStore?
    private let deviceService = DeviceService()
    private let capture = CaptureService()
    private var deviceTask: Task<Void, Never>?
    private var targetTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var activeConfig: CaptureConfiguration?
    private var stopRequested = false
    // 搜索输入与数据库结果异步更新，回车导航等待对应快照完成。
    private var appliedSessionID: String?
    private var appliedSearchText = ""
    private var appliedFilter = LogFilter()
    private var pendingSearchDirection: Int?
    private var revision = 0
    private var initialized = false
    private var maximumID: Int64 = 0
    private var rateCount = 0
    private var lastRateTime = Date()
    @Published var recordsPerSecond = 0

    init() {
        let custom = ProcessInfo.processInfo.environment["LUMEN_DATA_DIR"]
        root = custom.map { URL(fileURLWithPath: $0) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Lumen", isDirectory: true)
        do { store = try SessionStore(root: root) }
        catch { lastError = error.localizedDescription }
        if let data = UserDefaults.standard.data(forKey: "savedFilters"), let values = try? JSONDecoder().decode([SavedFilter].self, from: data) { savedFilters = values }
    }

    var selectedDevice: DeviceInfo? { devices.first { $0.id == selectedDeviceID } }
    var currentSession: LogSession? { sessions.first { $0.id == selectedSessionID } }
    var viewingLive: Bool { selectedSessionID == activeSessionID && activeSessionID != nil }
    var canStart: Bool {
        store != nil && selectedDevice?.connected == true && !state.isActive &&
        !bundleID.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func bootstrap() async {
        guard !initialized else { return }; initialized = true
        await refreshSessions()
        // 上次异常退出的活动会话仍可阅读，将显示状态恢复为已保存。
        if let store {
            do { try await store.retryPendingDeletions() }
            catch { lastError = "会话文件清理失败，将在下次启动重试：\(error.localizedDescription)" }
            for var session in (try? await store.sessions()) ?? [] where session.status == "采集中" {
                session.status = "已保存"; try? await store.saveSession(session)
            }
            await refreshSessions()
        }
        // 启动先展示 App 控制台入口，不把旧会话误当作当前采集结果。
        showLiveView()
        await discover()
        deviceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { break }
                await self.discover(quiet: true)
            }
        }
    }

    func discover(quiet: Bool = false) async {
        guard !isDiscovering else { return }
        isDiscovering = true; defer { isDiscovering = false }
        do {
            devices = try await deviceService.devices()
            if !devices.contains(where: { $0.id == selectedDeviceID }), let first = devices.first(where: \.connected) {
                selectedDeviceID = first.id; deviceChanged()
            } else if apps.isEmpty && selectedDevice?.connected == true && !isLoadingTargets {
                loadTargets()
            }
            if !quiet { NSLog("[Lumen] 设备发现完成：已连接=%d", devices.filter(\.connected).count) }
        } catch { if !quiet { lastError = error.localizedDescription }; NSLog("[Lumen] 设备发现失败：%@", error.localizedDescription) }
    }

    func deviceChanged() {
        UserDefaults.standard.set(selectedDeviceID, forKey: "deviceID")
        apps = []; loadTargets()
    }

    func loadTargets() {
        guard selectedDevice?.connected == true else { return }
        targetTask?.cancel(); let device = selectedDeviceID
        isLoadingTargets = true
        targetTask = Task { [weak self] in
            guard let self else { return }
            let newApps = try? await deviceService.apps(deviceID: device)
            guard !Task.isCancelled, selectedDeviceID == device else { return }
            apps = newApps ?? []; isLoadingTargets = false
        }
    }

    func chooseApp(_ app: AppTarget) { bundleID = app.id }

    func startCapture() async {
        guard canStart, let device = selectedDevice, let store else { return }
        lastError = nil
        state = .starting; stopRequested = false
        bundleID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let processName = apps.first(where: { $0.id == bundleID })?.executable ?? bundleID
        UserDefaults.standard.set(bundleID, forKey: "bundleID")
        do {
            // 先清理超额历史，再检查总容量；避免旧会话阻止新采集。
            await refreshSessions()
            let storageRoot = root
            let bytes = await Task.detached(priority: .utility) {
                let enumerator = FileManager.default.enumerator(at: storageRoot, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles)
                var total = 0
                while let file = enumerator?.nextObject() as? URL { total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
                return total
            }.value
            guard bytes < 2 * 1024 * 1024 * 1024 else { throw appError("本地日志超过 2 GB。请先导出备份并删除不需要的日志会话。") }
            let id = UUID().uuidString
            pendingSessionIDs.insert(id)
            defer { pendingSessionIDs.remove(id) }
            let name = apps.first(where: { $0.id == bundleID })?.name ?? processName
            let session = LogSession(id: id, title: name.isEmpty ? bundleID : name, deviceName: device.name,
                                     process: processName, mode: .console, createdAt: Date(), count: 0, status: "采集中")
            try await store.saveSession(session)
            let folder = try await store.folder(for: id)
            activeConfig = CaptureConfiguration(deviceID: device.id, process: processName, bundleID: bundleID, folder: folder)
            activeSessionID = id; maximumID = 0; autoScroll = true
            // 新控制台不继承设备日志会话的筛选，避免已采到业务输出却被旧条件隐藏。
            filter = LogFilter(); searchText = ""; showFilters = false
            await refreshSessions(); selectSession(id)
            beginReader()
        } catch { state = .idle; lastError = error.localizedDescription; NSLog("[Lumen] 无法开始采集：%@", error.localizedDescription) }
    }

    private func beginReader() {
        guard let config = activeConfig, let sessionID = activeSessionID else { return }
        let stream = AsyncStream<CaptureEvent> { continuation in
            capture.start(config) { event in
                continuation.yield(event)
                if case .finished = event { continuation.finish() }
            }
        }
        captureTask = Task { [weak self] in
            for await event in stream {
                guard let self else { break }
                await handle(event, sessionID: sessionID)
            }
        }
    }

    private func handle(_ event: CaptureEvent, sessionID: String) async {
        guard sessionID == activeSessionID, let store else { return }
        switch event {
        case .started:
            state = .recording
            if stopRequested { state = .stopping; capture.stop() }
        case .records(let records):
            do {
                lastRecordAt = Date()
                try await store.write(records, sessionID: sessionID)
                let newMaximum = max(maximumID, records.map(\.id).max() ?? 0)
                rateCount += Int(newMaximum - maximumID); maximumID = newMaximum
                let elapsed = Date().timeIntervalSince(lastRateTime)
                if elapsed >= 1 { recordsPerSecond = Int(Double(rateCount) / elapsed); rateCount = 0; lastRateTime = Date() }
                if let index = sessions.firstIndex(where: { $0.id == sessionID }) { sessions[index].count = Int(maximumID) }
                if selectedSessionID == sessionID {
                    if let record = records.first(where: { $0.id == selectedRecord?.id }) { selectedRecord = record }
                    scheduleRefresh()
                }
            } catch {
                lastError = error.localizedDescription; stopRequested = true; state = .stopping; capture.stop()
            }
        case .finished(let message):
            if let message { lastError = message }
            await finishSession()
        }
    }

    func stopCapture() {
        stopRequested = true
        if state.isActive { state = .stopping; capture.stop() }
    }

    private func finishSession() async {
        if let id = activeSessionID, var session = sessions.first(where: { $0.id == id }), let store {
            session.status = "已保存"; try? await store.saveSession(session)
        }
        state = .idle; activeSessionID = nil; activeConfig = nil; recordsPerSecond = 0
        await refreshSessions(); scheduleRefresh()
        NSLog("[Lumen] 会话已保存，目标 App 保持原有运行状态")
    }

    func selectSession(_ id: String) {
        selectedSessionID = id; selectedIDs = []; selectedRecord = nil; rows = []; tableVersion += 1; pageOffset = 0
        filter.afterID = 0; searchIndex = -1; searchMatches = []; pendingSearchDirection = nil
        if id != activeSessionID { autoScroll = false }
        scheduleRefresh(latest: true)
    }

    func showLiveView() {
        if let id = activeSessionID { selectSession(id); return }
        selectedSessionID = nil; selectedIDs = []; selectedRecord = nil
        rows = []; tableVersion += 1; totalCount = 0; filteredCount = 0; filter.afterID = 0
    }

    private func refreshSessions() async {
        guard let store else { return }
        do { try await store.pruneSessions(protecting: protectedSessionIDs) }
        catch { lastError = "旧会话清理失败：\(error.localizedDescription)" }
        do {
            sessions = try await store.sessions().filter(\.isConsoleVisible)
            if let id = selectedSessionID, !sessions.contains(where: { $0.id == id }) { resetDeletedSessionView() }
        } catch { lastError = error.localizedDescription }
    }

    private var protectedSessionIDs: Set<String> {
        pendingSessionIDs.union(activeSessionID.map { [$0] } ?? [])
    }

    func canDeleteSession(_ id: String) -> Bool {
        !protectedSessionIDs.contains(id) && !deletingSessionIDs.contains(id)
    }

    /// 仅删除已结束的会话；完成后按当前选择决定是否清空阅读状态。
    func deleteSession(_ id: String) async {
        guard canDeleteSession(id), let store else { return }
        deletingSessionIDs.insert(id)
        defer { deletingSessionIDs.remove(id) }
        do {
            try await store.deleteSession(id, protecting: protectedSessionIDs)
            showNotice("日志会话已删除")
        } catch { lastError = "删除会话失败：\(error.localizedDescription)"; NSLog("[Lumen] 删除会话失败：%@", error.localizedDescription) }
        await refreshSessions()
    }

    private func resetDeletedSessionView() {
        refreshTask?.cancel(); revision += 1
        selectedSessionID = nil; selectRecords([]); scrollTarget = nil
        rows = []; tableVersion += 1; totalCount = 0; filteredCount = 0; pageOffset = 0
        searchMatches = []; searchIndex = -1; pendingSearchDirection = nil
    }

    func scheduleRefresh(latest: Bool = false) {
        refreshTask?.cancel(); revision += 1; let currentRevision = revision
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            await loadRows(latest: latest, expectedRevision: currentRevision)
        }
    }

    private func loadRows(latest: Bool, expectedRevision: Int, target: Int64? = nil) async {
        guard let id = selectedSessionID, let store else { return }
        let snapshot = filter, query = searchText
        guard snapshot.validationError == nil else { rows = []; tableVersion += 1; filteredCount = 0; return }
        do {
            let allCount = try await store.count(sessionID: id, filter: LogFilter())
            let count = try await store.count(sessionID: id, filter: snapshot)
            var offset = min(pageOffset, max(0, count - 1))
            if latest || (viewingLive && autoScroll) { offset = max(0, count - pageSize) }
            if let target { let before = try await store.count(sessionID: id, filter: snapshot, before: target); offset = (before / pageSize) * pageSize }
            let result = try await store.records(sessionID: id, filter: snapshot, offset: offset, limit: pageSize)
            let matches = try await store.search(sessionID: id, filter: snapshot, query: query)
            guard expectedRevision == revision, id == selectedSessionID, !Task.isCancelled else { return }
            totalCount = allCount; filteredCount = count; pageOffset = offset; rows = result; tableVersion += 1; searchMatches = matches
            appliedSessionID = id
            appliedSearchText = query; appliedFilter = snapshot
            if let direction = pendingSearchDirection {
                pendingSearchDirection = nil
                findNext(direction)
                return
            }
            if latest, !viewingLive { scrollTarget = rows.last?.id }
            if let target { selectRecords([target]); scrollTarget = target }
            else if let record = selectedRecord, let updated = rows.first(where: { $0.id == record.id }) { selectedRecord = updated }
        } catch { if !Task.isCancelled { lastError = error.localizedDescription } }
    }

    func selectRecords(_ ids: Set<Int64>, displayedRecords: [LogRecord]? = nil) {
        selectedIDs = ids
        selectionSnapshot = (displayedRecords ?? rows).filter { ids.contains($0.id) }
        selectedRecord = selectionSnapshot.last
        // 阅读和复制期间停止自动跟随，避免新日志把选区移出当前页面。
        if !ids.isEmpty { autoScroll = false }
    }

    func movePage(_ direction: Int) {
        autoScroll = false; pageOffset = max(0, min(max(0, filteredCount - pageSize), pageOffset + direction * pageSize))
        scheduleRefresh()
    }
    func resumeScrolling() { autoScroll = true; scheduleRefresh(latest: true) }
    func clearView() {
        Task {
            guard let id = selectedSessionID, let store else { return }
            filter.afterID = (try? await store.maximumID(sessionID: id)) ?? 0
            selectedRecord = nil; selectedIDs = []; showNotice("视图已清空，历史日志仍然保留")
        }
    }
    func resetFilters() { filter = LogFilter(afterID: filter.afterID) }
    func showContext() { filter = LogFilter(); showFilters = false; if let record = selectedRecord { jump(to: record.id) } }
    func findNext(_ direction: Int) {
        guard filter.validationError == nil else { return }
        if appliedSessionID != selectedSessionID || appliedSearchText != searchText || appliedFilter != filter {
            pendingSearchDirection = direction; scheduleRefresh(); return
        }
        guard !searchMatches.isEmpty else { return }
        searchIndex = searchIndex < 0 ? (direction > 0 ? 0 : searchMatches.count - 1) : (searchIndex + direction + searchMatches.count) % searchMatches.count
        jump(to: searchMatches[searchIndex])
    }
    private func jump(to id: Int64) {
        autoScroll = false; refreshTask?.cancel(); revision += 1; let expected = revision
        Task { await loadRows(latest: false, expectedRevision: expected, target: id) }
    }
    /// 独立生成复制内容，避免复制时重新读取正在变化的列表。
    var selectedCopyText: String {
        let selected = selectionSnapshot.filter { selectedIDs.contains($0.id) }
        return selected.isEmpty ? selectedRecord?.raw ?? "" : selected.map(\.raw).joined(separator: "\n")
    }
    func copySelection() {
        let text = selectedCopyText
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        if !text.isEmpty {
            NSLog("[Lumen] 已复制选中日志快照：记录数=%d", selectedIDs.count)
            showNotice("已复制日志")
        }
    }
    func saveFilter(name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        savedFilters.append(SavedFilter(name: name, include: filter.include, exclude: filter.exclude, regex: filter.regex, levels: Array(filter.levels)))
        UserDefaults.standard.set(try? JSONEncoder().encode(savedFilters), forKey: "savedFilters")
    }
    func applyFilter(_ saved: SavedFilter) {
        filter = LogFilter(include: saved.include, exclude: saved.exclude, regex: saved.regex, levels: Set(saved.levels), afterID: filter.afterID)
        showFilters = true
    }
    func removeFilter(_ id: String) {
        savedFilters.removeAll { $0.id == id }; UserDefaults.standard.set(try? JSONEncoder().encode(savedFilters), forKey: "savedFilters")
    }
    func export(json: Bool, all: Bool) {
        guard let id = selectedSessionID, let store else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [json ? .init(filenameExtension: "jsonl") ?? .plainText : .plainText]
        panel.nameFieldStringValue = "\(currentSession?.title ?? "Lumen")-\(all ? "全部" : "筛选").\(json ? "jsonl" : "txt")"
        panel.title = all ? "导出整个会话" : "导出当前筛选结果"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isExporting = true; let snapshot = all ? LogFilter() : filter
        Task {
            defer { isExporting = false }
            do { try await store.export(sessionID: id, filter: snapshot, to: url, json: json); showNotice("日志已导出") }
            catch { lastError = error.localizedDescription }
        }
    }
    func importFile() {
        guard let store else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.plainText, .json, .data]; panel.allowsMultipleSelection = false
        panel.message = "导入 TXT、LOG 或 Lumen 导出的 JSONL（最大 32 MB）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isImporting = true
        Task {
            defer { isImporting = false }
            do {
                let records = try await LogImporter.read(url)
                let id = UUID().uuidString
                pendingSessionIDs.insert(id)
                defer { pendingSessionIDs.remove(id) }
                let session = LogSession(id: id, title: url.lastPathComponent, deviceName: "本地导入", process: "离线日志", mode: .device,
                                         createdAt: Date(), count: records.count, status: "已导入")
                try await store.saveSession(session)
                for start in stride(from: 0, to: records.count, by: 1000) { try await store.write(Array(records[start..<min(records.count, start + 1000)]), sessionID: id) }
                let folder = try await store.folder(for: id)
                try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent("original.\(url.pathExtension)"))
                await refreshSessions(); selectSession(id); showNotice("已导入 \(records.count) 条日志")
            } catch { lastError = "导入失败：\(error.localizedDescription)" }
        }
    }
    func revealSession() {
        if let id = selectedSessionID { NSWorkspace.shared.open(root.appendingPathComponent("Sessions/\(id)")) }
        else { NSWorkspace.shared.open(root) }
    }
    func changeFontSize(_ delta: Double) { fontSize = min(18, max(10, fontSize + delta)); UserDefaults.standard.set(fontSize, forKey: "fontSize") }
    func showNotice(_ text: String) {
        notice = text
        Task { try? await Task.sleep(for: .seconds(3)); if notice == text { notice = nil } }
    }
    func shutdown() async {
        deviceTask?.cancel(); targetTask?.cancel()
        if state.isActive {
            stopCapture()
            for _ in 0..<60 { if state == .idle { break }; try? await Task.sleep(for: .milliseconds(100)) }
        }
        await refreshSessions()
    }
    private func appError(_ message: String) -> NSError { NSError(domain: "Lumen", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
