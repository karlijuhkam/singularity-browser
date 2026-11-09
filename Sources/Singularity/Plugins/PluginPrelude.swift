import Foundation

/// The JavaScript that runs before a plugin's page script, in the plugin's own isolated world
/// (`WKContentWorld` "plugin-<id>"), and defines the page API the plugin's `page.ts` uses:
///
///     singularity.siteMatches        // true: this page is one of the plugin's sites
///     singularity.send(payload)      // -> Promise<reply from the plugin's background program>
///     singularity.addFieldButton(input, { title, iconURL?, onClick })
///     singularity.showMenu(anchor, [{ title, subtitle? }])   // -> Promise<index | null>
///     singularity.fillLogin({ usernameInput?, passwordInput?, username?, password? })
///
/// It is two user scripts (see `PluginScripts`):
/// 1. `source(...)`, at document start: the API, and network functions switched off.
/// 2. `wrap(...)`, at document end: the plugin's transpiled page.ts, run only when
///    `singularity.siteMatches` is true. It is a separate script so the plugin's code can't see
///    the prelude's private variables (the secret below).
///
/// What a content world gives us: the page's own scripts can't see anything defined here, can't
/// call `singularity`, and can't reach the message handler (it is registered for this world only).
/// The plugin's code, though, shares this world with the prelude; see "Real clicks" below for what
/// that means.
///
/// Real clicks: buttons and menus live in a *closed* shadow root, so the page can tell they are
/// there but can't read or click inside them; a script's `element.click()` or `dispatchEvent`
/// produces `isTrusted: false` events, which are ignored. On a real click the prelude asks
/// Singularity for a one-time click token, proving with `secret` (random per plugin version and web
/// view, known only to this prelude and to the native handler) that the request is its own. The
/// next `send` within 2 s carries the token, and Singularity only lets a fill through for a send
/// that carried a valid one. The secret lives in a variable of the prelude's own function, which
/// the plugin's code can't read. The built-ins the prelude relies on at click time are copied
/// before any plugin code runs, so replacing them later doesn't help the plugin. Before asking for
/// a token, the prelude also checks the click wasn't hijacked (see `genuineClick` below).
enum PluginPrelude {
    /// - Parameters:
    ///   - configJSON: `{"pluginID", "handlerName", "pageSites", "pageAdditions", "fillForms"}`, the
    ///     site lists as `SitePattern.BrowserMatcher` arrays (see `PluginScripts`).
    ///   - secret: from `PluginPageRequest.makeSecret()` (64 hex digits).
    static func source(configJSON: String, secret: String) -> String {
        precondition(secret.allSatisfy(\.isHexDigit), "the secret is inserted into JavaScript as-is")
        // The secret first: it is hex, so it can't contain the config marker (the other way round, a
        // site pattern could in theory contain the secret marker).
        return template
            .replacingOccurrences(of: "__SECRET__", with: "\"" + secret + "\"")
            .replacingOccurrences(of: "__CONFIG__", with: configJSON)
    }

    /// The plugin's transpiled page script, wrapped so it only runs where `siteMatches` is true and
    /// so an exception (also in async code) ends up in the console with the plugin's name.
    /// `pluginID` is a validated id (lowercase letters, digits, dashes).
    static func wrap(pluginID: String, code: String) -> String {
        """
        (() => {
          const api = window.singularity;
          if (!api || api.siteMatches !== true) return;
          (async () => {
        \(code)
          })().catch((error) => console.error("Plugin \(pluginID): page script failed:", error));
        })();
        """
    }

    // Kept boring on purpose: plugin authors read this to see exactly what their API does.
    private static let template = #"""
    (() => {
      "use strict";
      if (window.singularity) return; // already set up in this frame

      const config = __CONFIG__;
      // Proves to Singularity that a click-token request comes from this prelude. Never put it
      // anywhere the plugin's code could read it (no globals, no properties, no messages but ours).
      const secret = __SECRET__;

      // ---- 1. Our own copies of the built-ins we rely on ------------------------------------------
      // Taken now, before any plugin code runs, so a plugin replacing them later changes nothing here.
      const apply = Reflect.apply;
      const defineProperty = Object.defineProperty;
      const freeze = Object.freeze;
      const now = Date.now;
      const stringify = JSON.stringify;
      const listen = EventTarget.prototype.addEventListener;
      const unlisten = EventTarget.prototype.removeEventListener;
      const createElement = Document.prototype.createElement;
      const attachShadow = Element.prototype.attachShadow;
      const setAttribute = Element.prototype.setAttribute;
      const getAttribute = Element.prototype.getAttribute;
      const getComputedStyle = window.getComputedStyle;
      const getPropertyValue = CSSStyleDeclaration.prototype.getPropertyValue;
      const parentNodeOf = Object.getOwnPropertyDescriptor(Node.prototype, "parentNode").get;
      const documentElementOf = Object.getOwnPropertyDescriptor(Document.prototype, "documentElement").get;
      const bodyOf = Object.getOwnPropertyDescriptor(Document.prototype, "body").get;
      const RealWeakSet = WeakSet;
      const appendChild = Node.prototype.appendChild;
      const removeElement = Element.prototype.remove;
      const getRect = Element.prototype.getBoundingClientRect;
      const checkVisibility = Element.prototype.checkVisibility; // Safari 17.4+
      const setInputValue = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set;
      const isConnected = Object.getOwnPropertyDescriptor(Node.prototype, "isConnected").get;
      const textContent = Object.getOwnPropertyDescriptor(Node.prototype, "textContent").set;
      const RealInputEvent = InputEvent;
      const RealEvent = Event;
      const RealMutationObserver = MutationObserver;
      const RealResizeObserver = ResizeObserver;
      const requestFrame = window.requestAnimationFrame.bind(window);
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[config.handlerName];
      const post = handler ? handler.postMessage.bind(handler) : null;

      const on = (target, type, fn, options) => apply(listen, target, [type, fn, options]);
      const off = (target, type, fn, options) => apply(unlisten, target, [type, fn, options]);
      const make = (tag) => apply(createElement, document, [tag]);
      const setText = (node, text) => apply(textContent, node, [String(text)]);
      const connected = (node) => apply(isConnected, node, []);
      const rectOf = (el) => apply(getRect, el, []);
      const styleOf = (el, name) => apply(getPropertyValue, apply(getComputedStyle, window, [el]), [name]);
      const parentOf = (node) => apply(parentNodeOf, node, []);
      const rootElement = () => apply(documentElementOf, document, []);
      const bodyElement = () => apply(bodyOf, document, []);

      // ---- 2. Is this page one of the plugin's sites? ----------------------------------------------
      // The patterns were parsed by Singularity (SitePattern.browserMatcher). Singularity checks
      // every message again natively, so this only decides whether the plugin's code starts.
      const matchesAny = (matchers) => {
        const scheme = location.protocol.replace(/:$/, "");
        let host = location.hostname.toLowerCase();
        if (host.endsWith(".")) host = host.slice(0, -1);
        const path = location.pathname + location.search;
        return matchers.some((m) => {
          if (!m.schemes.includes(scheme)) return false;
          if (m.hostKind === "exact" && host !== m.host) return false;
          if (m.hostKind === "domainAndSubdomains" && host !== m.host && !host.endsWith("." + m.host)) return false;
          return new RegExp(m.pathRegex).test(path);
        });
      };
      const siteMatches = matchesAny(config.pageSites) && matchesAny(config.pageAdditions);
      const fillAllowed = siteMatches && matchesAny(config.fillForms);

      // ---- 3. No network for the plugin's page code ------------------------------------------------
      // Defence in depth: plugins can't send what they see in a page anywhere. These are replaced in
      // this world only (the page's own scripts are unaffected), can't be put back, and throw.
      // Every frame runs this prelude (forMainFrameOnly: false), so child frames are locked the same way.
      // What this can NOT stop: a script that may change the page can also make the page load
      // things, and those requests can carry data: `new Image().src = …`, inserting an <img>,
      // <script> or <link> element, CSS url(…), assigning `location`, submitting a form. They can't
      // be blocked from a script that must touch the DOM; plugins are reviewed with that in mind.
      function blocked() { throw new Error("network isn't available to plugins"); }
      const lock = (target, name) => {
        try { defineProperty(target, name, { value: blocked, writable: false, configurable: false }); } catch (_) {}
      };
      // For properties read like `window.caches`: reading them throws.
      const lockGetter = (target, name) => {
        try { defineProperty(target, name, { get: blocked, configurable: false }); } catch (_) {}
      };
      // Methods on built-in prototypes (so instances made any other way can't use them either).
      const lockMethods = (constructorName, names) => {
        const C = window[constructorName];
        if (C && C.prototype) for (const name of names) lock(C.prototype, name);
      };
      lockMethods("CacheStorage", ["open", "match", "has"]);
      lockMethods("Cache", ["add", "addAll", "put"]);
      lockMethods("Worklet", ["addModule"]);               // audioWorklet, paintWorklet, …
      lockMethods("FontFaceSet", ["add", "load"]);         // document.fonts
      lockMethods("ServiceWorkerContainer", ["register"]); // navigator.serviceWorker
      lockMethods("Navigation", ["navigate"]);             // window.navigation, where present
      lockMethods("Navigator", ["sendBeacon"]);
      lock(navigator, "sendBeacon");
      if (document.fonts) { lock(document.fonts, "add"); lock(document.fonts, "load"); }
      lockGetter(window, "caches");
      for (const name of ["fetch", "XMLHttpRequest", "WebSocket", "WebSocketStream", "EventSource", "Worker",
                          "SharedWorker", "RTCPeerConnection", "webkitRTCPeerConnection", "WebTransport",
                          "importScripts", "open", "FontFace"]) {
        lock(window, name);
      }
      // Dynamic import() works in this world and can load a module from any URL. transpile-page.ts
      // refuses page scripts that contain "import(", so the remaining way is code built from a
      // string at run time: eval, the Function constructors and string timers are switched off too.
      function noCodeFromStrings() { throw new Error("running code from a string isn't available to plugins"); }
      const lockCode = (target, name) => {
        try { defineProperty(target, name, { value: noCodeFromStrings, writable: false, configurable: false }); } catch (_) {}
      };
      lockCode(window, "eval");
      lockCode(window, "Function");
      for (const fn of [function () {}, async function () {}, function* () {}, async function* () {}]) {
        lockCode(Object.getPrototypeOf(fn), "constructor");
      }
      for (const name of ["setTimeout", "setInterval"]) {
        const original = window[name];
        try {
          defineProperty(window, name, {
            value: (callback, ...rest) => {
              if (typeof callback !== "function") noCodeFromStrings();
              return apply(original, window, [callback, ...rest]);
            },
            writable: false,
            configurable: false,
          });
        } catch (_) {}
      }
      // A new frame's window would have fresh copies of everything above: don't hand them out.
      for (const proto of [HTMLIFrameElement.prototype, HTMLFrameElement.prototype, HTMLObjectElement.prototype]) {
        for (const name of ["contentWindow", "contentDocument"]) {
          try { defineProperty(proto, name, { get: () => null, configurable: false }); } catch (_) {}
        }
      }

      // ---- 4. Talking to the plugin's background program --------------------------------------------
      // Click tickets: a real click on our button or menu asks Singularity for a click token at once
      // and keeps the pending answer for 2 s. The plugin's next send() takes it (once).
      let clickTicket = null;
      const realClickHappened = () => {
        const token = post ? post({ type: "click", secret }).catch(() => null) : Promise.resolve(null);
        clickTicket = { token, until: now() + 2000 };
      };
      const takeClickTicket = () => {
        const ticket = clickTicket;
        clickTicket = null;
        return ticket && now() <= ticket.until ? ticket : null;
      };

      /** Sends `payload` (anything JSON can carry) to the plugin's background program and resolves
       *  with its reply. Rejects when the plugin isn't running or the payload is over 256 KB. */
      const send = async (payload) => {
        if (!post) throw new Error("Singularity isn't listening for this plugin here");
        const json = stringify(payload === undefined ? null : payload);
        const ticket = takeClickTicket(); // before any await: only the first send after a click gets it
        const token = ticket ? await ticket.token : null;
        return await post({ type: "send", json, token: typeof token === "string" ? token : null });
      };

      // ---- 5. Our elements: a host in the page, everything else in a closed shadow root ---------------
      const HOST_STYLE = "all: initial !important; position: fixed !important; z-index: 2147483647 !important; " +
                         "margin: 0 !important; padding: 0 !important; border: 0 !important; display: block !important;";
      const makeHost = () => {
        const host = make("div");
        const root = apply(attachShadow, host, [{ mode: "closed" }]);
        return { host, root };
      };
      // Writes the host's style only when it differs, so our own write doesn't start another round
      // through the MutationObserver below (which puts the style back whenever the page changes it).
      // Returns whether it wrote.
      const setStyle = (host, style) => {
        if (apply(getAttribute, host, ["style"]) === style) return false;
        apply(setAttribute, host, ["style", style]);
        return true;
      };
      const placedStyle = (left, top, width, height) => HOST_STYLE +
        ` left: ${left}px !important; top: ${top}px !important; width: ${width}px !important; height: ${height}px !important;`;
      const place = (host, left, top, width, height) => setStyle(host, placedStyle(left, top, width, height));
      const hide = (host) => setStyle(host, HOST_STYLE + " display: none !important;");
      // Our hosts are direct children of <html>; put one back there if the page moved or removed it.
      const ensureInPage = (host) => {
        const root = rootElement();
        if (!root || parentOf(host) === root) return false;
        apply(appendChild, root, [host]);
        return true;
      };
      // A page that keeps undoing our repairs (moving, restyling or removing our elements) shouldn't
      // keep us busy: each element gets at most 10 repairs per second, then we give it up.
      const repairBudget = () => {
        const times = [];
        return () => {
          const t = now();
          while (times.length > 0 && t - times[0] >= 1000) times.shift();
          times.push(t);
          return times.length <= 10;
        };
      };
      // Only data:image URLs: loading an icon from elsewhere would be a network request.
      const safeIcon = (url) => (typeof url === "string" && /^data:image\//i.test(url) ? url : null);

      // A real click, by a person, on our element where we put it and as we drew it. This is what
      // stops click-jacking: the page can restyle our host <div> (move it under a lure, fade it out,
      // blow it up) to collect a click the user meant for something else. So at click time:
      //   - the event is trusted (not a script's click() or dispatchEvent);
      //   - the host is still a child of <html>, its style attribute is exactly the one we wrote (our
      //     inline `all: initial !important` can't be beaten by a stylesheet, so any visual trick on
      //     the host itself has to go through that attribute), and its rectangle is where we put it
      //     (±2 px);
      //   - the click point lies inside that rectangle (except Return on a focused menu item, which
      //     has no point; the page can't focus inside our closed shadow root);
      //   - a field button is small (≤ 64 px); the clicked element is visible (checkVisibility); the
      //     host and <html> have opacity ≥ 0.9 and visibility "visible"; and the host, <html> and
      //     <body> have no filter, mask, clip-path or blend mode (each can hide a clickable button).
      // Remaining risk we can't see from here: an overlay with `pointer-events: none` drawn over our
      // button lets a click through while the user sees the overlay. The authoring guide therefore
      // recommends a menu pick before releasing passwords.
      const near = (a, b) => Math.abs(a - b) <= 2;
      const unblended = (el) =>
        styleOf(el, "filter") === "none" && styleOf(el, "mask-image") === "none" &&
        styleOf(el, "-webkit-mask-image") === "none" && styleOf(el, "clip-path") === "none" &&
        styleOf(el, "mix-blend-mode") === "normal";
      const genuineClick = (event, host, element, expected, isMenuItem) => {
        const allowKeyboard = isMenuItem;
        if (event.isTrusted !== true || !expected) return false;
        const root = rootElement();
        if (!root || parentOf(host) !== root) return false;
        if (apply(getAttribute, host, ["style"]) !==
            placedStyle(expected.left, expected.top, expected.width, expected.height)) return false;
        const r = rectOf(host);
        if (!near(r.left, expected.left) || !near(r.top, expected.top) ||
            !near(r.width, expected.width) || !near(r.height, expected.height)) return false;
        const keyboard = allowKeyboard && event.detail === 0 && event.clientX === 0 && event.clientY === 0;
        if (!keyboard && !(event.clientX >= r.left && event.clientX <= r.right &&
                           event.clientY >= r.top && event.clientY <= r.bottom)) return false;
        const e = rectOf(element);
        if (!isMenuItem && (e.width > 64 || e.height > 64)) return false;
        if (typeof checkVisibility === "function" &&
            !apply(checkVisibility, element, [{ opacityProperty: true, visibilityProperty: true }])) return false;
        for (const el of [host, root]) {
          if (!(Number(styleOf(el, "opacity")) >= 0.9) || styleOf(el, "visibility") !== "visible") return false;
        }
        const body = bodyElement();
        for (const el of body ? [host, root, body] : [host, root]) {
          if (!unblended(el)) return false;
        }
        return true;
      };

      const BUTTON_CSS = `
        button { all: initial; box-sizing: border-box; width: 100%; height: 100%; display: flex;
                 align-items: center; justify-content: center; cursor: pointer; border-radius: 4px;
                 background: rgba(127,127,127,0.12); }
        button:hover { background: rgba(127,127,127,0.28); }
        button:focus-visible { outline: 2px solid -webkit-focus-ring-color; }
        img, svg { width: 70%; height: 70%; pointer-events: none; }`;
      // A small key: shown when the plugin gives no icon. (Our own constant markup, not plugin data.)
      const KEY_ICON = `<svg viewBox="0 0 16 16" aria-hidden="true"><path fill="currentColor" d="M10.5 1a4.5 4.5 0 0 0-4.32 5.77L1 11.94V15h3.06l.94-.94V12.5h1.56l.94-.94V10h1.56l.17-.17A4.5 4.5 0 1 0 10.5 1Zm1 3a1.25 1.25 0 1 1 0 2.5 1.25 1.25 0 0 1 0-2.5Z"/></svg>`;

      // ---- 6. Field buttons --------------------------------------------------------------------------
      // One button per input (a Map keyed by the input). Buttons follow their input on scroll, resize
      // and page changes, and go away when the input leaves the page (re-rendered forms).
      const buttons = new Map(); // input -> { host, button, options }
      let framePending = false;

      // Where an input's button belongs (viewport coordinates), or null when the input is too small
      // or off screen. Used for drawing and, at click time, to check nobody moved the button.
      const placement = (input) => {
        const r = rectOf(input);
        if (r.width < 24 || r.height < 12 || r.bottom < 0 || r.top > innerHeight) return null;
        const size = Math.max(12, Math.min(22, r.height - 6));
        return { left: Math.round(r.right - size - 4), top: Math.round(r.top + (r.height - size) / 2), width: size, height: size };
      };
      const samePlace = (a, b) => (a === null && b === null) ||
        (!!a && !!b && a.left === b.left && a.top === b.top && a.width === b.width && a.height === b.height);
      const givenUp = new RealWeakSet(); // inputs whose button the page kept tampering with
      const removeButton = (input, entry) => {
        apply(removeElement, entry.host, []);
        entry.resizeObserver.disconnect();
        buttons.delete(input);
      };
      const layoutButtons = () => {
        framePending = false;
        for (const [input, entry] of buttons) {
          if (!connected(input)) {
            removeButton(input, entry);
            continue;
          }
          const at = placement(input);
          const inputMoved = !samePlace(at, entry.placed);
          const wrote = ensureInPage(entry.host) |
            (at ? place(entry.host, at.left, at.top, at.width, at.height) : hide(entry.host));
          entry.placed = at;
          // A write although the input didn't move means the page changed our element: a repair.
          if (wrote && !inputMoved && !entry.mayRepair()) {
            removeButton(input, entry);
            givenUp.add(input);
            console.warn(`Plugin ${config.pluginID}: the page keeps moving or removing a field button; it was removed.`);
          }
        }
      };
      const scheduleLayout = () => {
        if (framePending || buttons.size === 0) return;
        framePending = true;
        requestFrame(layoutButtons);
      };
      // Any change in the page may move inputs; a change to one of our hosts (the page rewriting its
      // style, say) puts our style back. Writing the same style again is skipped (setStyle), so our
      // own writes end there.
      const pageObserver = new RealMutationObserver((records) => {
        if (openMenu && records.some((r) => r.target === openMenu.host || r.target === rootElement())) {
          openMenu.scheduleRestore();
        }
        scheduleLayout();
      });
      let watching = false;
      const watchPage = () => {
        if (watching) return;
        watching = true;
        pageObserver.observe(document.documentElement, { childList: true, subtree: true, attributes: true });
        on(window, "scroll", scheduleLayout, { capture: true, passive: true });
        on(window, "resize", scheduleLayout, { passive: true });
      };

      /** Puts a button inside the right edge of `input`. Calling it again for the same input updates
       *  the existing button instead of adding another. `onClick(input)` runs only for real clicks. */
      const addFieldButton = (input, options) => {
        if (!(input instanceof HTMLInputElement)) throw new TypeError("addFieldButton needs an <input> element");
        if (givenUp.has(input)) return;
        const title = String(options && options.title ? options.title : "").slice(0, 200);
        const onClick = options && options.onClick;
        if (typeof onClick !== "function") throw new TypeError("addFieldButton needs an onClick function");

        const existing = buttons.get(input);
        if (existing) {
          existing.options = { onClick };
          apply(setAttribute, existing.button, ["title", title]);
          apply(setAttribute, existing.button, ["aria-label", title]);
          return;
        }

        const { host, root } = makeHost();
        const style = make("style");
        setText(style, BUTTON_CSS);
        const button = make("button");
        apply(setAttribute, button, ["type", "button"]);
        apply(setAttribute, button, ["title", title]);
        apply(setAttribute, button, ["aria-label", title]);
        const icon = safeIcon(options.iconURL);
        if (icon) {
          const img = make("img");
          apply(setAttribute, img, ["src", icon]);
          apply(setAttribute, img, ["alt", ""]);
          apply(appendChild, button, [img]);
        } else {
          button.innerHTML = KEY_ICON;
        }
        apply(appendChild, root, [style]);
        apply(appendChild, root, [button]);

        const entry = { input, host, button, options: { onClick }, placed: undefined, mayRepair: repairBudget(),
                        resizeObserver: new RealResizeObserver(scheduleLayout) };
        // Keep the field focused when the button is pressed (some forms validate on blur).
        on(button, "mousedown", (event) => event.preventDefault());
        on(button, "click", (event) => {
          event.preventDefault();
          event.stopPropagation();
          const input = entry.input;
          // Where we drew it must still be where the input wants it, and the click must pass the checks.
          const placed = entry.placed;
          const wanted = placement(input);
          const inPlace = placed && wanted && near(placed.left, wanted.left) && near(placed.top, wanted.top) &&
            near(placed.width, wanted.width) && near(placed.height, wanted.height);
          if (!inPlace || !genuineClick(event, host, button, placed, false)) {
            layoutButtons(); // put it back where it belongs; no action, no token
            return;
          }
          realClickHappened();
          try {
            const result = entry.options.onClick(input);
            if (result && typeof result.catch === "function") {
              result.catch((error) => console.error(`Plugin ${config.pluginID}: button action failed:`, error));
            }
          } catch (error) {
            console.error(`Plugin ${config.pluginID}: button action failed:`, error);
          }
        });
        entry.resizeObserver.observe(input);
        buttons.set(input, entry);
        hide(host);
        ensureInPage(host);
        watchPage();
        scheduleLayout();
      };

      // ---- 7. Menu ------------------------------------------------------------------------------------
      const MENU_CSS = `
        .menu { all: initial; box-sizing: border-box; display: flex; flex-direction: column; min-width: 220px;
                max-width: 360px; max-height: 320px; overflow-y: auto; padding: 4px; border-radius: 8px;
                font: 13px -apple-system, system-ui, sans-serif; color: CanvasText; background: Canvas;
                box-shadow: 0 6px 24px rgba(0,0,0,0.25), 0 0 0 0.5px rgba(0,0,0,0.25); }
        button { all: initial; box-sizing: border-box; display: block; width: 100%; padding: 6px 10px;
                 border-radius: 5px; cursor: pointer; font: inherit; color: inherit; }
        button:hover, button:focus { background: Highlight; color: HighlightText; outline: none; }
        .title, .subtitle { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .subtitle { opacity: 0.7; font-size: 12px; }
        .empty { padding: 6px 10px; opacity: 0.7; }`;
      let openMenu = null; // { host, finish }

      /** Shows a menu under `anchor`. Resolves with the index of the item picked (a real click or
       *  Return), or null when it is dismissed (Escape, a click elsewhere, or another menu). Titles
       *  and subtitles are shown as plain text. An empty list shows "Nothing to show". */
      const showMenu = (anchor, items) => {
        if (!(anchor instanceof Element)) return Promise.reject(new TypeError("showMenu needs an anchor element"));
        if (openMenu) openMenu.finish(null);
        const list = Array.isArray(items) ? items.slice(0, 50) : [];

        return new Promise((resolve) => {
          const { host, root } = makeHost();
          const style = make("style");
          setText(style, MENU_CSS);
          const menu = make("div");
          apply(setAttribute, menu, ["class", "menu"]);
          apply(setAttribute, menu, ["role", "menu"]);
          const itemButtons = [];
          let menuRect = null;      // where we put the menu (checked at click time)
          let scheduleRestore = () => {};   // puts the menu back (next frame) if the page moves or restyles it

          const finish = (value) => {
            if (openMenu && openMenu.host === host) openMenu = null;
            off(window, "pointerdown", outside, true);
            off(window, "keydown", keys, true);
            off(window, "resize", dismiss, true);
            apply(removeElement, host, []);
            resolve(value);
          };
          const dismiss = () => finish(null);
          const outside = (event) => {
            if (event.isTrusted && !event.composedPath().includes(host)) finish(null);
          };
          const keys = (event) => {
            if (!event.isTrusted) return;
            if (event.key === "Escape") { event.preventDefault(); finish(null); return; }
            if (event.key === "ArrowDown" || event.key === "ArrowUp") {
              event.preventDefault();
              const at = itemButtons.indexOf(root.activeElement);
              const step = event.key === "ArrowDown" ? 1 : -1;
              const next = itemButtons[(at + step + itemButtons.length) % itemButtons.length];
              if (next) next.focus({ preventScroll: true });
            }
          };

          list.forEach((item, index) => {
            const button = make("button");
            apply(setAttribute, button, ["type", "button"]);
            apply(setAttribute, button, ["role", "menuitem"]);
            const title = make("span");
            apply(setAttribute, title, ["class", "title"]);
            setText(title, String(item && item.title != null ? item.title : "").slice(0, 200));
            apply(appendChild, button, [title]);
            if (item && item.subtitle != null && item.subtitle !== "") {
              const subtitle = make("span");
              apply(setAttribute, subtitle, ["class", "subtitle"]);
              setText(subtitle, String(item.subtitle).slice(0, 200));
              apply(appendChild, button, [subtitle]);
            }
            on(button, "click", (event) => {
              event.preventDefault();
              event.stopPropagation();
              // Return on a focused item also produces a real click (with no click point).
              if (!genuineClick(event, host, button, menuRect, true)) {
                scheduleRestore();
                return;
              }
              realClickHappened();
              finish(index);
            });
            itemButtons.push(button);
            apply(appendChild, menu, [button]);
          });
          if (itemButtons.length === 0) {
            const empty = make("div");
            apply(setAttribute, empty, ["class", "empty"]);
            setText(empty, "Nothing to show");
            apply(appendChild, menu, [empty]);
          }
          apply(appendChild, root, [style]);
          apply(appendChild, root, [menu]);

          // Below the anchor, or above it when there's no room below.
          const r = rectOf(anchor);
          const height = Math.min(320, Math.max(1, itemButtons.length) * 44 + 8);
          const top = r.bottom + 4 + height > innerHeight && r.top - 4 - height > 0 ? r.top - 4 - height : r.bottom + 4;
          const left = Math.max(4, Math.min(r.left, innerWidth - 364));
          menuRect = { left: Math.round(left), top: Math.round(top), width: 360, height };
          const menuStyle = placedStyle(menuRect.left, menuRect.top, menuRect.width, menuRect.height);
          const restore = () => {
            const moved = ensureInPage(host);
            return setStyle(host, menuStyle) || moved;
          };
          // Repairs happen once per frame at most; a page that undoes them more than 10 times in a
          // second gets the menu closed (resolving null) instead of a fight.
          const mayRepair = repairBudget();
          let restorePending = false;
          scheduleRestore = () => {
            if (restorePending) return;
            restorePending = true;
            requestFrame(() => {
              restorePending = false;
              if (!openMenu || openMenu.host !== host) return;
              if (restore() && !mayRepair()) finish(null);
            });
          };
          restore();
          openMenu = { host, finish, scheduleRestore };
          watchPage();
          on(window, "pointerdown", outside, true);
          on(window, "keydown", keys, true);
          on(window, "resize", dismiss, true);
          if (itemButtons[0]) itemButtons[0].focus({ preventScroll: true });
        });
      };

      // ---- 8. Filling ---------------------------------------------------------------------------------
      // Sets a field the way typing would: the browser's own value setter (so frameworks such as React
      // notice), then "input" and "change" events.
      const setField = (input, value) => {
        if (value == null) return;
        if (!(input instanceof HTMLInputElement)) throw new TypeError("fillLogin needs <input> elements");
        apply(setInputValue, input, [String(value)]);
        input.dispatchEvent(new RealInputEvent("input", { bubbles: true, composed: true, inputType: "insertReplacementText", data: String(value) }));
        input.dispatchEvent(new RealEvent("change", { bubbles: true }));
      };

      /** Fills a login form. Only on sites in the plugin's fillForms permission. */
      const fillLogin = (fields) => {
        if (!fillAllowed) throw new Error("this plugin may not fill forms on this site");
        const f = fields || {};
        if (f.usernameInput) setField(f.usernameInput, f.username);
        if (f.passwordInput) setField(f.passwordInput, f.password);
      };

      // ---- 9. The API ---------------------------------------------------------------------------------
      defineProperty(window, "singularity", {
        value: freeze({ siteMatches, send, addFieldButton, showMenu, fillLogin }),
        writable: false,
        configurable: false,
        enumerable: false,
      });
    })();
    """#
}
