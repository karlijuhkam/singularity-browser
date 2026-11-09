// Runs as a plugin's page script in the plugin's world (see main.swift). For each way of putting a
// frame into the page, it inserts an <iframe src="/slow?..."> (which stays on its initial
// about:blank document, into which WebKit injects no user scripts) and checks the new frame's
// window: cookie, localStorage, fetch and Function must all throw. Frames are found with indexed
// access only (never window.length, which itself locks frames), so each route's own hook is tested.
const say = (text) => webkit.messageHandlers.probeOut.postMessage(String(text));
const results = [];

const framesNow = () => {
  const list = [];
  for (let k = 0; k < 1000; k++) { const w = window[k]; if (!w) break; list.push(w); }
  return list;
};
const state = (w, label) => {
  const open = [];
  const attempt = (name, fn) => { try { fn(); open.push(name); } catch (_) {} };
  attempt("cookie", () => w.document.cookie);
  attempt("localStorage", () => w.localStorage.getItem("jwt"));
  attempt("indexedDB", () => w.indexedDB.open("x"));
  attempt("fetch", () => { const p = w.fetch("/beacon?" + encodeURIComponent(label)); p.catch(() => {}); });
  attempt("Function", () => w.Function("return 1")());
  attempt("eval", () => w.eval("1"));
  return open.length === 0 ? "locked" : "UNLOCKED (" + open.join(", ") + ")";
};
const routeNames = [];
const report = (name, text) => { results.push(text); routeNames.push(name); say("route " + name + ": " + text); };
const check = (name, w) => report(name, w ? state(w, name) : "no frame");
// The new frame whose element loads /slow?<name> (so a frame that appears late from an earlier
// route isn't mistaken for this one).
const frameFor = (name) => framesNow().find((w) => {
  try {
    const e = w.frameElement;
    return !!e && (e.getAttribute("src") || e.getAttribute("data") || "").endsWith("/slow?" + name);
  } catch (_) { return false; }
});
const route = (name, tag, insert) => {
  try { insert(); } catch (e) { report(name, "insert failed: " + e.message); return; }
  check(name, frameFor(tag));
};
const slow = (name) => { const f = document.createElement("iframe"); f.src = "/slow?" + name; return f; };
const box = () => { const d = document.createElement("div"); document.getElementById("box").appendChild(d); return d; };
const html = (name) => '<iframe src="/slow?' + name + '"></iframe>';

// The plugin's own window, and the page's frame that is still loading.
check("own window", window);
check("page frame still loading (window.parserslow)", window.parserslow);

// Node and element insertion.
route("appendChild", "appendChild", () => box().appendChild(slow("appendChild")));
route("insertBefore", "insertBefore", () => { const d = box(); d.insertBefore(slow("insertBefore"), null); });
route("replaceChild", "replaceChild", () => { const d = box(); const s = d.appendChild(document.createElement("span")); d.replaceChild(slow("replaceChild"), s); });
route("append", "append", () => box().append(slow("append")));
route("prepend", "prepend", () => box().prepend(slow("prepend")));
route("before", "before", () => { const d = box(); d.appendChild(document.createElement("span")).before(slow("before")); });
route("after", "after", () => { const d = box(); d.appendChild(document.createElement("span")).after(slow("after")); });
route("replaceWith", "replaceWith", () => { const d = box(); d.appendChild(document.createElement("span")).replaceWith(slow("replaceWith")); });
route("replaceChildren", "replaceChildren", () => box().replaceChildren(slow("replaceChildren")));
route("text.after", "textAfter", () => { const d = box(); d.appendChild(document.createTextNode("t")).after(slow("textAfter")); });
route("insertAdjacentElement", "iae", () => box().insertAdjacentElement("afterbegin", slow("iae")));
route("insertAdjacentHTML", "iah", () => box().insertAdjacentHTML("beforeend", html("iah")));
route("innerHTML", "innerHTML", () => { box().innerHTML = html("innerHTML"); });
route("outerHTML", "outerHTML", () => { const d = box(); const s = d.appendChild(document.createElement("span")); s.outerHTML = html("outerHTML"); });
route("setHTMLUnsafe", "setHTMLUnsafe", () => box().setHTMLUnsafe(html("setHTMLUnsafe")));
route("Range.insertNode", "insertNode", () => { const r = document.createRange(); r.selectNodeContents(box()); r.insertNode(slow("insertNode")); });
route("Range.surroundContents", "surround", () => { const d = box(); d.textContent = "x"; const r = document.createRange(); r.selectNodeContents(d); r.surroundContents(slow("surround")); });
route("execCommand insertHTML", "execCommand", () => {
  const edit = document.getElementById("edit"); edit.focus();
  const r = document.createRange(); r.selectNodeContents(edit);
  const sel = getSelection(); sel.removeAllRanges(); sel.addRange(r);
  document.execCommand("insertHTML", false, html("execCommand"));
});
route("moved frame (prepend existing)", "moved", () => { const d = box(); const f = d.appendChild(slow("moved")); document.getElementById("box").prepend(f); });

// Setters that take a whole node.
const tbl = document.getElementById("tbl");
route("table.caption", "caption", () => { const c = document.createElement("caption"); c.appendChild(slow("caption")); tbl.caption = c; });
route("table.tHead", "thead", () => { const t = document.createElement("thead"); t.insertRow().insertCell().appendChild(slow("thead")); tbl.tHead = t; });
route("table.tFoot", "tfoot", () => { const t = document.createElement("tfoot"); t.insertRow().insertCell().appendChild(slow("tfoot")); tbl.tFoot = t; });
route("DOMParser + adoptNode + caption", "parsed", () => {
  const t = document.createElement("table"); box().appendChild(t);
  const parsed = new DOMParser().parseFromString("<table><caption>" + html("parsed") + "</caption></table>", "text/html");
  t.caption = document.adoptNode(parsed.querySelector("caption"));
});
route("importNode(template.content)", "template", () => box().appendChild(document.importNode(document.getElementById("tpl").content, true)));
route("template.content.cloneNode", "template2", () => box().appendChild(document.getElementById("tpl2").content.cloneNode(true)));

// <select>: an <option> can hold any element.
const option = (name) => { const o = document.createElement("option"); o.appendChild(slow(name)); return o; };
const sel = document.getElementById("sel");
route("select.add", "selectAdd", () => sel.add(option("selectAdd")));
route("select.options.add", "optionsAdd", () => sel.options.add(option("optionsAdd")));
route("select[i] = option (indexed setter)", "selectIndexed", () => { sel[sel.options.length] = option("selectIndexed"); });
route("select.options[i] = option (indexed setter)", "optionsIndexed", () => { sel.options[sel.options.length] = option("optionsIndexed"); });

// Attributes on a connected <object>.
const object = () => { const o = document.createElement("object"); o.type = "text/html"; o.width = 20; o.height = 20; box().appendChild(o); return o; };
route("object.data", "objectData", () => { object().data = "/slow?objectData"; });
route("object.setAttribute(data)", "objectSetAttribute", () => object().setAttribute("data", "/slow?objectSetAttribute"));
route("NamedNodeMap.setNamedItem(data)", "setNamedItem", () => { const o = object(); const a = document.createAttribute("data"); a.value = "/slow?setNamedItem"; o.attributes.setNamedItem(a); });
route("Attr.value on a connected object", "attrValue", () => { const o = object(); o.setAttribute("data", ""); o.getAttributeNode("data").value = "/slow?attrValue"; });

// document.write into a blank child frame (the new frame is a grandchild).
{
  const blank = box().appendChild(document.createElement("iframe"));
  const w = framesNow().find((x) => { try { return x.frameElement === blank; } catch (_) { return false; } });
  if (!w) report("document.write into a child", "no frame");
  else {
    try { w.document.open(); w.document.write(html("written")); w.document.close(); } catch (e) { report("document.write into a child", "insert failed: " + e.message); }
    check("document.write into a child", w[0]);
  }
}

// An <object> makes its frame later, at layout, with no DOM change: reached from a task that isn't
// a timer, animation frame or send() reply (here a MessageChannel), nothing has locked it yet.
const viaMessages = (name, tag, insert, then) => {
  try { insert(); } catch (e) { report(name, "insert failed: " + e.message); then(); return; }
  const channel = new MessageChannel();
  let tries = 0;
  channel.port1.onmessage = () => {
    const w = frameFor(tag);
    if (w || ++tries > 2000) { check(name, w); then(); return; }
    channel.port2.postMessage(0);
  };
  channel.port2.postMessage(0);
};

// Routes the prelude can't hook (see "Known limitations" in the spec): reported, not a surprise.
const knownGaps = new Set(["select[i] = option (indexed setter)", "select.options[i] = option (indexed setter)",
                           "object.setAttribute(data), reached from a MessageChannel task"]);

viaMessages("object.setAttribute(data), reached from a MessageChannel task", "objectLate",
            () => object().setAttribute("data", "/slow?objectLate"), later);

// Later, in a timer: every frame (objects' late frames included), the page's frame once loaded,
// then document.body (last: it replaces the page's body).
function later() {
  setTimeout(() => {
    const where = (w) => { try { const e = w.frameElement; return e ? e.tagName.toLowerCase() + " " + (e.getAttribute("src") || e.getAttribute("data")) : "?"; } catch (_) { return "?"; } };
    const open = framesNow().filter((w) => state(w, "timer") !== "locked");
    report("any frame, from a timer 1.5 s later", open.length === 0 ? "locked" : "UNLOCKED (" + open.map(where).join(", ") + ")");
    check("page frame loaded (window[0])", window[0]);
    route("document.body setter", "body", () => { const b = document.createElement("body"); b.appendChild(slow("body")); document.body = b; });
    const names = [...routeNames];
    const unlocked = names.filter((n, i) => results[i].startsWith("UNLOCKED"));
    const surprises = unlocked.filter((n) => !knownGaps.has(n));
    const noFrame = results.filter((r) => !r.startsWith("UNLOCKED") && r !== "locked").length;
    say("RESULT " + results.length + " routes: " + (results.length - unlocked.length - noFrame) + " locked, " +
        unlocked.length + " unlocked (" + (unlocked.length - surprises.length) + " known gaps, " + surprises.length +
        " new: " + (surprises.join("; ") || "none") + "), " + noFrame + " without a frame");
  }, 1500);
}
