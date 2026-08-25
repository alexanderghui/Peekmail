import Foundation
import WebKit
import Combine

final class ProfileImageMessageHandler: NSObject, WKScriptMessageHandler {
    static var onCandidate: ((UUID, URL) -> Void)?

    private let accountID: UUID

    init(accountID: UUID) {
        self.accountID = accountID
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let source = message.body as? String, let url = URL(string: source) else { return }
        Self.onCandidate?(accountID, url)
    }
}

class GmailAccount: ObservableObject, Identifiable {
    let id: UUID
    let webView: WKWebView
    @Published var email: String?
    @Published var unreadCount: Int = 0
    @Published var profileImageData: Data?
    @Published var usesProfileImageForGoogleControl: Bool
    private let profileImageMessageHandler: ProfileImageMessageHandler

    init(id: UUID = UUID(), email: String? = nil, isNew: Bool = false) {
        self.id = id
        self.email = email
        self.profileImageMessageHandler = ProfileImageMessageHandler(accountID: id)
        let defaults = UserDefaults.standard
        if defaults.integer(forKey: Self.profileImageVersionKey(for: id)) == Self.profileImageCacheVersion {
            self.profileImageData = defaults.data(forKey: Self.profileImageKey(for: id))
            self.usesProfileImageForGoogleControl = defaults.bool(forKey: Self.profileImageControlKey(for: id))
        } else {
            self.profileImageData = nil
            self.usesProfileImageForGoogleControl = false
            defaults.removeObject(forKey: Self.profileImageKey(for: id))
            defaults.removeObject(forKey: Self.profileImageVersionKey(for: id))
            defaults.removeObject(forKey: Self.profileImageControlKey(for: id))
        }

        // Each account gets its own isolated data store so cookies/sessions are separate.
        // This allows multiple Gmail accounts to be logged in simultaneously.
        let config = WKWebViewConfiguration()
        let dataStore = WKWebsiteDataStore(forIdentifier: id)
        config.websiteDataStore = dataStore
        config.userContentController.add(profileImageMessageHandler, name: "profileImageCandidate")
        let profileImageScript = WKUserScript(
            source: """
            (function() {
                var allowedHosts = ['accounts.google.com', 'ogs.google.com', 'myaccount.google.com'];
                if (!allowedHosts.some(function(host) { return location.hostname === host || location.hostname.endsWith('.' + host); })) return;

                function reportProfileImage() {
                    var images = Array.from(document.images).filter(function(image) {
                        var source = image.currentSrc || image.src || '';
                        return image.complete && image.naturalWidth >= 32 && image.naturalHeight >= 32 &&
                            source.indexOf('googleusercontent.com') !== -1 && source.indexOf('/ogw/') === -1;
                    });
                    images.sort(function(a, b) {
                        var aLabel = ((a.alt || '') + ' ' + (a.getAttribute('aria-label') || '')).toLowerCase();
                        var bLabel = ((b.alt || '') + ' ' + (b.getAttribute('aria-label') || '')).toLowerCase();
                        var aScore = aLabel.indexOf('profile') !== -1 ? 1 : 0;
                        var bScore = bLabel.indexOf('profile') !== -1 ? 1 : 0;
                        if (aScore !== bScore) return bScore - aScore;
                        return (b.naturalWidth * b.naturalHeight) - (a.naturalWidth * a.naturalHeight);
                    });
                    if (images.length > 0) {
                        window.webkit.messageHandlers.profileImageCandidate.postMessage(images[0].currentSrc || images[0].src);
                    }
                }

                reportProfileImage();
                new MutationObserver(reportProfileImage).observe(document.documentElement, {
                    childList: true,
                    subtree: true,
                    attributes: true,
                    attributeFilter: ['src']
                });
            })();
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(profileImageScript)

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

    static func profileImageKey(for id: UUID) -> String {
        "profileImage.\(id.uuidString)"
    }

    static func profileImageVersionKey(for id: UUID) -> String {
        "profileImageVersion.\(id.uuidString)"
    }

    static func profileImageControlKey(for id: UUID) -> String {
        "profileImageForGoogleControl.\(id.uuidString)"
    }

    static let profileImageCacheVersion = 3
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
        UserDefaults.standard.removeObject(forKey: GmailAccount.profileImageKey(for: account.id))
        UserDefaults.standard.removeObject(forKey: GmailAccount.profileImageVersionKey(for: account.id))
        UserDefaults.standard.removeObject(forKey: GmailAccount.profileImageControlKey(for: account.id))
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

    func setProfileImageData(
        _ data: Data,
        for account: GmailAccount,
        useForGoogleControl: Bool = false
    ) {
        guard accounts.contains(where: { $0.id == account.id }) else { return }
        account.profileImageData = data
        account.usesProfileImageForGoogleControl = useForGoogleControl
        UserDefaults.standard.set(data, forKey: GmailAccount.profileImageKey(for: account.id))
        UserDefaults.standard.set(
            GmailAccount.profileImageCacheVersion,
            forKey: GmailAccount.profileImageVersionKey(for: account.id)
        )
        UserDefaults.standard.set(
            useForGoogleControl,
            forKey: GmailAccount.profileImageControlKey(for: account.id)
        )
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
