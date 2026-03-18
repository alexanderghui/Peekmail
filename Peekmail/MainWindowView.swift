import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject var accountManager: AccountManager

    var body: some View {
        HStack(spacing: 0) {
            // Always show sidebar
            accountSidebar

            // Gmail WebView for selected account
            // .id() forces SwiftUI to recreate the view when switching accounts
            // (otherwise updateNSView is called on the old webview, not the new one)
            if accountManager.selectedIndex < accountManager.accounts.count {
                let account = accountManager.accounts[accountManager.selectedIndex]
                GmailWebView(webView: account.webView)
                    .id(account.id)
            } else {
                Text("No accounts configured")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // Gmail dark sidebar color: #1a1a1a / rgb(26,26,26) for dark theme
    // Gmail light sidebar: #f6f8fc — we'll use the dark one to match Gmail's dark mode
    private let sidebarBg = Color(red: 0.16, green: 0.16, blue: 0.16)
    private let sidebarIconColor = Color.white.opacity(0.55)

    private var accountSidebar: some View {
        VStack(spacing: 0) {
            // Back/Forward navigation — pushed below traffic lights
            HStack(spacing: 6) {
                Button(action: goBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(sidebarIconColor)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)

                Button(action: goForward) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(sidebarIconColor)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 40) // space for traffic light buttons
            .padding(.bottom, 12)

            // Account avatars
            VStack(spacing: 12) {
                ForEach(Array(accountManager.accounts.enumerated()), id: \.element.id) { index, account in
                    AccountAvatarButton(
                        account: account,
                        isSelected: index == accountManager.selectedIndex,
                        action: {
                            accountManager.selectedIndex = index
                        },
                        onRemove: accountManager.accounts.count > 1 ? {
                            removeAccount(at: index)
                        } : nil
                    )
                }

                // Add account button
                Button(action: addAccount) {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.15))
                            .frame(width: 38, height: 38)

                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(Color.white.opacity(0.7))
                    }
                }
                .buttonStyle(.plain)
                .help("Add Account")
            }

            Spacer()

            // Bottom actions
            VStack(spacing: 18) {
                Button(action: reloadPage) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(sidebarIconColor)
                }
                .buttonStyle(.plain)
                .help("Reload")

                Button(action: openSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(sidebarIconColor)
                }
                .buttonStyle(.plain)
                .help("Settings")
            }
            .padding(.bottom, 18)
        }
        .frame(width: 80)
        .background(sidebarBg)
    }

    private func addAccount() {
        accountManager.addAccount()
        accountManager.selectedIndex = accountManager.accounts.count - 1

        if let appDelegate = AppDelegate.shared {
            appDelegate.observeUnreadCounts()
        }
    }

    private func removeAccount(at index: Int) {
        accountManager.removeAccount(at: index)

        if let appDelegate = AppDelegate.shared {
            appDelegate.observeUnreadCounts()
        }
    }

    private func goBack() {
        accountManager.currentWebView?.goBack()
    }

    private func goForward() {
        accountManager.currentWebView?.goForward()
    }

    private func reloadPage() {
        accountManager.currentWebView?.reloadFromOrigin()
    }

    private func openSettings() {
        AppDelegate.shared?.openPreferencesFromSidebar()
    }
}

struct AccountAvatarButton: View {
    @ObservedObject var account: GmailAccount
    let isSelected: Bool
    let action: () -> Void
    var onRemove: (() -> Void)?

    var body: some View {
        Button(action: action) {
            ZStack {
                // Selection ring
                if isSelected {
                    Circle()
                        .stroke(Color.blue, lineWidth: 2.5)
                        .frame(width: 44, height: 44)
                }

                // Avatar
                if let imageData = account.profileImageData, let nsImage = NSImage(data: imageData) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 38, height: 38)
                        .clipShape(Circle())
                } else {
                    // Fallback: person icon for not-yet-logged-in, initial letter for logged in
                    Circle()
                        .fill(Color.gray.opacity(0.5))
                        .frame(width: 38, height: 38)
                        .overlay(
                            Group {
                                if account.email == nil {
                                    Image(systemName: "person.fill")
                                        .font(.system(size: 18, weight: .medium))
                                        .foregroundColor(.white.opacity(0.7))
                                } else {
                                    Text(accountInitial)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(.white)
                                }
                            }
                        )
                }

                // Unread badge
                if account.unreadCount > 0 {
                    Text("\(account.unreadCount)")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.red)
                        .clipShape(Capsule())
                        .offset(x: 16, y: -16)
                }
            }
        }
        .buttonStyle(.plain)
        .help(account.email ?? "Gmail Account")
        .contextMenu {
            if let email = account.email {
                Text(email)
            }
            if let onRemove = onRemove {
                Divider()
                Button(role: .destructive, action: onRemove) {
                    Label("Remove Account", systemImage: "trash")
                }
            }
        }
    }

    private var accountInitial: String {
        if let email = account.email, let first = email.first {
            return String(first).uppercased()
        }
        return "G"
    }
}
