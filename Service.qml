import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Owns the conversation with Venice.ai. The bar widget is instantiated once
// per monitor, so this lives in a `service` plugin and is shared: one poll,
// one token read, one set of state for every screen.
Item {
  id: root

  property var settings: ({})
  property bool active: true

  // ------------------------------------------------------------ published

  property var snapshot: null
  property bool hasToken: false
  property bool needsToken: false
  property bool loading: false
  property bool refreshing: false
  property bool storeBusy: false
  property bool backendPaused: false
  property bool pendingRefresh: false
  property string errorKind: ""
  property string lastError: ""
  property string storeError: ""
  property string storage: "keyring"
  property double lastUpdated: 0
  property double now: Date.now()

  // App launcher state. "unknown" until checkApp() returns; statuses mirror
  // the ones the panel renders: missing / installed / outdated / foreign.
  property string appStatus: "unknown"
  property string appUrl: ""
  property string appError: ""
  property bool appBusy: false
  property bool appAutoChecked: false
  property bool appCheckPending: false

  readonly property string pluginDirectory: Model.fileUrlPath(Qt.resolvedUrl("."))
  readonly property string helperPath: pluginDirectory + "/bin/venice-billing"
  readonly property string appHelperPath: pluginDirectory + "/bin/venice-app"

  // A widget with no shell.json overrides legitimately receives {}, so
  // "settings arrived" is an explicit handshake from the panel rather than a
  // property of the object.
  property bool settingsReady: false
  readonly property bool autoInstallApp: setting("autoInstallApp", true) === true

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 30, 15, 3600)
  readonly property int warnAtPercent: intSetting("warnAtPercent", 25, 5, 50)
  readonly property string tokenStorage: storageSetting()

  readonly property bool hasData: snapshot !== null
  readonly property real diemPct: hasData ? Model.diemPercent(snapshot) : 0
  readonly property string tier: hasData ? Model.tier(snapshot, warnAtPercent) : "none"
  readonly property bool healthy: tier === "healthy"
  readonly property bool low: tier === "low"
  readonly property bool depleted: tier === "depleted"
  readonly property bool stale: lastUpdated > 0 && (now - lastUpdated) > staleAfterMs
  readonly property int staleAfterMs: Math.max(90000, refreshIntervalSec * 2500)
  readonly property string summary: hasData ? Model.summary(snapshot) : ""

  // ------------------------------------------------------------- settings

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, low, high) {
    var n = Number(setting(name, fallback))
    if (!isFinite(n)) return fallback
    return Math.max(low, Math.min(high, Math.round(n)))
  }

  function storageSetting() {
    return String(setting("tokenStorage", "keyring")) === "file" ? "file" : "keyring"
  }

  onSettingsChanged: {
    settingsReady = true
    // Switching backends must not keep serving state from the old one, and a
    // paused backend should get an immediate retry so the panel reflects the
    // new setting.
    if (tokenStorage !== storage) {
      needsToken = false
      backendPaused = false
      refresh(true)
    }
    maybeAutoInstall()
  }

  // --------------------------------------------------------------- actions

  function refresh(force) {
    if (!active) return
    if (balanceProc.running) {
      // A backend switch or a just-saved token must not be dropped because a
      // poll happened to be in flight. Queue one more pass.
      if (force) pendingRefresh = true
      return
    }
    if (!force && (needsToken || backendPaused)) return
    if (force) backendPaused = false

    loading = true
    refreshing = hasData
    lastError = ""
    errorKind = ""
    balanceProc.command = ["/bin/sh", helperPath, "balance", "--storage=" + tokenStorage]
    balanceProc.running = true
  }

  // Called by the panel when it switches storage after a keyring failure.
  function beginTokenEntry() {
    needsToken = true
    backendPaused = false
    storeError = ""
    lastError = ""
    errorKind = ""
  }

  function storeToken(value) {
    if (!active) return
    var token = String(value || "").replace(/\r/g, "").trim()
    if (token === "") {
      storeError = "Paste a token first."
      return
    }
    if (storeProc.running) return

    storeBusy = true
    storeError = ""
    lastError = ""
    errorKind = ""
    storeProc.pending = token
    storeProc.command = ["/bin/sh", helperPath, "store-token", "--storage=" + tokenStorage]
    storeProc.running = true
  }

  // ------------------------------------------------------------ app launcher

  function checkApp() {
    if (!active) return
    if (appStatusProc.running) {
      appCheckPending = true
      return
    }
    appCheckPending = false
    appStatusProc.command = ["/bin/sh", appHelperPath, "status"]
    appStatusProc.running = true
  }

  function runApp(action) {
    if (!active || appBusy || appActionProc.running) return
    appBusy = true
    appError = ""
    appStatus = "installing"
    appActionProc.command = ["/bin/sh", appHelperPath, action]
    appActionProc.running = true
  }

  function ensureApp() { runApp("ensure") }
  function installApp() { runApp("install") }

  function openApp() {
    // Chromium names the --app window class brave-venice.ai__chat-Default (or
    // chromium-…-Default), which is unique enough to focus without matching
    // ordinary browser tabs that merely mention Venice.ai.
    Quickshell.execDetached([
      "omarchy-launch-or-focus-webapp",
      "venice.ai__chat",
      "https://venice.ai/chat"
    ])
  }

  // One-shot: only after a successful balance proves the plugin is really in
  // use, and only once the panel's settings have arrived (autoInstallApp can
  // be turned off). The helper's marker makes this survive restarts.
  function maybeAutoInstall() {
    // `hasData` is a binding over `snapshot`; inside applyResult it can still
    // report the previous value, so look at the property that was just set.
    if (!active || appAutoChecked || !settingsReady || snapshot === null || !autoInstallApp) return
    appAutoChecked = true
    runApp("ensure")
  }

  // --------------------------------------------------------------- results

  function applyResult(text) {
    loading = false
    refreshing = false

    var parsed = Model.parseResult(text)
    if (!parsed.ok) {
      var kind = parsed.kind || "parse"
      errorKind = kind
      lastError = parsed.message || "Balance request failed"
      if (kind === "no-token") {
        hasToken = false
        needsToken = true
        // With no token at all there is no account to show. Keeping a snapshot
        // here would display balances that belong to a token that has been
        // removed or to a different storage backend.
        snapshot = null
        lastUpdated = 0
      } else if (kind === "auth") {
        hasToken = true
        needsToken = true
      } else if (kind === "keyring" || kind === "file") {
        backendPaused = true
        backendRetry.restart()
      }
      return
    }

    snapshot = Model.normalize(parsed.data)
    storage = parsed.storage !== "" ? parsed.storage : tokenStorage
    hasToken = true
    needsToken = false
    backendPaused = false
    storeError = ""
    errorKind = ""
    lastError = ""
    lastUpdated = Date.now()
    now = lastUpdated
    maybeAutoInstall()
  }

  // --------------------------------------------------------------- plumbing

  Process {
    id: balanceProc
    running: false
    command: []
    stdout: StdioCollector { id: balanceOut; waitForEnd: true }
    stderr: StdioCollector { id: balanceErr; waitForEnd: true }
    onExited: function(exitCode) {
      var text = String(balanceOut.text || "").trim()
      if (text === "") {
        root.loading = false
        root.refreshing = false
        root.errorKind = "parse"
        root.lastError = String(balanceErr.text || "The balance helper returned nothing").trim()
      } else {
        root.applyResult(text)
      }
      if (root.pendingRefresh) {
        root.pendingRefresh = false
        root.refresh(true)
      }
    }
  }

  // The token is written to stdin so it never appears in argv, and the
  // property is cleared the moment the helper has it.
  Process {
    id: storeProc
    property string pending: ""
    running: false
    command: []
    stdinEnabled: true
    stdout: StdioCollector { id: storeOut; waitForEnd: true }
    stderr: StdioCollector { id: storeErr; waitForEnd: true }
    onStarted: {
      if (pending !== "") write(pending + "\n")
      pending = ""
    }
    onExited: function(exitCode) {
      root.storeBusy = false
      var parsed = Model.parseAction(String(storeOut.text || "").trim())
      if (!parsed.ok) {
        root.storeError = parsed.message || String(storeErr.text || "Could not save the token").trim()
        root.errorKind = parsed.kind || "keyring"
        root.lastError = root.storeError
        if (root.errorKind === "keyring" || root.errorKind === "file") {
          root.backendPaused = true
          backendRetry.restart()
        }
        return
      }
      root.storage = parsed.storage !== "" ? parsed.storage : root.tokenStorage
      root.storeError = ""
      root.lastError = ""
      root.errorKind = ""
      root.needsToken = false
      root.hasToken = true
      root.backendPaused = false
      root.refresh(true)
    }
  }

  Process {
    id: appStatusProc
    running: false
    command: []
    stdout: StdioCollector { id: appStatusOut; waitForEnd: true }
    stderr: StdioCollector { id: appStatusErr; waitForEnd: true }
    onExited: function(exitCode) {
      var parsed = Model.parseAppStatus(String(appStatusOut.text || "").trim())
      if (!parsed.ok) {
        root.appStatus = "error"
        root.appError = parsed.message || String(appStatusErr.text || "Could not read the app status").trim()
      } else {
        root.appUrl = parsed.url
        root.appError = ""
        if (!parsed.installed) root.appStatus = "missing"
        else if (parsed.foreign) root.appStatus = "foreign"
        else if (parsed.chatUrl) root.appStatus = "installed"
        else root.appStatus = "outdated"
      }
      if (root.appCheckPending) {
        root.appCheckPending = false
        root.checkApp()
      }
    }
  }

  Process {
    id: appActionProc
    running: false
    command: []
    stdout: StdioCollector { id: appActionOut; waitForEnd: true }
    stderr: StdioCollector { id: appActionErr; waitForEnd: true }
    onExited: function(exitCode) {
      var parsed = Model.parseAction(String(appActionOut.text || "").trim())
      root.appBusy = false
      if (!parsed.ok) {
        root.appStatus = "error"
        root.appError = parsed.message || String(appActionErr.text || "Could not install the app").trim()
        return
      }
      root.appError = ""
      root.checkApp()
    }
  }

  Component.onCompleted: checkApp()

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: root.active && !root.needsToken && !root.backendPaused
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // A locked keyring should not be hammered once a minute (and re-prompt on
  // every poll). Back off, but let the user retry immediately from the panel.
  Timer {
    id: backendRetry
    interval: 5 * 60 * 1000
    repeat: false
    onTriggered: {
      root.backendPaused = false
      root.refresh(true)
    }
  }

  Timer {
    interval: 15000
    repeat: true
    running: root.active
    triggeredOnStart: true
    onTriggered: root.now = Date.now()
  }
}
