import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Bar button + popup for Quilt's tile layouts, plus the drop areas drawn on
// empty tiles. The layout itself runs inside Hyprland (engine.lua); the
// sibling `quilt` script loads it and passes commands to it, and the engine
// reports back through files in $XDG_RUNTIME_DIR/quilt.
Panel {
  id: root
  moduleName: "ugurcanbulut.quilt"
  ipcTarget: "ugurcanbulut.quilt"

  readonly property string pluginDir: decodeURIComponent(Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")).replace(/\/$/, "")
  readonly property string script: pluginDir + "/quilt"
  readonly property string stateDir: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/quilt"

  // Built-in Hyprland layouts Quilt can switch to, and their icons.
  readonly property var builtInLayouts: ({ dwindle: 0xF056E, scrolling: 0xF0728, monocle: 0xF0293, master: 0xF056D })

  // Specs per workspace, from the engine.
  property var summary: ({})
  property var sections: []

  // Keep in sync with SMART in engine.lua.
  readonly property var smartSpecs: ({
    standard: ["12", "6|6", "6|6:2", "6:2|6:2", "4|4:2|4:2", "4:2|4:2|4:2"],
    ultrawide: ["2|8|2", "6|6", "3|6|3", "3|6|3:2", "3:2|6|3:2", "4:2|4:2|4:2"],
    portrait: ["12", "12:2", "12:3", "6:2|6:2", "6:2|6:3", "6:3|6:3"]
  })

  property int cursorIndex: -1

  // The focused workspace, named the way the engine names it.
  readonly property var focusedWorkspace: Hyprland.focusedWorkspace
  readonly property string activeKey: keyFor(focusedWorkspace)
  readonly property var activeEntry: summary[activeKey] || null
  readonly property string activeSpec: activeEntry ? activeEntry.spec : ""
  property var activeTiles: null
  readonly property int activeWindows: activeTiles && activeTiles.workspace === activeKey
    ? activeTiles.windows
    : (focusedWorkspace && focusedWorkspace.lastIpcObject ? focusedWorkspace.lastIpcObject.windows || 0 : 0)

  // Presets in popup order, flattened for the keyboard cursor.
  readonly property var flatPresets: {
    var all = []
    sections.forEach(function(section) { section.presets.forEach(function(p) { all.push(p) }) })
    return all
  }
  readonly property int mirrorIndex: flatPresets.length
  readonly property int mainIndex: flatPresets.length + 1
  readonly property int offIndex: flatPresets.length + 2

  function keyFor(ws) {
    if (!ws) return ""
    if (ws.id > 0) return String(ws.id)
    if (String(ws.name).indexOf("special:") === 0) return ws.name
    return "name:" + ws.name
  }

  function fileFor(key) { return stateDir + "/" + key.replace(/[\/:]/g, "_") + ".json" }

  function glyph(codePoint) { return String.fromCodePoint(codePoint) }

  function run(args) { Quickshell.execDetached([root.script].concat(args)) }

  function load() { if (!loadProc.running) loadProc.running = true }

  // "4|8", "8|4:2" -> columns on a 10- or 12-column grid, or null.
  function parseSpec(spec) {
    if (typeof spec !== "string" || !spec.length) return null
    var cols = [], total = 0
    var parts = spec.split("|")
    for (var i = 0; i < parts.length; i++) {
      var m = parts[i].trim().match(/^(\d+)\s*(?::\s*(\d+))?$/)
      if (!m) return null
      var span = parseInt(m[1]), rows = m[2] ? parseInt(m[2]) : 1
      if (span < 1 || rows < 1 || rows > 8) return null
      cols.push({ span: span, rows: rows })
      total += span
    }
    return (total === 10 || total === 12) ? { cols: cols, total: total } : null
  }

  // Tiles of a spec in a unit square, each with its place in the fill order
  // (biggest first), as the engine fills them.
  function tilesFor(spec) {
    var layout = parseSpec(spec)
    if (!layout) return []
    var tiles = [], x = 0
    layout.cols.forEach(function(col) {
      var w = col.span / layout.total
      for (var r = 0; r < col.rows; r++) tiles.push({ x: x, y: r / col.rows, w: w, h: 1 / col.rows })
      x += w
    })
    var order = tiles.map(function(t, i) { return i })
    order.sort(function(a, b) {
      var sa = tiles[a].w * tiles[a].h, sb = tiles[b].w * tiles[b].h
      return Math.abs(sa - sb) > 1e-6 ? sb - sa : a - b
    })
    order.forEach(function(tileIndex, rank) { tiles[tileIndex].rank = rank })
    return tiles
  }

  function monitorShape() {
    var m = Hyprland.focusedMonitor
    if (!m) return "standard"
    var w = m.width, h = m.height
    if (h > w) return "portrait"
    return w / h >= 2 ? "ultrawide" : "standard"
  }

  function smartSpec(count) {
    var list = smartSpecs[monitorShape()]
    return list[Math.max(count, 1) - 1] || list[list.length - 1]
  }

  // What a preset button draws: the spec itself, or for Smart the spec it
  // would pick right now.
  function previewSpec(spec) {
    if (spec === "smart") return smartSpec(activeWindows)
    return spec
  }

  function isCurrent(preset) { return preset.spec.replace(/\s/g, "") === activeSpec }

  function applyPreset(preset) {
    var args = ["set", preset.spec]
    if (preset.gapsIn !== undefined || preset.gapsOut !== undefined)
      args.push(String(preset.gapsIn !== undefined ? preset.gapsIn : ""), String(preset.gapsOut !== undefined ? preset.gapsOut : ""))
    run(args)
    root.close()
  }

  function activate(index) {
    if (index >= 0 && index < flatPresets.length) applyPreset(flatPresets[index])
    else if (index === mirrorIndex) { run(["mirror"]); root.close() }
    else if (index === mainIndex) { run(["main"]); root.close() }
    else if (index === offIndex) { run(["off"]); root.close() }
  }

  function moveCursor(dx, dy) {
    if (cursorIndex < 0) { cursorIndex = 0; return }
    var next = cursorIndex + dx + dy * 4
    cursorIndex = Math.max(0, Math.min(offIndex, next))
  }

  function buildSections(builtIn) {
    var custom = setting("presets", [])
    var mine = (Array.isArray(custom) ? custom : []).map(function(entry) {
      var p = typeof entry === "string" ? { spec: entry } : entry
      if (!p || typeof p.spec !== "string" || !parseSpec(p.spec.replace(/\s/g, ""))) return null
      return { spec: p.spec.replace(/\s/g, ""), label: p.label || p.spec, gapsIn: p.gapsIn, gapsOut: p.gapsOut }
    }).filter(Boolean)
    var showBuiltIn = setting("builtInPresets", true) !== false
    var list = (builtIn || []).filter(function(s) { return showBuiltIn || s.title === "ADAPTIVE" })
    if (mine.length) list.splice(list.length - (list.length && list[list.length - 1].title === "ADAPTIVE" ? 1 : 0), 0, { title: "YOURS", presets: mine })
    sections = list
  }

  property var builtInSections: []
  onBuiltInSectionsChanged: buildSections(builtInSections)
  onSettingsChanged: buildSections(builtInSections)

  onOpenedChanged: {
    if (!opened) return
    cursorIndex = -1
    scroller.contentY = 0
    Hyprland.refreshWorkspaces()
    Hyprland.refreshMonitors()
  }

  Component.onCompleted: load()

  // A config reload starts a fresh Lua state in Hyprland, which drops the
  // engine; load it again.
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name === "configreloaded") root.load()
    }
  }

  Process {
    id: loadProc
    command: [root.script, "load"]
  }

  FileView {
    path: root.pluginDir + "/presets.json"
    onLoaded: {
      try { root.builtInSections = JSON.parse(text()).sections || [] } catch (e) { root.builtInSections = [] }
    }
  }

  FileView {
    path: root.stateDir + "/state.json"
    watchChanges: true
    onFileChanged: reload()
    onLoaded: {
      try { root.summary = JSON.parse(text()).workspaces || {} } catch (e) { root.summary = {} }
    }
    onLoadFailed: root.summary = {}
  }

  FileView {
    path: root.activeEntry ? root.fileFor(root.activeKey) : ""
    watchChanges: true
    onFileChanged: reload()
    onLoaded: {
      try { root.activeTiles = JSON.parse(text()) } catch (e) { root.activeTiles = null }
    }
    onLoadFailed: root.activeTiles = null
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // A layout drawn small: filled tiles solid, tiles past `windows` outlined.
  component Thumb: Item {
    id: thumb
    property string spec: ""
    property int windows: -1
    property color color: Color.foreground
    property real gap: 1.5

    readonly property var tiles: root.tilesFor(spec)

    Repeater {
      model: thumb.tiles

      Rectangle {
        required property var modelData
        readonly property bool filled: thumb.windows < 0 || modelData.rank < thumb.windows

        x: modelData.x * thumb.width + thumb.gap / 2
        y: modelData.y * thumb.height + thumb.gap / 2
        width: modelData.w * thumb.width - thumb.gap
        height: modelData.h * thumb.height - thumb.gap
        radius: Math.min(2, width / 4)
        color: filled ? thumb.color : "transparent"
        opacity: filled ? 0.9 : 0.6
        border.color: thumb.color
        border.width: filled ? 0 : 1
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    readonly property bool grid: root.parseSpec(root.activeTiles && root.activeTiles.workspace === root.activeKey ? root.activeTiles.spec : root.activeSpec) !== null

    text: grid ? "" : root.glyph(root.builtInLayouts[root.activeSpec] || 0xF0574)
    iconComponent: grid ? miniQuilt : null
    tooltipText: "Quilt · " + (root.activeSpec || "Omarchy default") + (root.activeSpec === "smart" && root.activeTiles ? " (" + root.activeTiles.spec + ")" : "")
      + "\nScroll to resize · right-click for the next preset"
    onPressed: function(b) {
      if (b === Qt.RightButton) root.run(["next"])
      else root.toggle()
    }
    onWheelMoved: function(delta) { root.run([delta > 0 ? "grow" : "shrink"]) }
  }

  Component {
    id: miniQuilt
    Thumb {
      spec: root.activeTiles && root.activeTiles.workspace === root.activeKey ? root.activeTiles.spec : root.activeSpec
      windows: root.activeTiles && root.activeTiles.workspace === root.activeKey && !root.activeTiles.smart ? root.activeTiles.windows : -1
      color: root.bar ? root.bar.foreground : Color.foreground
      gap: 2
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: root.activate(root.cursorIndex)
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      // m mirrors, s swaps the focused window into the main tile, x turns
      // Quilt off for this workspace.
      onTextKey: function(t) {
        if (t === "m") root.activate(root.mirrorIndex)
        else if (t === "s") root.activate(root.mainIndex)
      }
      onDeleteRequested: root.activate(root.offIndex)

      Flickable {
        id: scroller
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        interactive: contentHeight > height
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: scroller.width
          spacing: Style.space(10)

          // Which workspace this applies to, and what it uses now.
          Item {
            width: parent.width
            implicitHeight: Math.max(title.implicitHeight, current.implicitHeight)

            Text {
              id: title
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: "Workspace " + (root.focusedWorkspace ? root.focusedWorkspace.name : "")
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              id: current
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: (root.activeSpec || "Omarchy default") + " · " + root.activeWindows + (root.activeWindows === 1 ? " window" : " windows")
              color: root.bar.foreground
              opacity: 0.6
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          Repeater {
            model: root.sections

            Column {
              id: sectionColumn
              required property var modelData
              required property int index
              readonly property int offset: {
                var n = 0
                for (var i = 0; i < index; i++) n += root.sections[i].presets.length
                return n
              }

              width: column.width
              spacing: Style.space(6)

              PanelSectionHeader {
                text: sectionColumn.modelData.title
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
              }

              Grid {
                id: presetGrid
                width: parent.width
                columns: 4
                spacing: Style.space(6)

                readonly property real cellWidth: (width - spacing * (columns - 1)) / columns

                Repeater {
                  model: sectionColumn.modelData.presets

                  Button {
                    id: presetButton
                    required property var modelData
                    required property int index
                    readonly property int flatIndex: sectionColumn.offset + index
                    readonly property bool builtIn: root.builtInLayouts[modelData.spec] !== undefined

                    width: presetGrid.cellWidth
                    height: Style.space(62)
                    bordered: true
                    selected: root.isCurrent(modelData)
                    tooltipText: modelData.label || modelData.spec
                    foreground: root.bar.foreground
                    fontFamily: root.bar.fontFamily
                    hasCursor: root.cursorIndex === flatIndex
                    onClicked: root.applyPreset(modelData)
                    onHovered: function(h) { if (h) root.cursorIndex = presetButton.flatIndex }
                    onHasCursorChanged: if (hasCursor) root.ensureVisible(this)

                    Thumb {
                      visible: !presetButton.builtIn
                      x: (parent.width - width) / 2
                      y: Style.space(8)
                      width: parent.width - Style.space(18)
                      height: Style.space(28)
                      spec: root.previewSpec(presetButton.modelData.spec)
                      windows: root.activeWindows
                      color: root.bar.foreground
                    }

                    Text {
                      visible: presetButton.builtIn
                      x: (parent.width - width) / 2
                      y: Style.space(6)
                      textFormat: Text.PlainText
                      text: root.glyph(root.builtInLayouts[presetButton.modelData.spec] || 0xF0574)
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.space(26)
                    }

                    Text {
                      anchors.horizontalCenter: parent.horizontalCenter
                      anchors.bottom: parent.bottom
                      anchors.bottomMargin: Style.space(5)
                      width: parent.width - Style.space(8)
                      horizontalAlignment: Text.AlignHCenter
                      fontSizeMode: Text.HorizontalFit
                      minimumPixelSize: 7
                      textFormat: Text.PlainText
                      text: presetButton.modelData.spec
                      color: root.bar.foreground
                      opacity: 0.7
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                }
              }
            }
          }

          PanelSeparator { foreground: root.bar.foreground }

          Row {
            id: actionRow
            width: parent.width
            spacing: Style.space(6)

            readonly property real cellWidth: (width - spacing * 2) / 3

            Button {
              width: actionRow.cellWidth
              iconText: root.glyph(0xF10E7) // md-flip-horizontal
              text: "Mirror"
              tooltipText: "Flip the layout left to right"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              hasCursor: root.cursorIndex === root.mirrorIndex
              onClicked: root.activate(root.mirrorIndex)
              onHovered: function(h) { if (h) root.cursorIndex = root.mirrorIndex }
              onHasCursorChanged: if (hasCursor) root.ensureVisible(this)
            }

            Button {
              width: actionRow.cellWidth
              iconText: root.glyph(0xF04E1) // md-swap-horizontal
              text: "To main"
              tooltipText: "Swap the focused window into the main tile"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              hasCursor: root.cursorIndex === root.mainIndex
              onClicked: root.activate(root.mainIndex)
              onHovered: function(h) { if (h) root.cursorIndex = root.mainIndex }
              onHasCursorChanged: if (hasCursor) root.ensureVisible(this)
            }

            Button {
              width: actionRow.cellWidth
              iconText: root.glyph(0xF05B2) // md-window-restore
              text: "Off"
              tooltipText: "Back to Omarchy's default layout on this workspace"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              hasCursor: root.cursorIndex === root.offIndex
              onClicked: root.activate(root.offIndex)
              onHovered: function(h) { if (h) root.cursorIndex = root.offIndex }
              onHasCursorChanged: if (hasCursor) root.ensureVisible(this)
            }
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: "Scroll on the bar icon to widen or narrow the focused window's column. Right-click it for the next preset."
            color: root.bar.foreground
            opacity: 0.5
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  function ensureVisible(item) {
    var top = item.mapToItem(column, 0, 0).y
    var bottom = top + item.height
    var margin = Style.space(8)
    if (top < scroller.contentY + margin) scroller.contentY = Math.max(0, top - margin)
    else if (bottom > scroller.contentY + scroller.height - margin)
      scroller.contentY = Math.min(scroller.contentHeight - scroller.height, bottom + margin - scroller.height)
  }

  // Drop areas: outlines on the empty tiles of the workspace shown on this
  // bar's monitor. They sit on the layer just above the wallpaper, so windows
  // cover them, and take clicks only inside the outlines.
  PanelWindow {
    id: dropLayer
    readonly property var barWindow: button.QsWindow.window
    readonly property var monitor: barWindow && barWindow.screen ? Hyprland.monitorFor(barWindow.screen) : null
    readonly property string key: monitor ? root.keyFor(monitor.activeWorkspace) : ""
    readonly property var entry: root.summary[key] || null
    property var tiles: null
    readonly property var emptyTiles: {
      if (!entry || !root.parseSpec(entry.spec) || !tiles || tiles.workspace !== key) return []
      return tiles.tiles.filter(function(t) { return !t.filled })
    }

    screen: barWindow ? barWindow.screen : null
    visible: emptyTiles.length > 0 && monitor !== null
    color: "transparent"
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Bottom
    WlrLayershell.namespace: "quilt-drop-areas"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    mask: Region { regions: dropRegions.instances }

    FileView {
      path: dropLayer.entry ? root.fileFor(dropLayer.key) : ""
      watchChanges: true
      onFileChanged: reload()
      onLoaded: {
        try { dropLayer.tiles = JSON.parse(text()) } catch (e) { dropLayer.tiles = null }
      }
      onLoadFailed: dropLayer.tiles = null
    }

    Variants {
      id: dropRegions
      model: dropLayer.emptyTiles
      Region {
        required property var modelData
        x: modelData.rect.x - dropLayer.monitor.x
        y: modelData.rect.y - dropLayer.monitor.y
        width: modelData.rect.w
        height: modelData.rect.h
      }
    }

    Repeater {
      model: dropLayer.emptyTiles

      Item {
        id: dropArea
        required property var modelData

        x: modelData.rect.x - dropLayer.monitor.x
        y: modelData.rect.y - dropLayer.monitor.y
        width: modelData.rect.w
        height: modelData.rect.h

        Rectangle {
          anchors.fill: parent
          radius: Style.cornerRadius
          color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, dropMouse.containsMouse ? 0.12 : 0.05)
          border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, dropMouse.containsMouse ? 0.7 : 0.35)
          border.width: 2

          Behavior on color { ColorAnimation { duration: 120 } }
        }

        Column {
          anchors.centerIn: parent
          spacing: Style.space(6)

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            text: "+"
            color: Color.foreground
            opacity: 0.7
            font.family: Style.font.family
            font.pixelSize: Style.space(72)
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            text: "Tile " + dropArea.modelData.index + " · click to open an app here"
            color: Color.foreground
            opacity: 0.6
            font.family: Style.font.family
            font.pixelSize: Style.font.heading
          }
        }

        MouseArea {
          id: dropMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.run(["target", String(dropArea.modelData.index), dropLayer.key])
        }
      }
    }
  }
}
