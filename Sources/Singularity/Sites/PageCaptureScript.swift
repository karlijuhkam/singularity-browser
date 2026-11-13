import SingularityCore
import WebKit

/// "Let agents see console and network": the scripts that collect a page's console problems and
/// failed requests, and the handler that receives them.
///
/// WKWebView has no API for a page's console or network. The only route is a script inside the
/// page's own JavaScript world that wraps `console.error/warn`, `fetch` and `XMLHttpRequest` and
/// listens for `error` and `unhandledrejection`. Two scripts work together:
///
/// 1. **The collector**, in the page's world. It has to be there to see the page's own calls, so
///    the page can notice it and can feed it invented entries. That is accepted (the owner
///    switched the site on) and is why everything collected counts as untrusted page content.
/// 2. **The relay**, in an isolated content world of ours. The collector hands each entry over
///    as a DOM event; the relay passes it to the app. This split exists because a message handler
///    registered in the page's world would be visible (`webkit.messageHandlers…`) to *every* page
///    the web view loads, switched on or not. A handler in our own world is invisible to pages.
///
/// Both scripts begin by comparing `location.origin` with the list of switched-on sites and do
/// nothing on any other page, so pages of other sites see no trace. The list is part of the
/// script text; when it changes the scripts are replaced (`PluginScripts`), which applies from a
/// page's next load. The app checks the sender again for every message (`CaptureBridge`).
@MainActor
enum PageCaptureScript {
    static let world = WKContentWorld.world(name: "singularity-capture")
    static let handlerName = "singularityCapture"
    /// The DOM event the collector hands entries to the relay with. Random per launch, so a page
    /// can't have a listener waiting for it by name.
    private static let eventName = "sg-" + UUID().uuidString.lowercased()

    /// The two user scripts for a Space whose switched-on sites are `sites`; none when the list is empty.
    static func scripts(sites: [String]) -> [WKUserScript] {
        guard !sites.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: sites),
              let sitesJSON = String(data: data, encoding: .utf8) else { return [] }
        func fill(_ template: String) -> String {
            template.replacingOccurrences(of: "__SITES__", with: sitesJSON)
                .replacingOccurrences(of: "__EVENT__", with: "\"\(eventName)\"")
                .replacingOccurrences(of: "__HANDLER__", with: "\"\(handlerName)\"")
                .replacingOccurrences(of: "__LIMIT__", with: String(PageCapture.maxTextBytes))
        }
        return [
            // The relay first, so it is listening before the collector can send anything.
            WKUserScript(source: fill(relay), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world),
            WKUserScript(source: fill(collector), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page),
        ]
    }

    private static let relay = ##"""
    (() => {
      if (!__SITES__.includes(location.origin)) return;
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[__HANDLER__];
      if (!handler) return;
      window.addEventListener(__EVENT__, (event) => {
        if (typeof event.detail === "string") handler.postMessage(event.detail);
      });
    })();
    """##

    private static let collector = ##"""
    (() => {
      if (!__SITES__.includes(location.origin)) return;
      const LIMIT = __LIMIT__;
      // Keep our own references: the page may replace these later.
      const dispatch = window.dispatchEvent.bind(window);
      const RealCustomEvent = CustomEvent;
      const stringify = JSON.stringify;
      const send = (entry) => {
        try { dispatch(new RealCustomEvent(__EVENT__, { detail: stringify(entry) })); } catch (_) {}
      };
      const cut = (text) => {
        text = String(text);
        return text.length > LIMIT ? text.slice(0, LIMIT) + "\n[cut: " + text.length + " characters in all]" : text;
      };
      const describe = (value) => {
        try {
          if (typeof value === "string") return value;
          // WebKit's `stack` has only the frames, not the message, so both are given.
          if (value instanceof Error) return value.name + ": " + value.message + (value.stack ? "\n" + value.stack : "");
          if (value instanceof Element) return "<" + value.tagName.toLowerCase() + ">";
          if (typeof value === "object" && value !== null) {
            const json = stringify(value);
            return json === undefined ? String(value) : json;
          }
          return String(value);
        } catch (_) { return "[unprintable]"; }
      };

      // ---- console.error / console.warn --------------------------------------------------------
      for (const [name, level] of [["error", "error"], ["warn", "warning"]]) {
        const original = console[name];
        console[name] = function (...args) {
          try { send({ t: "console", level, text: cut(args.map(describe).join(" ")) }); } catch (_) {}
          return original.apply(this, args);
        };
      }

      // ---- uncaught exceptions, failed resources, unhandled promise rejections ------------------
      // `true`: the capture phase, because "error" events of elements (an <img> that failed) don't bubble.
      window.addEventListener("error", (event) => {
        try {
          const target = event.target;
          if (target && target !== window && target.tagName) {
            const address = target.currentSrc || target.src || target.href || "";
            send({ t: "console", level: "resource", text: cut("Failed to load <" + target.tagName.toLowerCase() + "> " + address) });
          } else {
            const text = event.error ? describe(event.error) : String(event.message);
            send({ t: "console", level: "exception", text: cut(text), source: String(event.filename || ""), line: event.lineno | 0 });
          }
        } catch (_) {}
      }, true);
      window.addEventListener("unhandledrejection", (event) => {
        try { send({ t: "console", level: "rejection", text: cut("Unhandled promise rejection: " + describe(event.reason)) }); } catch (_) {}
      });

      // ---- helpers for requests ------------------------------------------------------------------
      const isText = (type) => !type || /^text\/|json|xml|javascript|x-www-form-urlencoded|graphql/i.test(type);
      const headersObject = (headers) => {
        const out = {};
        try {
          if (!headers) return out;
          if (headers instanceof Headers) headers.forEach((value, name) => { out[name] = String(value); });
          else if (Array.isArray(headers)) for (const pair of headers) out[String(pair[0])] = String(pair[1]);
          else for (const name of Object.keys(headers)) out[name] = String(headers[name]);
        } catch (_) {}
        return out;
      };
      const describeBody = (body) => {
        try {
          if (body === undefined || body === null) return undefined;
          if (typeof body === "string") return cut(body);
          if (body instanceof URLSearchParams) return cut(body.toString());
          if (body instanceof FormData) {
            const parts = [];
            body.forEach((value, name) => parts.push(name + "=" + (typeof value === "string" ? value : "[file " + value.name + ", " + value.size + " bytes]")));
            return cut("[form data]\n" + parts.join("\n"));
          }
          if (body instanceof Blob) return "[binary: " + (body.type || "unknown type") + ", " + body.size + " bytes]";
          if (body instanceof ArrayBuffer || ArrayBuffer.isView(body)) return "[binary: " + body.byteLength + " bytes]";
          return "[a stream; not captured]";
        } catch (_) { return undefined; }
      };
      // Reads at most LIMIT characters of a response and then lets go of it, so an error answer
      // that never ends (a stream) is neither buffered nor held open by us.
      const readLimited = async (response) => {
        const type = response.headers.get("content-type") || "";
        if (!isText(type)) return "[binary: " + (type || "unknown type") + ", " + (response.headers.get("content-length") || "?") + " bytes]";
        if (!response.body) return "";
        const reader = response.body.getReader();
        const decoder = new TextDecoder();
        let text = "";
        try {
          while (text.length <= LIMIT) {
            const { done, value } = await reader.read();
            if (done) return text;
            text += decoder.decode(value, { stream: true });
          }
          return cut(text);
        } finally {
          try { reader.cancel(); } catch (_) {}
        }
      };

      // ---- fetch -------------------------------------------------------------------------------
      // Only failures are looked at: a response with status ≥ 400 (its copy is read, the page's own
      // response is untouched) or a request that got no answer. Everything else passes straight through.
      const realFetch = window.fetch;
      if (typeof realFetch === "function") {
        window.fetch = function (input, init) {
          const promise = realFetch.apply(this, arguments);
          try {
            const request = (typeof Request === "function" && input instanceof Request) ? input : null;
            const base = {
              t: "net", kind: "fetch",
              method: String((init && init.method) || (request && request.method) || "GET"),
              url: (() => { try { return new URL(request ? request.url : String(input), location.href).href; } catch (_) { return String(input); } })(),
              reqHeaders: headersObject((init && init.headers) || (request && request.headers)),
              reqBody: init && "body" in init ? describeBody(init.body) : (request && request.body ? "[sent as a Request object; not captured]" : undefined),
            };
            promise.then((response) => {
              if (response.status < 400) return;
              let copy = null;
              try { copy = response.clone(); } catch (_) {}
              const entry = Object.assign({}, base, { status: response.status, resHeaders: headersObject(response.headers) });
              if (!copy) { send(entry); return; }
              readLimited(copy).then((body) => send(Object.assign(entry, { resBody: body })), () => send(entry));
            }, (error) => {
              send(Object.assign({}, base, { error: describe(error && error.message ? error.message : error) }));
            });
          } catch (_) {}
          return promise;
        };
      }

      // ---- XMLHttpRequest ----------------------------------------------------------------------
      const proto = XMLHttpRequest.prototype;
      const realOpen = proto.open, realSend = proto.send, realSetHeader = proto.setRequestHeader;
      const notes = new WeakMap();
      proto.open = function (method, url) {
        try {
          let address = String(url);
          try { address = new URL(address, location.href).href; } catch (_) {}
          notes.set(this, { method: String(method), url: address, headers: {} });
        } catch (_) {}
        return realOpen.apply(this, arguments);
      };
      proto.setRequestHeader = function (name, value) {
        try { const note = notes.get(this); if (note) note.headers[String(name)] = String(value); } catch (_) {}
        return realSetHeader.apply(this, arguments);
      };
      proto.send = function (body) {
        try {
          const note = notes.get(this);
          if (note) {
            note.body = describeBody(body);
            this.addEventListener("loadend", () => {
              try {
                if (this.status >= 200 && this.status < 400) return;
                const entry = { t: "net", kind: "xhr", method: note.method, url: note.url, reqHeaders: note.headers, reqBody: note.body };
                if (this.status === 0) { send(Object.assign(entry, { error: "no response (network error, blocked or aborted)" })); return; }
                const headers = {};
                for (const line of String(this.getAllResponseHeaders() || "").split(/\r?\n/)) {
                  const at = line.indexOf(":");
                  if (at > 0) headers[line.slice(0, at).trim()] = line.slice(at + 1).trim();
                }
                let text;
                if (this.responseType === "" || this.responseType === "text") text = cut(this.responseText);
                else if (this.responseType === "json") text = cut(stringify(this.response));
                else text = "[binary: " + (this.getResponseHeader("content-type") || "unknown type") + "]";
                send(Object.assign(entry, { status: this.status, resHeaders: headers, resBody: text }));
              } catch (_) {}
            });
          }
        } catch (_) {}
        return realSend.apply(this, arguments);
      };
    })();
    """##
}

/// Receives the relay's messages and files them under the tab they came from.
@MainActor
final class CaptureBridge: NSObject, WKScriptMessageHandler {
    private weak var state: AppState?

    init(state: AppState?) {
        self.state = state
    }

    /// Registers the handler in our own content world (never the page's). Call it once per content controller.
    func install(in controller: WKUserContentController) {
        controller.add(self, contentWorld: PageCaptureScript.world, name: PageCaptureScript.handlerName)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // The gate that counts: the scripts' own site check is only there to leave other pages
        // untouched. Here the sender is checked against the owner's two switches as they are now.
        guard message.frameInfo.isMainFrame, let json = message.body as? String,
              let state, let webView = message.webView, let tabID = state.web.tabID(for: webView),
              // A little window's page is in no Space's tab list: no agent could read what is
              // captured for it, so nothing is kept.
              let controller = state.web.existingController(tabID), !controller.isArtifact, !controller.isLittle,
              let space = state.space(controller.spaceID) else { return }
        let origin = message.frameInfo.securityOrigin
        var components = URLComponents()
        components.scheme = origin.protocol
        components.host = origin.host
        if origin.port != 0 { components.port = origin.port }
        let site = SiteInfo.site(of: components.url)
        guard InspectionRules.isAllowed(space, site: site), let site else { return }
        controller.recordCapture(json: json, site: site)
    }
}
