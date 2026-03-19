import AppKit
import SwiftUI
import WebKit
import os

class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate!

    private var statusItem: NSStatusItem!
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var accountManager = AccountManager.shared
    private var notificationManager = NotificationManager.shared
    private var titleObservations: [NSKeyValueObservation] = []
    private var feedPollTimer: Timer?
    private var notifiedEmailIds: Set<String> = []
    private var hasCompletedFirstPoll = false
    private var lastTitlePollTime: Date = .distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        setupMenuBarIcon()
        setupActivationPolicy()
        notificationManager.requestPermission()

        // Ensure at least one account exists
        if accountManager.accounts.isEmpty {
            accountManager.addAccount()
        }

        observeUnreadCounts()
        startFeedPolling()
        setupMainMenu()

        // Fetch profile images for accounts that already have emails
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            for account in self?.accountManager.accounts ?? [] {
                if account.email != nil, account.profileImageData == nil {
                    self?.fetchProfileImage(for: account)
                }
            }
        }
    }

    // MARK: - Main Menu (for keyboard shortcuts)

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About Peekmail", action: #selector(openPreferences), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Preferences...", action: #selector(openPreferences), keyEquivalent: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Peekmail", action: #selector(quitApp), keyEquivalent: "q"))
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu (for Cmd+C/V/X/A — nil target sends through responder chain to WKWebView)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: Selector(("cut:")), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: Selector(("copy:")), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: Selector(("paste:")), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: Selector(("selectAll:")), keyEquivalent: "a")
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // File menu (for Cmd+W)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(NSMenuItem(title: "Close Window", action: #selector(hideWindow), keyEquivalent: "w"))
        let fileMenuItem = NSMenuItem()
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // View menu (for Cmd+R)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(NSMenuItem(title: "Reload", action: #selector(reloadPage), keyEquivalent: "r"))
        let viewMenuItem = NSMenuItem()
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Menu Bar

    private func setupMenuBarIcon() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            updateMenuBarIcon(unreadCount: 0)
            button.action = #selector(statusBarButtonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self
        }
    }

    @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent!

        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            toggleMainWindow()
        }
    }

    private func toggleMainWindow() {
        if let window = mainWindow, window.isVisible {
            window.orderOut(nil)
        } else {
            showMainWindow()
        }
    }

    func showMainWindow() {
        if mainWindow == nil {
            createMainWindow()
        }

        guard let window = mainWindow else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createMainWindow() {
        let contentView = MainWindowView()
            .environmentObject(accountManager)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Peekmail"
        window.contentView = NSHostingView(rootView: contentView)
        window.center()
        window.setFrameAutosaveName("PeekmailMainWindow")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.backgroundColor = .white
        window.toolbar = NSToolbar()
        window.toolbar?.isVisible = false
        window.minSize = NSSize(width: 600, height: 400)
        window.collectionBehavior = [.moveToActiveSpace]

        self.mainWindow = window
    }

    // MARK: - Context Menu

    private func showContextMenu() {
        let menu = NSMenu()

        // Account list
        for (index, account) in accountManager.accounts.enumerated() {
            let title = account.email ?? "Account \(index + 1)"
            let item = NSMenuItem(title: title, action: #selector(switchAccount(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
            if index == accountManager.selectedIndex {
                item.state = .on
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Add Account", action: #selector(addAccount), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Compose New Email", action: #selector(composeEmail), keyEquivalent: "n"))
        menu.addItem(NSMenuItem(title: "Reload", action: #selector(reloadPage), keyEquivalent: "r"))
        menu.addItem(.separator())

        let showInDockItem = NSMenuItem(title: "Show in Dock", action: #selector(toggleShowInDock(_:)), keyEquivalent: "")
        showInDockItem.target = self
        showInDockItem.state = UserDefaults.standard.bool(forKey: "showInDock") ? .on : .off
        menu.addItem(showInDockItem)

        let audioItem = NSMenuItem(title: "Sound on New Mail", action: #selector(toggleAudioAlert(_:)), keyEquivalent: "")
        audioItem.target = self
        audioItem.state = UserDefaults.standard.bool(forKey: "audioAlerts") ? .on : .off
        menu.addItem(audioItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Preferences...", action: #selector(openPreferences), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Peekmail", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil // Reset so left-click works again
    }

    // MARK: - Menu Actions

    @objc private func switchAccount(_ sender: NSMenuItem) {
        accountManager.selectedIndex = sender.tag
        if mainWindow == nil || !mainWindow!.isVisible {
            showMainWindow()
        }
    }

    @objc private func addAccount() {
        accountManager.addAccount()
        accountManager.selectedIndex = accountManager.accounts.count - 1
        showMainWindow()
        observeUnreadCounts()
    }

    @objc private func hideWindow() {
        mainWindow?.orderOut(nil)
    }

    @objc private func composeEmail() {
        showMainWindow()
        accountManager.currentWebView?.load(URLRequest(url: URL(string: "https://mail.google.com/mail/u/0/#compose")!))
    }

    @objc func reloadPage() {
        accountManager.currentWebView?.reloadFromOrigin()
    }

    @objc private func toggleShowInDock(_ sender: NSMenuItem) {
        let current = UserDefaults.standard.bool(forKey: "showInDock")
        UserDefaults.standard.set(!current, forKey: "showInDock")
        setupActivationPolicy()
    }

    @objc private func toggleAudioAlert(_ sender: NSMenuItem) {
        let current = UserDefaults.standard.bool(forKey: "audioAlerts")
        UserDefaults.standard.set(!current, forKey: "audioAlerts")
    }

    @objc private func openPreferences() {
        if settingsWindow == nil {
            let settingsView = SettingsView()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 250),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Peekmail Preferences"
            window.contentView = NSHostingView(rootView: settingsView)
            window.center()
            window.isReleasedWhenClosed = false
            self.settingsWindow = window
        }

        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    func openPreferencesFromSidebar() {
        openPreferences()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Activation Policy

    private func setupActivationPolicy() {
        let showInDock = UserDefaults.standard.bool(forKey: "showInDock")
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }

    // MARK: - Unread Count

    func updateMenuBarIcon(unreadCount: Int) {
        guard let button = statusItem.button else { return }

        if unreadCount > 0 {
            button.image = drawEnvelopeIcon(filled: true)
            button.image?.isTemplate = false
            button.contentTintColor = nil
            button.title = " \(unreadCount)"
            // Style the title to match menu bar text
            let font = NSFont.menuBarFont(ofSize: 0)
            button.attributedTitle = NSAttributedString(
                string: " \(unreadCount)",
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor.controlTextColor,
                ]
            )
        } else {
            button.image = drawEnvelopeIcon(filled: false)
            button.image?.isTemplate = true
            button.contentTintColor = nil
            button.title = ""
            button.attributedTitle = NSAttributedString(string: "")
        }

        // Update dock badge
        DispatchQueue.main.async {
            if unreadCount > 0 {
                NSApp.dockTile.badgeLabel = "\(unreadCount)"
            } else {
                NSApp.dockTile.badgeLabel = nil
            }
            NSApp.dockTile.display()
        }
    }

    private func drawEnvelopeIcon(filled: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            let lineWidth: CGFloat = 1.5
            let inset = lineWidth / 2
            let bodyRect = NSRect(x: inset, y: inset, width: rect.width - lineWidth, height: rect.height - lineWidth)
            let cornerRadius: CGFloat = 1.5

            if filled {
                // Filled envelope using menu bar label color (adapts to light/dark)
                let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: cornerRadius, yRadius: cornerRadius)
                NSColor.controlTextColor.setFill()
                bodyPath.fill()

                // Transparent V flap (cut out from filled body)
                let flapPath = NSBezierPath()
                flapPath.move(to: NSPoint(x: inset, y: rect.height - inset))
                flapPath.line(to: NSPoint(x: rect.width / 2, y: rect.height * 0.38))
                flapPath.line(to: NSPoint(x: rect.width - inset, y: rect.height - inset))
                NSColor.clear.setStroke()
                flapPath.lineWidth = lineWidth
                flapPath.lineCapStyle = .round
                flapPath.lineJoinStyle = .round
                let ctx = NSGraphicsContext.current?.cgContext
                ctx?.setBlendMode(.clear)
                flapPath.stroke()
                ctx?.setBlendMode(.normal)
            } else {
                // Outline envelope
                let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: cornerRadius, yRadius: cornerRadius)
                NSColor.black.setStroke()
                bodyPath.lineWidth = lineWidth
                bodyPath.stroke()

                // V flap
                let flapPath = NSBezierPath()
                flapPath.move(to: NSPoint(x: inset, y: rect.height - inset))
                flapPath.line(to: NSPoint(x: rect.width / 2, y: rect.height * 0.38))
                flapPath.line(to: NSPoint(x: rect.width - inset, y: rect.height - inset))
                NSColor.black.setStroke()
                flapPath.lineWidth = lineWidth
                flapPath.lineCapStyle = .round
                flapPath.lineJoinStyle = .round
                flapPath.stroke()
            }
            return true
        }
        image.isTemplate = !filled
        return image
    }

    // MARK: - Title Observer (for extracting email address)

    func observeUnreadCounts() {
        titleObservations.removeAll()

        for account in accountManager.accounts {
            let observation = account.webView.observe(\.title, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async {
                    self?.handleTitleChange()
                }
            }
            titleObservations.append(observation)
        }
    }

    private func handleTitleChange() {
        for account in accountManager.accounts {
            let title = account.webView.title ?? ""
            if account.email == nil, let email = parseEmail(from: title) {
                account.email = email
                accountManager.saveAccounts()
                fetchProfileImage(for: account)
            }
        }
    }

    private func fetchProfileImage(for account: GmailAccount) {
        // Extract profile image URL from Gmail's page
        let js = """
        (function() {
            var img = document.querySelector('img.gb_l, img.gb_m, a[href*="accounts.google.com"] img, img[data-srcset*="googleusercontent"]');
            if (img) return img.src || img.getAttribute('data-srcset') || '';
            return '';
        })()
        """
        account.webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let urlString = result as? String, !urlString.isEmpty,
                  let url = URL(string: urlString) else {
                // Fallback: try again after a delay (Gmail may not have loaded the avatar yet)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    self?.retryFetchProfileImage(for: account, attempt: 1)
                }
                return
            }
            self?.downloadProfileImage(from: url, for: account)
        }
    }

    private func retryFetchProfileImage(for account: GmailAccount, attempt: Int) {
        guard attempt < 5, account.profileImageData == nil else { return }
        let js = """
        (function() {
            var imgs = document.querySelectorAll('img');
            for (var i = 0; i < imgs.length; i++) {
                var src = imgs[i].src || '';
                if (src.includes('googleusercontent.com') && (src.includes('photo') || src.includes('/a/'))) {
                    return src;
                }
            }
            return '';
        })()
        """
        account.webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let urlString = result as? String, !urlString.isEmpty,
                  let url = URL(string: urlString) else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    self?.retryFetchProfileImage(for: account, attempt: attempt + 1)
                }
                return
            }
            self?.downloadProfileImage(from: url, for: account)
        }
    }

    private func downloadProfileImage(from url: URL, for account: GmailAccount) {
        // Request a larger version of the image
        let largerURL: URL
        if url.absoluteString.contains("=s") {
            largerURL = URL(string: url.absoluteString.replacingOccurrences(of: #"=s\d+"#, with: "=s96", options: .regularExpression)) ?? url
        } else {
            largerURL = url
        }

        URLSession.shared.dataTask(with: largerURL) { data, _, _ in
            guard let data = data, NSImage(data: data) != nil else { return }
            DispatchQueue.main.async {
                account.profileImageData = data
            }
        }.resume()
    }

    private func parseEmail(from title: String) -> String? {
        let pattern = #"[\w.+-]+@[\w-]+\.[\w.]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
              let range = Range(match.range, in: title) else {
            return nil
        }
        return String(title[range])
    }

    // MARK: - Atom Feed Polling (for unread count)

    private func startFeedPolling() {
        // Poll immediately, then every 15 seconds
        pollAllAccounts()
        feedPollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.pollAllAccounts()
        }
    }

    private func pollAllAccounts() {
        for account in accountManager.accounts {
            // Skip accounts that haven't logged in yet (no email detected)
            guard account.email != nil else { continue }
            pollAtomFeed(for: account)
        }
    }

    private func pollAtomFeed(for account: GmailAccount) {
        let feedURL = URL(string: "https://mail.google.com/mail/feed/atom")!

        account.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            let googleCookies = cookies.filter { $0.domain.contains("google.com") || $0.domain.contains("gmail.com") }
            if googleCookies.isEmpty { return }

            let cookieHeader = googleCookies
                .map { "\($0.name)=\($0.value)" }
                .joined(separator: "; ")

            // Use an ephemeral session so cookies don't leak between accounts
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15
            // Inject only this account's WKWebView cookies
            for cookie in googleCookies {
                config.httpCookieStorage?.setCookie(cookie)
            }
            let session = URLSession(configuration: config)

            session.dataTask(with: URLRequest(url: feedURL)) { data, response, error in
                guard let data = data, error == nil else { return }

                let xml = String(data: data, encoding: .utf8) ?? ""
                let unread = self?.parseFullCount(from: xml) ?? 0
                let entries = self?.parseEntries(from: xml) ?? []

                DispatchQueue.main.async {
                    self?.handleFeedResult(for: account, unreadCount: unread, entries: entries)
                }
            }.resume()
        }
    }

    struct EmailEntry {
        let id: String
        let sender: String
        let subject: String
        let summary: String
        let link: String?
    }

    private func parseFullCount(from xml: String) -> Int {
        let pattern = #"<fullcount>(\d+)</fullcount>"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let range = Range(match.range(at: 1), in: xml) else {
            return 0
        }
        return Int(xml[range]) ?? 0
    }

    private func parseEntries(from xml: String) -> [EmailEntry] {
        var entries: [EmailEntry] = []

        // Match each <entry>...</entry> block
        let entryPattern = #"<entry>(.*?)</entry>"#
        guard let entryRegex = try? NSRegularExpression(pattern: entryPattern, options: .dotMatchesLineSeparators) else {
            return entries
        }

        let matches = entryRegex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))

        for match in matches {
            guard let entryRange = Range(match.range(at: 1), in: xml) else { continue }
            let entryXml = String(xml[entryRange])

            let id = extractTag("id", from: entryXml) ?? UUID().uuidString
            let subject = extractTag("title", from: entryXml) ?? "(no subject)"
            let summary = extractTag("summary", from: entryXml) ?? ""
            let sender = extractTag("name", from: entryXml) ?? "Unknown"
            let link = extractLinkHref(from: entryXml)

            entries.append(EmailEntry(id: id, sender: sender, subject: subject, summary: summary, link: link))
        }

        return entries
    }

    private func extractTag(_ tag: String, from xml: String) -> String? {
        let pattern = "<\(tag)>(.*?)</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators),
              let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let range = Range(match.range(at: 1), in: xml) else {
            return nil
        }
        // Decode basic XML entities
        return String(xml[range])
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    private func extractLinkHref(from xml: String) -> String? {
        let pattern = #"<link[^>]+href="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let range = Range(match.range(at: 1), in: xml) else {
            return nil
        }
        return String(xml[range])
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private let logger = Logger(subsystem: "com.peekmail.app", category: "feed")

    private func handleFeedResult(for account: GmailAccount, unreadCount: Int, entries: [EmailEntry]) {
        account.unreadCount = unreadCount

        let totalUnread = accountManager.accounts.reduce(0) { $0 + $1.unreadCount }
        logger.notice("Feed result: unread=\(unreadCount), entries=\(entries.count), total=\(totalUnread), firstPoll=\(!self.hasCompletedFirstPoll)")
        updateMenuBarIcon(unreadCount: totalUnread)

        if !hasCompletedFirstPoll {
            // First poll: seed all current email IDs so we don't spam notifications on launch
            for entry in entries {
                notifiedEmailIds.insert(entry.id)
            }
            hasCompletedFirstPoll = true
                return
        }

        // Subsequent polls: notify for any new emails
        var didNotify = false
        for entry in entries {
            if !notifiedEmailIds.contains(entry.id) {
                notifiedEmailIds.insert(entry.id)
                notificationManager.sendEmailNotification(
                    sender: entry.sender,
                    subject: entry.subject,
                    snippet: entry.summary,
                    link: entry.link,
                    accountId: account.id.uuidString
                )
                didNotify = true
            }
        }

        if didNotify && UserDefaults.standard.bool(forKey: "audioAlerts") {
            let soundName = UserDefaults.standard.string(forKey: "alertSound") ?? "Glass"
            NSSound(named: NSSound.Name(soundName))?.play()
        }

        // Keep notified set from growing unbounded
        if notifiedEmailIds.count > 200 {
            notifiedEmailIds = Set(notifiedEmailIds.suffix(100))
        }

    }
}

// MARK: - NSWindowDelegate

extension AppDelegate: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
