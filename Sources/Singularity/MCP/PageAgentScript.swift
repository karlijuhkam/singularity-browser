import WebKit

/// The JavaScript that lets agents read and operate web pages: `read_page`, `find`, `click`, `type`.
///
/// It is injected into every web and artifact tab at document start, into a separate
/// *content world*. A content world is an isolated JavaScript environment over the same DOM: the
/// page's own scripts cannot see or modify `window.__singularityAgent`, nor the refs it hands out.
///
/// Refs: each element gets a number the first time it is reported, remembered in a WeakMap for
/// the life of the page. The same element keeps its ref across calls, even as other parts of the
/// DOM change. An element that was removed (e.g. re-rendered) gets a new ref when seen again.
///
/// Frames: the script runs in every frame (each document has its own refs and a random `key`).
/// WebKit has no public list of a page's frames, so a parent introduces each child: it posts
/// `{__singularityAgentFrame: <token>}` to the iframe's window, and the child's listener (added
/// at document start, so before any of the page's own) swallows that message and reports the
/// token and its key to the app's `singularityAgentFrame` handler, which only exists in this
/// world. The handler's `WKScriptMessage.frameInfo` is what `callAsyncJavaScript(in:)` needs to
/// reach that frame later (`AgentFrames`). The page's own listeners never see the message.
@MainActor
enum PageAgentScript {
    static let world = WKContentWorld.world(name: "singularity-agent")
    /// The message handler, in `world` only, through which frames introduce themselves.
    static let frameHandlerName = "singularityAgentFrame"

    static func install(in configuration: WKWebViewConfiguration) {
        let script = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world)
        configuration.userContentController.addUserScript(script)
        configuration.userContentController.add(AgentFrameRelay.shared, contentWorld: world, name: frameHandlerName)
    }

    static let source = ##"""
    (() => {
      if (window.__singularityAgent) return;

      // ---- frames -------------------------------------------------------------------------
      // This document's key: refs are only valid in the document that handed them out.
      const key = (crypto.randomUUID && crypto.randomUUID()) || String(Math.random()).slice(2) + String(Date.now());
      // A parent's introduction (see the Swift comment above). Capture phase, added first.
      window.addEventListener("message", (event) => {
        const data = event.data;
        if (!data || typeof data !== "object" || typeof data.__singularityAgentFrame !== "string") return;
        event.stopImmediatePropagation();
        try {
          window.webkit.messageHandlers.singularityAgentFrame.postMessage({ token: data.__singularityAgentFrame, key });
        } catch (e) {}
      }, true);
      const MAX_FRAMES = 50;
      const frameByToken = new Map(); // token -> WeakRef(iframe element)
      const newToken = () => ((crypto.randomUUID && crypto.randomUUID()) || String(Math.random()).slice(2));
      // Asks a child frame to introduce itself to the app under a fresh token.
      const tokenOfFrame = new WeakMap(); // iframe element -> its token (one per element, so the map stays small)
      const announce = (el) => {
        let token = tokenOfFrame.get(el);
        if (!token) { token = newToken(); tokenOfFrame.set(el, token); frameByToken.set(token, new WeakRef(el)); }
        try { el.contentWindow && el.contentWindow.postMessage({ __singularityAgentFrame: token }, "*"); } catch (e) {}
        return token;
      };
      const frameLabel = (el) => clean(el.getAttribute("title") || el.getAttribute("aria-label") || el.getAttribute("name")
        || el.getAttribute("src") || "", 80);
      const isFrame = (el) => el.tagName === "IFRAME" || el.tagName === "FRAME";
      // The iframe elements of this document (open shadow roots included), in order.
      const frameElements = () => {
        const out = [];
        const visit = (root) => {
          for (const el of root.querySelectorAll("*")) {
            if (isFrame(el)) out.push(el);
            if (el.shadowRoot) visit(el.shadowRoot);
          }
        };
        if (document.documentElement) visit(document);
        return out;
      };
      // For `find`: introduces this document's visible frames; returns their tokens.
      const listFrames = () => JSON.stringify(frameElements().filter((el) => !isHidden(el)).slice(0, MAX_FRAMES).map(announce));

      // ---- refs ---------------------------------------------------------------------------
      const refToElement = new Map();   // number -> WeakRef(element)
      const elementToRef = new WeakMap(); // element -> number
      let nextRef = 1;
      const refFor = (el) => {
        let ref = elementToRef.get(el);
        if (!ref) {
          ref = nextRef++;
          elementToRef.set(el, ref);
          refToElement.set(ref, new WeakRef(el));
        }
        return ref;
      };
      const lookup = (ref) => {
        const el = refToElement.get(Number(ref))?.deref();
        if (!el || !el.isConnected) {
          throw new Error(`No element with ref ${ref} on the current page (it may have changed). Call read_page again.`);
        }
        return el;
      };

      // ---- helpers ------------------------------------------------------------------------
      const SKIP_TAGS = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "HEAD", "META", "LINK", "SVG", "CANVAS"]);
      const MEANINGFUL = "a[href],button,input,select,textarea,summary,[role],[tabindex],[contenteditable],h1,h2,h3,h4,h5,h6,img[alt],iframe,frame,[draggable=true],[onclick]";
      const INTERACTIVE_ROLES = new Set(["link", "button", "textbox", "searchbox", "combobox", "listbox", "checkbox",
        "radio", "slider", "switch", "tab", "menuitem", "menuitemcheckbox", "menuitemradio", "option", "spinbutton",
        "clickable", "draggable"]);
      const TEXT_ROLES = new Set(["textbox", "searchbox", "combobox", "spinbutton"]);
      const LANDMARKS = new Set(["navigation", "main", "form", "dialog", "banner", "contentinfo", "complementary", "search", "region"]);

      const clean = (text, max = 100) => {
        const s = (text || "").replace(/\s+/g, " ").trim();
        return s.length > max ? s.slice(0, max - 1) + "…" : s;
      };
      const quote = (s) => `"${s.replace(/"/g, "'")}"`;

      const isHidden = (el) => {
        if (el.hidden || el.getAttribute("aria-hidden") === "true") return true;
        const style = getComputedStyle(el);
        if (style.display === "none" || style.visibility === "hidden" || style.visibility === "collapse") return true;
        if (style.display === "contents") return false;
        const rect = el.getBoundingClientRect();
        return rect.width === 0 && rect.height === 0 && style.overflow !== "visible";
      };

      const roleOf = (el) => {
        const explicit = el.getAttribute("role");
        if (explicit) return explicit.trim().split(/\s+/)[0];
        switch (el.tagName) {
          case "A": return el.hasAttribute("href") ? "link" : null;
          case "BUTTON": case "SUMMARY": return "button";
          case "SELECT": return el.multiple ? "listbox" : "combobox";
          case "TEXTAREA": return "textbox";
          case "IMG": return el.getAttribute("alt") ? "img" : null;
          case "H1": case "H2": case "H3": case "H4": case "H5": case "H6": return "heading";
          case "NAV": return "navigation";
          case "MAIN": return "main";
          case "FORM": return "form";
          case "DIALOG": return "dialog";
          case "INPUT": {
            const type = (el.getAttribute("type") || "text").toLowerCase();
            if (type === "hidden") return null;
            if (["button", "submit", "reset", "image"].includes(type)) return "button";
            if (type === "checkbox") return "checkbox";
            if (type === "radio") return "radio";
            if (type === "range") return "slider";
            if (type === "search") return "searchbox";
            if (type === "number") return "spinbutton";
            return "textbox";
          }
        }
        if (el.isContentEditable && el.hasAttribute("contenteditable")) return "textbox";
        if (el.hasAttribute("tabindex") && el.tabIndex >= 0) return "focusable";
        // No role, but made to be dragged or clicked (Playwright lists these too).
        if (el.getAttribute("draggable") === "true") return "draggable";
        if (el.hasAttribute("onclick")) return "clickable";
        if (el.tagName !== "BODY" && el.tagName !== "HTML" && getComputedStyle(el).cursor === "pointer"
            && !(el.parentElement && getComputedStyle(el.parentElement).cursor === "pointer")) return "clickable";
        return null;
      };

      const isInteractive = (role) => INTERACTIVE_ROLES.has(role) || role === "focusable";

      const nameOf = (el, role) => {
        const label = el.getAttribute("aria-label");
        if (label && clean(label)) return clean(label);
        const labelledBy = el.getAttribute("aria-labelledby");
        if (labelledBy) {
          const text = labelledBy.split(/\s+/).map((id) => document.getElementById(id)?.textContent || "").join(" ");
          if (clean(text)) return clean(text);
        }
        if (el.labels && el.labels.length) {
          const text = Array.from(el.labels).map((l) => l.textContent).join(" ");
          if (clean(text)) return clean(text);
        }
        if (el.tagName === "IMG") return clean(el.getAttribute("alt"));
        if (el.tagName === "INPUT" && ["button", "submit", "reset"].includes((el.type || "").toLowerCase())) {
          return clean(el.value || el.type);
        }
        if (!TEXT_ROLES.has(role)) {
          const text = clean(el.innerText || el.textContent);
          if (text) return text;
        }
        return clean(el.getAttribute("placeholder") || el.getAttribute("title") || el.getAttribute("name") || "");
      };

      const extrasOf = (el, role) => {
        const parts = [];
        if (TEXT_ROLES.has(role) && "value" in el && el.value) {
          parts.push(`value=${quote(el.type === "password" ? "••••" : clean(el.value, 60))}`);
        }
        if (role === "slider" && "value" in el) parts.push(`value=${quote(clean(String(el.value), 30))}`);
        if (role === "combobox" && el.tagName === "SELECT" && el.selectedOptions?.length) {
          parts.push(`selected=${quote(clean(el.selectedOptions[0].textContent, 60))}`);
        }
        if (role === "checkbox" || role === "radio" || role === "switch") {
          const checked = "checked" in el ? el.checked : el.getAttribute("aria-checked") === "true";
          parts.push(checked ? "checked" : "unchecked");
        }
        if (el.disabled || el.getAttribute("aria-disabled") === "true") parts.push("disabled");
        const expanded = el.getAttribute("aria-expanded");
        if (expanded) parts.push(expanded === "true" ? "expanded" : "collapsed");
        if (role === "link") {
          const href = el.getAttribute("href") || "";
          if (href && !href.startsWith("javascript:")) parts.push(`href=${quote(clean(href, 80))}`);
        }
        return parts.length ? " " + parts.join(" ") : "";
      };

      const describe = (el) => {
        const role = roleOf(el) || el.tagName.toLowerCase();
        return `[${refFor(el)}] ${role} ${quote(nameOf(el, role))}`;
      };

      // ---- read_page ------------------------------------------------------------------------
      const snapshot = (maxChars) => {
        const lines = [];
        let visited = 0;
        let framesSeen = 0;
        const LIMIT = 8000;

        const walk = (node, depth) => {
          for (const child of node.childNodes) {
            if (visited > LIMIT) return;
            if (child.nodeType === Node.TEXT_NODE) {
              const text = clean(child.textContent, 300);
              if (text) lines.push(`${"  ".repeat(depth)}text ${quote(text)}`);
              continue;
            }
            if (child.nodeType !== Node.ELEMENT_NODE) continue;
            const el = child;
            visited++;
            if (SKIP_TAGS.has(el.tagName) || isHidden(el)) continue;

            const role = roleOf(el);
            const indent = "  ".repeat(depth);
            if (isFrame(el)) {
              // The app replaces this line with the frame's own outline (AgentFrames).
              if (framesSeen++ < MAX_FRAMES) lines.push(`${indent}@@frame ${announce(el)}@@ ${quote(frameLabel(el))}`);
              else lines.push(`${indent}iframe ${quote(frameLabel(el))} (not read: too many frames)`);
              continue;
            }
            if (isInteractive(role)) {
              lines.push(`${indent}[${refFor(el)}] ${role} ${quote(nameOf(el, role))}${extrasOf(el, role)}`);
              // A <select>'s choices (pick one with type), and a listbox's or menu's options.
              if (el.tagName === "SELECT") {
                Array.from(el.options).slice(0, 20).forEach((o) =>
                  lines.push(`${indent}  option ${quote(clean(o.textContent, 80))}${o.selected ? " selected" : ""}`));
                if (el.options.length > 20) lines.push(`${indent}  … ${el.options.length - 20} more options`);
              } else if (role === "listbox" || role === "menu" || role === "tree" || role === "radiogroup" || role === "tablist") {
                walk(el, depth + 1);
              }
              continue; // the name already covers the contents
            }
            // Tables: one line per row of plain cells, so columns stay together.
            if (el.tagName === "TABLE") {
              lines.push(`${indent}table:`);
              walk(el, depth + 1);
              continue;
            }
            if (["THEAD", "TBODY", "TFOOT"].includes(el.tagName)) {
              walk(el, depth);
              continue;
            }
            if (el.tagName === "TR" && !el.querySelector(MEANINGFUL)) {
              const cells = Array.from(el.cells).map((c) => quote(clean(c.innerText, 80)));
              if (cells.length) lines.push(`${indent}row: ${cells.join(" | ")}`);
              continue;
            }
            if (role === "heading") {
              const level = /^H[1-6]$/.test(el.tagName) ? el.tagName[1] : (el.getAttribute("aria-level") || "?");
              lines.push(`${indent}heading ${quote(nameOf(el, role))} (level ${level})`);
              continue;
            }
            if (role === "img") {
              lines.push(`${indent}img ${quote(nameOf(el, role))}`);
              continue;
            }
            if (LANDMARKS.has(role)) {
              const label = el.getAttribute("aria-label");
              lines.push(`${indent}${role}${label ? " " + quote(clean(label)) : ""}:`);
              walk(el, depth + 1);
              continue;
            }
            if (el.shadowRoot) {
              walk(el.shadowRoot, depth);
            }
            // A block with text but nothing to interact with inside: one line of text.
            if (!el.querySelector(MEANINGFUL) && !el.shadowRoot) {
              const text = clean(el.innerText, 300);
              if (text) lines.push(`${indent}text ${quote(text)}`);
              continue;
            }
            walk(el, depth);
          }
        };

        if (document.body) walk(document.body, 0);

        const header = `Title: ${document.title}\nURL: ${location.href}\n`;
        let output = header;
        let shown = 0;
        for (const line of lines) {
          if (output.length + line.length + 1 > maxChars) break;
          output += line + "\n";
          shown++;
        }
        if (shown < lines.length) {
          output += `… truncated: ${lines.length - shown} more lines. Use find(tab_id, query) to locate specific elements.\n`;
        } else if (visited > LIMIT) {
          output += `… page is very large; stopped after ${LIMIT} elements. Use find(tab_id, query).\n`;
        }
        return output;
      };

      // ---- find -------------------------------------------------------------------------------
      const find = (query, maxResults) => {
        const needle = String(query).toLowerCase().trim();
        if (!needle) throw new Error("find needs a non-empty query");
        const results = [];
        const seen = new Set();
        for (const el of document.body ? document.body.querySelectorAll("*") : []) {
          if (results.length >= maxResults) break;
          if (SKIP_TAGS.has(el.tagName)) continue;
          const role = roleOf(el);
          if (isInteractive(role)) {
            const name = nameOf(el, role);
            const haystack = [name, el.getAttribute("placeholder"), el.getAttribute("href"), "value" in el ? el.value : ""]
              .filter(Boolean).join(" ").toLowerCase();
            if (haystack.includes(needle) && !isHidden(el)) {
              results.push(`[${refFor(el)}] ${role} ${quote(name)}${extrasOf(el, role)}`);
            }
            continue;
          }
          // Text matches: the smallest element whose own text contains the query.
          if (el.querySelector(MEANINGFUL)) continue;
          const text = (el.innerText || "").replace(/\s+/g, " ");
          const index = text.toLowerCase().indexOf(needle);
          if (index < 0 || seen.has(text) || isHidden(el)) continue;
          seen.add(text);
          const start = Math.max(0, index - 60);
          const snippet = (start > 0 ? "…" : "") + text.slice(start, index + needle.length + 60).trim() + "…";
          const near = el.closest("a[href],button,[role=button],[role=link]");
          // A ref for the text's element too: something to hover, or to click when it is clickable.
          results.push(`[${refFor(el)}] text ${quote(snippet)}${near ? ` (inside ${describe(near)})` : ""}`);
        }
        return results.length ? results.join("\n") : `No matches for ${quote(String(query))}.`;
      };

      // ---- click / type --------------------------------------------------------------------------
      const click = (ref) => {
        const el = lookup(ref);
        el.scrollIntoView({ block: "center", inline: "center" });
        const rect = el.getBoundingClientRect();
        const init = { bubbles: true, cancelable: true, composed: true, button: 0,
                       clientX: rect.left + rect.width / 2, clientY: rect.top + rect.height / 2 };
        el.dispatchEvent(new PointerEvent("pointerdown", init));
        el.dispatchEvent(new MouseEvent("mousedown", init));
        if (typeof el.focus === "function") el.focus({ preventScroll: true });
        el.dispatchEvent(new PointerEvent("pointerup", init));
        el.dispatchEvent(new MouseEvent("mouseup", init));
        el.click();
        return `Clicked ${describe(el)}.`;
      };

      const type = (ref, text, submit) => {
        const el = lookup(ref);
        el.scrollIntoView({ block: "center" });
        el.focus();
        if (el.isContentEditable) {
          document.execCommand("selectAll", false);
          document.execCommand("insertText", false, text);
        } else if (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) {
          // Use the browser's own value setter, then announce the change the way typing would.
          // This also works with frameworks such as React that watch the value property.
          const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
          Object.getOwnPropertyDescriptor(proto, "value").set.call(el, text);
          el.dispatchEvent(new InputEvent("input", { bubbles: true, composed: true, inputType: "insertText", data: text }));
          el.dispatchEvent(new Event("change", { bubbles: true }));
        } else if (el instanceof HTMLSelectElement) {
          const option = Array.from(el.options).find((o) => o.value === text || clean(o.textContent) === text);
          if (!option) throw new Error(`No option ${quote(text)} in ${describe(el)}.`);
          el.value = option.value;
          el.dispatchEvent(new Event("input", { bubbles: true }));
          el.dispatchEvent(new Event("change", { bubbles: true }));
        } else {
          throw new Error(`${describe(el)} is not a text field.`);
        }

        let submitted = "";
        if (submit) {
          const keyInit = { key: "Enter", code: "Enter", keyCode: 13, which: 13, bubbles: true, cancelable: true, composed: true };
          const notCancelled = el.dispatchEvent(new KeyboardEvent("keydown", keyInit));
          el.dispatchEvent(new KeyboardEvent("keypress", keyInit));
          el.dispatchEvent(new KeyboardEvent("keyup", keyInit));
          const form = el.form || el.closest("form");
          if (notCancelled && form) {
            if (typeof form.requestSubmit === "function") form.requestSubmit(); else form.submit();
            submitted = " and submitted the form";
          } else {
            submitted = " and pressed Enter";
          }
        }
        return `Typed into ${describe(el)}${submitted}.`;
      };

      // ---- hover and drag: script events (real mouse moves don't reach a page in the background) --
      let hovered = null;
      const centre = (el) => {
        const r = el.getBoundingClientRect();
        return { clientX: r.left + r.width / 2, clientY: r.top + r.height / 2 };
      };
      const fire = (el, Type, name, extra) =>
        el.dispatchEvent(new Type(name, Object.assign({ bubbles: !/enter|leave/.test(name), cancelable: true, composed: true, view: window }, extra)));
      // Entering an element enters its ancestors too (mouseenter doesn't bubble, so each gets its own).
      const chain = (el) => { const out = []; for (let n = el; n && n.nodeType === 1; n = n.parentElement) out.push(n); return out; };
      const hover = (ref) => {
        const el = lookup(ref);
        el.scrollIntoView({ block: "center", inline: "center" });
        const at = centre(el);
        const now = chain(el);
        const before = hovered && hovered.isConnected ? chain(hovered) : [];
        if (hovered && hovered !== el && hovered.isConnected) {
          fire(hovered, PointerEvent, "pointerout", at); fire(hovered, MouseEvent, "mouseout", at);
          for (const left of before.filter((n) => !now.includes(n))) {
            fire(left, PointerEvent, "pointerleave", at); fire(left, MouseEvent, "mouseleave", at);
          }
        }
        fire(el, PointerEvent, "pointerover", at); fire(el, MouseEvent, "mouseover", at);
        for (const entered of now.filter((n) => !before.includes(n)).reverse()) {
          fire(entered, PointerEvent, "pointerenter", at); fire(entered, MouseEvent, "mouseenter", at);
        }
        fire(el, PointerEvent, "pointermove", at); fire(el, MouseEvent, "mousemove", at);
        hovered = el;
        return `Pointed at ${describe(el)}`;
      };
      const drag = (fromRef, toRef) => {
        const from = lookup(fromRef), to = lookup(toRef);
        from.scrollIntoView({ block: "center", inline: "center" });
        const a = centre(from), b = centre(to);
        const data = new DataTransfer();
        const button = { button: 0, buttons: 1 };
        fire(from, PointerEvent, "pointerdown", Object.assign({}, a, button));
        fire(from, MouseEvent, "mousedown", Object.assign({}, a, button));
        fire(from, DragEvent, "dragstart", Object.assign({ dataTransfer: data }, a));
        const steps = 5;
        for (let i = 1; i <= steps; i++) {
          const at = { clientX: a.clientX + (b.clientX - a.clientX) * i / steps, clientY: a.clientY + (b.clientY - a.clientY) * i / steps };
          const over = document.elementFromPoint(at.clientX, at.clientY) || to;
          fire(over, PointerEvent, "pointermove", Object.assign({}, at, button));
          fire(over, MouseEvent, "mousemove", Object.assign({}, at, button));
          fire(from, DragEvent, "drag", Object.assign({ dataTransfer: data }, at));
        }
        fire(to, DragEvent, "dragenter", Object.assign({ dataTransfer: data }, b));
        fire(to, DragEvent, "dragover", Object.assign({ dataTransfer: data }, b));
        fire(to, DragEvent, "drop", Object.assign({ dataTransfer: data }, b));
        fire(from, DragEvent, "dragend", Object.assign({ dataTransfer: data }, b));
        fire(to, PointerEvent, "pointerup", Object.assign({}, b, { button: 0, buttons: 0 }));
        fire(to, MouseEvent, "mouseup", Object.assign({}, b, { button: 0, buttons: 0 }));
        return `Dragged ${describe(from)} onto ${describe(to)}`;
      };

      // ---- positions, for real clicks (AgentInput) ------------------------------------------
      // The element of a point, looking into open shadow roots.
      const deepElementFromPoint = (x, y) => {
        let el = document.elementFromPoint(x, y);
        while (el && el.shadowRoot) {
          const inner = el.shadowRoot.elementFromPoint(x, y);
          if (!inner || inner === el) break;
          el = inner;
        }
        return el;
      };
      const reaches = (target, hit) => {
        for (let node = hit; node; node = node.parentNode || node.host) if (node === target) return true;
        return false;
      };
      // The centre of an element in this frame's viewport, scrolled into view, and what is on top
      // of it there. `visible` false: it has no box to click (hidden, e.g. a CSS-hover submenu).
      // A real mouse down on these opens a native menu or picker in front of the owner.
      const NATIVE_POPUP_INPUTS = new Set(["color", "date", "datetime-local", "month", "week", "time"]);
      const point = (ref) => {
        const el = lookup(ref);
        if (el.tagName === "SELECT" || (el.tagName === "INPUT" && NATIVE_POPUP_INPUTS.has((el.getAttribute("type") || "").toLowerCase()))) {
          return JSON.stringify({ visible: false, reason: "menu" });
        }
        if (isHidden(el)) return JSON.stringify({ visible: false, reason: "hidden" });
        el.scrollIntoView({ block: "center", inline: "center" });
        const rect = el.getBoundingClientRect();
        if (rect.width === 0 || rect.height === 0) return JSON.stringify({ visible: false, reason: "hidden" });
        const x = rect.left + rect.width / 2, y = rect.top + rect.height / 2;
        const hit = deepElementFromPoint(x, y);
        // Nothing there: the point is outside the viewport (a skip link at left:-10000px).
        if (!hit) return JSON.stringify({ visible: false, reason: "offscreen" });
        const label = el.tagName === "INPUT" || el.tagName === "SELECT" || el.tagName === "TEXTAREA" ? Array.from(el.labels || []) : [];
        const covered = reaches(el, hit) || label.some((l) => reaches(l, hit)) ? null : describe(hit);
        return JSON.stringify({ visible: true, x, y, covered });
      };
      // Where a point of a child frame (frame-relative CSS px) is in this frame's viewport, and what
      // is on top of it there. The iframe's border and padding are its content box's offset.
      const frameOffset = (token, x, y) => {
        const el = frameByToken.get(token)?.deref();
        if (!el || !el.isConnected) throw new Error("That frame is gone from the page. Call read_page again.");
        const at = () => {
          const rect = el.getBoundingClientRect();
          const style = getComputedStyle(el);
          return [rect.left + el.clientLeft + parseFloat(style.paddingLeft || "0") + x,
                  rect.top + el.clientTop + parseFloat(style.paddingTop || "0") + y];
        };
        let [ax, ay] = at();
        if (ax < 0 || ay < 0 || ax > innerWidth || ay > innerHeight) {
          el.scrollIntoView({ block: "center", inline: "center" });
          [ax, ay] = at();
        }
        const hit = deepElementFromPoint(ax, ay);
        return JSON.stringify({ visible: true, x: ax, y: ay, covered: hit === el ? null : (hit ? describe(hit) : "nothing") });
      };
      // The focused element, for press_key's approval: is Enter a form submission? a password?
      const focusInfo = () => {
        const el = document.activeElement;
        if (!el || el === document.body) return JSON.stringify({ description: "the page", inForm: false, isPassword: false });
        // Focus is inside a frame: the app asks that frame (AgentToolbox.focusedElement).
        if (isFrame(el)) return JSON.stringify({ description: describe(el), inForm: false, isPassword: false, frameToken: announce(el) });
        return JSON.stringify({
          description: describe(el),
          inForm: !!(el.form || el.closest("form")),
          isPassword: el.tagName === "INPUT" && (el.getAttribute("type") || "").toLowerCase() === "password",
        });
      };
      // Before real keystrokes into a field: focus it and select what is in it, so typing replaces it.
      const focusAndSelect = (ref) => {
        const el = lookup(ref);
        el.focus();
        if (el.isContentEditable) document.execCommand("selectAll", false);
        else if (typeof el.select === "function") { try { el.select(); } catch (e) {} }
        return describe(el);
      };

      // ---- inspect (for approvals: what would acting on this element do?) -------------------
      const inspect = (ref) => {
        const el = lookup(ref);
        const role = roleOf(el) || el.tagName.toLowerCase();
        const form = el.form || el.closest("form");
        const tag = el.tagName;
        const type = (el.getAttribute("type") || "").toLowerCase();
        // Clicking these submits their form: submit buttons/inputs, and <button> without a type.
        const submits = !!form && ((tag === "BUTTON" && (type === "" || type === "submit"))
          || (tag === "INPUT" && (type === "submit" || type === "image")));
        const link = el.closest("a[href]");
        const href = link && !link.getAttribute("href").startsWith("javascript:") ? link.href : null;
        return JSON.stringify({
          description: describe(el),
          submits,
          href,
          isPassword: tag === "INPUT" && type === "password",
        });
      };

      window.__singularityAgent = Object.freeze({ key, snapshot, find, listFrames, click, type, inspect,
                                                  point, frameOffset, focusInfo, focusAndSelect, hover, drag });
    })();
    """##
}
