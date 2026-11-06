import AppKit
import Foundation
import SwiftUI

struct WLEDPreset: Identifiable, Hashable {
    let id: Int
    let name: String
    let colors: [WLEDPresetColor]
}

struct WLEDPresetColor: Hashable {
    let red: Int
    let green: Int
    let blue: Int

    var color: Color {
        Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255,
              blue: Double(blue) / 255, opacity: 1)
    }
}

struct CodexFixtureIntegration: Codable, Equatable {
    var isEnabled = false
    var showCompletion = true
    var showAttention = true
    var completionSeconds = 3.0
    var completionPreset = 3
    var attentionPreset = 4
}

struct WLEDLight: Identifiable, Equatable {
    var id: String
    var name: String
    var host: String
    var port: Int
    var mac: String
    var firmware: String
    var isOn: Bool
    var brightness: Int
    var red: Int
    var green: Int
    var blue: Int
    var presets: [WLEDPreset]
    var failedChecks: Int = 0

    var baseURL: URL { URL(string: "http://\(host):\(port)/")! }
    var color: Color {
        Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255,
              blue: Double(blue) / 255, opacity: 1)
    }
}

final class WLEDDiscovery: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    @Published private(set) var lights: [WLEDLight] = []
    @Published private(set) var attentionCount = 0
    @Published var selectedID: String?
    @Published var activeFixtureID: String?
    @Published private(set) var codexIntegrations: [String: CodexFixtureIntegration] = [:]

    private let browser = NetServiceBrowser()
    private var services: [String: NetService] = [:]
    private var refreshTimer: Timer?
    private var attentionTimer: Timer?
    private var integrationTimer: Timer?
    private let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/WLED Display Sync")
    private var refreshInProgress = Set<String>()
    private var integrationInProgress = Set<String>()
    private var integrationRenderKeys: [String: String] = [:]
    private var didMigrateLegacyIntegration = false
    private lazy var integrationsURL = support.appendingPathComponent("fixture-integrations.json")

    override init() {
        super.init()
        loadIntegrations()
        browser.delegate = self
        browser.searchForServices(ofType: "_wled._tcp.", inDomain: "local.")
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshAll()
        }
        attentionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.readAttentionCount()
        }
        integrationTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.renderIntegrations()
        }
        readAttentionCount()
    }

    deinit {
        browser.stop()
        refreshTimer?.invalidate()
        attentionTimer?.invalidate()
        integrationTimer?.invalidate()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        let key = serviceKey(service)
        services[key] = service
        service.delegate = self
        service.resolve(withTimeout: 4)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        remove(serviceKey(service))
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.hostName?.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              !host.isEmpty else { return }
        let key = serviceKey(sender)
        Task { await inspect(host: host, port: sender.port > 0 ? sender.port : 80, key: key) }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        // Keep the Bonjour result so the periodic refresh can retry if resolution was transient.
        _ = errorDict
    }

    func refreshAll() {
        let current = Set(lights.map(\.id))
        for light in lights {
            guard !refreshInProgress.contains(light.id) else { continue }
            refreshInProgress.insert(light.id)
            Task { await refresh(light) }
        }
        // Keep Bonjour entries eligible for rediscovery after a brief outage.
        for (key, service) in services where !current.contains(key) {
            if let host = service.hostName?.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
               !host.isEmpty {
                Task { await inspect(host: host, port: service.port > 0 ? service.port : 80, key: key) }
            } else {
                service.delegate = self
                service.resolve(withTimeout: 4)
            }
        }
    }

    func setPower(_ light: WLEDLight, on: Bool) {
        update(light, payload: ["on": on, "tt": 0])
    }

    func setBrightness(_ light: WLEDLight, value: Int) {
        update(light, payload: ["bri": max(1, min(255, value)), "tt": 0])
    }

    func setColor(_ light: WLEDLight, red: Int, green: Int, blue: Int) {
        update(light, payload: [
            "on": true,
            "tt": 0,
            "seg": [["id": 0, "col": [[red, green, blue]]]]
        ])
    }

    func applyPreset(_ preset: WLEDPreset, to light: WLEDLight) {
        update(light, payload: ["ps": preset.id, "tt": 0])
    }

    func savePreset(_ light: WLEDLight, name: String, slot: Int) {
        let cleanName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
        guard !cleanName.isEmpty, (1...250).contains(slot) else { return }

        Task {
            guard let url = URL(string: "json/state", relativeTo: light.baseURL),
                  let body = try? JSONSerialization.data(withJSONObject: [
                    "psave": slot,
                    "n": cleanName,
                    "ib": true,
                    "sb": true
                  ]) else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 3
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            guard (try? await URLSession.shared.data(for: request)) != nil else { return }

            // WLED persists presets asynchronously, so give it a moment before reloading the list.
            try? await Task.sleep(nanoseconds: 500_000_000)
            await inspect(host: light.host, port: light.port, key: light.id)
        }
    }

    func acknowledgeAttention() {
        CodexEventBridge.acknowledgeAttention()
        readAttentionCount()
    }

    func fixtureKey(_ light: WLEDLight) -> String {
        light.mac.isEmpty ? light.id : light.mac
    }

    func codexIntegration(for light: WLEDLight) -> CodexFixtureIntegration {
        codexIntegrations[fixtureKey(light)] ?? CodexFixtureIntegration()
    }

    func setCodexIntegration(_ integration: CodexFixtureIntegration, for light: WLEDLight) {
        codexIntegrations[fixtureKey(light)] = integration
        saveIntegrations()
        integrationRenderKeys.removeValue(forKey: light.id)
        if integration.isEnabled {
            renderIntegrations()
        } else {
            restoreIntegrationState(for: light)
        }
    }

    func removeCodexIntegration(for light: WLEDLight) {
        codexIntegrations.removeValue(forKey: fixtureKey(light))
        saveIntegrations()
        integrationRenderKeys.removeValue(forKey: light.id)
        restoreIntegrationState(for: light)
    }

    private func serviceKey(_ service: NetService) -> String {
        "\(service.domain)|\(service.type)|\(service.name)"
    }

    private func remove(_ key: String) {
        services[key]?.delegate = nil
        services.removeValue(forKey: key)
        DispatchQueue.main.async { self.lights.removeAll { $0.id == key } }
    }

    private func inspect(host: String, port: Int, key: String) async {
        guard let info = await getJSON(host: host, port: port, path: "json/info") else { return }
        let state = await getJSON(host: host, port: port, path: "json/state") ?? [:]
        let presetsJSON = await getJSON(host: host, port: port, path: "presets.json") ?? [:]
        let segment = ((state["seg"] as? [[String: Any]]) ?? []).first ?? [:]
        let colors = segment["col"] as? [[Int]] ?? []
        let color = colors.first ?? [255, 255, 255]
        let presets = presetsJSON.compactMap { id, value -> WLEDPreset? in
            guard let number = Int(id), number > 0, let details = value as? [String: Any] else { return nil }
            let name = (details["n"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return WLEDPreset(id: number,
                              name: (name?.isEmpty == false ? name! : "Preset \(number)"),
                              colors: presetColors(from: details))
        }.sorted { $0.id < $1.id }

        let light = WLEDLight(
            id: key,
            name: (info["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? host,
            host: host,
            port: port,
            mac: (info["mac"] as? String ?? "").uppercased(),
            firmware: info["ver"] as? String ?? "",
            isOn: state["on"] as? Bool ?? false,
            brightness: state["bri"] as? Int ?? 128,
            red: color.count > 0 ? color[0] : 255,
            green: color.count > 1 ? color[1] : 255,
            blue: color.count > 2 ? color[2] : 255,
            presets: presets
        )
        DispatchQueue.main.async {
            if let index = self.lights.firstIndex(where: { $0.id == key }) {
                self.lights[index] = light
            } else {
                self.lights.append(light)
                self.lights.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
            self.migrateLegacyIntegrationIfNeeded(to: light)
        }
    }

    private func refresh(_ light: WLEDLight) async {
        let lightID = light.id
        defer { DispatchQueue.main.async { self.refreshInProgress.remove(lightID) } }
        guard let state = await getJSON(host: light.host, port: light.port, path: "json/state") else {
            DispatchQueue.main.async {
                guard let index = self.lights.firstIndex(where: { $0.id == lightID }) else { return }
                self.lights[index].failedChecks += 1
                if self.lights[index].failedChecks >= 2 { self.lights.remove(at: index) }
            }
            return
        }
        DispatchQueue.main.async {
            guard let index = self.lights.firstIndex(where: { $0.id == lightID }) else { return }
            self.lights[index].failedChecks = 0
            self.lights[index].isOn = state["on"] as? Bool ?? self.lights[index].isOn
            self.lights[index].brightness = state["bri"] as? Int ?? self.lights[index].brightness
            if let segment = (state["seg"] as? [[String: Any]])?.first,
               let color = (segment["col"] as? [[Int]])?.first {
                if color.count > 0 { self.lights[index].red = color[0] }
                if color.count > 1 { self.lights[index].green = color[1] }
                if color.count > 2 { self.lights[index].blue = color[2] }
            }
        }
    }

    private func presetColors(from details: [String: Any]) -> [WLEDPresetColor] {
        let segments: [[String: Any]]
        if let list = details["seg"] as? [[String: Any]] {
            segments = list
        } else if let single = details["seg"] as? [String: Any] {
            segments = [single]
        } else {
            segments = []
        }

        var result: [WLEDPresetColor] = []
        var seen = Set<WLEDPresetColor>()
        for segment in segments {
            let storedColors = segment["col"] as? [[Int]] ?? []
            let effectID = segment["fx"] as? Int ?? 0
            let visibleColors: [[Int]]
            if effectID == 0 {
                // WLED's solid effect uses only the first color even though saved
                // presets often retain stale secondary and tertiary values.
                visibleColors = Array(storedColors.prefix(1))
            } else {
                let nonBlack = storedColors.filter {
                    $0.count >= 3 && ($0[0] != 0 || $0[1] != 0 || $0[2] != 0)
                }
                visibleColors = nonBlack.isEmpty ? Array(storedColors.prefix(1)) : nonBlack
            }

            for components in visibleColors where components.count >= 3 {
                let color = WLEDPresetColor(red: components[0], green: components[1], blue: components[2])
                if seen.insert(color).inserted { result.append(color) }
                if result.count == 6 { return result }
            }
        }
        return result
    }

    private func update(_ light: WLEDLight, payload: [String: Any]) {
        Task {
            guard let url = URL(string: "json/state", relativeTo: light.baseURL),
                  let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 3
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            _ = try? await URLSession.shared.data(for: request)
            await refresh(light)
        }
    }

    private func loadIntegrations() {
        guard let data = try? Data(contentsOf: integrationsURL),
              let values = try? JSONDecoder().decode([String: CodexFixtureIntegration].self, from: data) else { return }
        codexIntegrations = values
    }

    private func saveIntegrations() {
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(codexIntegrations) else { return }
        try? data.write(to: integrationsURL, options: .atomic)
    }

    private func migrateLegacyIntegrationIfNeeded(to light: WLEDLight) {
        guard !didMigrateLegacyIntegration else { return }
        didMigrateLegacyIntegration = true
        guard codexIntegrations.isEmpty else { return }
        let legacyURL = support.appendingPathComponent("codex-settings.json")
        let values = (try? Data(contentsOf: legacyURL)).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        } ?? [:]
        var integration = CodexFixtureIntegration()
        integration.isEnabled = true
        integration.showCompletion = values["showCompletion"] as? Bool ?? true
        integration.showAttention = values["showAttention"] as? Bool ?? true
        integration.completionSeconds = values["completionSeconds"] as? Double ?? 3
        codexIntegrations[fixtureKey(light)] = integration
        saveIntegrations()
    }

    private func renderIntegrations() {
        let snapshot = CodexEventBridge.snapshot()
        attentionCount = snapshot.attentionCount
        let enabled = lights.compactMap { light -> (WLEDLight, CodexFixtureIntegration)? in
            let integration = codexIntegration(for: light)
            return integration.isEnabled ? (light, integration) : nil
        }
        let longestCompletion = enabled.map { $0.1.completionSeconds }.max() ?? 3
        let now = Date().timeIntervalSince1970
        let retention = max(1, longestCompletion) + 1
        if snapshot.done.values.contains(where: { now - $0 >= retention }) {
            CodexEventBridge.purgeCompletions(olderThan: retention)
        }

        for (light, integration) in enabled {
            let desiredKey: String
            let preset: Int?
            if snapshot.hasAttention && integration.showAttention {
                desiredKey = "attention:\(integration.attentionPreset)"
                preset = integration.attentionPreset
            } else if integration.showCompletion,
                      let latest = snapshot.latestCompletion,
                      now - latest < integration.completionSeconds {
                desiredKey = "done:\(latest):\(integration.completionPreset)"
                preset = integration.completionPreset
            } else {
                desiredKey = "idle"
                preset = nil
            }

            guard integrationRenderKeys[light.id] != desiredKey,
                  !integrationInProgress.contains(light.id) else { continue }
            integrationInProgress.insert(light.id)
            Task { await transitionIntegration(light: light, desiredKey: desiredKey, preset: preset) }
        }
    }

    private func restoreIntegrationState(for light: WLEDLight) {
        guard !integrationInProgress.contains(light.id) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.restoreIntegrationState(for: light)
            }
            return
        }
        integrationInProgress.insert(light.id)
        Task { await transitionIntegration(light: light, desiredKey: "idle", preset: nil) }
    }

    private func transitionIntegration(light: WLEDLight, desiredKey: String, preset: Int?) async {
        let originalURL = integrationOriginalURL(for: light)
        var succeeded = false
        if let preset {
            if !FileManager.default.fileExists(atPath: originalURL.path) {
                guard let current = await getJSON(host: light.host, port: light.port, path: "json/state"),
                      current["on"] as? Bool ?? false,
                      let data = try? JSONSerialization.data(withJSONObject: current) else {
                    DispatchQueue.main.async { self.integrationInProgress.remove(light.id) }
                    return
                }
                try? data.write(to: originalURL, options: .atomic)
            }
            succeeded = await postJSON(["ps": preset, "tt": 0], to: light)
        } else if let data = try? Data(contentsOf: originalURL),
                  let original = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            succeeded = await postJSON(original.merging(["tt": 0]) { _, new in new }, to: light)
            if succeeded { try? FileManager.default.removeItem(at: originalURL) }
        } else {
            succeeded = true
        }

        DispatchQueue.main.async {
            if succeeded { self.integrationRenderKeys[light.id] = desiredKey }
            self.integrationInProgress.remove(light.id)
            if succeeded { Task { await self.refresh(light) } }
        }
    }

    private func postJSON(_ payload: [String: Any], to light: WLEDLight) async -> Bool {
        guard let url = URL(string: "json/state", relativeTo: light.baseURL),
              let body = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private func integrationOriginalURL(for light: WLEDLight) -> URL {
        let safeKey = fixtureKey(light).filter { $0.isLetter || $0.isNumber }
        return support.appendingPathComponent("integration-original-\(safeKey).json")
    }

    private func getJSON(host: String, port: Int, path: String) async -> [String: Any]? {
        guard let url = URL(string: "http://\(host):\(port)/\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.5
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return result
        } catch {
            return nil
        }
    }

    private func readAttentionCount() {
        let url = support.appendingPathComponent("indicator-events.json")
        guard let data = try? Data(contentsOf: url),
              let events = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            attentionCount = 0
            return
        }
        attentionCount = (events["attention"] as? [String: Any])?.count ?? 0
    }
}

final class WLEDControlAppDelegate: NSObject, NSApplicationDelegate {
    private let discovery = WLEDDiscovery()
    private let pageRouter = WLEDPageRouter()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var menuTimer: Timer?
    private var window: NSWindow?
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installMainMenu()
        statusItem.button?.image = NSImage(systemSymbolName: "lightbulb", accessibilityDescription: "WLED Control")
        statusItem.button?.toolTip = "WLED Control"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))
        startBackgroundServicesIfNeeded()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 280, height: 110)
        popover.contentViewController = NSHostingController(rootView: WLEDPopoverView(
            openSettings: { [weak self] in self?.openSettings() },
            openFixture: { [weak self] id in self?.openFixtureControls(id) },
            stopServices: { [weak self] in self?.stopServices() }
        ).environmentObject(discovery))
        updateStatusItem()
        menuTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.updateStatusItem()
        }
        openControls(NSMenuItem())
        if CommandLine.arguments.contains("--popover") {
            DispatchQueue.main.async { self.showPopover() }
        }
    }

    private func updateStatusItem() {
        statusItem.button?.title = discovery.attentionCount > 0 ? " \(discovery.attentionCount)" : ""
        let rowsHeight = discovery.lights.isEmpty ? 44 : Int(ceil(Double(discovery.lights.count) / 3.0)) * 84
        popover.contentSize = NSSize(width: 280, height: CGFloat(min(rowsHeight + 58, 418)))
    }

    private func startBackgroundServicesIfNeeded() {
        let launchAgents = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        for label in ["local.wled-display-sync"] {
            let plist = launchAgents.appendingPathComponent("\(label).plist")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["bootstrap", "gui/\(getuid())", plist.path]
            try? process.run()
            process.waitUntilExit()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown { popover.performClose(sender) } else { showPopover() }
    }

    private func openFixtureControls(_ id: String) {
        popover.performClose(nil)
        discovery.selectedID = id
        pageRouter.selectedSection = .fixtures
        presentMainWindow()
    }

    private func openSettings() {
        popover.performClose(nil)
        pageRouter.selectedSection = .fixtures
        presentMainWindow()
    }

    private func stopServices() {
        let domain = "gui/\(getuid())"
        for label in ["local.wled-indicator", "local.wled-display-sync", "local.wled-alerts-menu"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["bootout", "\(domain)/\(label)"]
            try? process.run()
            process.waitUntilExit()
        }
        NSApp.terminate(nil)
    }

    @objc private func openControls(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { discovery.selectedID = id }
        pageRouter.selectedSection = .fixtures
        presentMainWindow()
    }

    private func presentMainWindow() {
        ensureMainWindow()
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    private func ensureMainWindow() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 950, height: 700),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            // Keep the cached window alive after its close button or Command-W is used.
            // Otherwise AppKit can release it while `self.window` still points at the
            // old Objective-C object, and reopening Settings crashes in objc_msgSend.
            window.isReleasedWhenClosed = false
            window.title = "WLED Control"
            window.contentMinSize = NSSize(width: 950, height: 700)
            window.contentViewController = NSHostingController(rootView: WLEDSettingsView()
                .environmentObject(discovery).environmentObject(pageRouter))
            window.center()
            window.setFrameAutosaveName("WLEDControlWindow")
            self.window = window
        }
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "WLED Control")
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettingsFromMenu), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide WLED Control", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit WLED Control", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        mainMenu.addItem(appItem)
        mainMenu.setSubmenu(appMenu, for: appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let close = fileMenu.addItem(withTitle: "Close Window", action: #selector(closeMainWindow), keyEquivalent: "w")
        close.target = self
        mainMenu.addItem(fileItem)
        mainMenu.setSubmenu(fileMenu, for: fileItem)

        let fixtureItem = NSMenuItem()
        let fixtureMenu = NSMenu(title: "Fixture")
        addFixtureMenuItem("Refresh Fixtures", key: "r", action: #selector(refreshFixtures), to: fixtureMenu)
        fixtureMenu.addItem(.separator())
        for index in 0..<9 {
            let item = NSMenuItem(title: "Select Fixture \(index + 1)", action: #selector(selectFixtureShortcut(_:)),
                                  keyEquivalent: "\(index + 1)")
            item.keyEquivalentModifierMask = [.command, .option]
            item.target = self
            item.representedObject = index
            fixtureMenu.addItem(item)
        }
        fixtureMenu.addItem(.separator())
        addFixtureMenuItem("Toggle Power", key: "p", modifiers: [.command, .shift], action: #selector(toggleActivePower), to: fixtureMenu)
        addFixtureMenuItem("Increase Brightness", key: "=", action: #selector(increaseActiveBrightness), to: fixtureMenu)
        addFixtureMenuItem("Decrease Brightness", key: "-", action: #selector(decreaseActiveBrightness), to: fixtureMenu)
        fixtureMenu.addItem(.separator())
        addFixtureMenuItem("Set Red", key: "r", modifiers: [.command, .option], action: #selector(setActiveRed), to: fixtureMenu)
        addFixtureMenuItem("Set Green", key: "g", modifiers: [.command, .option], action: #selector(setActiveGreen), to: fixtureMenu)
        addFixtureMenuItem("Set Blue", key: "b", modifiers: [.command, .option], action: #selector(setActiveBlue), to: fixtureMenu)
        addFixtureMenuItem("Set White", key: "w", modifiers: [.command, .option], action: #selector(setActiveWhite), to: fixtureMenu)
        fixtureMenu.addItem(.separator())
        for index in 0..<9 {
            let item = NSMenuItem(title: "Apply Preset \(index + 1)", action: #selector(applyPresetShortcut(_:)),
                                  keyEquivalent: "\(index + 1)")
            item.target = self
            item.representedObject = index
            fixtureMenu.addItem(item)
        }
        addFixtureMenuItem("Open WLED Web Interface", key: "o", modifiers: [.command, .option], action: #selector(openActiveWebInterface), to: fixtureMenu)
        mainMenu.addItem(fixtureItem)
        mainMenu.setSubmenu(fixtureMenu, for: fixtureItem)

        NSApp.mainMenu = mainMenu
    }

    private func addFixtureMenuItem(_ title: String, key: String,
                                    modifiers: NSEvent.ModifierFlags = [.command],
                                    action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        menu.addItem(item)
    }

    private var activeLight: WLEDLight? {
        if let id = discovery.activeFixtureID ?? discovery.selectedID,
           let light = discovery.lights.first(where: { $0.id == id }) { return light }
        return discovery.lights.first
    }

    @objc private func showSettingsFromMenu() { openSettings() }
    @objc private func closeMainWindow() { window?.performClose(nil) }
    @objc private func refreshFixtures() { discovery.refreshAll() }
    @objc private func selectFixtureShortcut(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int, discovery.lights.indices.contains(index) else { return }
        let light = discovery.lights[index]
        discovery.activeFixtureID = light.id
        discovery.selectedID = light.id
        pageRouter.selectedSection = .fixtures
        presentMainWindow()
    }
    @objc private func toggleActivePower() { if let light = activeLight { discovery.setPower(light, on: !light.isOn) } }
    @objc private func increaseActiveBrightness() { if let light = activeLight { discovery.setBrightness(light, value: light.brightness + 16) } }
    @objc private func decreaseActiveBrightness() { if let light = activeLight { discovery.setBrightness(light, value: light.brightness - 16) } }
    @objc private func setActiveRed() { setActiveColor(red: 255, green: 0, blue: 0) }
    @objc private func setActiveGreen() { setActiveColor(red: 0, green: 255, blue: 0) }
    @objc private func setActiveBlue() { setActiveColor(red: 0, green: 0, blue: 255) }
    @objc private func setActiveWhite() { setActiveColor(red: 255, green: 255, blue: 255) }
    private func setActiveColor(red: Int, green: Int, blue: Int) {
        if let light = activeLight { discovery.setColor(light, red: red, green: green, blue: blue) }
    }
    @objc private func applyPresetShortcut(_ sender: NSMenuItem) {
        guard let light = activeLight, let index = sender.representedObject as? Int,
              light.presets.indices.contains(index) else { return }
        discovery.applyPreset(light.presets[index], to: light)
    }
    @objc private func openActiveWebInterface() {
        if let light = activeLight { NSWorkspace.shared.open(light.baseURL) }
    }

}

@main
struct WLEDControlMain {
    static func main() {
        if CodexEventBridge.handleCommandLine() { return }
        let application = NSApplication.shared
        let delegate = WLEDControlAppDelegate()
        application.delegate = delegate
        application.run()
    }
}

private final class WLEDPageRouter: ObservableObject {
    @Published var selectedSection: WLEDSettingsSection = .fixtures
}

private enum MenuFixtureAction: String, CaseIterable, Identifiable {
    case acknowledgeOrToggle
    case togglePower
    case openControls
    case acknowledgeAlert
    case doNothing

    var id: Self { self }

    var title: String {
        switch self {
        case .acknowledgeOrToggle: "Acknowledge Alert or Toggle Power"
        case .togglePower: "Toggle Power"
        case .openControls: "Open Fixture Controls"
        case .acknowledgeAlert: "Acknowledge Alert"
        case .doNothing: "Do Nothing"
        }
    }

}

struct WLEDPopoverView: View {
    @EnvironmentObject private var discovery: WLEDDiscovery
    @AppStorage("wled.menu.clickAction") private var clickActionRaw = MenuFixtureAction.acknowledgeOrToggle.rawValue
    @AppStorage("wled.menu.holdAction") private var holdActionRaw = MenuFixtureAction.openControls.rawValue
    @State private var iconsByFixture: [String: String] = [:]
    @State private var attentionGlow = false
    let openSettings: () -> Void
    let openFixture: (String) -> Void
    let stopServices: () -> Void

    private let icons = ["lightbulb.fill", "lamp.desk.fill", "tv.fill", "desktopcomputer",
                         "fanblades.fill", "sun.max.fill", "bed.double.fill", "sofa.fill",
                         "gamecontroller.fill", "sparkles"]

    var body: some View {
        VStack(spacing: 6) {
            if discovery.lights.isEmpty {
                Text("No fixtures available")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                ScrollView(.vertical, showsIndicators: discovery.lights.count > 12) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 76, maximum: 92), spacing: 8)], spacing: 8) {
                        ForEach(discovery.lights) { light in
                            fixtureTile(light)
                        }
                    }
                }
                .frame(maxHeight: 360)
            }

            Divider()

            HStack {
                Button {
                    stopServices()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Stop WLED services and close")
                Spacer()
                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 30, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Settings")
            }
        }
        .padding(8)
        .frame(width: 264)
        .background(.regularMaterial)
        .onAppear {
            loadFixtureIcons()
            withAnimation(.easeInOut(duration: 0.48).repeatForever(autoreverses: true)) {
                attentionGlow = true
            }
        }
        .onChange(of: discovery.lights.map(\.id)) { _ in loadFixtureIcons() }
    }

    private func fixtureTile(_ light: WLEDLight) -> some View {
        let needsAttention = needsAcknowledgement(light)
        let accent = needsAttention ? attentionColor(for: light) : light.color
        let background = needsAttention
            ? accent.opacity(attentionGlow ? 0.18 : 0.08)
            : (light.isOn ? accent.opacity(0.12) : Color.primary.opacity(0.045))
        let border = needsAttention
            ? accent.opacity(attentionGlow ? 0.9 : 0.45)
            : (light.isOn ? accent.opacity(0.55) : Color.clear)

        return VStack(spacing: 6) {
            Image(systemName: iconFor(light))
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(needsAttention ? accent : (light.isOn ? light.color : .secondary))
            Text(light.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(2).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 70, maxHeight: 70)
        .padding(5)
        .background(background, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(border, lineWidth: 1))
        .shadow(color: needsAttention ? accent.opacity(attentionGlow ? 0.6 : 0.2) : .clear,
                radius: attentionGlow ? 10 : 4)
        .overlay(alignment: .topTrailing) {
            if needsAttention {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, accent)
                    .padding(7)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 13))
        .gesture(
            LongPressGesture(minimumDuration: 0.55)
                .exclusively(before: TapGesture())
                .onEnded { result in
                    switch result {
                    case .first(true): perform(holdAction, for: light)
                    case .first(false): break
                    case .second(_): perform(clickAction, for: light)
                    }
                }
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { perform(clickAction, for: light) }
        .help(needsAttention
              ? "\(light.name) has a pending Codex alert. Click: \(clickAction.title). Hold: \(holdAction.title)."
              : "\(light.name): \(light.isOn ? "On" : "Off"). Click: \(clickAction.title). Hold: \(holdAction.title).")
        .contextMenu {
            Menu("Choose Icon") {
                ForEach(icons, id: \.self) { icon in
                    Button {
                        UserDefaults.standard.set(icon, forKey: iconPreferenceKey(for: light))
                        iconsByFixture[light.id] = icon
                    } label: {
                        Label(icon.replacingOccurrences(of: ".fill", with: "").capitalized,
                              systemImage: icon)
                    }
                }
            }
            Button("Fixture Controls…") { openFixture(light.id) }
        }
    }

    private func iconPreferenceKey(for light: WLEDLight) -> String { "wled.fixture.icon.\(light.id)" }
    private func needsAcknowledgement(_ light: WLEDLight) -> Bool {
        let integration = discovery.codexIntegration(for: light)
        return discovery.attentionCount > 0 && integration.isEnabled && integration.showAttention
    }
    private func attentionColor(for light: WLEDLight) -> Color {
        let integration = discovery.codexIntegration(for: light)
        return light.presets.first(where: { $0.id == integration.attentionPreset })?.colors.first?.color ?? .orange
    }
    private var clickAction: MenuFixtureAction {
        MenuFixtureAction(rawValue: clickActionRaw) ?? .acknowledgeOrToggle
    }
    private var holdAction: MenuFixtureAction {
        MenuFixtureAction(rawValue: holdActionRaw) ?? .openControls
    }
    private func perform(_ action: MenuFixtureAction, for light: WLEDLight) {
        switch action {
        case .acknowledgeOrToggle:
            if needsAcknowledgement(light) {
                discovery.acknowledgeAttention()
            } else {
                discovery.setPower(light, on: !light.isOn)
            }
        case .togglePower:
            discovery.setPower(light, on: !light.isOn)
        case .openControls:
            openFixture(light.id)
        case .acknowledgeAlert:
            if needsAcknowledgement(light) { discovery.acknowledgeAttention() }
        case .doNothing:
            break
        }
    }
    private func iconFor(_ light: WLEDLight) -> String {
        iconsByFixture[light.id] ?? "lightbulb.fill"
    }
    private func loadFixtureIcons() {
        for light in discovery.lights {
            iconsByFixture[light.id] = UserDefaults.standard.string(forKey: iconPreferenceKey(for: light)) ?? "lightbulb.fill"
        }
    }
}

private enum WLEDSettingsSection: String, CaseIterable, Identifiable {
    case fixtures = "Fixtures"
    case general = "General"
    case integrations = "Integrations"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .fixtures: "lightbulb.2"
        case .integrations: "puzzlepiece.extension"
        }
    }
}

struct WLEDSettingsView: View {
    @EnvironmentObject private var discovery: WLEDDiscovery
    @EnvironmentObject private var router: WLEDPageRouter
    @AppStorage("wled.menu.clickAction") private var menuClickAction = MenuFixtureAction.acknowledgeOrToggle.rawValue
    @AppStorage("wled.menu.holdAction") private var menuHoldAction = MenuFixtureAction.openControls.rawValue
    @State private var codexStatus = CodexHookManager.status()
    @State private var codexMessage = ""
    @State private var showingCodexMessage = false
    @State private var confirmingCodexRemoval = false
    @State private var fixtureIcons: [String: String] = [:]
    @State private var selectedFixtureID: String?
    private let fixtureIconChoices = ["lightbulb.fill", "lamp.desk.fill", "lightswitch.on.fill", "sun.max.fill", "sparkles", "desktopcomputer", "tv.fill", "bed.double.fill"]

    private var selectedFixture: WLEDLight? {
        discovery.lights.first { $0.id == selectedFixtureID }
    }

    var body: some View {
        NavigationSplitView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(WLEDSettingsSection.allCases) { item in
                        Button { router.selectedSection = item } label: {
                            HStack(spacing: 12) {
                                Image(systemName: item.symbol)
                                    .font(.system(size: 22))
                                    .foregroundStyle(router.selectedSection == item ? .blue : .secondary)
                                    .frame(width: 32, height: 32)
                                Text(item.rawValue).font(.system(size: 14, weight: .medium))
                                Spacer()
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 8)
                            .background(router.selectedSection == item ? Color.blue.opacity(0.1) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8)
                    }
                    Spacer()
                }
                .padding(.top, 12)
                .frame(minWidth: 200, maxWidth: 220)
                .background(Color(nsColor: .windowBackgroundColor))
                .toolbar(removing: .sidebarToggle)
            } detail: {
                settingsDetail
                    .toolbar {
                        ToolbarItem(placement: .principal) { Spacer() }
                        ToolbarItem(placement: .primaryAction) {
                            Button { discovery.refreshAll() } label: {
                                Label("Refresh Fixtures", systemImage: "arrow.clockwise")
                            }
                            .help("Refresh fixtures")
                        }
                    }
            }
        .toolbar(removing: .title)
        .navigationSplitViewStyle(.balanced)
        .tint(.blue)
        .onAppear {
            refreshHookStatus()
            loadFixtureIcons()
            acceptPendingFixtureSelection()
        }
        .onChange(of: discovery.selectedID) { _ in acceptPendingFixtureSelection() }
        .onChange(of: discovery.lights.map(\.id)) { ids in
            if let selectedFixtureID, !ids.contains(selectedFixtureID) { self.selectedFixtureID = nil }
        }
        .alert("Codex Connection", isPresented: $showingCodexMessage) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(codexMessage)
        }
        .confirmationDialog("Remove Codex connection?", isPresented: $confirmingCodexRemoval) {
            Button("Remove Connection", role: .destructive) { removeCodexConnection() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes only WLED Control’s hooks. Other Codex hooks and settings are preserved.")
        }
    }

    @ViewBuilder private var settingsDetail: some View {
        if router.selectedSection == .fixtures, let light = selectedFixture {
            LightDetailView(light: light, onBack: { selectedFixtureID = nil })
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(router.selectedSection.rawValue)
                        .font(.system(size: 24, weight: .bold))
                        .padding(.bottom, 8)
                    detailContent
                    Spacer()
                }
                .padding(.horizontal, 24).padding(.bottom, 24).padding(.top, 8)
                .frame(maxWidth: 1050, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    @ViewBuilder private var detailContent: some View {
        switch router.selectedSection {
        case .general:
            settingsSection("Menu Dropdown Behavior", symbol: "cursorarrow.click") {
                menuActionRow("Clicking a fixture", selection: $menuClickAction)
                Divider()
                menuActionRow("Holding a fixture", selection: $menuHoldAction)
            }
        case .fixtures:
            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    if discovery.lights.isEmpty {
                        ContentUnavailableView("No fixtures available", systemImage: "lightbulb.slash")
                            .frame(maxWidth: .infinity, minHeight: 220)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
                            ForEach(discovery.lights) { light in
                                Button {
                                    selectedFixtureID = light.id
                                    discovery.activeFixtureID = light.id
                                } label: {
                                    VStack(alignment: .leading, spacing: 12) {
                                        HStack {
                                            Image(systemName: fixtureIcons[light.id] ?? "lightbulb.fill")
                                                .font(.system(size: 23, weight: .medium))
                                                .foregroundStyle(light.isOn ? light.color : .secondary)
                                                .frame(width: 44, height: 44)
                                                .background((light.isOn ? light.color : Color.secondary).opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                                .padding(.trailing, 34)
                                        }
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(light.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                            Text(light.isOn ? "On · \(Int(Double(light.brightness) * 100 / 255))%" : "Off")
                                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
                                    .padding(14)
                                    .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(light.isOn ? light.color.opacity(0.3) : Color.primary.opacity(0.08), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                                .help("Open controls for \(light.name)")
                                .overlay(alignment: .topTrailing) {
                                    Button { discovery.setPower(light, on: !light.isOn) } label: {
                                        Image(systemName: light.isOn ? "power.circle.fill" : "power.circle")
                                            .font(.system(size: 22))
                                            .foregroundStyle(light.isOn ? .green : .secondary)
                                            .frame(width: 32, height: 32)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .padding(14)
                                    .help("Turn \(light.name) \(light.isOn ? "off" : "on")")
                                }
                                .contextMenu {
                                    Menu("Choose icon") {
                                        ForEach(fixtureIconChoices, id: \.self) { symbol in
                                            Button { setFixtureIcon(symbol, for: light) } label: { Label(symbol, systemImage: symbol) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(12)
            } label: {
                Label("Connected Fixtures", systemImage: "lightbulb.2")
                    .font(.title3.bold()).padding(4)
            }
        case .integrations:
            VStack(alignment: .leading, spacing: 24) {
                settingsSection("Codex Connection", symbol: "sparkles") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: codexStatus.isConnected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(codexStatus.isConnected ? .green : .orange)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(codexStatus.summary).font(.system(size: 15, weight: .semibold))
                            }
                            Spacer()
                            Button(codexStatus.isConnected ? "Repair" : "Install") { installCodexConnection() }
                                .buttonStyle(.borderedProminent)
                        }
                        Divider()
                        codexStatusRow("Questions and approvals", connected: codexStatus.hooksConnected)
                        codexStatusRow("Completed tasks", connected: codexStatus.notificationsConnected)
                        Divider()
                        HStack {
                            Button("Test Completion") { CodexEventBridge.testCompletion() }
                            Button("Test Attention") { CodexEventBridge.testAttention() }
                            Spacer()
                            Menu("Advanced") {
                                Button("Open Codex Settings") { CodexHookManager.openCodexSettings() }
                                Button("Open Hooks File") { CodexHookManager.openHooksFile() }
                                Divider()
                                Button("Remove Connection", role: .destructive) { confirmingCodexRemoval = true }
                            }
                        }
                    }
                }

                if discovery.lights.isEmpty {
                    ContentUnavailableView("No fixtures available", systemImage: "lightbulb.slash")
                } else {
                    ForEach(discovery.lights) { light in integrationSection(for: light) }
                }
            }
        }
    }

    private func settingsSection<Content: View>(_ title: String, symbol: String,
                                                @ViewBuilder content: () -> Content) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0, content: content).padding(12)
        } label: {
            Label(title, systemImage: symbol).font(.title3.bold()).padding(4)
        }
    }

    private func menuActionRow(_ title: String, selection: Binding<String>) -> some View {
        HStack {
            Text(title).font(.system(size: 15, weight: .medium))
            Spacer()
            Picker(title, selection: selection) {
                ForEach(MenuFixtureAction.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            .labelsHidden()
            .frame(width: 265)
        }
        .padding(.vertical, 8)
    }

    private func fixtureIconKey(_ light: WLEDLight) -> String { "wled.fixture.icon.\(light.id)" }

    private func loadFixtureIcons() {
        for light in discovery.lights {
            fixtureIcons[light.id] = UserDefaults.standard.string(forKey: fixtureIconKey(light)) ?? "lightbulb.fill"
        }
    }

    private func setFixtureIcon(_ symbol: String, for light: WLEDLight) {
        fixtureIcons[light.id] = symbol
        UserDefaults.standard.set(symbol, forKey: fixtureIconKey(light))
    }

    private func acceptPendingFixtureSelection() {
        guard let id = discovery.selectedID,
              discovery.lights.contains(where: { $0.id == id }) else { return }
        router.selectedSection = .fixtures
        selectedFixtureID = id
        discovery.activeFixtureID = id
        discovery.selectedID = nil
    }

    private func refreshHookStatus() {
        codexStatus = CodexHookManager.status()
    }

    private func codexStatusRow(_ title: String, connected: Bool) -> some View {
        HStack {
            Label(title, systemImage: connected ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(connected ? .primary : .secondary)
            Spacer()
            Text(connected ? "Connected" : "Not connected")
                .font(.caption.weight(.medium))
                .foregroundStyle(connected ? .green : .secondary)
        }
    }

    private func installCodexConnection() {
        do {
            codexMessage = try CodexHookManager.installOrRepair()
        } catch {
            codexMessage = error.localizedDescription
        }
        refreshHookStatus()
        showingCodexMessage = true
    }

    private func removeCodexConnection() {
        do {
            codexMessage = try CodexHookManager.remove()
        } catch {
            codexMessage = error.localizedDescription
        }
        refreshHookStatus()
        showingCodexMessage = true
    }

    private func integrationSection(for light: WLEDLight) -> some View {
        let integration = discovery.codexIntegration(for: light)
        return GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                if integration.isEnabled {
                    HStack {
                        Label("Codex", systemImage: "sparkles").font(.system(size: 15, weight: .semibold))
                        Spacer()
                        Toggle("Enabled", isOn: codexBinding(for: light, \.isEnabled)).labelsHidden()
                    }
                    Divider()
                    Toggle("Show completed tasks", isOn: codexBinding(for: light, \.showCompletion))
                    Toggle("Questions and approval requests", isOn: codexBinding(for: light, \.showAttention))
                    HStack {
                        Text("Completion duration")
                        Slider(value: codexBinding(for: light, \.completionSeconds), in: 1...10, step: 0.5)
                        Text("\(integration.completionSeconds, specifier: "%.1f") sec")
                            .monospacedDigit().frame(width: 58, alignment: .trailing)
                    }
                    Picker("Completion preset", selection: codexBinding(for: light, \.completionPreset)) {
                        ForEach(light.presets) { Text($0.name).tag($0.id) }
                    }
                    Picker("Attention preset", selection: codexBinding(for: light, \.attentionPreset)) {
                        ForEach(light.presets) { Text($0.name).tag($0.id) }
                    }
                    Divider()
                    HStack {
                        Button("Remove Integration", role: .destructive) {
                            discovery.removeCodexIntegration(for: light)
                        }
                        Spacer()
                        Button("Acknowledge Pending Attention") { discovery.acknowledgeAttention() }
                            .disabled(discovery.attentionCount == 0)
                    }
                } else {
                    HStack {
                        Spacer()
                        Menu("Add Integration") {
                            Button("Codex") {
                                var value = CodexFixtureIntegration()
                                value.isEnabled = true
                                if let first = light.presets.first { value.completionPreset = first.id }
                                if light.presets.count > 1 { value.attentionPreset = light.presets[1].id }
                                discovery.setCodexIntegration(value, for: light)
                            }
                        }
                    }
                }
            }
            .padding(12)
        } label: {
            Label(light.name, systemImage: fixtureIcons[light.id] ?? "lightbulb.fill")
                .font(.title3.bold()).padding(4)
        }
    }

    private func codexBinding<Value>(for light: WLEDLight,
                                     _ keyPath: WritableKeyPath<CodexFixtureIntegration, Value>) -> Binding<Value> {
        Binding(
            get: { discovery.codexIntegration(for: light)[keyPath: keyPath] },
            set: { newValue in
                var integration = discovery.codexIntegration(for: light)
                integration[keyPath: keyPath] = newValue
                discovery.setCodexIntegration(integration, for: light)
            }
        )
    }
}

struct ControllerView: View {
    @EnvironmentObject private var discovery: WLEDDiscovery
    let onSettings: () -> Void
    @State private var selectedID: String?

    private var selected: WLEDLight? { discovery.lights.first { $0.id == selectedID } }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedID) {
                Section("Online Lights") {
                    ForEach(discovery.lights) { light in
                        HStack(spacing: 10) {
                            Image(systemName: light.isOn ? "lightbulb.fill" : "lightbulb")
                                .foregroundStyle(light.isOn ? light.color : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(light.name).fontWeight(.medium)
                                Text(light.host).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Circle().fill(.green).frame(width: 7, height: 7)
                        }
                        .tag(light.id)
                    }
                }
            }
            .navigationTitle("WLED Lights")
            .toolbar {
                ToolbarItem { Button { discovery.refreshAll() } label: { Image(systemName: "arrow.clockwise") } }
                ToolbarItem { Button(action: onSettings) { Image(systemName: "gearshape") }.help("Settings") }
            }
        } detail: {
            if let light = selected {
                LightDetailView(light: light)
            } else if discovery.lights.isEmpty {
                ContentUnavailableView("No WLED lights nearby", systemImage: "lightbulb.slash",
                    description: Text("Lights appear here automatically while they advertise WLED on your local network."))
            } else {
                ContentUnavailableView("Choose a light", systemImage: "lightbulb",
                    description: Text("Select a fixture on the left to control it."))
            }
        }
        .onChange(of: discovery.lights.map(\.id)) { ids in
            if let preferred = discovery.selectedID, ids.contains(preferred) {
                selectedID = preferred
                discovery.selectedID = nil
            } else if !ids.contains(selectedID ?? "") {
                selectedID = ids.first
            }
        }
        .onAppear {
            if let preferred = discovery.selectedID, discovery.lights.contains(where: { $0.id == preferred }) {
                selectedID = preferred
                discovery.selectedID = nil
            } else if selectedID == nil {
                selectedID = discovery.lights.first?.id
            }
        }
        .onChange(of: selectedID) { newValue in discovery.selectedID = newValue }
        .onChange(of: discovery.selectedID) { value in
            if let value, discovery.lights.contains(where: { $0.id == value }) { selectedID = value }
        }
    }
}

struct LightDetailView: View {
    @EnvironmentObject private var discovery: WLEDDiscovery
    let light: WLEDLight
    var onBack: (() -> Void)? = nil
    @State private var brightness: Double = 128
    @State private var selectedColor = Color.white
    @State private var showingSavePreset = false
    @State private var pendingColorSend: DispatchWorkItem?
    @State private var colorSyncResume: DispatchWorkItem?
    @State private var isChangingColor = false
    @State private var isApplyingDeviceColor = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let onBack {
                    Button(action: onBack) {
                        Label("All Fixtures", systemImage: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }

                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(light.name).font(.system(size: 24, weight: .bold))
                        Text("\(light.host)  ·  \(light.mac.isEmpty ? "WLED" : light.mac)")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Power", isOn: Binding(
                        get: { light.isOn },
                        set: { discovery.setPower(light, on: $0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }

                GroupBox {
                    HStack {
                        Image(systemName: "sun.min")
                        Slider(value: $brightness, in: 1...255, step: 1) { editing in
                            if !editing { discovery.setBrightness(light, value: Int(brightness)) }
                        }
                        Image(systemName: "sun.max.fill")
                        Text("\(Int(brightness * 100 / 255))%")
                            .monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                    .padding(12)
                } label: {
                    Label("Brightness", systemImage: "sun.max")
                        .font(.title3.bold()).padding(4)
                }

                GroupBox {
                    HStack {
                        ColorPicker("Choose a color", selection: $selectedColor, supportsOpacity: false)
                            .onChange(of: selectedColor) { color in send(color) }
                        Spacer()
                        RoundedRectangle(cornerRadius: 8)
                            .fill(light.color).frame(width: 64, height: 40)
                    }
                    .padding(12)
                } label: {
                    Label("Color", systemImage: "paintpalette")
                        .font(.title3.bold()).padding(4)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        if !light.presets.isEmpty {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
                                ForEach(light.presets) { preset in
                                    Button { discovery.applyPreset(preset, to: light) } label: {
                                        HStack(spacing: 8) {
                                            if !preset.colors.isEmpty {
                                                PresetColorSwatch(colors: preset.colors)
                                            }
                                            Text(preset.name).lineLimit(1)
                                            Spacer(minLength: 0)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Divider()
                        }
                        Button {
                            showingSavePreset = true
                        } label: {
                            Label("Save Current State as Preset…", systemImage: "plus")
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(12)
                } label: {
                    Label("Presets", systemImage: "square.grid.2x2")
                        .font(.title3.bold()).padding(4)
                }

                HStack {
                    Button {
                        NSWorkspace.shared.open(light.baseURL)
                    } label: {
                        Label("Open WLED Web Interface…", systemImage: "safari")
                    }
                    .buttonStyle(.link)
                    Spacer()
                    if !light.firmware.isEmpty {
                        Text("WLED \(light.firmware)").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 24).padding(.top, 8)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear {
            discovery.activeFixtureID = light.id
            syncControls()
        }
        .onChange(of: light.id) { _ in syncControls() }
        .onChange(of: light.brightness) { value in brightness = Double(value) }
        .onChange(of: light.color) { value in
            if !isChangingColor { applyDeviceColor(value) }
        }
        .onDisappear {
            pendingColorSend?.cancel()
            colorSyncResume?.cancel()
        }
        .sheet(isPresented: $showingSavePreset) {
            SavePresetView(light: light) { name, slot in
                discovery.savePreset(light, name: name, slot: slot)
            }
        }
        .navigationTitle(light.name)
    }

    private func syncControls() {
        brightness = Double(light.brightness)
        applyDeviceColor(light.color)
    }

    private func send(_ color: Color) {
        guard !isApplyingDeviceColor else { return }
        let rgb = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor.white
        let red = Int((rgb.redComponent * 255).rounded())
        let green = Int((rgb.greenComponent * 255).rounded())
        let blue = Int((rgb.blueComponent * 255).rounded())

        // ColorPicker emits many changes while dragging. Send only the most recent
        // value and temporarily ignore device echoes so stale responses cannot pull
        // the picker backward under the pointer.
        pendingColorSend?.cancel()
        colorSyncResume?.cancel()
        isChangingColor = true

        let sendWork = DispatchWorkItem {
            discovery.setColor(light, red: red, green: green, blue: blue)
        }
        pendingColorSend = sendWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: sendWork)

        let resumeWork = DispatchWorkItem { isChangingColor = false }
        colorSyncResume = resumeWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65, execute: resumeWork)
    }

    private func applyDeviceColor(_ color: Color) {
        isApplyingDeviceColor = true
        selectedColor = color
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { isApplyingDeviceColor = false }
    }
}

private struct PresetColorSwatch: View {
    let colors: [WLEDPresetColor]

    var body: some View {
        HStack(spacing: 1) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, presetColor in
                Rectangle().fill(presetColor.color)
            }
        }
        .frame(width: 34, height: 13)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.16), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(colors.count == 1 ? "One preset color" : "\(colors.count) preset colors")
    }
}

private struct SavePresetView: View {
    @Environment(\.dismiss) private var dismiss
    let light: WLEDLight
    let onSave: (String, Int) -> Void
    @State private var name: String
    @State private var slot: Int
    @State private var confirmingOverwrite = false

    init(light: WLEDLight, onSave: @escaping (String, Int) -> Void) {
        self.light = light
        self.onSave = onSave
        let usedSlots = Set(light.presets.map(\.id))
        let firstFreeSlot = (1...250).first { !usedSlots.contains($0) } ?? 250
        _name = State(initialValue: "")
        _slot = State(initialValue: firstFreeSlot)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var existingPreset: WLEDPreset? {
        light.presets.first { $0.id == slot }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Save Preset").font(.title2.bold())
                Text("Save \(light.name)’s current color, brightness, effects, and segments.")
                    .foregroundStyle(.secondary)
            }

            Form {
                TextField("Name", text: $name, prompt: Text("Preset name"))
                Stepper(value: $slot, in: 1...250) {
                    HStack {
                        Text("Preset slot")
                        Spacer()
                        Text("\(slot)").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            if let existingPreset {
                Label("Slot \(slot) currently contains “\(existingPreset.name)”.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(existingPreset == nil ? "Save Preset" : "Review Overwrite") {
                    if existingPreset == nil { commitSave() } else { confirmingOverwrite = true }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onChange(of: name) { value in
            if value.count > 32 { name = String(value.prefix(32)) }
        }
        .confirmationDialog(
            "Overwrite preset \(slot)?",
            isPresented: $confirmingOverwrite,
            titleVisibility: .visible
        ) {
            Button("Overwrite “\(existingPreset?.name ?? "Preset \(slot)")”", role: .destructive) { commitSave() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces the preset with \(light.name)’s current state.")
        }
    }

    private func commitSave() {
        onSave(trimmedName, slot)
        dismiss()
    }
}
