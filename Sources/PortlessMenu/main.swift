import SwiftUI
import AppKit

struct PackageJSON: Decodable {
    let scripts: [String: String]?
    let dependencies: [String: String]?
    let devDependencies: [String: String]?
    let optionalDependencies: [String: String]?
}

struct PackageScript: Identifiable, Hashable {
    let key: String
    let command: String

    var id: String { key }

    var isLikelyPortless: Bool {
        command.localizedCaseInsensitiveContains("portless") ||
        key.localizedCaseInsensitiveContains("portless")
    }
}

struct RunningApp: Identifiable, Hashable {
    enum Source: Hashable {
        case managed
        case external
    }

    let id: String
    let pid: Int32
    let name: String
    let scriptKey: String
    let folderPath: String
    let command: String
    let source: Source
    let startedAt: Date
    let ports: [Int]
    let urls: [String]
    let lastLogLine: String?
}

struct RunRecord: Identifiable, Hashable {
    enum State: String, Hashable {
        case running
        case exitedOK
        case failed
    }

    let id: String
    let pid: Int32
    let name: String
    let command: String
    let startedAt: Date
    var endedAt: Date?
    var state: State
    var exitCode: Int32?
    var lastLogLine: String?
}

struct RecentLaunch: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let scriptKey: String
    let folderPath: String
    let commandParts: [String]
    let createdAt: Date
}

struct ScriptRunnerPlan {
    let args: [String]
    let warning: String?
}

struct ProxyRoute: Identifiable, Hashable {
    let id: String
    let rawLine: String
    let name: String
    let url: String?
    let scheme: String?
    let host: String?
    let port: Int?

    var endpoint: String {
        if let url, !url.isEmpty {
            return url
        }
        guard let host else { return rawLine }
        let resolvedScheme = scheme ?? "http"
        if let port {
            return "\(resolvedScheme)://\(host):\(port)"
        }
        return "\(resolvedScheme)://\(host)"
    }
}

final class ManagedProcess {
    let process: Process
    let app: RunningApp

    init(process: Process, app: RunningApp) {
        self.process = process
        self.app = app
    }
}

@MainActor
final class PortlessMenuModel: ObservableObject {
    @Published var selectedFolderPath: String?
    @Published var recentFolders: [String] = []
    @Published var scripts: [PackageScript] = []
    @Published var scriptFilter: String = ""
    @Published var selectedScriptKey: String = ""
    @Published var runName: String = ""
    @Published var usePortlessWrapper: Bool = true
    @Published var runningApps: [RunningApp] = []
    @Published var recentRuns: [RunRecord] = []
    @Published var recentLaunches: [RecentLaunch] = []
    @Published var routes: [String] = []
    @Published var proxyRoutes: [ProxyRoute] = []
    @Published var proxyPort: String = ""
    @Published var proxyUseHTTPS: Bool = false
    @Published var proxyNoTLS: Bool = false
    @Published var proxyCertPath: String = ""
    @Published var proxyKeyPath: String = ""
    @Published var hasLocalPortlessDependency: Bool = false
    @Published var isPortlessInstalledGlobally: Bool = false
    @Published var isInstallingPortless: Bool = false
    @Published var statusMessage: String = "Pick a project folder to begin."

    private let recentFoldersKey = "portlessMenu.recentFolders"
    private let recentLaunchesKey = "portlessMenu.recentLaunches"
    private let proxyPortKey = "portlessMenu.proxyPort"
    private let proxyUseHTTPSKey = "portlessMenu.proxyUseHTTPS"
    private let proxyNoTLSKey = "portlessMenu.proxyNoTLS"
    private let proxyCertPathKey = "portlessMenu.proxyCertPath"
    private let proxyKeyPathKey = "portlessMenu.proxyKeyPath"
    private let maxRecentFolders = 8

    private var managed: [Int32: ManagedProcess] = [:]
    private var external: [Int32: RunningApp] = [:]
    private var monitorTimer: Timer?

    private var managedLogBuffers: [Int32: String] = [:]
    private var managedLogLines: [Int32: [String]] = [:]
    private var managedURLs: [Int32: Set<String>] = [:]
    private var managedPorts: [Int32: Set<Int>] = [:]
    private var runRecordsByPID: [Int32: RunRecord] = [:]
    private var cachedBinPaths: [String]?
    private var cachedBinPathsAt: Date?
    private var commandExistsCache: [String: (exists: Bool, at: Date)] = [:]
    private var runningAppsRefreshWorkItem: DispatchWorkItem?
    private var runHistoryRefreshWorkItem: DispatchWorkItem?
    private let maxRunHistory = 20
    private let maxRecentLaunches = 12
    private let toolCacheTTL: TimeInterval = 30
    private let knownPortlessPackages = ["portless", "@vercel-labs/portless"]
    private let preferredBinPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/opt/local/bin"
    ]

    init() {
        loadRecentFolders()
        loadRecentLaunches()
        loadProxySettings()
        DispatchQueue.main.async { [weak self] in
            self?.refreshPortlessAvailability()
            self?.startMonitoring()
            self?.refreshRoutes()
        }
    }

    deinit {
        monitorTimer?.invalidate()
    }

    var filteredScripts: [PackageScript] {
        let filter = scriptFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        if filter.isEmpty {
            return scripts
        }

        return scripts.filter {
            $0.key.localizedCaseInsensitiveContains(filter) ||
            $0.command.localizedCaseInsensitiveContains(filter)
        }
    }

    var selectedScriptNeedsPortlessTool: Bool {
        guard let script = scripts.first(where: { $0.key == selectedScriptKey }) else { return false }
        if usePortlessWrapper {
            return !isSelfBootstrappingPortlessCommand(script.command)
        }
        return script.isLikelyPortless && !isSelfBootstrappingPortlessCommand(script.command)
    }

    var canRunSelectedPortlessScript: Bool {
        hasLocalPortlessDependency || isPortlessInstalledGlobally || !selectedScriptNeedsPortlessTool
    }

    var proxyStartValidationMessage: String? {
        let cert = proxyCertPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = proxyKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)

        if !proxyPort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let port = Int(proxyPort.trimmingCharacters(in: .whitespacesAndNewlines)),
                  (1...65535).contains(port) else {
                return "Proxy port must be a number between 1 and 65535."
            }
        }

        if cert.isEmpty != key.isEmpty {
            return "Set both cert and key paths or leave both empty."
        }

        if !cert.isEmpty && !proxyUseHTTPS {
            return "Enable HTTPS to use custom cert/key files."
        }

        if !cert.isEmpty && !FileManager.default.fileExists(atPath: cert) {
            return "Cert file was not found at the provided path."
        }

        if !key.isEmpty && !FileManager.default.fileExists(atPath: key) {
            return "Key file was not found at the provided path."
        }

        return nil
    }

    func ensureSelectedScriptIsVisible() {
        let visible = filteredScripts
        if visible.contains(where: { $0.key == selectedScriptKey }) {
            return
        }

        if let preferred = visible.first(where: { $0.isLikelyPortless }) ?? visible.first {
            selectedScriptKey = preferred.key
        } else {
            selectedScriptKey = ""
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            loadFolder(url)
        }
    }

    func loadFolder(_ url: URL) {
        selectedFolderPath = url.path
        addRecentFolder(url.path)
        if runName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            runName = suggestedAppName(from: url.path)
        }
        readScripts(from: url)
    }

    func readScripts(from folderURL: URL) {
        let packageURL = folderURL.appendingPathComponent("package.json")

        guard let data = try? Data(contentsOf: packageURL) else {
            scripts = []
            selectedScriptKey = ""
            hasLocalPortlessDependency = false
            statusMessage = "No package.json found in selected folder."
            return
        }

        do {
            let decoded = try JSONDecoder().decode(PackageJSON.self, from: data)
            let discovered = (decoded.scripts ?? [:])
                .map { PackageScript(key: $0.key, command: $0.value) }
                .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            hasLocalPortlessDependency = hasKnownPortlessPackage(in: decoded)

            scripts = discovered
            ensureSelectedScriptIsVisible()
            refreshPortlessAvailability()
            statusMessage = discovered.isEmpty ? "No scripts found in package.json." : "Loaded \(discovered.count) scripts."
        } catch {
            scripts = []
            selectedScriptKey = ""
            hasLocalPortlessDependency = false
            statusMessage = "Failed to parse package.json: \(error.localizedDescription)"
        }
    }

    func runSelectedScript() {
        guard
            let folder = selectedFolderPath,
            !selectedScriptKey.isEmpty,
            scripts.contains(where: { $0.key == selectedScriptKey })
        else {
            statusMessage = "Select a folder and script before running."
            return
        }

        if selectedScriptNeedsPortlessTool && !canRunSelectedPortlessScript {
            statusMessage = "Portless tool not found. Use Install Portless first."
            return
        }

        guard let selectedScript = scripts.first(where: { $0.key == selectedScriptKey }) else {
            statusMessage = "Unable to resolve selected script."
            return
        }

        let packageManager = detectPackageManager(at: folder)
        let runnerPlan = resolveScriptRunner(packageManager: packageManager, scriptKey: selectedScriptKey)
        let normalizedName = normalizeAppName(
            runName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? suggestedAppName(from: folder)
                : runName
        )

        let isPortlessScript = selectedScript.command.localizedCaseInsensitiveContains("portless")
        let useWrapper = usePortlessWrapper && !isPortlessScript

        let displayName = useWrapper ? normalizedName : selectedScriptKey
        let commandParts: [String]
        if useWrapper {
            commandParts = ["portless", normalizedName] + runnerPlan.args
        } else {
            commandParts = runnerPlan.args
        }
        startManagedProcess(
            commandParts: commandParts,
            folder: folder,
            displayName: displayName,
            scriptKey: selectedScriptKey,
            warning: runnerPlan.warning,
            storeRecent: true
        )
        if runName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            runName = suggestedAppName(from: folder)
        }
    }

    func runRecentLaunch(id: String) {
        guard let launch = recentLaunches.first(where: { $0.id == id }) else {
            statusMessage = "Recent launch not found."
            return
        }
        startManagedProcess(
            commandParts: launch.commandParts,
            folder: launch.folderPath,
            displayName: launch.name,
            scriptKey: launch.scriptKey,
            warning: nil,
            storeRecent: true
        )
    }

    private func startManagedProcess(
        commandParts: [String],
        folder: String,
        displayName: String,
        scriptKey: String,
        warning: String?,
        storeRecent: Bool
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = commandParts
        process.environment = toolExecutionEnvironment()
        process.currentDirectoryURL = URL(fileURLWithPath: folder)

        let out = Pipe()
        process.standardOutput = out
        process.standardError = out

        do {
            try process.run()
        } catch {
            statusMessage = "Failed to start script: \(error.localizedDescription)"
            return
        }

        let pid = process.processIdentifier
        let app = RunningApp(
            id: "managed-\(pid)",
            pid: pid,
            name: displayName,
            scriptKey: scriptKey,
            folderPath: folder,
            command: commandParts.joined(separator: " "),
            source: .managed,
            startedAt: Date(),
            ports: [],
            urls: [],
            lastLogLine: nil
        )

        managed[pid] = ManagedProcess(process: process, app: app)
        managedLogBuffers[pid] = ""
        managedLogLines[pid] = []
        managedURLs[pid] = []
        managedPorts[pid] = []

        let record = RunRecord(
            id: "run-\(pid)-\(Int(Date().timeIntervalSince1970))",
            pid: pid,
            name: displayName,
            command: commandParts.joined(separator: " "),
            startedAt: Date(),
            endedAt: nil,
            state: .running,
            exitCode: nil,
            lastLogLine: nil
        )
        runRecordsByPID[pid] = record
        refreshRunHistory()

        if storeRecent {
            addRecentLaunch(
                name: displayName,
                scriptKey: scriptKey,
                folderPath: folder,
                commandParts: commandParts
            )
        }

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in
                self?.consumeOutput(pid: pid, data: data)
            }
        }

        scheduleRunningAppsRefresh()

        let startedAt = Date()
        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                let lastLine = self?.managedLogLines[pid]?.last
                let runtime = Date().timeIntervalSince(startedAt)
                self?.updateRunRecordForTermination(pid: pid, exitCode: proc.terminationStatus, lastLine: lastLine)
                self?.cleanupManagedProcess(pid: pid)
                self?.scheduleRunningAppsRefresh()
                self?.refreshRoutes()

                if proc.terminationStatus != 0 {
                    self?.statusMessage = "Run failed (exit \(proc.terminationStatus)): \(lastLine ?? "see terminal output in command logs")"
                } else if runtime < 2.0 {
                    self?.statusMessage = "Run exited quickly. Last log: \(lastLine ?? "no output")"
                }
            }
        }

        statusMessage = "Started \(displayName) (pid \(pid))."
        if let warning {
            statusMessage = "Started \(displayName) (pid \(pid)). \(warning)"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshRoutes()
        }
    }

    func installPortless() {
        guard !isInstallingPortless else { return }
        isInstallingPortless = true

        let installCommand = globalInstallCommand()
        statusMessage = "Installing Portless..."

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", installCommand]
        process.environment = toolExecutionEnvironment()

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            isInstallingPortless = false
            statusMessage = "Failed to start installer: \(error.localizedDescription)"
            return
        }

        process.terminationHandler = { [weak self] proc in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                self?.isInstallingPortless = false
                self?.invalidateToolCaches()
                self?.refreshPortlessAvailability()
                if proc.terminationStatus == 0 {
                    self?.statusMessage = "Portless installed successfully."
                } else if let summary = output
                    .split(separator: "\n")
                    .map(String.init)
                    .last(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    self?.statusMessage = "Install failed: \(summary)"
                } else {
                    self?.statusMessage = "Portless install failed."
                }
            }
        }
    }

    func stop(_ pid: Int32) {
        if let managedProcess = managed[pid] {
            managedProcess.process.terminate()
            statusMessage = "Stopped pid \(pid)."
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/kill")
        task.arguments = ["-TERM", "\(pid)"]

        do {
            try task.run()
            statusMessage = "Sent TERM to external pid \(pid)."
            external.removeValue(forKey: pid)
            refreshRunningApps()
        } catch {
            statusMessage = "Failed to stop pid \(pid): \(error.localizedDescription)"
        }
    }

    func refreshPortlessProcessesNow(onComplete: (() -> Void)? = nil) {
        refreshPortlessProcessesAsync(onComplete: onComplete)
    }

    func recentFolderLabel(for path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    func openInBrowser(_ rawURL: String) {
        guard let url = URL(string: rawURL), url.scheme != nil else {
            statusMessage = "Invalid URL: \(rawURL)"
            return
        }
        NSWorkspace.shared.open(url)
        statusMessage = "Opened \(rawURL)"
    }

    func refreshPortlessAvailability() {
        isPortlessInstalledGlobally = commandExists("portless")
    }

    func startProxy() {
        guard canRunSelectedPortlessScript || isPortlessInstalledGlobally else {
            statusMessage = "Install Portless before starting proxy."
            return
        }
        if let validation = proxyStartValidationMessage {
            statusMessage = validation
            return
        }
        let plan = buildProxyStartPlan()
        statusMessage = "Starting Portless proxy..."
        runAsyncCommand(plan.arguments) { [weak self] code, output in
            guard let self else { return }
            if code == 0 {
                if let warning = plan.warning {
                    self.statusMessage = "Portless proxy started. \(warning)"
                } else {
                    self.statusMessage = "Portless proxy started."
                }
                self.refreshRoutes()
            } else {
                self.statusMessage = "Proxy start failed: \(self.lastNonEmptyLine(from: output) ?? "unknown error")"
            }
        }
    }

    func stopProxy() {
        statusMessage = "Stopping Portless proxy..."
        runAsyncCommand(["portless", "proxy", "stop"]) { [weak self] code, output in
            guard let self else { return }
            if code == 0 {
                self.statusMessage = "Portless proxy stopped."
                self.refreshRoutes()
            } else {
                self.statusMessage = "Proxy stop failed: \(self.lastNonEmptyLine(from: output) ?? "unknown error")"
            }
        }
    }

    func restartProxy() {
        guard canRunSelectedPortlessScript || isPortlessInstalledGlobally else {
            statusMessage = "Install Portless before restarting proxy."
            return
        }
        if let validation = proxyStartValidationMessage {
            statusMessage = validation
            return
        }

        statusMessage = "Restarting Portless proxy..."
        runAsyncCommand(["portless", "proxy", "stop"]) { [weak self] _, _ in
            self?.startProxy()
        }
    }

    func trustProxyCertificate() {
        guard commandExists("portless") else {
            statusMessage = "Install Portless before trusting certificates."
            return
        }

        statusMessage = "Requesting admin access to trust Portless certificate..."
        runAsyncAdminShell("portless trust") { [weak self] code, output in
            guard let self else { return }
            if code == 0 {
                self.statusMessage = "Portless certificate trusted."
            } else {
                let summary = self.lastNonEmptyLine(from: output) ?? "authorization failed"
                self.statusMessage = "Trust failed: \(summary)"
            }
        }
    }

    func refreshRoutes() {
        guard commandExists("portless") else {
            routes = []
            proxyRoutes = []
            return
        }

        runAsyncCommand(["portless", "list"]) { [weak self] code, output in
            guard let self else { return }
            if code != 0 {
                self.routes = []
                self.proxyRoutes = []
                return
            }

            let lines = output
                .split(separator: "\n")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            self.routes = lines
            self.proxyRoutes = self.parseProxyRoutes(from: lines)
        }
    }

    private func startMonitoring() {
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPortlessProcessesAsync()
            }
        }

        refreshPortlessProcessesAsync()
    }

    private func refreshPortlessProcessesAsync(onComplete: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let snapshot = Self.captureOutputStatic(
                executable: "/usr/bin/pgrep",
                arguments: ["-fal", "portless"]
            )
            Task { @MainActor in
                self.updateExternalProcesses(fromSnapshot: snapshot)
                self.scheduleRunningAppsRefresh()
                onComplete?()
            }
        }
    }

    private func refreshRunningApps() {
        let managedApps = managed.values.map { managedProcess in
            let base = managedProcess.app
            let pid = base.pid
            return RunningApp(
                id: base.id,
                pid: base.pid,
                name: base.name,
                scriptKey: base.scriptKey,
                folderPath: base.folderPath,
                command: base.command,
                source: base.source,
                startedAt: base.startedAt,
                ports: Array(managedPorts[pid] ?? []).sorted(),
                urls: Array(managedURLs[pid] ?? []).sorted(),
                lastLogLine: managedLogLines[pid]?.last
            )
        }

        let externalApps = external
            .filter { managed[$0.key] == nil }
            .map(\.value)

        runningApps = (managedApps + externalApps)
            .sorted { $0.startedAt > $1.startedAt }
    }

    private func scheduleRunningAppsRefresh() {
        runningAppsRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.refreshRunningApps()
        }
        runningAppsRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }

    private func updateExternalProcesses(fromSnapshot snapshot: String) {
        guard !snapshot.isEmpty else {
            external = [:]
            return
        }

        var next: [Int32: RunningApp] = [:]

        for line in snapshot.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard parts.count == 2, let pid = Int32(parts[0]) else { continue }

            let command = String(parts[1])
            guard managed[pid] == nil else { continue }

            let existing = external[pid]
            let startDate = existing?.startedAt ?? Date()
            let urls = extractURLs(from: command)
            let ports = extractPorts(from: command, urls: urls)

            let app = RunningApp(
                id: "external-\(pid)",
                pid: pid,
                name: "Portless (external)",
                scriptKey: "external",
                folderPath: inferWorkingDirectory(from: command) ?? "unknown",
                command: command,
                source: .external,
                startedAt: startDate,
                ports: ports,
                urls: urls,
                lastLogLine: existing?.lastLogLine
            )
            next[pid] = app
        }

        external = next
    }

    private func cleanupManagedProcess(pid: Int32) {
        managed.removeValue(forKey: pid)
        managedLogBuffers.removeValue(forKey: pid)
        managedLogLines.removeValue(forKey: pid)
        managedURLs.removeValue(forKey: pid)
        managedPorts.removeValue(forKey: pid)
    }

    private func updateRunRecordForTermination(pid: Int32, exitCode: Int32, lastLine: String?) {
        guard var record = runRecordsByPID[pid] else { return }
        record.endedAt = Date()
        record.exitCode = exitCode
        record.lastLogLine = lastLine
        record.state = exitCode == 0 ? .exitedOK : .failed
        runRecordsByPID[pid] = record
        refreshRunHistory()
    }

    private func refreshRunHistory() {
        recentRuns = runRecordsByPID.values
            .sorted { $0.startedAt > $1.startedAt }
        if recentRuns.count > maxRunHistory {
            let keep = Array(recentRuns.prefix(maxRunHistory))
            recentRuns = keep
            let keepIDs = Set(keep.map(\.id))
            runRecordsByPID = runRecordsByPID.filter { keepIDs.contains($0.value.id) }
        }
    }

    private func scheduleRunHistoryRefresh() {
        runHistoryRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.refreshRunHistory()
        }
        runHistoryRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    private func consumeOutput(pid: Int32, data: Data) {
        guard var buffer = managedLogBuffers[pid] else { return }

        buffer += String(decoding: data, as: UTF8.self)
        let lines = buffer.split(separator: "\n", omittingEmptySubsequences: false)

        guard !lines.isEmpty else {
            managedLogBuffers[pid] = buffer
            return
        }

        let hasTrailingNewline = buffer.hasSuffix("\n")
        let completeCount = hasTrailingNewline ? lines.count : max(lines.count - 1, 0)

        for index in 0..<completeCount {
            let line = String(lines[index]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty {
                appendLogLine(pid: pid, line: line)
            }
        }

        if hasTrailingNewline {
            managedLogBuffers[pid] = ""
        } else {
            managedLogBuffers[pid] = String(lines.last ?? "")
        }

        refreshRunningApps()
    }

    private func appendLogLine(pid: Int32, line: String) {
        var logs = managedLogLines[pid] ?? []
        logs.append(line)
        if logs.count > 40 {
            logs.removeFirst(logs.count - 40)
        }
        managedLogLines[pid] = logs
        if var record = runRecordsByPID[pid] {
            record.lastLogLine = line
            runRecordsByPID[pid] = record
            scheduleRunHistoryRefresh()
        }

        let urls = extractURLs(from: line)
        if !urls.isEmpty {
            var knownURLs = managedURLs[pid] ?? []
            urls.forEach { knownURLs.insert($0) }
            managedURLs[pid] = knownURLs

            var knownPorts = managedPorts[pid] ?? []
            let parsedPorts = extractPorts(from: line, urls: urls)
            parsedPorts.forEach { knownPorts.insert($0) }
            managedPorts[pid] = knownPorts
            return
        }

        let ports = extractPorts(from: line, urls: [])
        if !ports.isEmpty {
            var knownPorts = managedPorts[pid] ?? []
            ports.forEach { knownPorts.insert($0) }
            managedPorts[pid] = knownPorts
        }
    }

    private func extractURLs(from text: String) -> [String] {
        let pattern = #"https?://[^\s\"']+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)

        return matches.compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return String(text[range])
        }
    }

    private func extractPorts(from text: String, urls: [String]) -> [Int] {
        var ports = Set<Int>()

        for rawURL in urls {
            if let components = URLComponents(string: rawURL), let port = components.port {
                ports.insert(port)
            }
        }

        let patterns = [
            #"(?:--port|port\s*[:=]?\s*)(\d{2,5})"#,
            #":(\d{2,5})"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            let matches = regex.matches(in: text, options: [], range: range)
            for match in matches {
                guard match.numberOfRanges > 1,
                      let portRange = Range(match.range(at: 1), in: text),
                      let port = Int(text[portRange]),
                      (1...65535).contains(port) else {
                    continue
                }
                ports.insert(port)
            }
        }

        return Array(ports).sorted()
    }

    private func inferWorkingDirectory(from command: String) -> String? {
        let components = command.split(separator: " ")
        for component in components {
            let value = String(component)
            if value.hasPrefix("/") && value.contains("/") {
                return URL(fileURLWithPath: value).deletingLastPathComponent().path
            }
        }
        return nil
    }

    private func detectPackageManager(at folderPath: String) -> String {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: folderPath)

        if fm.fileExists(atPath: root.appendingPathComponent("pnpm-lock.yaml").path) {
            return "pnpm"
        }
        if fm.fileExists(atPath: root.appendingPathComponent("yarn.lock").path) {
            return "yarn"
        }
        return "npm"
    }

    private func hasKnownPortlessPackage(in packageJSON: PackageJSON) -> Bool {
        let dictionaries = [
            packageJSON.dependencies ?? [:],
            packageJSON.devDependencies ?? [:],
            packageJSON.optionalDependencies ?? [:]
        ]

        for dictionary in dictionaries {
            for package in knownPortlessPackages where dictionary[package] != nil {
                return true
            }
        }
        return false
    }

    private func isSelfBootstrappingPortlessCommand(_ command: String) -> Bool {
        let lower = command.lowercased()
        return lower.contains("npx portless") ||
            lower.contains("pnpm dlx portless") ||
            lower.contains("yarn dlx portless")
    }

    private func commandExists(_ command: String) -> Bool {
        if let cached = commandExistsCache[command], Date().timeIntervalSince(cached.at) < toolCacheTTL {
            return cached.exists
        }

        for path in candidateBinPaths() {
            let candidate = URL(fileURLWithPath: path).appendingPathComponent(command).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                commandExistsCache[command] = (true, Date())
                return true
            }
        }

        let output = captureOutput(executable: "/usr/bin/which", arguments: [command])
        let exists = !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        commandExistsCache[command] = (exists, Date())
        return exists
    }

    private func globalInstallCommand() -> String {
        if commandExists("pnpm") {
            return "pnpm add -g portless"
        }
        if commandExists("yarn") {
            return "yarn global add portless"
        }
        return "npm install -g portless"
    }

    private func buildProxyStartPlan() -> (arguments: [String], warning: String?) {
        var args = ["portless", "proxy", "start"]
        var warning: String?

        let trimmedPort = proxyPort.trimmingCharacters(in: .whitespacesAndNewlines)
        if let port = Int(trimmedPort), (1...65535).contains(port) {
            args.append(contentsOf: ["--port", String(port)])
            if port < 1024 {
                warning = "Using port \(port) may require elevated privileges."
            }
        }

        if proxyUseHTTPS {
            args.append("--https")
        }

        if proxyNoTLS {
            args.append("--no-tls")
        }

        let cert = proxyCertPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = proxyKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cert.isEmpty && !key.isEmpty {
            args.append(contentsOf: ["--cert", cert, "--key", key])
        }

        return (args, warning)
    }

    private func runAsyncShell(_ command: String, completion: @escaping (Int32, String) -> Void) {
        let environment = toolExecutionEnvironment()
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", command]
            process.environment = environment

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(decoding: data, as: UTF8.self)
                DispatchQueue.main.async {
                    completion(process.terminationStatus, output)
                }
            } catch {
                DispatchQueue.main.async {
                    completion(1, error.localizedDescription)
                }
            }
        }
    }

    private func runAsyncCommand(_ arguments: [String], completion: @escaping (Int32, String) -> Void) {
        let environment = toolExecutionEnvironment()
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = arguments
            process.environment = environment

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(decoding: data, as: UTF8.self)
                DispatchQueue.main.async {
                    completion(process.terminationStatus, output)
                }
            } catch {
                DispatchQueue.main.async {
                    completion(1, error.localizedDescription)
                }
            }
        }
    }

    private func runAsyncAdminShell(_ command: String, completion: @escaping (Int32, String) -> Void) {
        let environment = toolExecutionEnvironment()
        let pathValue = environment["PATH"] ?? ""
        let shellCommand = "export PATH=\(shellQuote(pathValue)); \(command)"
        let script = "do shell script \(appleScriptString(shellCommand)) with administrator privileges"

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(decoding: data, as: UTF8.self)
                DispatchQueue.main.async {
                    completion(process.terminationStatus, output)
                }
            } catch {
                DispatchQueue.main.async {
                    completion(1, error.localizedDescription)
                }
            }
        }
    }

    private func captureOutput(executable: String, arguments: [String], useToolEnvironment: Bool = true) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if useToolEnvironment {
            process.environment = toolExecutionEnvironment()
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        var data = Data()
        let readComplete = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .utility).async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            readComplete.signal()
        }

        do {
            try process.run()

            let waitResult = readComplete.wait(timeout: .now() + 2.0)
            if waitResult == .timedOut {
                process.terminate()
                return ""
            }

            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        } catch {
            return ""
        }
    }

    nonisolated private static func captureOutputStatic(executable: String, arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        var data = Data()
        let readComplete = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .utility).async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            readComplete.signal()
        }

        do {
            try process.run()
            let waitResult = readComplete.wait(timeout: .now() + 2.0)
            if waitResult == .timedOut {
                process.terminate()
                return ""
            }
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        } catch {
            return ""
        }
    }

    private func toolExecutionEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let existingPath = environment["PATH"] ?? ""
        let mergedPath = (candidateBinPaths() + [existingPath])
            .joined(separator: ":")
        environment["PATH"] = mergedPath
        return environment
    }

    private func normalizeAppName(_ raw: String) -> String {
        let value = raw.lowercased()
        let pattern = #"[^a-z0-9\.-]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return value.replacingOccurrences(of: " ", with: "-")
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let replaced = regex.stringByReplacingMatches(in: value, options: [], range: range, withTemplate: "-")
        return replaced.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
    }

    private func packageScriptArgs(packageManager: String, scriptKey: String) -> [String] {
        let key = scriptKey.trimmingCharacters(in: .whitespacesAndNewlines)
        switch packageManager {
        case "npm":
            return ["npm", "run", key]
        case "pnpm":
            return ["pnpm", key]
        case "yarn":
            return ["yarn", key]
        default:
            return [packageManager, key]
        }
    }

    private func resolveScriptRunner(packageManager: String, scriptKey: String) -> ScriptRunnerPlan {
        let key = scriptKey.trimmingCharacters(in: .whitespacesAndNewlines)

        if packageManager == "pnpm" {
            if commandExists("pnpm") {
                return ScriptRunnerPlan(args: ["pnpm", key], warning: nil)
            }
            if commandExists("corepack") {
                return ScriptRunnerPlan(
                    args: ["corepack", "pnpm", key],
                    warning: "pnpm binary not in PATH, using corepack pnpm."
                )
            }
            if commandExists("yarn") {
                return ScriptRunnerPlan(
                    args: ["yarn", key],
                    warning: "pnpm not found in PATH, using yarn."
                )
            }
            return ScriptRunnerPlan(
                args: ["npm", "run", key],
                warning: "pnpm not found in PATH, using npm run."
            )
        }

        if packageManager == "yarn" {
            if commandExists("yarn") {
                return ScriptRunnerPlan(args: ["yarn", key], warning: nil)
            }
            return ScriptRunnerPlan(
                args: ["npm", "run", key],
                warning: "yarn not found in PATH, using npm run."
            )
        }

        if commandExists("npm") {
            return ScriptRunnerPlan(args: ["npm", "run", key], warning: nil)
        }

        return ScriptRunnerPlan(
            args: ["node", "--run", key],
            warning: "npm not found in PATH, attempting node --run."
        )
    }

    private func suggestedAppName(from folderPath: String) -> String {
        let base = URL(fileURLWithPath: folderPath).lastPathComponent
        let normalized = normalizeAppName(base)
        return normalized.isEmpty ? "myapp" : normalized
    }

    private func lastNonEmptyLine(from output: String) -> String? {
        output
            .split(separator: "\n")
            .map(String.init)
            .last(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    private func candidateBinPaths() -> [String] {
        if let cached = cachedBinPaths,
           let at = cachedBinPathsAt,
           Date().timeIntervalSince(at) < toolCacheTTL {
            return cached
        }

        var paths = preferredBinPaths
        let home = NSHomeDirectory()

        let userPaths = [
            "\(home)/.volta/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.yarn/bin",
            "\(home)/.pnpm",
            "\(home)/Library/pnpm",
            "\(home)/.local/bin"
        ]
        paths.append(contentsOf: userPaths)

        let dynamicBinCommands: [(String, [String])] = [
            ("/usr/bin/npm", ["bin", "-g"]),
            ("/opt/homebrew/bin/pnpm", ["bin", "-g"]),
            ("/usr/local/bin/pnpm", ["bin", "-g"]),
            ("/opt/homebrew/bin/yarn", ["global", "bin"]),
            ("/usr/local/bin/yarn", ["global", "bin"])
        ]

        for (executable, args) in dynamicBinCommands {
            let output = captureOutput(executable: executable, arguments: args, useToolEnvironment: false)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !output.isEmpty {
                paths.append(output)
            }
        }

        var unique: [String] = []
        for path in paths where !path.isEmpty {
            if !unique.contains(path) {
                unique.append(path)
            }
        }
        cachedBinPaths = unique
        cachedBinPathsAt = Date()
        return unique
    }

    private func invalidateToolCaches() {
        cachedBinPaths = nil
        cachedBinPathsAt = nil
        commandExistsCache = [:]
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func parseProxyRoutes(from lines: [String]) -> [ProxyRoute] {
        var parsed: [ProxyRoute] = []

        for (index, line) in lines.enumerated() {
            let lower = line.lowercased()
            if lower == "routes" || lower.hasPrefix("name ") || lower.hasPrefix("app ") {
                continue
            }

            let urls = extractURLs(from: line)
            let primaryURL = urls.first
            let components = primaryURL.flatMap(URLComponents.init(string:))
            let ports = extractPorts(from: line, urls: urls)

            let name: String
            if let arrowRange = line.range(of: "->") {
                name = String(line[..<arrowRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            } else {
                name = line.split(separator: " ").first.map(String.init) ?? "route-\(index + 1)"
            }

            let route = ProxyRoute(
                id: "route-\(index)-\(line.hashValue)",
                rawLine: line,
                name: name.isEmpty ? "route-\(index + 1)" : name,
                url: primaryURL,
                scheme: components?.scheme,
                host: components?.host,
                port: components?.port ?? ports.first
            )
            parsed.append(route)
        }

        return parsed
    }

    private func loadRecentFolders() {
        let saved = UserDefaults.standard.array(forKey: recentFoldersKey) as? [String] ?? []
        recentFolders = saved.filter { FileManager.default.fileExists(atPath: $0) }
    }

    private func loadRecentLaunches() {
        guard let data = UserDefaults.standard.data(forKey: recentLaunchesKey) else {
            recentLaunches = []
            return
        }
        if let decoded = try? JSONDecoder().decode([RecentLaunch].self, from: data) {
            recentLaunches = decoded.filter { FileManager.default.fileExists(atPath: $0.folderPath) }
        } else {
            recentLaunches = []
        }
    }

    private func loadProxySettings() {
        let defaults = UserDefaults.standard
        proxyPort = defaults.string(forKey: proxyPortKey) ?? ""
        proxyUseHTTPS = defaults.bool(forKey: proxyUseHTTPSKey)
        proxyNoTLS = defaults.bool(forKey: proxyNoTLSKey)
        proxyCertPath = defaults.string(forKey: proxyCertPathKey) ?? ""
        proxyKeyPath = defaults.string(forKey: proxyKeyPathKey) ?? ""
    }

    func saveProxySettings() {
        let defaults = UserDefaults.standard
        defaults.set(proxyPort.trimmingCharacters(in: .whitespacesAndNewlines), forKey: proxyPortKey)
        defaults.set(proxyUseHTTPS, forKey: proxyUseHTTPSKey)
        defaults.set(proxyNoTLS, forKey: proxyNoTLSKey)
        defaults.set(proxyCertPath.trimmingCharacters(in: .whitespacesAndNewlines), forKey: proxyCertPathKey)
        defaults.set(proxyKeyPath.trimmingCharacters(in: .whitespacesAndNewlines), forKey: proxyKeyPathKey)
    }

    private func addRecentFolder(_ path: String) {
        let normalized = URL(fileURLWithPath: path).path
        recentFolders.removeAll { $0 == normalized }
        recentFolders.insert(normalized, at: 0)

        if recentFolders.count > maxRecentFolders {
            recentFolders = Array(recentFolders.prefix(maxRecentFolders))
        }

        UserDefaults.standard.set(recentFolders, forKey: recentFoldersKey)
    }

    private func addRecentLaunch(name: String, scriptKey: String, folderPath: String, commandParts: [String]) {
        let normalizedFolder = URL(fileURLWithPath: folderPath).path
        let signature = "\(normalizedFolder)|\(commandParts.joined(separator: " "))"
        recentLaunches.removeAll {
            "\($0.folderPath)|\($0.commandParts.joined(separator: " "))" == signature
        }
        recentLaunches.insert(
            RecentLaunch(
                id: UUID().uuidString,
                name: name,
                scriptKey: scriptKey,
                folderPath: normalizedFolder,
                commandParts: commandParts,
                createdAt: Date()
            ),
            at: 0
        )
        if recentLaunches.count > maxRecentLaunches {
            recentLaunches = Array(recentLaunches.prefix(maxRecentLaunches))
        }
        saveRecentLaunches()
    }

    private func saveRecentLaunches() {
        if let data = try? JSONEncoder().encode(recentLaunches) {
            UserDefaults.standard.set(data, forKey: recentLaunchesKey)
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: PortlessMenuModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                sectionCard("Project") {
                    HStack {
                        Button("Open Folder") { model.chooseFolder() }
                        Button("Refresh") { model.refreshPortlessProcessesNow() }
                    }
                    Text(model.selectedFolderPath ?? "No folder selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    if !model.recentFolders.isEmpty {
                        Text("Recent")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ScrollView(.horizontal) {
                            HStack(spacing: 6) {
                                ForEach(model.recentFolders, id: \.self) { path in
                                    Button(model.recentFolderLabel(for: path)) {
                                        model.loadFolder(URL(fileURLWithPath: path))
                                    }
                                    .help(path)
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                }

                sectionCard("Scripts") {
                    HStack(spacing: 6) {
                        statusTag("CLI", ok: model.isPortlessInstalledGlobally)
                        statusTag("Local dep", ok: model.hasLocalPortlessDependency)
                        Spacer()
                        Button(model.isInstallingPortless ? "Installing..." : "Install Portless") {
                            model.installPortless()
                        }
                        .disabled(model.isInstallingPortless)
                        .buttonStyle(.bordered)
                    }

                    if model.scripts.isEmpty {
                        Text("No scripts loaded")
                            .foregroundStyle(.secondary)
                    } else {
                        TextField("Filter scripts", text: $model.scriptFilter)
                            .onChange(of: model.scriptFilter) { _ in
                                model.ensureSelectedScriptIsVisible()
                            }

                        if model.filteredScripts.isEmpty {
                            Text("No scripts match filter")
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("Script", selection: $model.selectedScriptKey) {
                                ForEach(model.filteredScripts) { script in
                                    Text(script.isLikelyPortless ? "\(script.key) (Portless)" : script.key)
                                        .tag(script.key)
                                }
                            }
                        }

                        TextField("Portless app name", text: $model.runName)
                        Toggle("Use Portless wrapper", isOn: $model.usePortlessWrapper)
                        Button(model.usePortlessWrapper ? "Run With Portless" : "Run Script Directly") {
                            model.runSelectedScript()
                        }
                        .disabled(model.selectedScriptKey.isEmpty || (model.selectedScriptNeedsPortlessTool && !model.canRunSelectedPortlessScript))
                    }
                }

                sectionCard("Proxy") {
                    TextField("Proxy port (optional, e.g. 4433)", text: $model.proxyPort)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: model.proxyPort) { _ in
                            model.saveProxySettings()
                        }
                    Toggle("Enable HTTPS (--https)", isOn: $model.proxyUseHTTPS)
                        .onChange(of: model.proxyUseHTTPS) { _ in
                            model.saveProxySettings()
                        }
                    Toggle("Disable TLS to backend (--no-tls)", isOn: $model.proxyNoTLS)
                        .onChange(of: model.proxyNoTLS) { _ in
                            model.saveProxySettings()
                        }
                    TextField("TLS cert path (--cert)", text: $model.proxyCertPath)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: model.proxyCertPath) { _ in
                            model.saveProxySettings()
                        }
                    TextField("TLS key path (--key)", text: $model.proxyKeyPath)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: model.proxyKeyPath) { _ in
                            model.saveProxySettings()
                        }
                    if let validation = model.proxyStartValidationMessage {
                        Text(validation)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                    HStack {
                        Button("Start") { model.startProxy() }
                            .buttonStyle(.bordered)
                            .disabled(model.proxyStartValidationMessage != nil)
                        Button("Stop") { model.stopProxy() }.buttonStyle(.bordered)
                        Button("Restart") { model.restartProxy() }
                            .buttonStyle(.bordered)
                            .disabled(model.proxyStartValidationMessage != nil)
                        Button("Trust CA") { model.trustProxyCertificate() }.buttonStyle(.bordered)
                        Button("List Routes") { model.refreshRoutes() }.buttonStyle(.bordered)
                    }
                    if model.proxyRoutes.isEmpty {
                        Text("No active routes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(model.proxyRoutes) { route in
                                HStack(spacing: 6) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(route.name)
                                            .font(.caption)
                                        Text(route.endpoint)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                    Spacer()
                                    if let url = route.url {
                                        Button("Open") { model.openInBrowser(url) }
                                            .buttonStyle(.bordered)
                                    }
                                }
                            }
                        }
                    }
                }

                sectionCard("Running Apps", badge: "\(model.runningApps.count)") {
                    if model.runningApps.isEmpty {
                        Text(model.proxyRoutes.isEmpty ? "No running apps." : "Routes active, but no tracked wrapper process.")
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(model.runningApps) { app in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("\(app.name) - \(app.scriptKey)")
                                            .font(.subheadline)
                                        Spacer()
                                        Button {
                                            model.stop(app.pid)
                                        } label: {
                                            Label("Stop", systemImage: "stop.circle.fill")
                                        }
                                        .labelStyle(.titleAndIcon)
                                        .buttonStyle(.bordered)
                                    }
                                    if !app.urls.isEmpty {
                                        VStack(alignment: .leading, spacing: 4) {
                                            ForEach(app.urls, id: \.self) { appURL in
                                                HStack(spacing: 6) {
                                                    Text(appURL)
                                                        .font(.caption2)
                                                        .foregroundStyle(.secondary)
                                                        .lineLimit(1)
                                                    Spacer()
                                                    Button("Open") { model.openInBrowser(appURL) }
                                                        .buttonStyle(.bordered)
                                                }
                                            }
                                        }
                                    } else if let logLine = app.lastLogLine {
                                        Text(logLine)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    } else {
                                        Text("pid \(app.pid)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(8)
                                .background(Color.gray.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }

                sectionCard("Recent Runs", badge: "\(model.recentRuns.count)") {
                    if model.recentRuns.isEmpty {
                        Text("No recent runs")
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(model.recentRuns.prefix(6)) { run in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(run.name)
                                            .font(.subheadline)
                                        Text(run.lastLogLine ?? run.command)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Text(run.state == .running ? "running" : (run.state == .exitedOK ? "ok" : "failed"))
                                        .font(.caption2)
                                        .foregroundStyle(run.state == .failed ? .red : .secondary)
                                }
                            }
                        }
                    }
                }

                Text(model.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            .padding(12)
        }
        .frame(width: 500, height: 760)
    }

    @ViewBuilder
    private func sectionCard<Content: View>(_ title: String, badge: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                if let badge {
                    Text(badge)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            content()
        }
        .padding(10)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func statusTag(_ title: String, ok: Bool) -> some View {
        Text(ok ? "\(title): ready" : "\(title): missing")
            .font(.caption2)
            .foregroundStyle(ok ? Color.green : Color.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background((ok ? Color.green : Color.gray).opacity(0.14))
            .clipShape(Capsule())
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = SharedModel.instance
    private var statusItem: NSStatusItem?
    private var mainWindow: NSWindow?
    private var statusMenu: NSMenu?
    private let debugLoggingEnabled = ProcessInfo.processInfo.environment["PORTLESS_MENU_DEBUG"] == "1"

    private func log(_ message: String) {
        guard debugLoggingEnabled else { return }
        let url = URL(fileURLWithPath: "/tmp/portlessmenu.log")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        let data = Data(line.utf8)

        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: url)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("applicationDidFinishLaunching")
        NSApp.setActivationPolicy(.regular)
        log("activationPolicy=.regular")
        setupStatusItem()
        log("status item setup complete")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.openMainWindow()
        }
        NSApp.activate(ignoringOtherApps: true)
        log("app activated")
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.length = 96
        if let button = item.button {
            button.title = "Portless"
            button.image = NSImage(
                systemSymbolName: "bolt.horizontal.circle.fill",
                accessibilityDescription: "Portless"
            )
            button.imagePosition = .imageLeading
        }

        let menu = NSMenu()
        menu.delegate = self
        statusMenu = menu
        rebuildStatusMenu()
        item.menu = menu
        statusItem = item
    }

    private func rebuildStatusMenu() {
        guard let menu = statusMenu else { return }
        menu.removeAllItems()

        let openItem = NSMenuItem(
            title: "Open Portless Control",
            action: #selector(openMainWindow),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)

        let refreshItem = NSMenuItem(
            title: "Refresh Portless Processes",
            action: #selector(refreshProcesses),
            keyEquivalent: ""
        )
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())

        let runningHeader = NSMenuItem(title: "Running Apps", action: nil, keyEquivalent: "")
        runningHeader.isEnabled = false
        menu.addItem(runningHeader)

        if model.runningApps.isEmpty {
            let noneItem = NSMenuItem(title: "No running apps", action: nil, keyEquivalent: "")
            noneItem.isEnabled = false
            menu.addItem(noneItem)
        } else {
            for app in model.runningApps.prefix(10) {
                let stopItem = NSMenuItem(
                    title: "\(app.name) - \(app.scriptKey)",
                    action: #selector(stopFromMenu(_:)),
                    keyEquivalent: ""
                )
                stopItem.target = self
                stopItem.representedObject = NSNumber(value: app.pid)
                stopItem.image = NSImage(
                    systemSymbolName: "stop.circle.fill",
                    accessibilityDescription: "Stop"
                )
                stopItem.toolTip = "Stop pid \(app.pid)"
                menu.addItem(stopItem)
            }
        }

        menu.addItem(.separator())

        let recentHeader = NSMenuItem(title: "Recent Starts", action: nil, keyEquivalent: "")
        recentHeader.isEnabled = false
        menu.addItem(recentHeader)

        if model.recentLaunches.isEmpty {
            let noneRecent = NSMenuItem(title: "No recent starts", action: nil, keyEquivalent: "")
            noneRecent.isEnabled = false
            menu.addItem(noneRecent)
        } else {
            for launch in model.recentLaunches.prefix(8) {
                let item = NSMenuItem(
                    title: "\(launch.name) - \(launch.scriptKey)",
                    action: #selector(startRecentFromMenu(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = launch.id
                item.image = NSImage(
                    systemSymbolName: "play.circle.fill",
                    accessibilityDescription: "Start"
                )
                item.toolTip = launch.commandParts.joined(separator: " ")
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildStatusMenu()
        model.refreshPortlessProcessesNow { [weak self] in
            self?.rebuildStatusMenu()
        }
    }

    @objc private func openMainWindow() {
        log("openMainWindow invoked")

        if mainWindow == nil {
            let rootView = ContentView(model: model)
            let controller = NSHostingController(rootView: rootView)
            let window = NSWindow(contentViewController: controller)
            window.title = "Portless Control"
            window.setContentSize(NSSize(width: 560, height: 760))
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.center()
            mainWindow = window
            log("main window created")
        }

        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        log("main window shown")
    }

    @objc private func refreshProcesses() {
        rebuildStatusMenu()
        model.refreshPortlessProcessesNow { [weak self] in
            self?.rebuildStatusMenu()
        }
    }

    @objc private func stopFromMenu(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? NSNumber else { return }
        model.stop(value.int32Value)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.rebuildStatusMenu()
        }
    }

    @objc private func startRecentFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        model.runRecentLaunch(id: id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.rebuildStatusMenu()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

@MainActor
enum SharedModel {
    static let instance = PortlessMenuModel()
}

@main
struct PortlessMenuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
