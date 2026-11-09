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
@MainActor
enum PageAgentScript {
    static let world = WKContentWorld.world(name: "singularity-agent")

    static func install(in configuration: WKWebViewConfiguration) {
        let script = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world)
        configuration.userContentController.addUserScript(script)
    }

    static let source = ##"""
    (() => {
      if (window.__singularityAgent) return;

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
      const MEANINGFUL = "a[href],button,input,select,textarea,summary,[role],[tabindex],[contenteditable],h1,h2,h3,h4,h5,h6,img[alt]";
      const INTERACTIVE_ROLES = new Set(["link", "button", "textbox", "searchbox", "combobox", "listbox", "checkbox",
        "radio", "slider", "switch", "tab", "menuitem", "menuitemcheckbox", "menuitemradio", "option", "spinbutton"]);
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
            if (isInteractive(role)) {
              lines.push(`${indent}[${refFor(el)}] ${role} ${quote(nameOf(el, role))}${extrasOf(el, role)}`);
              continue; // the name already covers the contents
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
          results.push(`text ${quote(snippet)}${near ? ` (inside ${describe(near)})` : ""}`);
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

      window.__singularityAgent = Object.freeze({ snapshot, find, click, type, inspect });
    })();
    """##
}
