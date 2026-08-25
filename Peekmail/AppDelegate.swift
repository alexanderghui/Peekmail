import AppKit
import SwiftUI
import WebKit
import os

class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate!

    private var statusItem: NSStatusItem?
    private var mainWindow: NSWindow?
    private var mainWindowFrameBeforeHiding: NSRect?
    private var settingsWindow: NSWindow?
    private var accountManager = AccountManager.shared
    private var notificationManager = NotificationManager.shared
    private let updateChecker = UpdateChecker.shared
    private var webViewObservations: [NSKeyValueObservation] = []
    private var feedPollTimer: Timer?
    private var statusItemHealthTimer: Timer?
    private var profileImageRetryWorkItems: [UUID: DispatchWorkItem] = [:]
    private var profileImageDownloads: Set<UUID> = []
    private var notifiedEmailIds: Set<String> = []
    private var hasCompletedFirstPoll = false
    private var lastTitlePollTime: Date = .distantPast
    private var currentUnreadCount = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        ProfileImageMessageHandler.onCandidate = { [weak self] accountID, url in
            DispatchQueue.main.async {
                self?.handleProfileImageCandidate(accountID: accountID, url: url)
            }
        }
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

        statusItemHealthTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.ensureStatusItem()
        }

        // Fetch the visible account's profile image after Gmail has rendered.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self,
                  self.accountManager.selectedIndex < self.accountManager.accounts.count else { return }
            let account = self.accountManager.accounts[self.accountManager.selectedIndex]
            if account.email != nil {
                if account.profileImageData == nil {
                    self.fetchProfileImage(for: account)
                } else {
                    self.applyProfileImageToGoogleControl(for: account)
                }
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        ensureStatusItem()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    // MARK: - Main Menu (for keyboard shortcuts)

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About Peekmail", action: #selector(openPreferences), keyEquivalent: ""))
        appMenu.addItem(.separator())
        let checkForUpdatesItem = NSMenuItem(
            title: "Check for Updates...",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        checkForUpdatesItem.target = self
        appMenu.addItem(checkForUpdatesItem)
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

    @objc private func checkForUpdates() {
        updateChecker.checkManually()
    }

    // MARK: - Menu Bar

    private func setupMenuBarIcon() {
        ensureStatusItem()
    }

    private func ensureStatusItem() {
        if statusItem == nil || statusItem?.button == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

            if let button = statusItem?.button {
                button.action = #selector(statusBarButtonClicked(_:))
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
                button.target = self
            }
        }

        statusItem?.isVisible = true
        renderMenuBarIcon(unreadCount: currentUnreadCount)
    }

    @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu(relativeTo: sender)
        } else {
            toggleMainWindow()
        }
    }

    private func toggleMainWindow() {
        if let window = mainWindow, window.isVisible {
            hideMainWindow()
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
        restoreMainWindowFrameIfNeeded(window)

        if accountManager.selectedIndex < accountManager.accounts.count {
            refreshProfileImage(for: accountManager.accounts[accountManager.selectedIndex])
        }
    }

    private func hideMainWindow() {
        guard let window = mainWindow else { return }

        if !window.styleMask.contains(.fullScreen) {
            mainWindowFrameBeforeHiding = window.frame
        }

        window.orderOut(nil)
        ensureStatusItem()
    }

    private func restoreMainWindowFrameIfNeeded(_ window: NSWindow) {
        guard let preservedFrame = mainWindowFrameBeforeHiding,
              !window.styleMask.contains(.fullScreen) else { return }

        window.setFrame(preservedFrame, display: true)

        // Moving the window to the active Space can adjust its frame after it is ordered in.
        DispatchQueue.main.async { [weak window] in
            guard let window, window.isVisible,
                  !window.styleMask.contains(.fullScreen),
                  window.frame != preservedFrame else { return }
            window.setFrame(preservedFrame, display: true)
        }
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
        window.setFrameAutosaveName("PeekmailMainWindow")

        self.mainWindow = window
        mainWindowFrameBeforeHiding = window.frame
    }

    // MARK: - Context Menu

    private func showContextMenu(relativeTo button: NSStatusBarButton) {
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
        let addAccountItem = NSMenuItem(title: "Add Account", action: #selector(addAccount), keyEquivalent: "")
        addAccountItem.target = self
        menu.addItem(addAccountItem)
        menu.addItem(.separator())
        let composeItem = NSMenuItem(title: "Compose New Email", action: #selector(composeEmail), keyEquivalent: "n")
        composeItem.target = self
        menu.addItem(composeItem)
        let reloadItem = NSMenuItem(title: "Reload", action: #selector(reloadPage), keyEquivalent: "r")
        reloadItem.target = self
        menu.addItem(reloadItem)
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
        let preferencesItem = NSMenuItem(title: "Preferences...", action: #selector(openPreferences), keyEquivalent: ",")
        preferencesItem.target = self
        menu.addItem(preferencesItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Peekmail", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.height + 2),
            in: button
        )
    }

    // MARK: - Menu Actions

    @objc private func switchAccount(_ sender: NSMenuItem) {
        accountManager.selectedIndex = sender.tag
        if sender.tag < accountManager.accounts.count {
            refreshProfileImage(for: accountManager.accounts[sender.tag])
        }
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
        hideMainWindow()
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
        currentUnreadCount = unreadCount
        ensureStatusItem()
    }

    private func renderMenuBarIcon(unreadCount: Int) {
        guard let button = statusItem?.button else { return }

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
        webViewObservations.removeAll()

        for account in accountManager.accounts {
            let titleObservation = account.webView.observe(\.title, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async {
                    self?.handleTitleChange()
                }
            }
            webViewObservations.append(titleObservation)

            let loadObservation = account.webView.observe(\.estimatedProgress, options: [.new]) { [weak self, weak account] _, change in
                guard let account, (change.newValue ?? 0) >= 1 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    if self?.accountManager.currentWebView === account.webView,
                       account.email != nil {
                        if account.profileImageData == nil {
                            self?.fetchProfileImage(for: account)
                        } else {
                            self?.applyProfileImageToGoogleControl(for: account)
                        }
                    }
                }
            }
            webViewObservations.append(loadObservation)
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

    private let profileLogger = Logger(subsystem: "com.peekmail.app", category: "profile")

    func refreshProfileImage(for account: GmailAccount) {
        if account.profileImageData != nil {
            applyProfileImageToGoogleControl(for: account)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak account] in
            guard let self, let account,
                  self.accountManager.currentWebView === account.webView else { return }
            self.fetchProfileImage(for: account)
        }
    }

    private func fetchProfileImage(for account: GmailAccount, attempt: Int = 0) {
        guard account.profileImageData == nil,
              accountManager.currentWebView === account.webView else { return }

        // Snapshot Gmail's complete account control so Google-provided decorations around
        // the profile photo are preserved instead of caching only the inner image.
        let expectedEmailLiteral = String(reflecting: account.email ?? "")
        let js = """
        (function() {
            var expectedEmail = \(expectedEmailLiteral);

            function isVisibleTopRight(element) {
                if (!element) return false;
                var rect = element.getBoundingClientRect();
                var style = window.getComputedStyle(element);
                if (style.display === 'none' || style.visibility === 'hidden' || Number(style.opacity) === 0) return false;
                if (element.checkVisibility && !element.checkVisibility({checkOpacity: true, checkVisibilityCSS: true})) return false;
                var hit = document.elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2);
                return rect.width >= 24 && rect.height >= 24 &&
                    rect.top >= 0 && rect.top < 180 &&
                    rect.right > window.innerWidth - 260 &&
                    hit && (hit === element || element.contains(hit) || hit.contains(element));
            }

            var controls = Array.from(document.querySelectorAll(
                '[aria-label*="Google Account"], a[href*="SignOutOptions"]'
            )).filter(isVisibleTopRight);

            controls.sort(function(a, b) {
                var aMatches = (a.getAttribute('aria-label') || '').indexOf(expectedEmail) !== -1 ? 1 : 0;
                var bMatches = (b.getAttribute('aria-label') || '').indexOf(expectedEmail) !== -1 ? 1 : 0;
                if (aMatches !== bMatches) return bMatches - aMatches;
                return b.getBoundingClientRect().right - a.getBoundingClientRect().right;
            });

            function payloadForControl(control) {
                var controlRect = control.getBoundingClientRect();
                if (isVisibleTopRight(control) &&
                    controlRect.width >= 28 && controlRect.width <= 64 &&
                    controlRect.height >= 28 && controlRect.height <= 64 &&
                    Math.abs(controlRect.width - controlRect.height) <= 8) {
                    return {
                        x: controlRect.x,
                        y: controlRect.y,
                        width: controlRect.width,
                        height: controlRect.height
                    };
                }

                var elements = [control].concat(Array.from(control.querySelectorAll('*')));
                var avatarElements = elements.filter(function(element) {
                    var rect = element.getBoundingClientRect();
                    return isVisibleTopRight(element) &&
                        rect.width >= 24 && rect.width <= 64 &&
                        rect.height >= 24 && rect.height <= 64 &&
                        Math.abs(rect.width - rect.height) <= 8;
                });

                avatarElements.sort(function(a, b) {
                    var aRect = a.getBoundingClientRect();
                    var bRect = b.getBoundingClientRect();
                    return (bRect.width * bRect.height) - (aRect.width * aRect.height);
                });

                var avatar = avatarElements[0];
                if (!avatar) return null;
                var rect = avatar.getBoundingClientRect();
                return {
                    x: rect.x,
                    y: rect.y,
                    width: rect.width,
                    height: rect.height
                };
            }

            for (var i = 0; i < controls.length; i++) {
                var payload = payloadForControl(controls[i]);
                if (payload) return payload;
            }
            return null;
        })()
        """
        account.webView.evaluateJavaScript(js) { [weak self, weak account] result, error in
            guard let self, let account else { return }
            guard let payload = result as? [String: Any] else {
                if let error {
                    self.profileLogger.debug("Avatar lookup failed for account \(account.id): \(error.localizedDescription, privacy: .public)")
                }
                self.scheduleProfileImageRetry(for: account, attempt: attempt + 1)
                return
            }

            guard let x = payload["x"] as? Double,
                  let y = payload["y"] as? Double,
                  let width = payload["width"] as? Double,
                  let height = payload["height"] as? Double,
                  width >= 24,
                  height >= 24 else {
                self.scheduleProfileImageRetry(for: account, attempt: attempt + 1)
                return
            }

            self.snapshotProfileImage(
                in: CGRect(x: x, y: y, width: width, height: height),
                for: account,
                attempt: attempt
            )
        }
    }

    private func snapshotProfileImage(in rect: CGRect, for account: GmailAccount, attempt: Int) {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = rect

        account.webView.takeSnapshot(with: configuration) { [weak self, weak account] image, error in
            guard let self, let account else { return }
            if let image,
               let tiffData = image.tiffRepresentation,
               let representation = NSBitmapImageRep(data: tiffData),
               let pngData = representation.representation(using: .png, properties: [:]) {
                if self.isLikelyGeneratedInitial(representation) {
                    self.requestProfileImageFromAccountPanel(for: account, attempt: attempt)
                    return
                }
                DispatchQueue.main.async {
                    self.profileImageRetryWorkItems[account.id]?.cancel()
                    self.profileImageRetryWorkItems[account.id] = nil
                    self.accountManager.setProfileImageData(pngData, for: account)
                }
                return
            }

            if let error {
                self.profileLogger.debug("Avatar snapshot failed for account \(account.id): \(error.localizedDescription, privacy: .public)")
            }
            self.scheduleProfileImageRetry(for: account, attempt: attempt + 1)
        }
    }

    private func isLikelyGeneratedInitial(_ image: NSBitmapImageRep) -> Bool {
        var colorCounts: [Int: Int] = [:]
        var opaquePixelCount = 0

        for y in 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.5 else { continue }
                let red = Int(color.redComponent * 15)
                let green = Int(color.greenComponent * 15)
                let blue = Int(color.blueComponent * 15)
                let bucket = (red << 8) | (green << 4) | blue
                colorCounts[bucket, default: 0] += 1
                opaquePixelCount += 1
            }
        }

        guard opaquePixelCount > 0, let dominantCount = colorCounts.values.max() else { return false }
        let dominantRatio = Double(dominantCount) / Double(opaquePixelCount)
        return colorCounts.count < 80 && dominantRatio > 0.5
    }

    private func requestProfileImageFromAccountPanel(for account: GmailAccount, attempt: Int) {
        let js = """
        (function() {
            var controls = Array.from(document.querySelectorAll(
                '[aria-label*="Google Account"], a[href*="SignOutOptions"]'
            ));
            var control = controls.find(function(candidate) {
                return (candidate.getAttribute('aria-label') || '').indexOf('Google Account') !== -1;
            }) || controls[0];
            if (control && control.getAttribute('aria-expanded') !== 'true') {
                control.click();
                control.blur();
            }
        })()
        """
        account.webView.evaluateJavaScript(js, completionHandler: nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self, weak account] in
            guard let self, let account,
                  account.profileImageData == nil,
                  !self.profileImageDownloads.contains(account.id) else { return }
            self.closeAccountPanel(for: account)
            self.scheduleProfileImageRetry(for: account, attempt: attempt + 1)
        }
    }

    private func handleProfileImageCandidate(accountID: UUID, url: URL) {
        guard let account = accountManager.accounts.first(where: { $0.id == accountID }),
              account.profileImageData == nil,
              !profileImageDownloads.contains(accountID) else { return }
        profileImageDownloads.insert(accountID)
        downloadProfileImage(from: url, for: account)
    }

    private func downloadProfileImage(from url: URL, for account: GmailAccount) {
        account.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self, weak account] cookies in
            guard let self, let account else { return }
            let configuration = URLSessionConfiguration.ephemeral
            cookies.forEach { configuration.httpCookieStorage?.setCookie($0) }
            URLSession(configuration: configuration).dataTask(with: url) { [weak self, weak account] data, _, error in
                guard let self, let account else { return }
                guard let data,
                      let image = NSImage(data: data),
                      let tiffData = image.tiffRepresentation,
                      let representation = NSBitmapImageRep(data: tiffData),
                      !self.isLikelyGeneratedInitial(representation),
                      let pngData = representation.representation(using: .png, properties: [:]) else {
                    if let error {
                        self.profileLogger.debug("Profile image download failed for account \(account.id): \(error.localizedDescription, privacy: .public)")
                    }
                    DispatchQueue.main.async {
                        self.profileImageDownloads.remove(account.id)
                        self.scheduleProfileImageRetry(for: account, attempt: 1)
                    }
                    return
                }

                DispatchQueue.main.async {
                    self.profileImageDownloads.remove(account.id)
                    self.profileImageRetryWorkItems[account.id]?.cancel()
                    self.profileImageRetryWorkItems[account.id] = nil
                    self.accountManager.setProfileImageData(
                        pngData,
                        for: account,
                        useForGoogleControl: true
                    )
                    self.applyProfileImageToGoogleControl(for: account)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        self.closeAccountPanel(for: account)
                    }
                }
            }.resume()
        }
    }

    private func applyProfileImageToGoogleControl(for account: GmailAccount) {
        guard account.usesProfileImageForGoogleControl,
              let data = account.profileImageData else { return }
        let source = "data:image/png;base64,\(data.base64EncodedString())"
        let sourceLiteral = String(reflecting: source)
        let js = """
        (function() {
            var source = \(sourceLiteral);
            function applyPhoto() {
                var images = Array.from(document.images).filter(function(image) {
                    var rect = image.getBoundingClientRect();
                    return rect.width >= 24 && rect.width <= 64 &&
                        rect.height >= 24 && rect.height <= 64 &&
                        Math.abs(rect.width - rect.height) <= 8 &&
                        rect.top >= 0 && rect.top < 100 &&
                        rect.right > window.innerWidth - 90;
                });
                images.sort(function(a, b) {
                    return b.getBoundingClientRect().right - a.getBoundingClientRect().right;
                });
                var image = images[0];
                if (!image || image.src === source) return;
                image.removeAttribute('srcset');
                image.src = source;
            }

            if (window.__peekmailProfileControlObserver) {
                window.__peekmailProfileControlObserver.disconnect();
            }
            window.__peekmailProfileControlObserver = new MutationObserver(applyPhoto);
            window.__peekmailProfileControlObserver.observe(document.documentElement, {
                childList: true,
                subtree: true,
                attributes: true,
                attributeFilter: ['src', 'srcset']
            });
            applyPhoto();
        })()
        """
        account.webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func closeAccountPanel(for account: GmailAccount) {
        let js = """
        (function() {
            var controls = Array.from(document.querySelectorAll(
                '[aria-label*="Google Account"], a[href*="SignOutOptions"]'
            ));
            var expanded = controls.find(function(control) {
                return control.getAttribute('aria-expanded') === 'true';
            });
            if (expanded) {
                expanded.click();
                expanded.blur();
            }
            if (document.activeElement && document.activeElement.blur) {
                document.activeElement.blur();
            }
        })()
        """
        account.webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func scheduleProfileImageRetry(for account: GmailAccount, attempt: Int) {
        guard attempt <= 12,
              account.profileImageData == nil,
              accountManager.currentWebView === account.webView else { return }

        profileImageRetryWorkItems[account.id]?.cancel()
        let workItem = DispatchWorkItem { [weak self, weak account] in
            guard let self, let account,
                  account.profileImageData == nil,
                  self.accountManager.currentWebView === account.webView else { return }
            self.fetchProfileImage(for: account, attempt: attempt)
        }
        profileImageRetryWorkItems[account.id] = workItem
        let delay = min(2.0 + Double(attempt), 10.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
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
        if sender === mainWindow {
            hideMainWindow()
        } else {
            sender.orderOut(nil)
        }
        return false
    }
}
