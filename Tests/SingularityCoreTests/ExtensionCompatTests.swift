import Foundation
import JavaScriptCore
import Testing
@testable import SingularityCore

/// The source analysis behind `CompatAdapter`: which uses of Chrome APIs WebKit lacks are real code.
@Suite struct CompatSourceTests {
    static let lead = "Object(globalThis.__sg||chrome)"

    @Test func rewritesEachListedMember() {
        for (ns, member) in CompatMembers.missing {
            let chrome = CompatSource.rewrite("chrome.\(ns).\(member).addListener(f)")
            #expect(chrome.text == "\(Self.lead).\(ns).\(member).addListener(f)")
            #expect(chrome.members == ["\(ns).\(member)"])
            let browser = CompatSource.rewrite("browser.\(ns).\(member)")
            #expect(browser.text == "Object(globalThis.__sg||browser).\(ns).\(member)")
        }
    }

    @Test func rewritesOptionalChainingAndSpaces() {
        #expect(CompatSource.rewrite("chrome.action?.getUserSettings!==void 0").text
                == "\(Self.lead).action?.getUserSettings!==void 0")
        #expect(CompatSource.rewrite("chrome .storage. managed").text == "\(Self.lead) .storage. managed")
        #expect(CompatSource.rewrite("typeof chrome.runtime.onSuspend").text == "typeof \(Self.lead).runtime.onSuspend")
    }

    @Test func leavesLongerNamesAlone() {
        for text in ["chrome.runtime.onSuspendX", "mychrome.runtime.onSuspend", "x.chrome.runtime.onSuspend",
                     "chrome.runtime.onMessage", "chrome.storage.local", "$chrome.storage.managed", "chrome.storage.managedX"] {
            let out = CompatSource.rewrite(text)
            #expect(out.text == text, "\(text)")
            #expect(out.members.isEmpty)
        }
    }

    @Test func asiSafe() throws {
        let out = CompatSource.rewrite("foo()\nchrome.runtime.onSuspend.addListener(f)\n'x'\nchrome.storage.managed.get()")
        let js = try #require(JSContext())
        js.evaluateScript("var ok = 0, got = 0; var foo = () => 0; var f = 1; var chrome = {runtime:{onSuspend:{addListener(){ ok = 1 }}}, storage:{managed:{get(){ got = 1 }}}};")
        js.evaluateScript(out.text)
        #expect(js.exception == nil)
        #expect(js.evaluateScript("ok")?.toInt32() == 1)
        #expect(js.evaluateScript("got")?.toInt32() == 1)
    }

    @Test func skipsNonCode() {
        for text in ["'chrome.storage.managed'", "\"chrome.storage.managed\"", "`chrome.storage.managed ${x}`",
                     "// chrome.storage.managed", "/* chrome.storage.managed */", "/chrome\\.storage\\.managed/.test(s)",
                     "x = /[/]chrome.storage.managed/", "'it\\'s chrome.storage.managed'"] {
            #expect(CompatSource.rewrite(text).members.isEmpty, "\(text)")
        }
        for text in ["`${chrome.storage.managed}`", "if(a)/x/.test(b);chrome.storage.managed", "}/x/g;chrome.storage.managed",
                     "a = b / c; chrome.storage.managed", "x = (a+b)/2; chrome.storage.managed", "`a${`b${c}`}`;chrome.storage.managed",
                     "return/x/.test(y)?chrome.storage.managed:0", "o={a:{}}\nchrome.storage.managed"] {
            #expect(CompatSource.rewrite(text).members == ["storage.managed"], "\(text)")
        }
    }

    @Test func divisionIsCode() {
        let text = "a = b / chrome.x / c"
        let mask = CompatSource.codeMask(Array(text.utf8))
        let index = Array(text.utf8).firstIndex(of: UInt8(ascii: "c"))!
        #expect(mask[index])
    }

    @Test func quotesStayValid() throws {
        // Even a masking mistake inside a string leaves valid JavaScript.
        let spliced = CompatSource.splice("'chrome.storage.managed'", atWord: 1, length: 6, root: "chrome")
        let js = try #require(JSContext())
        js.evaluateScript(spliced)
        #expect(js.exception == nil)
        let double = CompatSource.splice("\"chrome.storage.managed\"", atWord: 1, length: 6, root: "chrome")
        js.evaluateScript(double)
        #expect(js.exception == nil)
    }

    @Test func webSocketDetection() {
        for text in ["new WebSocket(u)", "new WebSocket (u)", "x=new self.WebSocket(u)", "s = new globalThis . WebSocket(u)"] {
            #expect(CompatSource.constructsWebSocket(text), "\(text)")
        }
        for text in ["\"new WebSocket(u)\"", "// new WebSocket(u)", "typeof WebSocket", "WebSocket.OPEN", "new WebSocketX(u)", "renew WebSocket"] {
            #expect(!CompatSource.constructsWebSocket(text), "\(text)")
        }
    }

    @Test func importsAndImportScripts() {
        let text = "import a from \"./a.js\";import \"../b.js\";export {c} from './c.js';import(\"./lazy.js\");import.meta.url;export * as d from './d.js';export const e = 1; // import './no.js'"
        #expect(CompatSource.staticImports(text) == ["./a.js", "../b.js", "./c.js", "./d.js"])
        #expect(CompatSource.staticImports("import {x,\n y} from\n'./m.js'") == ["./m.js"])
        #expect(CompatSource.importScriptsArguments("importScripts(\"x.js\", 'y.js');importScripts(z)") == ["x.js", "y.js"])
    }

    @Test func namespaces() {
        #expect(CompatSource.usedNamespaces("chrome.idle.queryState(60)") == ["idle"])
        #expect(CompatSource.usedNamespaces("browser.notifications?.create()") == ["notifications"])
        #expect(CompatSource.usedNamespaces("\"chrome.idle\"").isEmpty)
        #expect(CompatSource.usedNamespaces("chrome.idleX").isEmpty)
    }
}

/// `CompatAdapter`: the adapted copy, in throwaway folders.
@Suite struct CompatAdapterTests {
    final class Folder {
        let root = FileManager.default.temporaryDirectory.appending(path: "sg-compat-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        var original: URL { root.appending(path: "original", directoryHint: .isDirectory) }
        var adapted: URL { root.appending(path: "adapted", directoryHint: .isDirectory) }
        init(_ files: [String: String]) throws {
            for (path, text) in files {
                let url = original.appending(path: path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func adapt(id: String = "local-0a0a0a0a") throws -> CompatSummary? {
            try CompatAdapter.adapt(original: original, into: adapted, extensionID: id)
        }
        func read(_ path: String) throws -> String { try String(contentsOf: adapted.appending(path: path), encoding: .utf8) }
        func manifest() throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(contentsOf: adapted.appending(path: "manifest.json"))) as! [String: Any]
        }
        func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: adapted.appending(path: path).path) }
    }

    static func manifest(background: String, extra: String = "") -> String {
        #"{"manifest_version":3,"name":"T","version":"1","permissions":["storage"],"host_permissions":["https://*/*"],"background":\#(background)\#(extra)}"#
    }

    @Test func needsNothing() throws {
        let f = try Folder(["manifest.json": Self.manifest(background: #"{"service_worker":"bg.js"}"#),
                            "bg.js": "chrome.runtime.onMessage.addListener(() => {})"])
        #expect(try f.adapt() == nil)
        #expect(!FileManager.default.fileExists(atPath: f.adapted.path))
    }

    @Test func memberUseAddsStandIns() throws {
        let content = #","content_scripts":[{"matches":["https://*/*"],"js":["cs.js"]},{"matches":["https://*/*"],"js":["main.js"],"world":"MAIN"}],"action":{"default_popup":"popup.html"}"#
        let f = try Folder([
            "manifest.json": Self.manifest(background: #"{"service_worker":"bg.js","type":"module"}"#, extra: content),
            "bg.js": "chrome.runtime.onSuspend.addListener(() => {})",
            "cs.js": "chrome.storage.managed.get().then(() => {})",
            "main.js": "window.x = 1",
            "popup.html": "<!doctype html><html><head><title>x</title></head><body></body></html>",
        ])
        let summary = try #require(try f.adapt())
        #expect(summary.standIns == ["runtime.onSuspend", "storage.managed"])
        #expect(!summary.backgroundPage)
        #expect(summary.recipe == nil)
        let m = try f.manifest()
        let scripts = m["content_scripts"] as! [[String: Any]]
        #expect(scripts[0]["js"] as? [String] == ["sg-compat.js", "cs.js"])
        #expect(scripts[1]["js"] as? [String] == ["main.js"])
        #expect(try f.read("popup.html").contains("<head><script src=\"/sg-compat.js\"></script><title>"))
        let background = m["background"] as! [String: Any]
        #expect(background["service_worker"] as? String == "sg-worker.js")
        #expect(background["type"] as? String == "module")
        #expect(try f.read("sg-worker.js") == "import \"/sg-compat.js\";\nimport \"./bg.js\";\n")
        #expect(try f.read("sg-compat.js") == CompatStandIns.script)
        #expect(try f.read("cs.js") == "Object(globalThis.__sg||chrome).storage.managed.get().then(() => {})")
        #expect(try f.read("main.js") == "window.x = 1")
        #expect(m["permissions"] as? [String] == ["storage"])
    }

    @Test func classicWorkerEntry() throws {
        let f = try Folder(["manifest.json": Self.manifest(background: #"{"service_worker":"js/bg.js"}"#),
                            "js/bg.js": "importScripts(\"lib.js\"); chrome.idle.queryState(60)",
                            "js/lib.js": "self.x = 1"])
        let summary = try #require(try f.adapt())
        #expect(summary.standIns == ["idle"])
        let background = try f.manifest()["background"] as! [String: Any]
        #expect(background["service_worker"] as? String == "js/sg-worker.js")
        #expect(try f.read("js/sg-worker.js") == "importScripts(\"/sg-compat.js\", \"bg.js\");\n")
        #expect(try f.read("js/bg.js") == "importScripts(\"lib.js\"); chrome.idle.queryState(60)")
    }

    @Test func webSocketMakesAPage() throws {
        let f = try Folder(["manifest.json": Self.manifest(background: #"{"service_worker":"bg.js","type":"module"}"#),
                            "bg.js": "import { open } from './net/net.js'; open()",
                            "net/net.js": "export function open() { return new WebSocket('wss://x') }"])
        let summary = try #require(try f.adapt())
        #expect(summary.backgroundPage)
        #expect(summary.standIns.isEmpty)
        let background = try f.manifest()["background"] as! [String: Any]
        #expect(background["page"] as? String == "sg-background.html")
        #expect(background["persistent"] as? Bool == false)
        #expect(background["service_worker"] == nil)
        #expect(try f.read("sg-background.html")
                == #"<!doctype html><meta charset="utf-8"><script src="/sg-compat.js"></script><script type="module" src="bg.js"></script>"#)
        #expect(summary.text == "Singularity adapts this extension to run here: background as a page.")
    }

    @Test func webSocketClassic() throws {
        let f = try Folder(["manifest.json": Self.manifest(background: #"{"service_worker":"w/bg.js"}"#),
                            "w/bg.js": "importScripts('a.js'); go()",
                            "w/a.js": "function go() { new WebSocket('wss://x') }"])
        let summary = try #require(try f.adapt())
        #expect(summary.backgroundPage)
        #expect(try f.read("w/sg-background.html")
                == #"<!doctype html><meta charset="utf-8"><script src="/sg-compat.js"></script><script src="/sg-import-scripts.js"></script><script src="a.js"></script><script src="bg.js"></script>"#)
        #expect(f.exists("sg-import-scripts.js"))
    }

    @Test func mentionIsNotAUse() throws {
        let f = try Folder(["manifest.json": Self.manifest(background: #"{"service_worker":"bg.js"}"#),
                            "bg.js": "// new WebSocket(u)\nconst s = \"chrome.storage.managed\""])
        #expect(try f.adapt() == nil)
    }

    @Test func dropsUpdateURLAndMetadata() throws {
        let f = try Folder(["manifest.json": Self.manifest(background: #"{"service_worker":"bg.js"}"#, extra: #","update_url":"https://u""#),
                            "bg.js": "chrome.runtime.requestUpdateCheck()",
                            "_metadata/verified_contents.json": "[]"])
        _ = try #require(try f.adapt())
        #expect(try f.manifest()["update_url"] == nil)
        #expect(!f.exists("_metadata"))
    }

    @Test func deterministic() throws {
        let f = try Folder(["manifest.json": Self.manifest(background: #"{"service_worker":"bg.js"}"#),
                            "bg.js": "chrome.runtime.onSuspend.addListener(f); new WebSocket(u)", "p.html": "<p>x"])
        _ = try f.adapt()
        let first = try PluginFingerprint.compute(folder: f.adapted)
        _ = try f.adapt()
        #expect(try PluginFingerprint.compute(folder: f.adapted) == first)
    }

    static let onePasswordShape = "function E_e(A){return browser.runtime.getManifest().manifest_version===A}function Xl(){return E_e(3)}function Jl(){return Xl()&&Fs()}var Fs=()=>!0;function Ab(){return Fs()&&Sn()}"

    @Test func recipeApplies() throws {
        let f = try Folder(["manifest.json": Self.manifest(background: #"{"service_worker":"background/background.js","type":"module"}"#),
                            "background/background.js": Self.onePasswordShape])
        let summary = try #require(try f.adapt(id: "aeblfdkhhhdcdjpifhhbdiojplfjncoa"))
        #expect(try f.read("background/background.js").contains(#"function Jl(){return Xl()&&Fs()&&typeof ServiceWorkerGlobalScope!=="undefined"}"#))
        #expect(try f.read("background/background.js").contains("function Ab(){return Fs()&&Sn()}"))
        let background = try f.manifest()["background"] as! [String: Any]
        #expect(background["page"] as? String == "background/sg-background.html")
        #expect(summary.recipe == "1Password")
        #expect(summary.text == "Singularity adapts this extension to run here: background as a page, 1Password recipe.")
    }

    @Test func recipeWrongCountFails() throws {
        let twice = try Folder(["manifest.json": Self.manifest(background: #"{"service_worker":"background/background.js"}"#),
                                "background/background.js": Self.onePasswordShape + "function Kl(){return Xl()&&Qe()}"])
        #expect(throws: CompatAdapter.Failure.recipeMismatch("background/background.js", expected: 1, found: 2)) {
            try twice.adapt(id: "aeblfdkhhhdcdjpifhhbdiojplfjncoa")
        }
        #expect(!FileManager.default.fileExists(atPath: twice.adapted.path))
        let none = try Folder(["manifest.json": Self.manifest(background: #"{"service_worker":"background/background.js"}"#),
                               "background/background.js": "var a = 1"])
        #expect(throws: CompatAdapter.Failure.recipeMismatch("background/background.js", expected: 1, found: 0)) {
            try none.adapt(id: "aeblfdkhhhdcdjpifhhbdiojplfjncoa")
        }
    }

    @Test func summaryText() {
        #expect(CompatSummary(standIns: ["a", "b", "c"], backgroundPage: true, recipe: nil).text
                == "Singularity adapts this extension to run here: stand-ins for 3 Chrome features, background as a page.")
        #expect(CompatSummary(standIns: ["a"], backgroundPage: false, recipe: nil).short == "stand-ins for 1 Chrome feature")
    }

    @Test func standInsBehave() throws {
        let js = try #require(JSContext())
        js.evaluateScript("""
        var out = {};
        var chrome = { runtime: { id: "x", getManifest() { return { name: "N", version: "1" } }, onMessage: {} },
                       storage: { local: { get() { return Promise.resolve({ a: 1 }) } } } };
        """)
        js.evaluateScript(CompatStandIns.script)
        js.evaluateScript(CompatStandIns.script)
        #expect(js.exception == nil)
        js.evaluateScript("""
        chrome.idle.queryState(60).then(v => out.idle = v);
        __sg.storage.managed.get().then(v => out.managed = JSON.stringify(v));
        __sg.storage.local.get().then(v => out.local = JSON.stringify(v));
        __sg.runtime.requestUpdateCheck(v => out.update = v.status);
        __sg.action.getUserSettings().then(v => out.toolbar = v.isOnToolbar);
        chrome.downloads.download({}).then(() => out.download = "ok", () => out.download = "refused");
        chrome.management.getSelf().then(v => out.self = v.name);
        chrome.management.setEnabled("x", false).then(() => out.enable = "ok", () => out.enable = "refused");
        var f = () => {}; __sg.webNavigation.onTabReplaced.addListener(f); __sg.webNavigation.onTabReplaced.removeListener(f);
        out.listener = __sg.webNavigation.onTabReplaced.hasListener(f);
        out.realWins = __sg.runtime.onMessage === undefined ? "no" : "yes";
        """)
        #expect(js.exception == nil)
        let out = try #require(js.evaluateScript("JSON.stringify(out)")?.toString())
        #expect(out.contains(#""idle":"active""#))
        #expect(out.contains(#""managed":"{}""#))
        #expect(out.contains(#""local":"{\"a\":1}""#))
        #expect(out.contains(#""update":"no_update""#))
        #expect(out.contains(#""toolbar":true"#))
        #expect(out.contains(#""download":"refused""#))
        #expect(out.contains(#""self":"N""#))
        #expect(out.contains(#""enable":"refused""#))
        #expect(out.contains(#""listener":false"#))
        #expect(out.contains(#""realWins":"yes""#))
        #expect(!CompatStandIns.script.contains("console."))
        #expect(!CompatStandIns.script.contains("sendNativeMessage"))
    }
}
