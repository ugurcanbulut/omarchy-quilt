import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Layout.js" as Layout

// The layout editor, a full-screen overlay over the tile area. "edit"
// reshapes the focused workspace's layout and applies every change as it is
// made; "new" draws a layout from scratch on an empty workspace. Both can save
// the result as a preset.
PanelWindow {
  id: editor

  property string script: ""
  // The engine's tiles file for the focused workspace, for app names.
  property var tilesInfo: null

  property string mode: ""
  property string key: ""
  property string returnKey: ""
  property string gapsIn: ""
  property string gapsOut: ""
  // App homes the workspace had when editing began ({ "2": "chromium" }),
  // and whether to keep each tile's app as its home.
  // What Done does to the workspace's app homes: "keep" them as they are
  // (they follow their tiles), "remember" each tile's app as its home, or
  // "clear" them. A preset saved from here takes the same choice.
  property string homesChoice: "keep"
  property var area: null
  property bool arrived: false

  property int gw: 12
  property int gh: 12
  property var rects: []
  // Undo steps, each { gw, gh, rects }: New can switch grid sizes.
  property var history: []
  property string appliedSpec: ""
  property var queue: []

  // Gestures in progress.
  property var draw: null
  property var dividerDrag: null
  property int dragTile: -1
  property point dragPoint: Qt.point(0, 0)

  readonly property bool editing: mode === "edit"
  readonly property string spec: rects.length ? Layout.format(gw, gh, rects) : ""
  property var dividerModel: []
  readonly property var monitor: screen ? Hyprland.monitorFor(screen) : null

  readonly property var drawRect: draw ? {
    "x": Math.min(draw.x0, draw.x1), "y": Math.min(draw.y0, draw.y1),
    "w": Math.abs(draw.x1 - draw.x0) + 1, "h": Math.abs(draw.y1 - draw.y0) + 1
  } : null
  readonly property bool drawValid: drawRect !== null && Layout.valid(rects.concat([drawRect]), gw, gh)
  readonly property int dropTarget: dragTile >= 0 ? tileAt(dragPoint.x, dragPoint.y) : -1

  // App names and app homes per tile, once the engine shows the layout
  // drawn here.
  readonly property bool engineCaughtUp: editing && tilesInfo !== null && tilesInfo.workspace === key && !!tilesInfo.tiles
    && Layout.normalize(tilesInfo.spec) === spec
  readonly property var apps: engineCaughtUp ? tilesInfo.tiles.map(function(t) { return t.app || "" }) : []
  readonly property var homes: engineCaughtUp ? tilesInfo.tiles.map(function(t) { return t.home || "" }) : []

  // The homes the workspace has now, by tile.
  function homesNow() {
    var out = {}
    homes.forEach(function(app, i) { if (app) out[String(i + 1)] = app })
    return out
  }

  // What Remember apps keeps: each tile's app, or the home it already has.
  function appsToRemember() {
    var out = {}
    apps.forEach(function(app, i) {
      var name = (app || homes[i] || "").toLowerCase()
      if (name && name !== "?") out[String(i + 1)] = name
    })
    return out
  }

  // On a dark scrim, whatever the theme.
  readonly property color ink: "white"
  readonly property color accent: Color.accent
  readonly property color warn: Color.urgent

  signal saveRequested(string label, string spec, var apps, string gapsIn, string gapsOut)

  visible: mode !== ""
  color: "transparent"
  anchors { top: true; bottom: true; left: true; right: true }
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.namespace: "quilt-editor"
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

  function keyFor(ws) {
    if (!ws) return ""
    if (ws.id > 0) return String(ws.id)
    if (String(ws.name).indexOf("special:") === 0) return ws.name
    return "name:" + ws.name
  }

  function luaString(text) { return JSON.stringify(String(text)) }

  function focusWorkspace(target) {
    Quickshell.execDetached(["hyprctl", "dispatch", "hl.dsp.focus({ workspace = " + luaString(target) + " })"])
  }

  function reset() {
    history = []
    draw = null
    dividerDrag = null
    dragTile = -1
    waitingSave = null
    saveWait.stop()
    nameField.text = ""
    card.x = Qt.binding(function() { return (editor.width - card.width) / 2 })
    card.y = Qt.binding(function() { return editor.height - card.height - Style.space(40) })
  }

  // Reshape the layout of workspace `options.key`, shown now as
  // options.spec (for Smart, the layout it picked).
  function startEdit(options) {
    var layout = Layout.editable(options.spec)
    if (!layout) return false
    reset()
    screen = options.screen
    key = options.key
    returnKey = ""
    gapsIn = options.gapsIn !== undefined && options.gapsIn !== null ? String(options.gapsIn) : ""
    gapsOut = options.gapsOut !== undefined && options.gapsOut !== null ? String(options.gapsOut) : ""
    homesChoice = "keep"
    gw = layout.gw
    gh = layout.gh
    rects = layout.rects
    appliedSpec = spec
    // The engine remembers the workspace as it is, for Cancel, and each
    // shape the edit passes through, for undo.
    send(["editing", "start"])
    area = tilesInfo && tilesInfo.workspace === key && tilesInfo.area ? tilesInfo.area : null
    if (!area) areaProc.running = true
    arrived = true
    mode = "edit"
    return true
  }

  // Draw a layout from scratch on an empty workspace.
  function startNew(options) {
    reset()
    screen = options.screen
    returnKey = options.returnKey
    key = options.key
    gapsIn = ""
    gapsOut = ""
    homesChoice = "keep"
    gw = 12
    gh = 12
    rects = []
    appliedSpec = ""
    area = null
    arrived = keyFor(Hyprland.focusedWorkspace) === key
    focusWorkspace(key)
    areaProc.running = true
    mode = "new"
  }

  // Empty gaps would make the script look them up from a preset; "-" means
  // the default.
  function gapArgs() { return [gapsIn || "-", gapsOut || "-"] }

  // keepHomes false: leave the workspace's app homes as the engine has them.
  function finish(keepHomes) {
    var back = mode === "new" && arrived ? returnKey : ""
    waitingSave = null
    saveWait.stop()
    // Edit: the homes as chosen. The engine reads each tile's app once the
    // last change has gone through.
    if (editing && keepHomes !== false) {
      if (homesChoice === "remember") send(["homes", "remember"])
      else if (homesChoice === "clear") send(["homes", "{}"])
      send(["editing", "done"])
    }
    mode = ""
    if (back) focusWorkspace(back)
  }

  // Everything back as it was: layout, gaps, homes, windows, and following
  // the monitor's default, whatever happened (undo included) in between.
  function cancel() {
    if (editing) send(["editing", "cancel"])
    finish(false)
  }

  // Save pressed before the engine shows the layout drawn here: the apps to
  // keep with the preset come from the engine's picture, so wait for it
  // (briefly).
  property var waitingSave: null
  onEngineCaughtUpChanged: if (engineCaughtUp && waitingSave) save(waitingSave.use)

  Timer {
    id: saveWait
    interval: 2000
    onTriggered: if (editor.waitingSave) editor.save(editor.waitingSave.use, true)
  }

  function save(use, force) {
    if (!rects.length || !Layout.parse(spec)) return
    if (editing && homesChoice !== "clear" && !engineCaughtUp && !force) {
      waitingSave = { use: use }
      saveWait.restart()
      return
    }
    waitingSave = null
    saveWait.stop()
    var label = nameField.text.trim()
    var apps = !editing || !engineCaughtUp || homesChoice === "clear" ? null
      : homesChoice === "remember" ? appsToRemember() : homesNow()
    saveRequested(label, spec, apps, gapsIn, gapsOut)
    if (use && returnKey) {
      var target = returnKey
      finish()
      send(["set", spec, "-", "-", "{}"], target)
    } else {
      finish()
    }
  }

  function remember(previous) {
    history = history.concat([{ gw: gw, gh: gh, rects: previous }]).slice(-50)
  }

  // Changes go through here so they can be undone.
  function change(next) {
    if (!next) return
    remember(rects)
    rects = Layout.sortRects(next)
  }

  function undo() {
    if (!history.length) return
    var step = history[history.length - 1]
    history = history.slice(0, -1)
    gw = step.gw
    gh = step.gh
    rects = step.rects
  }

  function setGrid(n) {
    if (gw === n && gh === n) return
    remember(rects)
    rects = []
    gw = n
    gh = n
  }

  function removeTile(i) {
    if (editing && rects.length < 2) return
    var next = rects.slice()
    next.splice(i, 1)
    change(next)
  }

  function splitTile(i, sideBySide) { change(Layout.split(rects, i, sideBySide)) }

  function tileAt(px, py) {
    var gx = px / canvas.unitW, gy = py / canvas.unitH
    for (var i = 0; i < rects.length; i++) {
      var r = rects[i]
      if (gx >= r.x && gx < r.x + r.w && gy >= r.y && gy < r.y + r.h) return i
    }
    return -1
  }

  function cellAt(px, py) {
    return {
      x: Math.max(0, Math.min(gw - 1, Math.floor(px / canvas.unitW))),
      y: Math.max(0, Math.min(gh - 1, Math.floor(py / canvas.unitH)))
    }
  }

  // Commands run one at a time, in order; a layout still waiting to be sent
  // is replaced by a newer one.
  function send(args, target) {
    var item = { args: args, key: target || key }
    var last = queue.length ? queue[queue.length - 1] : null
    if (args[0] === "set" && last && last.args[0] === "set" && last.key === item.key) queue = queue.slice(0, -1)
    queue = queue.concat([item])
    pump()
  }

  function pump() {
    if (runner.running || !queue.length) return
    var item = queue[0]
    queue = queue.slice(1)
    runner.environment = { QUILT_WORKSPACE: item.key }
    runner.command = [script].concat(item.args)
    runner.running = true
  }

  onSpecChanged: {
    if (editing && spec && spec !== appliedSpec && Layout.parse(spec)) {
      appliedSpec = spec
      send(["set", spec].concat(gapArgs(), ["keep"]))
    }
  }

  function refreshDividers() { dividerModel = Layout.dividers(rects, gw, gh) }

  onRectsChanged: if (!dividerDrag) refreshDividers()

  onVisibleChanged: if (visible) Qt.callLater(function() { keyCatcher.forceActiveFocus() })

  // Leaving the workspace ends the session: an edit keeps what was made,
  // a new layout is dropped.
  Connections {
    target: Hyprland
    function onFocusedWorkspaceChanged() {
      if (!editor.mode) return
      var now = editor.keyFor(Hyprland.focusedWorkspace)
      if (now === editor.key) editor.arrived = true
      else if (editor.arrived) editor.mode = ""
    }
  }

  Process {
    id: runner
    onExited: editor.pump()
  }

  Process {
    id: areaProc
    environment: ({ QUILT_WORKSPACE: editor.key })
    command: [editor.script, "area"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var a = JSON.parse(text)
          if (a && a.w > 0 && a.h > 0) editor.area = a
        } catch (e) {}
      }
    }
  }

  Item {
    id: keyCatcher
    anchors.fill: parent
    focus: true

    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Escape) {
        editor.cancel()
        event.accepted = true
      } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        if (editor.editing) editor.finish()
        else editor.save(false)
        event.accepted = true
      } else if (event.key === Qt.Key_Z && (event.modifiers & Qt.ControlModifier)) {
        editor.undo()
        event.accepted = true
      }
    }

    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, editor.editing ? 0.45 : 0.6)
    }

    Item {
      id: canvas
      visible: editor.area !== null && editor.monitor !== null
      x: editor.area && editor.monitor ? editor.area.x - editor.monitor.x : 0
      y: editor.area && editor.monitor ? editor.area.y - editor.monitor.y : 0
      width: editor.area ? editor.area.w : 0
      height: editor.area ? editor.area.h : 0

      readonly property real unitW: width / editor.gw
      readonly property real unitH: height / editor.gh

      // Grid lines, for drawing and to show where lines snap.
      Repeater {
        model: canvas.unitW >= 6 ? editor.gw + 1 : 0
        Rectangle {
          required property int index
          x: Math.round(index * canvas.unitW)
          width: 1
          height: canvas.height
          color: editor.ink
          opacity: 0.12
        }
      }

      Repeater {
        model: canvas.unitH >= 6 ? editor.gh + 1 : 0
        Rectangle {
          required property int index
          y: Math.round(index * canvas.unitH)
          height: 1
          width: canvas.width
          color: editor.ink
          opacity: 0.12
        }
      }

      // Drag across empty cells to draw a tile.
      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.CrossCursor
        onPressed: function(mouse) {
          keyCatcher.forceActiveFocus()
          var c = editor.cellAt(mouse.x, mouse.y)
          editor.draw = { x0: c.x, y0: c.y, x1: c.x, y1: c.y }
        }
        onPositionChanged: function(mouse) {
          if (!editor.draw) return
          var c = editor.cellAt(mouse.x, mouse.y)
          editor.draw = { x0: editor.draw.x0, y0: editor.draw.y0, x1: c.x, y1: c.y }
        }
        onReleased: {
          if (editor.drawValid) editor.change(editor.rects.concat([editor.drawRect]))
          editor.draw = null
        }
        onCanceled: editor.draw = null
      }

      Repeater {
        model: editor.rects

        Item {
          id: tile
          required property var modelData
          required property int index

          readonly property string app: editor.apps[index] || ""
          readonly property string home: editor.homes[index] || ""
          readonly property bool hot: tileHover.hovered && editor.dragTile < 0 && !editor.dividerDrag && !editor.draw
          readonly property bool target: editor.dropTarget === index && editor.dragTile !== index
          readonly property bool dragged: editor.dragTile === index

          x: modelData.x * canvas.unitW
          y: modelData.y * canvas.unitH
          width: modelData.w * canvas.unitW
          height: modelData.h * canvas.unitH

          HoverHandler { id: tileHover }

          Rectangle {
            anchors.fill: parent
            anchors.margins: Style.space(4)
            radius: Style.cornerRadius
            color: tile.target ? Qt.rgba(editor.accent.r, editor.accent.g, editor.accent.b, 0.3)
              : Qt.rgba(1, 1, 1, tile.hot ? 0.14 : (editor.editing ? 0.06 : 0.1))
            border.color: tile.target ? editor.accent : Qt.rgba(1, 1, 1, tile.hot ? 0.85 : 0.5)
            border.width: 2
            opacity: tile.dragged ? 0.5 : 1

            Behavior on color { ColorAnimation { duration: 100 } }
          }

          // A dark backdrop keeps the labels readable over busy windows.
          Rectangle {
            readonly property real room: parent.width - Style.space(24)
            anchors.centerIn: parent
            width: Math.min(room, labels.implicitWidth + Style.space(32))
            height: labels.implicitHeight + Style.space(16)
            radius: Style.cornerRadius
            color: Qt.rgba(0, 0, 0, 0.6)

            Column {
              id: labels
              anchors.centerIn: parent
              spacing: Style.space(2)

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                textFormat: Text.PlainText
                text: String(tile.index + 1)
                color: editor.ink
                opacity: 0.9
                font.family: Style.font.family
                font.pixelSize: Math.min(Style.space(56), tile.height * 0.3)
                font.bold: true
              }

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                width: Math.min(implicitWidth, tile.width - Style.space(56))
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: tile.app || (tile.home ? tile.home + "'s tile" : "empty")
                visible: editor.editing && editor.apps.length > 0
                color: editor.ink
                opacity: 0.8
                font.family: Style.font.family
                font.pixelSize: Style.font.heading
              }

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                textFormat: Text.PlainText
                text: Math.round(tile.modelData.w * 100 / editor.gw) + "% × " + Math.round(tile.modelData.h * 100 / editor.gh) + "%"
                color: editor.ink
                opacity: 0.6
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }

          // Press and drag onto another tile to swap their windows; right-click
          // removes the tile.
          MouseArea {
            anchors.fill: parent
            anchors.margins: Style.space(4)
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            cursorShape: editor.editing ? (editor.dragTile === tile.index ? Qt.ClosedHandCursor : Qt.OpenHandCursor) : Qt.ArrowCursor
            property point start: Qt.point(0, 0)

            onPressed: function(mouse) {
              keyCatcher.forceActiveFocus()
              start = Qt.point(mouse.x, mouse.y)
            }
            onClicked: function(mouse) {
              if (mouse.button === Qt.RightButton) Qt.callLater(editor.removeTile, tile.index)
            }
            onPositionChanged: function(mouse) {
              if (!editor.editing || !(mouse.buttons & Qt.LeftButton)) return
              if (editor.dragTile < 0 && Math.abs(mouse.x - start.x) + Math.abs(mouse.y - start.y) > 12) editor.dragTile = tile.index
              if (editor.dragTile === tile.index) editor.dragPoint = mapToItem(canvas, mouse.x, mouse.y)
            }
            onReleased: {
              if (editor.dragTile === tile.index && editor.dropTarget >= 0 && editor.dropTarget !== tile.index)
                editor.send(["swap", String(tile.index + 1), String(editor.dropTarget + 1)])
              editor.dragTile = -1
            }
            onCanceled: editor.dragTile = -1
          }

          Row {
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.margins: Style.space(10)
            spacing: Style.space(4)
            visible: tile.hot

            Button {
              visible: tile.modelData.w >= 2
              iconText: String.fromCodePoint(0xF0BCC) // md-view-split-vertical
              tooltipText: "Split side by side"
              bordered: true
              foreground: editor.ink
              background: Qt.rgba(0, 0, 0, 0.5)
              onClicked: Qt.callLater(editor.splitTile, tile.index, true)
            }

            Button {
              visible: tile.modelData.h >= 2
              iconText: String.fromCodePoint(0xF0BCB) // md-view-split-horizontal
              tooltipText: "Split top and bottom"
              bordered: true
              foreground: editor.ink
              background: Qt.rgba(0, 0, 0, 0.5)
              onClicked: Qt.callLater(editor.splitTile, tile.index, false)
            }

            Button {
              visible: !editor.editing || editor.rects.length > 1
              iconText: String.fromCodePoint(0xF0156) // md-close
              tooltipText: "Remove tile"
              bordered: true
              foreground: editor.ink
              background: Qt.rgba(0, 0, 0, 0.5)
              onClicked: Qt.callLater(editor.removeTile, tile.index)
            }
          }
        }
      }

      // The tile being drawn.
      Rectangle {
        visible: editor.drawRect !== null
        x: editor.drawRect ? editor.drawRect.x * canvas.unitW + Style.space(4) : 0
        y: editor.drawRect ? editor.drawRect.y * canvas.unitH + Style.space(4) : 0
        width: editor.drawRect ? editor.drawRect.w * canvas.unitW - Style.space(8) : 0
        height: editor.drawRect ? editor.drawRect.h * canvas.unitH - Style.space(8) : 0
        radius: Style.cornerRadius
        readonly property color tint: editor.drawValid ? editor.accent : editor.warn
        color: Qt.rgba(tint.r, tint.g, tint.b, 0.25)
        border.color: tint
        border.width: 2
      }

      // Lines between tiles (and between a tile and empty space): drag to
      // resize everything that meets there.
      Repeater {
        model: editor.dividerModel

        Item {
          id: divider
          required property var modelData
          required property int index
          readonly property bool vertical: modelData.orient === "v"
          readonly property bool active: editor.dividerDrag !== null && editor.dividerDrag.index === index
          readonly property real pos: active ? editor.dividerDrag.pos : modelData.pos
          readonly property real thickness: Style.space(14)

          visible: editor.dividerDrag === null || active
          x: vertical ? pos * canvas.unitW - thickness / 2 : modelData.from * canvas.unitW
          y: vertical ? modelData.from * canvas.unitH : pos * canvas.unitH - thickness / 2
          width: vertical ? thickness : (modelData.to - modelData.from) * canvas.unitW
          height: vertical ? (modelData.to - modelData.from) * canvas.unitH : thickness

          Rectangle {
            anchors.centerIn: parent
            width: divider.vertical ? (lineMouse.containsMouse || divider.active ? 4 : 2) : parent.width - Style.space(24)
            height: divider.vertical ? parent.height - Style.space(24) : (lineMouse.containsMouse || divider.active ? 4 : 2)
            radius: 2
            color: lineMouse.containsMouse || divider.active ? editor.accent : editor.ink
            opacity: lineMouse.containsMouse || divider.active ? 1 : 0.35
          }

          MouseArea {
            id: lineMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: divider.vertical ? Qt.SplitHCursor : Qt.SplitVCursor

            onPressed: {
              keyCatcher.forceActiveFocus()
              editor.dividerDrag = { index: divider.index, divider: divider.modelData, start: editor.rects, pos: divider.modelData.pos }
            }
            onPositionChanged: function(mouse) {
              var drag = editor.dividerDrag
              if (!drag || drag.index !== divider.index) return
              var p = mapToItem(canvas, mouse.x, mouse.y)
              var pos = Math.round(divider.vertical ? p.x / canvas.unitW : p.y / canvas.unitH)
              if (pos === drag.pos) return
              var next = Layout.moveDivider(drag.start, editor.gw, editor.gh, drag.divider, pos)
              if (!next) return
              editor.dividerDrag = { index: drag.index, divider: drag.divider, start: drag.start, pos: pos }
              editor.rects = Layout.sortRects(next)
            }
            onReleased: {
              var drag = editor.dividerDrag
              editor.dividerDrag = null
              if (drag && drag.pos !== drag.divider.pos) editor.remember(drag.start)
              Qt.callLater(editor.refreshDividers)
            }
          }
        }
      }

      // What a tile drag will do.
      Rectangle {
        visible: editor.dragTile >= 0
        x: editor.dragPoint.x + Style.space(14)
        y: editor.dragPoint.y + Style.space(14)
        width: dragLabel.implicitWidth + Style.space(16)
        height: dragLabel.implicitHeight + Style.space(10)
        radius: Style.cornerRadius
        color: Qt.rgba(0, 0, 0, 0.75)

        Text {
          id: dragLabel
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: editor.dropTarget >= 0 && editor.dropTarget !== editor.dragTile
            ? "Swap tile " + (editor.dragTile + 1) + " with tile " + (editor.dropTarget + 1)
            : "Drop on another tile to swap"
          color: editor.ink
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }
      }
    }

    // The toolbar. Drag it by its title if it covers a tile.
    Rectangle {
      id: card
      width: cardColumn.implicitWidth + Style.space(32)
      height: cardColumn.implicitHeight + Style.space(28)
      radius: Style.cornerRadius
      color: Color.popups.background
      border.color: Color.popups.border
      border.width: Math.max(1, Style.normalBorderWidth)

      // Clicks on the card stay on the card.
      MouseArea { anchors.fill: parent; onPressed: keyCatcher.forceActiveFocus() }

      Column {
        id: cardColumn
        anchors.centerIn: parent
        spacing: Style.space(10)

        Item {
          width: Math.max(controls.implicitWidth, Style.space(560))
          height: Math.max(cardTitle.implicitHeight, cardSpec.implicitHeight)

          DragHandler {
            target: card
            cursorShape: Qt.SizeAllCursor
          }

          Text {
            id: cardTitle
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: editor.editing ? "Edit layout · workspace " + editor.key.replace(/^name:/, "") : "New layout"
            color: Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Text {
            id: cardSpec
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(implicitWidth, parent.width - cardTitle.implicitWidth - Style.space(24))
            elide: Text.ElideMiddle
            textFormat: Text.PlainText
            text: editor.spec || "Nothing drawn yet"
            color: Color.popups.text
            opacity: 0.7
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
        }

        Text {
          width: Math.max(controls.implicitWidth, Style.space(560))
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: editor.editing
            ? "Drag a line to resize. Drag a tile onto another to swap their windows. Hover a tile to split or remove it (or right-click it), and drag across empty cells to add one. Changes apply as you go; Cancel puts the old layout back."
            : "Drag across the grid to draw a tile; cells you leave empty stay empty. Drag a line to resize, hover a tile to split or remove it."
          color: Color.popups.text
          opacity: 0.6
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Row {
          id: controls
          spacing: Style.space(6)

          // Buttons with an icon come out taller than text-only ones and the
          // name field; one height for all keeps the row even.
          readonly property real controlHeight: Style.space(32)

          Button {
            height: controls.controlHeight
            visible: !editor.editing
            text: "12 × 12"
            tooltipText: "A 12 × 12 grid"
            bordered: true
            selected: editor.gw === 12
            foreground: Color.popups.text
            onClicked: editor.setGrid(12)
          }

          Button {
            height: controls.controlHeight
            visible: !editor.editing
            text: "10 × 10"
            tooltipText: "A 10 × 10 grid"
            bordered: true
            selected: editor.gw === 10
            foreground: Color.popups.text
            onClicked: editor.setGrid(10)
          }

          Button {
            height: controls.controlHeight
            iconText: String.fromCodePoint(0xF054C) // md-undo
            tooltipText: "Undo (Ctrl+Z)"
            bordered: true
            enabled: editor.history.length > 0
            opacity: enabled ? 1 : 0.4
            foreground: Color.popups.text
            onClicked: editor.undo()
          }

          Button {
            height: controls.controlHeight
            visible: !editor.editing
            iconText: String.fromCodePoint(0xF01FE) // md-eraser
            tooltipText: "Clear"
            bordered: true
            enabled: editor.rects.length > 0
            opacity: enabled ? 1 : 0.4
            foreground: Color.popups.text
            onClicked: editor.change([])
          }

          // App homes after the edit, for this workspace and a saved preset.
          Row {
            visible: editor.editing
            spacing: controls.spacing

            Repeater {
              model: [
                { value: "keep", label: "Keep homes", tip: "App homes stay as they are; they follow their tiles" },
                { value: "remember", label: "Remember apps", tip: "Each app opens in its tile from now on, on this workspace and in a saved preset" },
                { value: "clear", label: "Clear homes", tip: "No app homes, on this workspace or in a saved preset" }
              ]

              Button {
                required property var modelData
                height: controls.controlHeight
                text: modelData.label
                tooltipText: modelData.tip
                bordered: true
                selected: editor.homesChoice === modelData.value
                foreground: Color.popups.text
                onClicked: editor.homesChoice = modelData.value
              }
            }
          }

          TextField {
            id: nameField
            height: controls.controlHeight
            verticalAlignment: TextInput.AlignVCenter
            width: Style.space(190)
            placeholderText: "Preset name"
            foreground: Color.popups.text
            onAccepted: editor.save(false)
          }

          Button {
            height: controls.controlHeight
            text: "Cancel"
            tooltipText: editor.editing ? "Put the old layout back (Esc)" : "Close without saving (Esc)"
            bordered: true
            foreground: Color.popups.text
            onClicked: editor.cancel()
          }

          Button {
            height: controls.controlHeight
            iconText: String.fromCodePoint(0xF0193) // md-content-save
            text: editor.editing ? "Save as preset" : "Save"
            tooltipText: "Add it to your presets"
            bordered: true
            enabled: editor.rects.length > 0
            opacity: enabled ? 1 : 0.4
            foreground: Color.popups.text
            onClicked: editor.save(false)
          }

          Button {
            height: controls.controlHeight
            visible: !editor.editing
            text: "Save and use"
            tooltipText: "Add it to your presets and use it on the workspace you came from"
            bordered: true
            enabled: editor.rects.length > 0
            opacity: enabled ? 1 : 0.4
            foreground: Color.popups.text
            onClicked: editor.save(true)
          }

          Button {
            height: controls.controlHeight
            visible: editor.editing
            iconText: String.fromCodePoint(0xF012C) // md-check
            text: "Done"
            tooltipText: "Keep the layout without saving a preset (Enter)"
            bordered: true
            foreground: Color.popups.text
            onClicked: editor.finish()
          }
        }
      }
    }
  }
}
