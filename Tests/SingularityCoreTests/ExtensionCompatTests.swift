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
