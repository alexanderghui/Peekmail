import Foundation
import WebKit
import Combine

class GmailAccount: ObservableObject, Identifiable {
    let id: UUID
    let webView: WKWebView
    @Published var email: String?
    @Published var unreadCount: Int = 0
    @Published var profileImageData: Data?

    init(id: UUID = UUID(), email: String? = nil, isNew: Bool = false) {
        self.id = id
        self.email = email

        // Each account gets its own isolated data store so cookies/sessions are separate.
        // This allows multiple Gmail accounts to be logged in simultaneously.
        let config = WKWebViewConfiguration()
        let dataStore = WKWebsiteDataStore(forIdentifier: id)
        config.websiteDataStore = dataStore

        self.webView = EditableWKWebView(frame: .zero, configuration: config)
        self.webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

        if isNew || email == nil {
            // New or not-yet-logged-in account: clear data and show Google sign-in
            dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in
                DispatchQueue.main.async {
                    let signInURL = URL(string: "https://accounts.google.com/ServiceLogin?service=mail&continue=https://mail.google.com/mail/")!
                    self?.webView.load(URLRequest(url: signInURL))
                }
            }
        } else {
            // Existing logged-in account: load Gmail directly (session restored from isolated data store)
            self.webView.load(URLRequest(url: URL(string: "https://mail.google.com")!))
        }
    }
}

class AccountManager: ObservableObject {
    static let shared = AccountManager()

    @Published var accounts: [GmailAccount] = []
    @Published var selectedIndex: Int = 0

    var currentWebView: WKWebView? {
        guard selectedIndex >= 0, selectedIndex < accounts.count else { return nil }
        return accounts[selectedIndex].webView
    }

    private init() {
        loadAccounts()
    }

    func addAccount() {
        let account = GmailAccount(isNew: true)
        accounts.append(account)
        saveAccounts()
    }

    func removeAccount(at index: Int) {
        guard index >= 0, index < accounts.count else { return }

        // Clear the data store for the removed account
        let account = accounts[index]
        account.webView.configuration.websiteDataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        ) {}

        accounts.remove(at: index)

        if selectedIndex >= accounts.count {
            selectedIndex = max(0, accounts.count - 1)
        }

        saveAccounts()
    }

    // MARK: - Persistence

    func saveAccounts() {
        let data = accounts.map { ["id": $0.id.uuidString, "email": $0.email ?? ""] }
        UserDefaults.standard.set(data, forKey: "accounts")
    }

    private func loadAccounts() {
        guard let data = UserDefaults.standard.array(forKey: "accounts") as? [[String: String]] else {
            return
        }

        for item in data {
            guard let idString = item["id"], let id = UUID(uuidString: idString) else { continue }
            let email = item["email"]?.isEmpty == true ? nil : item["email"]
            let account = GmailAccount(id: id, email: email)
            accounts.append(account)
        }
    }
}
