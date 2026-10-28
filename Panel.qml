import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "net.fidelramos.venice"
  ipcTarget: "net.fidelramos.venice"
  manageIpc: false

  // The bar mounts one widget per monitor. A `service` plugin is mounted once
  // and shared through serviceFor(); the local copy is only a fallback for a
  // host that does not offer it.
  readonly property var sharedService: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor(moduleName)
    : null
  readonly property var venice: sharedService || localService

  function pushSettings() {
    if (!venice) return
    venice.settings = settings
  }
  onSettingsChanged: pushSettings()
  onVeniceChanged: pushSettings()
  Component.onCompleted: pushSettings()

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ------------------------------------------------------------- appearance

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color accent: Commons.Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Commons.Style.font.family

  readonly property var bal: (venice && venice.hasData) ? venice.snapshot : null
  readonly property string tier: venice ? venice.tier : "none"
  // Any error marks the centre dot urgent. The arc keeps the last known
  // tier colour so stale-but-readable data still looks like data.
  readonly property bool alert: venice ? (venice.needsToken || venice.errorKind !== "") : false

  readonly property string errorLabel: {
    if (!venice || venice.errorKind === "") return ""
    switch (venice.errorKind) {
      case "network": return "Offline"
      case "keyring": return "Keyring unavailable"
      case "file": return "Token file unreadable"
      case "http": return "Venice error"
      case "parse": return "Bad response"
      case "auth": return "Token rejected"
      case "no-token": return "No token"
      default: return "Error"
    }
  }

  readonly property color statusColor: {
    if (!bal) return dim
    if (venice.needsToken || venice.errorKind === "keyring" || venice.errorKind === "file") return urgent
    if (tier === "low" || tier === "depleted") return urgent
    return accent
  }

  readonly property color barRingColor: {
    if (!bal) return Qt.darker(barForeground, 1.8)
    if (venice.needsToken || venice.errorKind === "keyring" || venice.errorKind === "file")
      return Qt.darker(barForeground, 1.8)
    if (tier === "low" || tier === "depleted") return urgent
    return Commons.Color.accent
  }

  // DIEM share of the epoch, or a full ring once only USD is left to spend.
  readonly property real ringPercent: {
    if (!bal) return 0
    if (bal.allocation > 0 && bal.diem > 0)
      return Math.max(0, Math.min(1, venice.diemPct / 100))
    return bal.usd > 0 ? 1 : 0
  }
  readonly property bool ringFilled: bal ? bal.canConsume : false

  readonly property string barLabelText: {
    if (bar && bar.vertical) return ""
    var mode = String(setting("barLabel", "none"))
    if (mode === "none") return ""
    if (!venice) return "—"
    if (!venice.hasData) return venice.loading ? "…" : "—"
    return Model.barLabel(mode, venice.snapshot)
  }

  readonly property string tooltipText: Model.tooltip(
    bal,
    {
      needsToken: venice ? venice.needsToken : false,
      errorMessage: venice ? venice.lastError : "",
      tier: tier,
      stale: venice ? (venice.errorKind !== "" && venice.hasData) : false,
      lastUpdated: venice ? venice.lastUpdated : 0,
      now: venice ? venice.now : Date.now()
    })

  readonly property string metaText: {
    if (!venice) return ""
    if (venice.needsToken) return venice.hasToken ? "Token rejected" : "API token required"
    if (venice.loading && !venice.hasData) return "Reading balance"
    if (venice.refreshing) return "Refreshing"
    if (venice.errorKind !== "" && venice.hasData) {
      var age = venice.lastUpdated ? " · last balance " + Model.updatedLabel(venice.lastUpdated, venice.now) : ""
      return errorLabel + age
    }
    if (!bal) return venice.errorKind !== "" ? errorLabel : "No data"
    var head = bal.allocation > 0
      ? Model.formatPercent(venice.diemPct) + " DIEM left"
      : Model.formatUsd(bal.usd) + " USD"
    var updated = Model.updatedLabel(venice.lastUpdated, venice.now)
    return updated !== "" ? head + " · " + updated : head
  }

  readonly property string currencyPill: {
    if (!bal) return ""
    switch (String(bal.currency)) {
      case "DIEM": return "DIEM"
      case "USD": return "USD"
      case "BUNDLED_CREDITS": return "BUNDLED"
      case "EARNED_CREDITS": return "EARNED"
      default: return ""
    }
  }

  readonly property string updatedText: {
    if (!venice || !venice.lastUpdated) return ""
    var stamp = Model.updatedLabel(venice.lastUpdated, venice.now)
    return (venice.errorKind !== "" ? "Last balance " : "Updated ") + stamp
  }

  // -------------------------------------------------------------- app launcher

  readonly property string appStatus: venice ? venice.appStatus : "unknown"
  readonly property bool appBusy: venice ? venice.appBusy : false
  readonly property string appError: venice ? venice.appError : ""

  // The install button only appears when no launcher exists. An existing
  // Venice.ai launcher (managed, outdated, or foreign) is never touched; the
  // note below explains why the button is absent. "error" covers both a failed
  // status read and a failed install, so Retry re-checks the launcher rather
  // than blindly installing.
  readonly property bool appCanInstall: appStatus === "missing"
    || appStatus === "installing" || appStatus === "error"

  readonly property string appButtonText: {
    if (appBusy || appStatus === "installing") return "Installing…"
    if (appStatus === "error") return "Retry"
    return "Install app"
  }

  readonly property string appNote: {
    if (appStatus === "error" && appError !== "") return appError
    if (appStatus === "outdated") return "Venice.ai is already in your app launcher; left unchanged."
    if (appStatus === "foreign") return "Another Venice.ai launcher exists; left unchanged."
    return ""
  }

  property string actionStatus: ""
  Timer {
    id: actionTimer
    interval: 1600
    onTriggered: root.actionStatus = ""
  }

  // ---------------------------------------------------------------- actions

  function refresh() { if (venice) venice.refresh(true) }
  // Let the panel release keyboard focus (and finish its 140ms fade) before
  // focusing an app window, otherwise the focus restore to the previous
  // window lands after the handoff and steals it back.
  property string pendingLink: ""
  Timer {
    id: linkTimer
    interval: 200
    repeat: false
    onTriggered: {
      var target = root.pendingLink
      root.pendingLink = ""
      if (target === "chat") {
        if (root.venice) root.venice.openApp()
        else Qt.openUrlExternally("https://venice.ai/chat")
      } else if (target === "api") {
        if (root.venice) root.venice.openApiPage()
      }
    }
  }

  function openChat() {
    root.close()
    root.pendingLink = "chat"
    linkTimer.restart()
  }
  function openApi() {
    root.close()
    root.pendingLink = "api"
    linkTimer.restart()
  }

  function appAction() {
    if (!venice || appBusy) return
    if (appStatus === "missing") venice.installApp()
    else if (appStatus === "error") venice.checkApp()
  }

  function copySummary() {
    if (!bal) return
    Quickshell.execDetached(["wl-copy", "--", Model.summary(bal)])
    actionStatus = "Copied balance"
    actionTimer.restart()
  }

  function saveToken() {
    if (!venice) return
    venice.storeToken(tokenField.text)
  }

  // Escape hatch for a host whose keyring is locked or unavailable. The token
  // has to be pasted again because the old copy cannot be read.
  function useFileStorage() {
    var entry = { id: root.moduleName }
    for (var key in root.settings) {
      if (key !== "id") entry[key] = root.settings[key]
    }
    entry.tokenStorage = "file"
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
    if (root.venice) {
      root.venice.settings = entry
      root.venice.beginTokenEntry()
    }
    Qt.callLater(function() { tokenField.forceActiveFocus() })
  }

  onOpenedChanged: {
    if (!opened) {
      tokenField.text = ""
      return
    }
    if (venice) venice.checkApp()
    if (venice && venice.needsToken)
      Qt.callLater(function() { tokenField.forceActiveFocus() })
    else
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Connections {
    target: root.venice
    function onNeedsTokenChanged() {
      if (!root.venice) return
      if (!root.venice.needsToken) {
        tokenField.text = ""
      } else if (root.opened) {
        Qt.callLater(function() { tokenField.forceActiveFocus() })
      }
    }
  }

  Service {
    id: localService
    active: root.sharedService === null
    settings: root.settings
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
    function chat(): void { root.openChat() }
    function api(): void { root.openApi() }
    function status(): string {
      if (!root.venice) return "unavailable"
      if (root.venice.needsToken) return root.venice.hasToken ? "token rejected" : "no token"
      if (!root.venice.hasData) return root.venice.loading ? "loading" : "no data"
      return Model.summary(root.venice.snapshot)
    }
  }

  // ------------------------------------------------------------------- bar

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    // Grows only as far as the label needs, so the bar does not jitter.
    fixedWidth: (root.bar && root.bar.vertical)
      ? -1
      : Math.round(barContent.implicitWidth + Commons.Style.spaceReal(horizontalMargin) * 2)
    tooltipText: root.tooltipText

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.refresh()
      else if (buttonCode === Qt.MiddleButton) root.copySummary()
      else root.toggle()
    }

    RowLayout {
      id: barContent
      anchors.centerIn: parent
      spacing: Commons.Style.space(5)

      VeniceRing {
        iconSize: Commons.Style.bar.iconCanvas * 0.72
        percent: root.ringPercent
        color: root.barRingColor
        trackColor: Commons.Util.alpha(root.barForeground, 0.22)
        filled: root.ringFilled
        alert: root.alert
        alertColor: root.urgent
        Layout.alignment: Qt.AlignVCenter
      }

      Text {
        textFormat: Text.PlainText
        visible: root.barLabelText !== ""
        text: root.barLabelText
        color: root.barForeground
        font.family: root.fontFamily
        font.pixelSize: Commons.Style.bar.iconFont
        renderType: Text.NativeRendering
        Layout.alignment: Qt.AlignVCenter
      }
    }
  }

  // ----------------------------------------------------------------- panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: (root.venice && root.venice.needsToken) ? tokenField : keyCatcher
    contentWidth: panel.fittedContentWidth(Commons.Style.space(360))
    contentHeight: panel.fittedContentHeight(panelFlick.contentHeight, Commons.Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: tokenField.activeFocus
      onCloseRequested: root.close()
      onTextKey: function(text) {
        var key = String(text).toLowerCase()
        if (key === "r") root.refresh()
        else if (key === "c") root.openChat()
        else if (key === "a") root.openApi()
      }
    }

    Flickable {
      id: panelFlick
      anchors.fill: parent
      contentWidth: width
      contentHeight: column.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      interactive: contentHeight > height
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: column
        width: panelFlick.width
        spacing: Commons.Style.space(12)

        // ------------------------------------------------------------ hero

        PanelHero {
          id: hero
          width: parent.width
          title: "Venice.ai"
          meta: root.metaText
          detail: root.currencyPill
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconOpacity: (root.venice && root.venice.loading && !root.venice.hasData) ? 0.5 : 1.0

          iconComponent: Component {
            VeniceRing {
              iconSize: Commons.Style.font.display
              percent: root.ringPercent
              color: root.statusColor
              trackColor: Commons.Util.alpha(root.foreground, 0.18)
              filled: root.ringFilled
              alert: root.alert
              alertColor: root.urgent
            }
          }

          trailingControl: Component {
            PanelActionButton {
              iconText: "\uf021"
              tooltipText: "Refresh (r)"
              foreground: hero.foreground
              fontFamily: hero.fontFamily
              enabled: !(root.venice && root.venice.loading)
              onClicked: root.refresh()
            }
          }
        }

        // ----------------------------------------------------- token setup

        Column {
          width: parent.width
          spacing: Commons.Style.space(8)
          visible: root.venice && root.venice.needsToken

          PanelSeparator { foreground: root.foreground }

          PanelSectionHeader {
            text: root.venice && root.venice.hasToken ? "REPLACE TOKEN" : "API TOKEN"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            width: parent.width
            text: root.venice && root.venice.hasToken
              ? "Venice rejected the saved token. Paste a new one to continue."
              : "Paste a Venice.ai API token to read your balance."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Commons.Style.font.body
            wrapMode: Text.WordWrap
          }

          TextField {
            id: tokenField
            width: parent.width
            password: true
            placeholderText: "API token"
            foreground: root.foreground
            onAccepted: root.saveToken()
            Keys.onEscapePressed: root.close()
          }

          RowLayout {
            width: parent.width
            spacing: Commons.Style.space(10)

            Button {
              text: (root.venice && root.venice.storeBusy) ? "Saving…" : "Save token"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: !(root.venice && root.venice.storeBusy) && tokenField.text.length > 0
              onClicked: root.saveToken()
            }

            Text {
              text: "venice.ai/settings/api →"
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: Commons.Style.font.bodySmall
              font.underline: true
              Layout.alignment: Qt.AlignVCenter
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openApi()
              }
            }

            Item { Layout.fillWidth: true }
          }

          Text {
            width: parent.width
            visible: root.venice && root.venice.storeError !== ""
            text: root.venice ? root.venice.storeError : ""
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Commons.Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            width: parent.width
            text: root.venice && root.venice.tokenStorage === "file"
              ? "Stored in a private 0600 file under ~/.local/state/venice."
              : "Stored in the system keyring. The helper reads it; the widget never displays it again."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Commons.Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        // ----------------------------------------------------------- error

        Column {
          width: parent.width
          spacing: Commons.Style.space(6)
          visible: root.venice && !root.venice.needsToken && root.venice.lastError !== ""

          PanelSeparator { foreground: root.foreground }

          Row {
            width: parent.width
            spacing: Commons.Style.space(8)

            Text {
              width: Math.max(0, parent.width - retryButton.width - Commons.Style.space(8))
              text: root.venice ? root.venice.lastError : ""
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Commons.Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Button {
              id: retryButton
              text: "Retry"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.refresh()
            }
          }

          Text {
            width: parent.width
            visible: root.venice && (root.venice.errorKind === "keyring" || root.venice.errorKind === "file")
            text: "If the keyring is locked, unlock it and retry — or store the token in a private file instead."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Commons.Style.font.caption
            wrapMode: Text.WordWrap
          }

          Button {
            visible: root.venice && (root.venice.errorKind === "keyring" || root.venice.errorKind === "file")
            text: "Store token in a private file"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.useFileStorage()
          }
        }

        // --------------------------------------------------------- balances

        Column {
          width: parent.width
          spacing: Commons.Style.space(10)
          visible: root.bal !== null

          PanelSeparator { foreground: root.foreground }

          // DIEM
          Column {
            width: parent.width
            spacing: Commons.Style.space(6)

            PanelSectionHeader {
              text: "DIEM"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            RowLayout {
              width: parent.width
              spacing: Commons.Style.space(6)

              Text {
                textFormat: Text.PlainText
                text: root.bal ? Model.formatDiem(root.bal.diem) : ""
                color: (root.venice && root.venice.depleted) ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Commons.Style.font.heading
                font.bold: true
                Layout.alignment: Qt.AlignBaseline
              }

              Text {
                textFormat: Text.PlainText
                visible: root.bal && root.bal.allocation > 0
                text: root.bal ? "/ " + Model.formatDiem(root.bal.allocation) : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Commons.Style.font.subtitle
                Layout.alignment: Qt.AlignBaseline
              }

              Text {
                textFormat: Text.PlainText
                text: "DIEM"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Commons.Style.font.body
                Layout.alignment: Qt.AlignBaseline
              }

              Item { Layout.fillWidth: true }
            }

            Rectangle {
              id: diemTrack
              visible: root.bal && root.bal.allocation > 0
              width: parent.width
              height: Commons.Style.space(7)
              radius: height / 2
              color: Commons.Util.alpha(root.foreground, 0.14)

              Rectangle {
                width: (root.venice && root.venice.diemPct > 0)
                  ? Math.max(2, Math.round(diemTrack.width * Math.min(root.venice.diemPct, 100) / 100))
                  : 0
                height: parent.height
                radius: parent.radius
                color: root.statusColor
              }
            }

            Text {
              width: parent.width
              text: root.bal && root.bal.allocation > 0
                ? Model.formatPercent(root.venice ? root.venice.diemPct : 0)
                  + " remaining this epoch (resets in "
                  + Model.resetIn(root.venice ? root.venice.now : Date.now()) + ")"
                : "No DIEM allocation — spending from USD"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Commons.Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // USD
          Column {
            width: parent.width
            spacing: Commons.Style.space(4)

            PanelSectionHeader {
              text: "USD"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            RowLayout {
              width: parent.width
              spacing: Commons.Style.space(6)

              Text {
                textFormat: Text.PlainText
                text: root.bal ? Model.formatUsd(root.bal.usd) : ""
                color: (root.bal && root.bal.usd < 0) ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Commons.Style.font.heading
                font.bold: true
                Layout.alignment: Qt.AlignBaseline
              }

              Text {
                textFormat: Text.PlainText
                text: "USD"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Commons.Style.font.body
                Layout.alignment: Qt.AlignBaseline
              }

              Item { Layout.fillWidth: true }
            }

            Text {
              width: parent.width
              text: (root.bal && root.bal.usd < 0)
                ? "Owed — top up to keep requests flowing"
                : "Prepaid balance"
              color: (root.bal && root.bal.usd < 0) ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Commons.Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          Text {
            width: parent.width
            visible: text !== ""
            text: root.bal ? Model.extraCredits(root.bal) : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Commons.Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        // -------------------------------------------------------------- app

        Column {
          width: parent.width
          spacing: Commons.Style.space(6)

          PanelSeparator { foreground: root.foreground }

          PanelSectionHeader {
            text: "APP"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          RowLayout {
            width: parent.width
            spacing: Commons.Style.space(8)

            Button {
              text: "Chat"
              bordered: true
              tooltipText: "Open Venice.ai Chat in its app window"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.openChat()
            }

            Button {
              text: "API keys"
              bordered: true
              tooltipText: "Open the Venice.ai API token page in its app window"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.openApi()
            }

            Item { Layout.fillWidth: true }

            Button {
              visible: root.appCanInstall
              text: root.appButtonText
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: !root.appBusy && root.appStatus !== "installing"
              onClicked: root.appAction()
            }
          }

          Text {
            width: parent.width
            visible: text !== ""
            text: root.appNote
            color: root.appStatus === "error" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Commons.Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        // ----------------------------------------------------------- footer

        Column {
          width: parent.width
          spacing: Commons.Style.space(6)

          PanelSeparator { foreground: root.foreground }

          Text {
            width: parent.width
            text: {
              var shortcuts = "r refresh · c chat · a api"
              if (root.actionStatus !== "") return root.actionStatus
              if (root.updatedText !== "") return root.updatedText + "  ·  " + shortcuts
              return shortcuts
            }
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Commons.Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }
}
