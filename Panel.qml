import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Layout.js" as Layout

// Bar button + popup for Quilt's tile layouts, plus the drop areas drawn on
// empty tiles and the layout editor. The layout itself runs inside Hyprland
// (engine.lua); the sibling `quilt` script loads it and passes commands to
// it, and the engine reports back through files in $XDG_RUNTIME_DIR/quilt.
Panel {
  id: root
  moduleName: "ugurcanbulut.quilt"
  ipcTarget: "ugurcanbulut.quilt"
  manageIpc: false

  readonly property string pluginDir: decodeURIComponent(Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")).replace(/\/$/, "")
  readonly property string script: pluginDir + "/quilt"
  readonly property string stateDir: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/quilt"

  // Built-in Hyprland layouts Quilt can switch to, and their icons.
  readonly property var builtInLayouts: ({ dwindle: 0xF056E, scrolling: 0xF0728, monocle: 0xF0293, master: 0xF056D })

  // Specs per workspace, from the engine.
  property var summary: ({})
  property var sections: []

  // Scroll deltas not yet worth a whole step (touchpads send many small ones).
  property real wheelAccumulator: 0

  property int cursorIndex: -1
  // A preset of yours that one more right-click removes.
  property int pendingDelete: -1

  // The focused workspace, named the way the engine names it.
  readonly property var focusedWorkspace: Hyprland.focusedWorkspace
  readonly property string activeKey: keyFor(focusedWorkspace)
  readonly property var activeEntry: summary[activeKey] || null
  readonly property string activeSpec: activeEntry ? activeEntry.spec : ""
  property var activeTiles: null
  readonly property int activeWindows: activeTiles && activeTiles.workspace === activeKey
    ? activeTiles.windows
    : (focusedWorkspace && focusedWorkspace.lastIpcObject ? focusedWorkspace.lastIpcObject.windows || 0 : 0)
  // The layout on screen: for Smart, the one it picked.
  readonly property string shownSpec: activeTiles && activeTiles.workspace === activeKey ? activeTiles.spec : activeSpec
  readonly property bool canEdit: activeEntry !== null && Layout.editable(shownSpec) !== null

  // Presets in popup order, flattened for the keyboard cursor.
  readonly property var flatPresets: {
    var all = []
    sections.forEach(function(section) { section.presets.forEach(function(p) { all.push(p) }) })
    return all
  }
  readonly property int editIndex: flatPresets.length
  readonly property int newIndex: flatPresets.length + 1
  readonly property int mirrorIndex: flatPresets.length + 2
  readonly property int mainIndex: flatPresets.length + 3
  readonly property int offIndex: flatPresets.length + 4

  // The popup's rows as the arrow keys see them: four presets to a row in
  // each section, then Edit | New, then Mirror | To main | Off.
  readonly property var navRows: {
    var rows = [], start = 0
    sections.forEach(function(section) {
      for (var i = 0; i < section.presets.length; i += 4) {
        var items = []
        for (var j = i; j < Math.min(i + 4, section.presets.length); j++) items.push(start + j)
        rows.push({ items: items, columns: 4 })
      }
      start += section.presets.length
    })
    rows.push({ items: [editIndex, newIndex], columns: 2 })
    rows.push({ items: [mirrorIndex, mainIndex, offIndex], columns: 3 })
    return rows
  }

  // A layout the bar icon's scroll wheel can resize: columns, not drawn.
  readonly property bool resizable: activeSpec !== "" && activeSpec.charAt(0) !== "@" && Layout.parse(activeSpec) !== null

  // The line under the buttons describes whatever the cursor is on.
  readonly property string hint: {
    var i = cursorIndex
    if (i >= 0 && i < flatPresets.length) return describe(flatPresets[i])
    if (i === editIndex) return canEdit
      ? "Edit this workspace's layout on screen: drag lines to resize, split, remove or swap tiles, then save it as a preset."
      : "Pick a grid layout for this workspace first, then edit it on screen."
    if (i === newIndex) return "Draw a new layout on an empty workspace, with any tiles you like, and save it as a preset."
    if (i === mirrorIndex) return "Flip the layout left to right. Windows go with their tiles."
    if (i === mainIndex) return "Swap the focused window into the biggest tile."
    if (i === offIndex) return "Back to Omarchy's layout on this workspace: the default, or what you picked with Super+L."
    return "Scroll on the bar icon to widen or narrow the focused window's column. Right-click it for the next preset."
  }

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

  function monitorShape() {
    var m = Hyprland.focusedMonitor
    if (!m) return "standard"
    var w = m.width, h = m.height
    // Hyprland reports the mode size; odd transforms turn it a quarter.
    var info = m.lastIpcObject
    if (info && info.transform % 2 === 1) { var t = w; w = h; h = t }
    if (h > w) return "portrait"
    return w / h >= 2 ? "ultrawide" : "standard"
  }

  function smartSpec(count) { return Layout.smartSpec(monitorShape(), count) }

  // What a preset button draws: the spec itself, or for Smart the spec it
  // would pick right now.
  function previewSpec(spec) {
    if (spec === "smart") return smartSpec(activeWindows)
    return spec
  }

  function isCurrent(preset) { return Layout.normalize(preset.spec) === Layout.normalize(activeSpec) }

  function describe(preset) {
    if (preset.description) return preset.description
    var layout = Layout.parse(preset.spec)
    var count = layout ? layout.rects.length : 0
    var text = (preset.label && preset.label !== preset.spec ? preset.label + " · " : "") + preset.spec
      + (count ? " · " + count + (count === 1 ? " tile" : " tiles") : "")
    if (preset.custom) text += pendingDelete === preset.customIndex ? ". Right-click again to remove it." : ". Right-click to remove it."
    return text
  }

  function saveSettings(changes) {
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, Object.assign({}, root.settings || {}, changes))
  }

  function customPresets() {
    var list = setting("presets", [])
    return Array.isArray(list) ? list.slice() : []
  }

  function savePreset(label, spec) {
    var list = customPresets()
    var exists = list.some(function(entry) {
      var p = typeof entry === "string" ? { spec: entry } : entry
      return p && p.spec === spec && (p.label || "") === label
    })
    if (!exists) list.push(label ? { spec: spec, label: label } : spec)
    saveSettings({ presets: list })
  }

  function removePreset(index) {
    var list = customPresets()
    list.splice(index, 1)
    pendingDelete = -1
    // With none left, drop the key instead of keeping an empty list.
    saveSettings({ presets: list.length ? list : undefined })
  }

  function focusedScreen() {
    var monitor = Hyprland.focusedMonitor
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) if (monitor && screens[i].name === monitor.name) return screens[i]
    var own = button.QsWindow.window
    return own && own.screen ? own.screen : screens[0]
  }

  // The highest-numbered workspace with no windows, from 99 down.
  function emptyWorkspace() {
    var busy = {}
    Hyprland.workspaces.values.forEach(function(ws) {
      var info = ws.lastIpcObject
      if (ws.id > 0 && info && info.windows > 0) busy[ws.id] = true
    })
    for (var id = 99; id > 10; id--) if (!busy[id]) return String(id)
    return "99"
  }

  function startEdit() {
    // One editor session at a time.
    if (editor.mode !== "") return
    if (!canEdit) {
      Quickshell.execDetached(["notify-send", "-a", "Quilt", "Quilt", "Pick a grid layout for this workspace first, then edit it."])
      return
    }
    root.close()
    editor.startEdit({
      screen: focusedScreen(), key: activeKey, spec: shownSpec, original: activeSpec,
      gapsIn: activeEntry.gapsIn, gapsOut: activeEntry.gapsOut
    })
  }

  function startNew() {
    if (editor.mode !== "") return
    root.close()
    Hyprland.refreshWorkspaces()
    editor.startNew({ screen: focusedScreen(), key: emptyWorkspace(), returnKey: activeKey })
  }

  function applyPreset(preset) {
    var args = ["set", preset.spec]
    if (preset.gapsIn !== undefined || preset.gapsOut !== undefined)
      args.push(String(preset.gapsIn !== undefined ? preset.gapsIn : ""), String(preset.gapsOut !== undefined ? preset.gapsOut : ""))
    run(args)
    root.close()
  }

  function activate(index) {
    if (index >= 0 && index < flatPresets.length) applyPreset(flatPresets[index])
    else if (index === editIndex) { if (canEdit) startEdit() }
    else if (index === newIndex) startNew()
    else if (index === mirrorIndex) { run(["mirror"]); root.close() }
    else if (index === mainIndex) { run(["main"]); root.close() }
    else if (index === offIndex) { run(["off"]); root.close() }
  }

  function moveCursor(dx, dy) {
    if (cursorIndex < 0) { cursorIndex = 0; return }
    if (dx !== 0) {
      cursorIndex = Math.max(0, Math.min(offIndex, cursorIndex + dx))
      return
    }
    // Up and down go to the item underneath, even where rows hold different
    // numbers of buttons.
    for (var r = 0; r < navRows.length; r++) {
      var column = navRows[r].items.indexOf(cursorIndex)
      if (column < 0) continue
      var target = navRows[r + dy]
      if (!target) return
      // On a boundary between two buttons, take the left one.
      var centre = (column + 0.5) / navRows[r].columns
      cursorIndex = target.items[Math.min(target.items.length - 1, Math.max(0, Math.ceil(centre * target.columns) - 1))]
      return
    }
  }

  function buildSections(builtIn) {
    var custom = setting("presets", [])
    var mine = (Array.isArray(custom) ? custom : []).map(function(entry, index) {
      var p = typeof entry === "string" ? { spec: entry } : entry
      if (!p || typeof p.spec !== "string" || !Layout.parse(p.spec.replace(/\s/g, ""))) return null
      return { spec: p.spec.replace(/\s/g, ""), label: p.label || p.spec, gapsIn: p.gapsIn, gapsOut: p.gapsOut, custom: true, customIndex: index }
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
    pendingDelete = -1
    if (!opened) return
    cursorIndex = -1
    scroller.contentY = 0
    Hyprland.refreshWorkspaces()
    Hyprland.refreshMonitors()
  }

  onCursorIndexChanged: {
    var p = flatPresets[cursorIndex]
    if (!p || p.customIndex !== pendingDelete) pendingDelete = -1
  }

  Component.onCompleted: load()

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function edit(): void { root.startEdit() }
    function create(): void { root.startNew() }
  }

  Editor {
    id: editor
    script: root.script
    tilesInfo: root.activeTiles
    onSaveRequested: function(label, spec) { root.savePreset(label, spec) }
  }

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

    readonly property var tiles: Layout.tilesFor(spec)

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
    readonly property bool grid: Layout.parse(root.shownSpec) !== null

    text: grid ? "" : root.glyph(root.builtInLayouts[root.activeSpec] || 0xF0574)
    iconComponent: grid ? miniQuilt : null
    tooltipText: "Quilt · " + (root.activeSpec || "Omarchy default") + (root.activeSpec === "smart" && root.activeTiles ? " (" + root.activeTiles.spec + ")" : "")
      + (root.resizable ? "\nScroll to resize · right-click for the next preset" : "\nRight-click for the next preset")
    onPressed: function(b) {
      if (b === Qt.RightButton) root.run(["next"])
      else root.toggle()
    }
    // One notch is one column; a touchpad swipe adds up to whole notches.
    onWheelMoved: function(delta) {
      if (!root.resizable) return
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      for (var i = 0; i < Math.abs(wheel.steps); i++) root.run([wheel.steps > 0 ? "grow" : "shrink"])
    }
  }

  Component {
    id: miniQuilt
    Thumb {
      spec: root.shownSpec
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
      // e edits the layout, n draws a new one, m mirrors, s swaps the
      // focused window into the main tile, x turns Quilt off here.
      onTextKey: function(t) {
        if (t === "e") root.activate(root.editIndex)
        else if (t === "n") root.activate(root.newIndex)
        else if (t === "m") root.activate(root.mirrorIndex)
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
                    // Your own presets: right-click twice to remove.
                    onRightClicked: {
                      if (!modelData.custom) return
                      root.cursorIndex = flatIndex
                      if (root.pendingDelete === modelData.customIndex) root.removePreset(modelData.customIndex)
                      else root.pendingDelete = modelData.customIndex
                    }
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
                      readonly property bool removing: presetButton.modelData.custom === true && root.pendingDelete === presetButton.modelData.customIndex
                      text: removing ? "Remove?" : (presetButton.modelData.custom === true && presetButton.modelData.label !== presetButton.modelData.spec ? presetButton.modelData.label : presetButton.modelData.spec)
                      color: removing ? Color.urgent : root.bar.foreground
                      opacity: removing ? 1 : 0.7
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
            id: editorRow
            width: parent.width
            spacing: Style.space(6)

            readonly property real cellWidth: (width - spacing) / 2

            Button {
              width: editorRow.cellWidth
              iconText: root.glyph(0xF18D9) // md-vector-square-edit
              text: "Edit"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              opacity: root.canEdit ? 1 : 0.45
              hasCursor: root.cursorIndex === root.editIndex
              onClicked: root.activate(root.editIndex)
              onHovered: function(h) { if (h) root.cursorIndex = root.editIndex }
              onHasCursorChanged: if (hasCursor) root.ensureVisible(this)
            }

            Button {
              width: editorRow.cellWidth
              iconText: root.glyph(0xF0F8D) // md-view-grid-plus
              text: "New"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              hasCursor: root.cursorIndex === root.newIndex
              onClicked: root.activate(root.newIndex)
              onHovered: function(h) { if (h) root.cursorIndex = root.newIndex }
              onHasCursorChanged: if (hasCursor) root.ensureVisible(this)
            }
          }

          Row {
            id: actionRow
            width: parent.width
            spacing: Style.space(6)

            readonly property real cellWidth: (width - spacing * 2) / 3

            Button {
              width: actionRow.cellWidth
              iconText: root.glyph(0xF10E7) // md-flip-horizontal
              text: "Mirror"
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
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              hasCursor: root.cursorIndex === root.offIndex
              onClicked: root.activate(root.offIndex)
              onHovered: function(h) { if (h) root.cursorIndex = root.offIndex }
              onHasCursorChanged: if (hasCursor) root.ensureVisible(this)
            }
          }

          // Three lines high whatever it says, so the popup doesn't jump.
          Item {
            width: parent.width
            height: threeLines.implicitHeight

            Text {
              id: threeLines
              visible: false
              text: "A\nA\nA"
              font: hintText.font
            }

            Text {
              id: hintText
              width: parent.width
              wrapMode: Text.WordWrap
              maximumLineCount: 3
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: root.hint
              color: root.bar.foreground
              opacity: 0.6
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
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
      // Not for Smart: a new window there would reshape the whole layout.
      if (!entry || !Layout.parse(entry.spec) || !tiles || tiles.workspace !== key) return []
      return tiles.tiles.filter(function(t) { return !t.filled })
    }

    screen: barWindow ? barWindow.screen : null
    // The editor draws its own tiles.
    visible: emptyTiles.length > 0 && monitor !== null && editor.mode === ""
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
