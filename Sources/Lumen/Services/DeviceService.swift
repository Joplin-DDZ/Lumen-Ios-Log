import Foundation

/// 使用官方 JSON 接口发现设备与 App；不解析 devicectl 的面向人类表格输出。
actor DeviceService {
    private var cachedDevices: [DeviceInfo] = []

    func devices() async throws -> [DeviceInfo] {
        if let xcrun = ToolLocator.find("xcrun") {
            do {
                let result = try await jsonCommand(xcrun, ["devicectl", "list", "devices"])
                let devices = result["devices"] as? [[String: Any]] ?? []
                let mapped = devices.compactMap { item -> DeviceInfo? in
                    guard let hardware = item["hardwareProperties"] as? [String: Any],
                          hardware["platform"] as? String == "iOS", let udid = hardware["udid"] as? String else { return nil }
                    let properties = item["deviceProperties"] as? [String: Any] ?? [:]
                    let connection = item["connectionProperties"] as? [String: Any] ?? [:]
                    return DeviceInfo(id: udid, name: properties["name"] as? String ?? "iPhone",
                                      version: properties["osVersionNumber"] as? String ?? "",
                                      model: hardware["productType"] as? String ?? "iPhone",
                                      connected: connection["tunnelState"] as? String == "connected")
                }
                cachedDevices = mapped
                return mapped.sorted { $0.connected && !$1.connected }
            } catch {
                // Xcode 不可用时，设备日志仍能仅依赖 libimobiledevice 工作。
                guard ToolLocator.find("idevice_id") != nil else { throw error }
            }
        }
        guard let tool = ToolLocator.find("idevice_id") else { throw missing("未找到设备工具。请安装 Xcode，或通过 Homebrew 安装 libimobiledevice。") }
        let (output, _) = try await CommandRunner.run(tool, ["-l"])
        var devices: [DeviceInfo] = []
        for udid in output.split(whereSeparator: \.isNewline).map(String.init) {
            if let cached = cachedDevices.first(where: { $0.id == udid }) { var connected = cached; connected.connected = true; devices.append(connected); continue }
            var name = "iPhone", version = ""
            if let info = ToolLocator.find("ideviceinfo"),
               let (xml, _) = try? await CommandRunner.run(info, ["-u", udid, "--xml"], timeout: 5),
               let data = xml.data(using: .utf8),
               let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                name = values["DeviceName"] as? String ?? name; version = values["ProductVersion"] as? String ?? ""
            }
            devices.append(DeviceInfo(id: udid, name: name, version: version, model: "iPhone", connected: true))
        }
        cachedDevices = devices
        return devices
    }

    func apps(deviceID: String) async throws -> [AppTarget] {
        guard let xcrun = ToolLocator.find("xcrun") else { throw missing("读取已安装 App 需要 Xcode；你也可以手动填写 Bundle ID。") }
        let result = try await jsonCommand(xcrun, ["devicectl", "device", "info", "apps", "--device", deviceID])
        return (result["apps"] as? [[String: Any]] ?? []).compactMap { app in
            guard let bundle = app["bundleIdentifier"] as? String else { return nil }
            let name = app["name"] as? String ?? bundle
            let executable = app["executableName"] as? String ??
                (app["url"] as? String).flatMap { URL(string: $0)?.deletingPathExtension().lastPathComponent } ?? name
            return AppTarget(id: bundle, name: name, executable: executable, version: app["version"] as? String ?? "")
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func processes(deviceID: String) async throws -> [RunningProcess] {
        guard let tool = ToolLocator.find("idevicesyslog") else { return [] }
        let (output, _) = try await CommandRunner.run(tool, ["-u", deviceID, "pidlist"], timeout: 8)
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2, let pid = Int(parts[0]) else { return nil }
            return RunningProcess(id: pid, name: String(parts[1]))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func jsonCommand(_ executable: URL, _ args: [String]) async throws -> [String: Any] {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try await CommandRunner.run(executable, args + ["--timeout", "8", "--quiet", "--json-output", file.path])
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        guard let result = root?["result"] as? [String: Any] else { throw missing("设备返回的数据格式无法识别。") }
        return result
    }
    private func missing(_ message: String) -> NSError {
        NSError(domain: "Lumen.Device", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
