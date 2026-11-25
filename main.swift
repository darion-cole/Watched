// Watched — a lightweight native macOS wrapper for watched.cx
// - Native WebKit (fast, low memory, hardware video decode)
// - Built-in ad/tracker blocker (toggle in View menu)
// - Routes through Cloudflare WARP's local proxy if it's running in Proxy mode,
//   otherwise connects directly (which is still tunneled when WARP is in normal mode)
// - Hides the Anime section, blocks pop-ups and off-site redirects
// Requires macOS 14+.

import Cocoa
import WebKit
import Network

// MARK: - Settings

let homeURL = URL(string: "https://watched.cx/home")!
/// Hosts allowed to load in the main window. Add one here if a login/redirect breaks.
let allowedHosts = ["watched.cx"]
/// Default port for WARP's local SOCKS5 proxy (`warp-cli mode proxy`).
let warpProxyPort: UInt16 = 40000
let blockAdsKey = "blockAds"

/// Ad, pop-under and tracker networks. Blocking these is most of the speedup.
let blockedDomains = [
    // Google ads / analytics
    "doubleclick.net", "googlesyndication.com", "googleadservices.com", "googletagmanager.com",
    "googletagservices.com", "google-analytics.com", "adservice.google.com",
    // Pop-under / redirect networks common on streaming sites
    "popads.net", "popcash.net", "propellerads.com", "propellerclick.com", "adsterra.com",
    "adsterratools.com", "highperformanceformat.com", "profitablecpmrate.com", "profitablegatecpm.com",
    "effectivegatecpm.com", "monetag.com", "onclickads.net", "onclickalgo.com", "clickadu.com",
    "hilltopads.net", "adcash.com", "exoclick.com", "exosrv.com", "juicyads.com", "trafficjunky.net",
    "a-ads.com", "ad-maven.com", "admaven.com", "galaksion.com", "richads.com", "rollerads.com",
    "pushame.com", "acint.net", "mgid.com", "taboola.com", "outbrain.com", "revcontent.com",
    "bidgear.com", "yllix.com", "adskeeper.com", "clksite.com", "dtscout.com",
    // Trackers
    "histats.com", "mc.yandex.ru", "yandex.ru", "hotjar.com", "clarity.ms", "scorecardresearch.com",
    "quantserve.com", "facebook.net", "amplitude.com", "mixpanel.com", "segment.io",
]

// MARK: - Helpers

func isAllowedHost(_ host: String) -> Bool {
    let h = host.lowercased()
    return allowedHosts.contains { h == $0 || h.hasSuffix("." + $0) }
}

/// True if something is listening on 127.0.0.1:warpProxyPort (i.e. WARP proxy mode is on).
func warpProxyAvailable() -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = warpProxyPort.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    return result == 0
}

func blockerRulesJSON() -> String {
    let rules: [[String: Any]] = blockedDomains.map { domain in
        let escaped = NSRegularExpression.escapedPattern(for: domain)
        return ["trigger": ["url-filter": "^[^:]+:(//)?([^/]+\\.)?\(escaped)[/:]"],
                "action": ["type": "block"]]
    }
    let data = try! JSONSerialization.data(withJSONObject: rules)
    return String(data: data, encoding: .utf8)!
}

/// Hides Anime links with plain CSS (no per-change JavaScript, so it costs nothing while browsing).
let hideAnimeJS = """
(function () {
  var s = document.createElement('style');
  s.textContent = `
    a[href^="/anime"], a[href*="watched.cx/anime"],
    li:has(> a[href^="/anime"]), li:has(> a[href*="watched.cx/anime"]) { display: none !important; }
  `;
  document.documentElement.appendChild(s);
})();
"""

/// Thin loading bar along the top edge so slow loads don't look like a freeze.
final class ProgressBar: NSView {
    var progress: Double = 0 { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width * progress, height: bounds.height).fill()
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    let progressBar = ProgressBar()
    var observers: [NSKeyValueObservation] = []
    var blockerList: WKContentRuleList?
    var blockMenuItem: NSMenuItem!
    var routeLabel = "direct"

    var blockAds: Bool { UserDefaults.standard.bool(forKey: blockAdsKey) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [blockAdsKey: true])

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()            // persistent cache + logins
        config.preferences.isElementFullscreenEnabled = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"

        if warpProxyAvailable() {
            let endpoint = NWEndpoint.hostPort(host: "127.0.0.1",
                                               port: NWEndpoint.Port(rawValue: warpProxyPort)!)
            config.websiteDataStore.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: endpoint)]
            routeLabel = "via WARP proxy"
        }

        config.userContentController.addUserScript(
            WKUserScript(source: hideAnimeJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.title = "Watched — \(routeLabel)"

        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        progressBar.frame = NSRect(x: 0, y: container.bounds.height - 3, width: container.bounds.width, height: 3)
        progressBar.autoresizingMask = [.width, .minYMargin]
        container.addSubview(progressBar)
        window.contentView = container

        window.center()
        window.setFrameAutosaveName("WatchedMainWindow")
        window.makeKeyAndOrderFront(nil)

        observers.append(webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
            Task { @MainActor in self?.updateProgress(wv.estimatedProgress) }
        })
        // Catches in-page (single-page-app) route changes that never fire a navigation.
        observers.append(webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
            Task { @MainActor in self?.redirectIfAnime(wv.url) }
        })

        buildMenu()
        NSApp.activate(ignoringOtherApps: true)

        Task { @MainActor in
            await self.loadBlocker()
            self.webView.load(URLRequest(url: homeURL))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: Ad blocking

    func loadBlocker() async {
        if blockerList == nil {
            blockerList = try? await WKContentRuleListStore.default()
                .compileContentRuleList(forIdentifier: "WatchedBlocker", encodedContentRuleList: blockerRulesJSON())
        }
        let ucc = webView.configuration.userContentController
        ucc.removeAllContentRuleLists()
        if blockAds, let list = blockerList { ucc.add(list) }
    }

    @objc func toggleBlockAds(_ sender: NSMenuItem) {
        UserDefaults.standard.set(!blockAds, forKey: blockAdsKey)
        sender.state = blockAds ? .on : .off
        Task { @MainActor in
            await self.loadBlocker()
            self.webView.reload()
        }
    }

    // MARK: Progress / routing

    func updateProgress(_ p: Double) {
        progressBar.progress = p
        progressBar.isHidden = p >= 1.0
    }

    func redirectIfAnime(_ url: URL?) {
        guard let url, let host = url.host, isAllowedHost(host) else { return }
        if url.path.lowercased().hasPrefix("/anime") { webView.load(URLRequest(url: homeURL)) }
    }

    // MARK: Navigation policy

    // Only let the main frame go to allowed hosts (blocks ad redirects). Player iframes are untouched.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        let isMainFrame = action.targetFrame?.isMainFrame ?? true
        if isMainFrame, let host = action.request.url?.host, !isAllowedHost(host) {
            return .cancel
        }
        return .allow
    }

    // Pop-ups: same-site links open in the main window, everything else is dropped.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, let host = url.host, isAllowedHost(host) {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { showError(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { showError(error) }

    func showError(_ error: Error) {
        let code = (error as NSError).code
        if code == NSURLErrorCancelled || code == 102 { return }  // our own cancels / frame load interrupted
        window.title = "Watched — couldn't load (\(routeLabel)). Is WARP connected?"
    }

    @objc func goHome(_ sender: Any?) { webView.load(URLRequest(url: homeURL)) }
    @objc func reloadPage(_ sender: Any?) { webView.reload() }
    @objc func back(_ sender: Any?) { webView.goBack() }
    @objc func forward(_ sender: Any?) { webView.goForward() }

    func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide Watched", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Watched", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // Needed so ⌘C / ⌘V / ⌘A work in the search box.
        let editItem = NSMenuItem(); main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        for (title, sel, key) in [("Home", #selector(goHome(_:)), "H"),
                                  ("Reload", #selector(reloadPage(_:)), "r"),
                                  ("Back", #selector(back(_:)), "["),
                                  ("Forward", #selector(forward(_:)), "]")] {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            item.target = self
            viewMenu.addItem(item)
        }
        viewMenu.addItem(.separator())
        blockMenuItem = NSMenuItem(title: "Block Ads & Trackers", action: #selector(toggleBlockAds(_:)), keyEquivalent: "")
        blockMenuItem.target = self
        blockMenuItem.state = blockAds ? .on : .off
        viewMenu.addItem(blockMenuItem)
        viewMenu.addItem(.separator())
        let fs = NSMenuItem(title: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(fs)
        viewItem.submenu = viewMenu

        NSApp.mainMenu = main
    }
}

@main
struct WatchedMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
