import Foundation

/// `sg-compat.js`, the stand-ins file `CompatAdapter` puts at the top of an adapted extension and
/// loads first wherever the extension runs code (content scripts, pages, the background).
///
/// What it does:
/// - Defines `globalThis.__sg`: for each namespace, the real `chrome.<ns>` with the stand-ins below
///   behind it. **The real member always wins**; a stand-in only answers where WebKit has nothing.
///   The rewritten code (`CompatSource.rewrite`) reads the missing members from here.
/// - Assigns whole missing namespaces (`idle`, `management`, …) onto the real `chrome` object,
///   which WebKit allows (it ignores new members of *existing* namespaces, hence `__sg`).
///
/// Stand-ins answer as Chrome does when a feature is off or empty, and grant nothing: events never
/// fire, settings read "off and not controllable" and can't be set, downloads and enabling other
/// extensions are refused, notifications are accepted and not shown. Nothing is logged.
public enum CompatStandIns {
    public static let fileName = "sg-compat.js"

    public static let script = #"""
// Singularity: stand-ins for Chrome extension APIs WebKit doesn't have. Generated; logs nothing.
(() => {
  "use strict";
  const g = globalThis;
  // An own property only: a page's `<div id="__sg">` shows up on the window, but not as its own.
  if (Object.prototype.hasOwnProperty.call(g, "__sg")) return;
  const real = g.chrome || g.browser;
  if (!real || !real.runtime) return;
  const event = () => {
    const listeners = new Set();
    return {
      addListener: (f) => { listeners.add(f); },
      removeListener: (f) => { listeners.delete(f); },
      hasListener: (f) => listeners.has(f),
      hasListeners: () => listeners.size > 0,
    };
  };
  // Both forms: a callback as the last argument, or a Promise.
  const api = (fn) => function (...args) {
    const callback = typeof args[args.length - 1] === "function" ? args.pop() : null;
    const result = new Promise((resolve) => resolve(fn(...args)));
    if (callback) { result.then((value) => callback(value), () => callback()); return undefined; }
    return result;
  };
  const refuse = (text) => () => { throw new Error(text); };
  const self = () => {
    const m = typeof real.runtime.getManifest === "function" ? (real.runtime.getManifest() || {}) : {};
    return {
      id: real.runtime.id, name: m.name || "", shortName: m.short_name || m.name || "", description: m.description || "",
      version: m.version || "", enabled: true, installType: "normal", type: "extension", mayDisable: false,
      offlineEnabled: false, optionsUrl: "", permissions: [], hostPermissions: [],
    };
  };
  const setting = () => ({
    get: api(() => ({ value: false, levelOfControl: "not_controllable" })),
    set: api(refuse("This setting can't be changed in Singularity.")),
    clear: api(refuse("This setting can't be changed in Singularity.")),
    onChange: event(),
  });
  let notificationID = 0;
  const extras = {
    idle: {
      queryState: api(() => "active"), setDetectionInterval: () => {}, getAutoLockDelay: api(() => 0),
      onStateChanged: event(),
    },
    management: {
      getSelf: api(self), getAll: api(() => [self()]),
      get: api((id) => { if (id === real.runtime.id) return self(); throw new Error("No extension with that id."); }),
      setEnabled: api(refuse("Extensions can't switch other extensions on or off in Singularity.")),
      onEnabled: event(), onDisabled: event(), onInstalled: event(), onUninstalled: event(),
    },
    privacy: {
      services: {
        passwordSavingEnabled: setting(), autofillEnabled: setting(), autofillAddressEnabled: setting(),
        autofillCreditCardEnabled: setting(),
      },
    },
    downloads: {
      download: api(refuse("Downloads from extensions aren't available in Singularity.")),
      search: api(() => []), onChanged: event(), onCreated: event(), onErased: event(),
    },
    notifications: {
      create: api((a) => (typeof a === "string" ? a : "sg-" + (++notificationID))),
      update: api(() => false), clear: api(() => false), getAll: api(() => ({})), getPermissionLevel: api(() => "granted"),
      onClicked: event(), onClosed: event(), onButtonClicked: event(),
    },
    webNavigation: {
      onCreatedNavigationTarget: event(), onHistoryStateUpdated: event(), onReferenceFragmentUpdated: event(),
      onTabReplaced: event(),
    },
    webRequest: { onAuthRequired: event(), onBeforeRedirect: event(), onSendHeaders: event(), onResponseStarted: event() },
    runtime: {
      requestUpdateCheck: api(() => ({ status: "no_update" })),
      onSuspend: event(), onMessageExternal: event(), onConnectExternal: event(), onUpdateAvailable: event(),
      onRestartRequired: event(),
    },
    permissions: { addHostAccessRequest: api(() => undefined), removeHostAccessRequest: api(() => undefined) },
    action: { getUserSettings: api(() => ({ isOnToolbar: true })) },
    storage: { managed: { get: api(() => ({})), getBytesInUse: api(() => 0), onChanged: event() } },
    windows: { onFocusChanged: event(), onCreated: event() },
  };
  for (const ns of ["idle", "management", "privacy", "downloads", "notifications"]) {
    if (real[ns] === undefined) { try { real[ns] = extras[ns]; } catch (e) { /* stays missing */ } }
  }
  // The real value wins; a stand-in answers only where the real object has nothing.
  const merge = (actual, standIn) => {
    if (actual === undefined || actual === null) return standIn;
    if (standIn === undefined || typeof actual !== "object") return actual;
    return new Proxy(actual, {
      get(target, key) {
        const value = Reflect.get(target, key);
        if (value === undefined) return standIn[key];
        if (typeof value === "function") return value.bind(target);
        if (value && typeof value === "object" && standIn[key] && typeof standIn[key] === "object") return merge(value, standIn[key]);
        return value;
      },
      has(target, key) { return key in target || key in standIn; },
    });
  };
  Object.defineProperty(g, "__sg", {
    // `sgCompat` tells the rewritten code this is ours (see CompatSource.replacement).
    value: new Proxy({}, { get: (_, ns) => (ns === "sgCompat" ? true : merge(real[ns], extras[ns])), has: (_, ns) => ns in real || ns in extras }),
    writable: false, configurable: false, enumerable: false,
  });
})();
"""#
}
