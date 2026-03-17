import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject var accountManager: AccountManager

    var body: some View {
        HStack(spacing: 0) {
            // Account sidebar (only show if multiple accounts)
            if accountManager.accounts.count > 1 {
                accountSidebar
            }

            // Gmail WebView for selected account
            if accountManager.selectedIndex < accountManager.accounts.count {
                GmailWebView(webView: accountManager.accounts[accountManager.selectedIndex].webView)
            } else {
                Text("No accounts configured")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var accountSidebar: some View {
        VStack(spacing: 8) {
            ForEach(Array(accountManager.accounts.enumerated()), id: \.element.id) { index, account in
                AccountButton(
                    account: account,
                    isSelected: index == accountManager.selectedIndex
                ) {
                    accountManager.selectedIndex = index
                }
            }

            Spacer()

            Button(action: addAccount) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 20))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 12)
        }
        .padding(.top, 12)
        .frame(width: 52)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func addAccount() {
        accountManager.addAccount()
        accountManager.selectedIndex = accountManager.accounts.count - 1

        // Re-observe titles
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.observeUnreadCounts()
        }
    }
}

struct AccountButton: View {
    @ObservedObject var account: GmailAccount
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isSelected ? Color.accentColor : Color.gray.opacity(0.3))
                    .frame(width: 36, height: 36)

                Text(accountInitial)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)

                // Unread badge
                if account.unreadCount > 0 {
                    Text("\(account.unreadCount)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.red)
                        .clipShape(Capsule())
                        .offset(x: 12, y: -12)
                }
            }
        }
        .buttonStyle(.plain)
        .help(account.email ?? "Gmail Account")
    }

    private var accountInitial: String {
        if let email = account.email, let first = email.first {
            return String(first).uppercased()
        }
        return "G"
    }
}
