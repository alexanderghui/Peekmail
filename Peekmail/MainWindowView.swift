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

    // Very light blue-grey sidebar
    private let sidebarBg = Color(red: 0.933, green: 0.945, blue: 0.965)
    private let sidebarIconColor = Color(red: 0.3, green: 0.3, blue: 0.35)

    private var accountSidebar: some View {
        VStack(spacing: 0) {
            // Spacer for traffic light buttons
            Spacer()
                .frame(height: 40)

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
                            .stroke(Color(red: 0.7, green: 0.72, blue: 0.76), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                            .frame(width: 44, height: 44)

                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(Color(red: 0.5, green: 0.52, blue: 0.56))
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
                        .frame(width: 50, height: 50)
                }

                // Avatar
                if let imageData = account.profileImageData, let nsImage = NSImage(data: imageData) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 44, height: 44)
                        .clipShape(Circle())
                } else {
                    // Fallback: Google-style person silhouette for not-yet-logged-in, initial letter for logged in
                    Circle()
                        .fill(account.email == nil ? Color(red: 0.72, green: 0.74, blue: 0.78) : Color.gray.opacity(0.5))
                        .frame(width: 44, height: 44)
                        .overlay(
                            Group {
                                if account.email == nil {
                                    Image(systemName: "person.fill")
                                        .font(.system(size: 22, weight: .regular))
                                        .foregroundColor(.white.opacity(0.85))
                                } else {
                                    Text(accountInitial)
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundColor(.white)
                                }
                            }
                        )
                }

                // Unread badge
                if account.unreadCount > 0 {
                    Text("\(account.unreadCount)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.red)
                        .clipShape(Capsule())
                        .offset(x: 18, y: -18)
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
