// UsageIcon — a minimal macOS menu bar app showing Claude Code usage.
//
// Design goals (see menubar_agent_prompt.md):
//  - Menu bar only, no dock icon, no window.
//  - Read the OAuth token from the macOS Keychain via the Security framework.
//  - Call GET https://api.anthropic.com/api/oauth/usage and pull just two numbers.
//  - Parse the response LOOSELY (JSONSerialization), so unknown/renamed/null
//    sibling fields never break us. This is the whole point of the app.
//  - Never crash; degrade gracefully to last-good values or "—".

import AppKit
import Security
import ServiceManagement

// MARK: - Render states

enum RenderState {
    case loading
    case notLoggedIn
    case authExpired
    case keepLast                                   // network/decode error: keep last good
    case ok(five: Int?, week: Int?, fiveReset: Date?, weekReset: Date?)
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let keychainService = "Claude Code-credentials"
    private let refreshInterval: TimeInterval = 120   // 2 minutes

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let fiveHourItem = NSMenuItem()
    private let weekItem = NSMenuItem()
    private let loginMenuItem = NSMenuItem()
    private var timer: Timer?

    private let worker = DispatchQueue(label: "com.local.usageicon.worker")
    private var cachedToken: String?      // read the Keychain once, then reuse

    // Last-good values, so a transient failure doesn't wipe the display.
    private var lastFive: Int?
    private var lastWeek: Int?
    private var lastFiveReset: Date?
    private var lastWeekReset: Date?

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt-and-suspenders with LSUIElement in Info.plist: no dock icon.
        NSApp.setActivationPolicy(.accessory)

        // Single instance only — a second copy would add a second menu bar icon
        // and fire its own Keychain prompts in parallel.
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != NSRunningApplication.current }
        if !others.isEmpty {
            NSApp.terminate(nil)
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "–  –"   // placeholder until the first fetch

        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(fiveHourItem)
        menu.addItem(weekItem)
        menu.addItem(.separator())
        loginMenuItem.title = "Open at Login"
        loginMenuItem.action = #selector(toggleLoginItem)
        loginMenuItem.target = self
        menu.addItem(loginMenuItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu

        enableLoginItemByDefault()
        refreshLoginItemState()
        render(.loading)
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    // Refresh when the menu is opened so the user always sees fresh numbers.
    func menuWillOpen(_ menu: NSMenu) {
        refresh()
        refreshLoginItemState()   // reflect changes made in System Settings
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Launch at login (SMAppService, macOS 13+)

    /// Register as a login item on first run so it starts automatically.
    private func enableLoginItemByDefault() {
        guard SMAppService.mainApp.status != .enabled else { return }
        do {
            try SMAppService.mainApp.register()
        } catch {
            NSLog("[ClaudeUsageIcon] login-item register failed: \(error.localizedDescription)")
        }
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("[ClaudeUsageIcon] login-item toggle failed: \(error.localizedDescription)")
        }
        refreshLoginItemState()
    }

    private func refreshLoginItemState() {
        loginMenuItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }

    // MARK: Data fetch

    private func refresh() {
        // Serial queue so the Keychain is touched at most once even if several
        // refreshes overlap; a permission prompt can block, so keep it off main.
        worker.async { [weak self] in
            guard let self = self else { return }

            let token: String
            if let cached = self.cachedToken {
                token = cached                  // reuse — no Keychain prompt
            } else if let fresh = self.readAccessToken() {
                self.cachedToken = fresh        // first read only
                token = fresh
            } else {
                DispatchQueue.main.async { self.render(.notLoggedIn) }
                return
            }

            var request = URLRequest(url: self.usageURL)
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.timeoutInterval = 20

            URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                guard let self = self else { return }

                if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                    self.worker.async { self.cachedToken = nil }   // expired: re-read next time
                    DispatchQueue.main.async { self.render(.authExpired) }
                    return
                }
                guard error == nil,
                      let data = data,
                      let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    DispatchQueue.main.async { self.render(.keepLast) }
                    return
                }

                let five = self.utilization(root["five_hour"])
                let week = self.utilization(root["seven_day"])
                // If we couldn't read either number the shape changed in a way we
                // don't understand — treat as an error and keep last-good values.
                if five == nil && week == nil {
                    DispatchQueue.main.async { self.render(.keepLast) }
                    return
                }

                let fiveReset = self.resetDate(root["five_hour"])
                let weekReset = self.resetDate(root["seven_day"])
                DispatchQueue.main.async {
                    self.render(.ok(five: five, week: week, fiveReset: fiveReset, weekReset: weekReset))
                }
            }.resume()
        }
    }

    // MARK: Keychain

    /// Reads the Claude Code OAuth access token from the login keychain.
    /// Mirrors `security find-generic-password -s "Claude Code-credentials" -w`:
    /// matched by service name only, then the JSON payload is parsed defensively.
    private func readAccessToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }

        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty else {
            return nil
        }
        return token
    }

    // MARK: Loose parsing helpers

    /// Pulls `<window>.utilization` as a rounded whole-number percentage.
    /// Tolerates missing / null / non-numeric values by returning nil.
    private func utilization(_ any: Any?) -> Int? {
        guard let dict = any as? [String: Any],
              let number = dict["utilization"] as? NSNumber else { return nil }
        return Int(number.doubleValue.rounded())
    }

    /// Pulls `<window>.resets_at` as a Date, or nil if absent/null/unparseable.
    private func resetDate(_ any: Any?) -> Date? {
        guard let dict = any as? [String: Any],
              let raw = dict["resets_at"] as? String else { return nil }
        return parseISODate(raw)
    }

    private func parseISODate(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: s) { return d }
        // Fallback for offsets like "+00:00" that some formatter versions reject.
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        return df.date(from: s)
    }

    // MARK: Rendering

    private func render(_ state: RenderState) {
        switch state {
        case .loading:
            renderUsage(five: lastFive, week: lastWeek, fiveReset: lastFiveReset, weekReset: lastWeekReset)

        case .notLoggedIn:
            renderMessage("Not logged in — open Claude Code")

        case .authExpired:
            renderMessage("Auth expired — restart Claude Code")

        case .keepLast:
            renderUsage(five: lastFive, week: lastWeek, fiveReset: lastFiveReset, weekReset: lastWeekReset)

        case let .ok(five, week, fiveReset, weekReset):
            if let five = five { lastFive = five }
            if let week = week { lastWeek = week }
            if let fiveReset = fiveReset { lastFiveReset = fiveReset }
            if let weekReset = weekReset { lastWeekReset = weekReset }
            renderUsage(five: lastFive, week: lastWeek, fiveReset: lastFiveReset, weekReset: lastWeekReset)
        }
    }

    private func renderUsage(five: Int?, week: Int?, fiveReset: Date?, weekReset: Date?) {
        weekItem.isHidden = false

        fiveHourItem.image = symbol("chart.pie.fill")
        fiveHourItem.title = "5hr: " + percentText(five)
        fiveHourItem.toolTip = resetTooltip("5-hour limit", fiveReset)

        weekItem.image = symbol("calendar")
        weekItem.title = "Week: " + percentText(week)
        weekItem.toolTip = resetTooltip("Weekly limit", weekReset)

        setMenuBar(five: five, week: week)
    }

    private func renderMessage(_ message: String) {
        fiveHourItem.image = symbol("exclamationmark.triangle")
        fiveHourItem.title = message
        fiveHourItem.toolTip = nil
        weekItem.isHidden = true
        setMenuBar(five: nil, week: nil)
    }

    /// Menu bar shows two numbers — session (5hr) on the left, weekly on the
    /// right — and no icon. Turns orange at ≥80% / red at ≥95% (highest of the two).
    private func setMenuBar(five: Int?, week: Int?) {
        guard let button = statusItem.button else { return }
        button.image = nil

        let left = five.map { "\($0)%" } ?? "–"
        let right = week.map { "\($0)%" } ?? "–"
        let text = "\(left)  \(right)"

        let level = max(five ?? 0, week ?? 0)
        if let color = warnColor(level) {
            button.attributedTitle = NSAttributedString(string: text, attributes: [.foregroundColor: color])
        } else {
            button.title = text     // plain title: adapts to light/dark menu bar
        }
    }

    private func warnColor(_ level: Int) -> NSColor? {
        if level >= 95 { return .systemRed }
        if level >= 80 { return .systemOrange }
        return nil
    }

    private func percentText(_ value: Int?) -> String {
        value.map { "\($0)%" } ?? "—"
    }

    private func resetTooltip(_ label: String, _ date: Date?) -> String? {
        guard let date = date else { return nil }
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return "\(label) resets \(df.string(from: date))"   // local time
    }

    private func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        return image?.withSymbolConfiguration(config)
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
