import QtQuick
import qs.Commons as Commons

// A thin ring gauge: the arc is the share of the DIEM epoch still available,
// the centre dot is whether Venice will currently spend. Deliberately
// monochrome and theme-driven — no green/amber/red of its own.
Item {
  id: root

  property real iconSize: 11
  property real percent: 0
  property color color: Commons.Color.foreground
  property color trackColor: Commons.Util.alpha(Commons.Color.foreground, 0.18)
  property bool filled: true
  property bool alert: false
  property color alertColor: Commons.Color.urgent

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  readonly property real clamped: Math.max(0, Math.min(1, Number(percent) || 0))
  readonly property real dotSize: Math.max(2, Math.round(iconSize * 0.3))

  // The Canvas paints once on creation; every input it reads needs its own
  // repaint trigger, otherwise the arc freezes at the first (often empty)
  // value while the dot and labels update around it.
  onClampedChanged: canvas.requestPaint()
  onColorChanged: canvas.requestPaint()
  onTrackColorChanged: canvas.requestPaint()
  onAlertChanged: canvas.requestPaint()
  onIconSizeChanged: canvas.requestPaint()

  Canvas {
    id: canvas
    anchors.fill: parent

    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    Component.onCompleted: requestPaint()

    onPaint: {
      var ctx = getContext("2d")
      ctx.clearRect(0, 0, width, height)

      var size = Math.min(width, height)
      if (size <= 0) return

      var line = Math.max(1.2, size * 0.14)
      var radius = Math.max(0.5, (size - line) / 2)
      var cx = width / 2
      var cy = height / 2

      ctx.lineWidth = line
      ctx.lineCap = "round"

      ctx.strokeStyle = root.trackColor
      ctx.beginPath()
      ctx.arc(cx, cy, radius, 0, Math.PI * 2)
      ctx.stroke()

      if (root.clamped > 0.0001) {
        ctx.strokeStyle = root.alert ? root.alertColor : root.color
        ctx.beginPath()
        if (root.clamped >= 0.9999) {
          ctx.arc(cx, cy, radius, 0, Math.PI * 2)
        } else {
          ctx.arc(cx, cy, radius, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * root.clamped)
        }
        ctx.stroke()
      }
    }
  }

  // The centre dot: filled when the account can spend, hollow when it cannot,
  // urgent when the token/keyring needs attention.
  Rectangle {
    width: root.dotSize
    height: root.dotSize
    radius: width / 2
    anchors.centerIn: parent
    visible: root.iconSize >= 8
    color: root.alert ? root.alertColor : (root.filled ? root.color : "transparent")
    border.width: (root.alert || root.filled) ? 0 : Math.max(1, Math.round(root.iconSize * 0.09))
    border.color: root.color
  }
}
