#if os(iOS)
import SwiftUI
import Perception
import TVCore
import WebKit

/// Every presentation owns an ephemeral WebKit store and one bounded status
/// check. A dismissed browser cannot persist a late login callback.
struct MangaWebLoginView: View {
    let source: String
    let url: URL
    let completion: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var session = MangaWebLoginSession()

    var body: some View {
        WithPerceptionTracking {
            NavigationStack {
                VStack(spacing: 0) {
                    if let failure = session.failure {
                        Text(failure).font(.footnote).foregroundStyle(.secondary).padding(12)
                    }
                    if let web = session.web { MangaLoginWebView(web: web) }
                    else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                }
                .navigationTitle("登录账号").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { session.stop(); dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button { session.verify() } label: {
                            if session.checking { ProgressView() } else { Text("完成登录") }
                        }.disabled(session.checking || session.web == nil)
                    }
                }
            }
            .task { await session.start(source: source, url: url) { completion(); dismiss() } }
            .onDisappear { session.stop() }
        }
    }
}

private struct MangaLoginWebView: UIViewRepresentable {
    let web: WKWebView
    func makeUIView(context: Context) -> WKWebView { web }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ uiView: WKWebView, coordinator: ()) { uiView.stopLoading() }
}

@MainActor @Perceptible final class MangaWebLoginSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    private(set) var web: WKWebView?
    private(set) var checking = false
    var failure: String?
    @PerceptionIgnored private var source = ""
    @PerceptionIgnored private var loginURL: URL?
    @PerceptionIgnored private var generation = UUID()
    @PerceptionIgnored private var operation: Task<Void, Never>?
    @PerceptionIgnored private var request: MangaWebLoginRequest?
    @PerceptionIgnored private var onSuccess: (() -> Void)?
    @PerceptionIgnored private var observation: NSKeyValueObservation?
    @PerceptionIgnored private var lastCheck = ""

    func start(source: String, url: URL, completed: @escaping () -> Void) async {
        guard web == nil else { return }
        self.source = source; loginURL = url; onSuccess = completed
        let id = UUID(); generation = id
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let saved = MangaCookieJar.webCookies(source)
        for cookie in saved {
            await configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
            guard !Task.isCancelled, generation == id else { return }
        }
        if let storage = MangaSourceData.shared.value(source, "_localStorage") as? [String: String],
           let encoded = try? JSONSerialization.data(withJSONObject: storage),
           let origin = URLComponents(url: url, resolvingAgainstBaseURL: false).map({ value -> String in
               var origin = value; origin.path = ""; origin.query = nil; origin.fragment = nil; origin.user = nil; origin.password = nil
               return origin.string ?? ""
           }), let expected = try? JSONSerialization.data(withJSONObject: origin, options: [.fragmentsAllowed]) {
            let code = "if(location.origin === \(String(decoding: expected, as: UTF8.self))){const saved=\(String(decoding: encoded, as: UTF8.self)); for(const k of Object.keys(saved)){if(localStorage.getItem(k)===null)localStorage.setItem(k,saved[k]);}}"
            configuration.userContentController.addUserScript(WKUserScript(source: code, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        guard !Task.isCancelled, generation == id else { return }
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.customUserAgent = MangaWebLoginRequest.userAgent
        view.navigationDelegate = self; view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        web = view
        observation = view.observe(\.title, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.scheduleVerification() }
        }
        view.load(URLRequest(url: url))
    }

    func stop() {
        generation = UUID(); request?.cancel(); request = nil
        operation?.cancel(); operation = nil; checking = false
        observation = nil; onSuccess = nil; lastCheck = ""
        web?.stopLoading(); web?.navigationDelegate = nil; web?.uiDelegate = nil; web = nil
    }

    func verify() { scheduleVerification(manual: true) }

    private func scheduleVerification(manual: Bool = false) {
        guard let web, let url = web.url, let loginURL,
              let host = url.host?.lowercased(), let loginHost = loginURL.host?.lowercased(),
              url.scheme == loginURL.scheme, url.port == loginURL.port,
              host == loginHost || host.hasSuffix("." + loginHost) else { return }
        let signature = url.absoluteString + "\n" + (web.title ?? "")
        guard manual || signature != lastCheck else { return }
        lastCheck = signature
        let prior = operation
        prior?.cancel(); request?.cancel()
        let token = MangaWebLoginRequest(); request = token
        let id = generation, title = web.title ?? "", key = source
        checking = true; failure = nil
        operation = Task { @MainActor [weak self, weak web] in
            if let prior { await prior.value }
            guard let self, let web, !Task.isCancelled, generation == id else { return }
            do {
                if !manual { try await Task.sleep(for: .milliseconds(300)) }
                let cookies = await web.configuration.websiteDataStore.httpCookieStore.allCookies()
                try Task.checkCancellation()
                let storage = (try? await web.callAsyncJavaScript("try { const value=JSON.stringify(Object.fromEntries(Object.entries(localStorage))); return value.length<=524288?value:'{}'; } catch { return '{}'; }",
                                                                arguments: [:], in: nil, contentWorld: .defaultClient)) as? String ?? "{}"
                let localStorage = (try? JSONDecoder().decode([String: String].self, from: Data(storage.utf8))) ?? [:]
                try Task.checkCancellation()
                let success = try await MangaRuntime.shared.signInWithWebPage(key, url: url, title: title, cookies: cookies,
                                                                            localStorage: localStorage, request: token)
                guard !Task.isCancelled, generation == id else { return }
                checking = false
                if success {
                    let completed = onSuccess
                    stop(); completed?()
                } else if manual { failure = "站点尚未确认登录，请完成网页中的登录后重试。" }
            } catch {
                if !Task.isCancelled, generation == id { checking = false; failure = error.mangaMessage }
            }
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        request?.cancel(); request = nil; operation?.cancel(); checking = false; lastCheck = ""
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { scheduleVerification() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { failure = "登录网页加载失败，请重试。" }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let allowed = ["http", "https", "about"].contains(action.request.url?.scheme?.lowercased() ?? "")
        decisionHandler(allowed ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil, ["http", "https"].contains(action.request.url?.scheme?.lowercased() ?? "") {
            webView.load(action.request)
        }
        return nil
    }
}
#endif
