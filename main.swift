// Watched — a lightweight native macOS wrapper for watched.cx
// - Native WebKit (fast, low memory, hardware video decode)
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

/// Hides Anime nav links and bounces any /anime page back home. Throttled to one pass per frame.
let hideAnimeJS = """
(function () {
  let queued = false;
  function pass() {
    queued = false;
    document.querySelectorAll('a[href^="/anime"], a[href*="watched.cx/anime"]').forEach(function (a) {
      var item = a.closest('li') || a;
      item.style.setProperty('display', 'none', 'important');
    });
    if (/^\\/anime/i.test(location.pathname)) location.replace('/home');
  }
  function schedule() { if (!queued) { queued = true; requestAnimationFrame(pass); } }
  pass();
  new MutationObserver(schedule).observe(document.documentElement, { childList: true, subtree: true });
})();
"""

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    var routeLabel = "direct"

    func applicationDidFinishLaunching(_ notification: Notification) {
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

        let script = WKUserScript(source: hideAnimeJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(script)

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
        window.contentView = webView
        window.center()
        window.setFrameAutosaveName("WatchedMainWindow")
        window.makeKeyAndOrderFront(nil)

        buildMenu()
        webView.load(URLRequest(url: homeURL))
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

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
