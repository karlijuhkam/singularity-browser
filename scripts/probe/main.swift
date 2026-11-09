import AppKit
import WebKit

// Frame-lock probe: loads www/index.html in a WKWebView with the real PluginPrelude (compiled in
// from Sources/Singularity/Plugins/PluginPrelude.swift) in a plugin world, runs frames.js there as
// the plugin's page script, and prints what it reports. Then checks the page's own world still
// reads its cookie and storage. Built and run by scripts/probe-plugin-frames.sh.
@MainActor final class Probe: NSObject, WKScriptMessageHandler {
    let web: WKWebView
    init(base: URL, plugin: String) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let world = WKContentWorld.world(name: "plugin-probe")
        let any = #"{"schemes":["http","https"],"hostKind":"any","host":"","pathRegex":"^.*$"}"#
        let config = #"{"pluginID":"probe","handlerName":"singularityPlugin","pageSites":[\#(any)],"pageAdditions":[\#(any)],"fillForms":[\#(any)]}"#
        let secret = String(repeating: "ab", count: 32)
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(source: PluginPrelude.source(configJSON: config, secret: secret),
                                              injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
        controller.addUserScript(WKUserScript(source: PluginPrelude.wrap(pluginID: "probe", code: plugin),
                                              injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        super.init()
        controller.add(self, contentWorld: world, name: "probeOut")
        web.load(URLRequest(url: base.appending(path: "index.html")))
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let text = "\(message.body)"
        print(text)
        if text.hasPrefix("RESULT") { checkPageWorld() }
    }

    func checkPageWorld() {
        Task { @MainActor in
            let js = "return 'cookie=' + document.cookie + ' ls=' + localStorage.getItem('jwt') + ' ss=' + sessionStorage.getItem('s') + ' fetch=' + typeof fetch"
            let result = try? await web.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page)
            print("page world: \(result ?? "nil")")
            exit(0)
        }
    }
}

let base = URL(string: CommandLine.arguments[1])!
let plugin = try! String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
let app = NSApplication.shared
let probe = MainActor.assumeIsolated { Probe(base: base, plugin: plugin) }
DispatchQueue.main.asyncAfter(deadline: .now() + 20) { print("timeout"); exit(2) }
app.run()
_ = probe
