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

  // The popup's tabs: Quilt's own presets, yours, and settings.
  property string tab: "builtin"
  property var builtInList: []
  property var yoursList: []
  readonly property var sections: tab === "yours"
    ? (yoursList.length ? [{ title: "", presets: yoursList }] : [])
    : tab === "settings" ? (picking ? pickerSections : []) : builtInList
  // Cursor positions that aren't presets or actions (those count from 0).
  readonly property int builtInTabIndex: -2
  readonly property int yoursTabIndex: -3
  readonly property int settingsTabIndex: -4
  readonly property int backIndex: -5
  readonly property int builtInSettingIndex: -10
  readonly property int dropAreasIndex: -11
  readonly property int scrollIndex: -12
  readonly property int overflowIndex: -13
  function monitorIndex(i) { return -20 - i }
  function smartIndex(count) { return -30 - count }

  // Settings, with their defaults.
  readonly property bool showBuiltIn: setting("builtInPresets", true) !== false
  readonly property bool dropAreasOn: setting("dropAreas", true) !== false
  readonly property bool scrollOn: setting("scrollResize", true) !== false
  readonly property string overflowMode: setting("overflow", "tabs") === "stack" ? "stack" : "tabs"

  // Connected monitors, for their default layouts.
  readonly property var monitors: Hyprland.monitors.values.map(function(m) {
    return { name: m.name, label: m.name + " · " + m.width + "×" + m.height, shape: shapeOf(m) }
  })

  // A layout picker over the settings: { kind: "monitor", name } or
  // { kind: "smart", shape, count }.
  property var picking: null
  readonly property string pickingValue: !picking ? ""
    : picking.kind === "monitor" ? monitorDefault(picking.name) : (smartChoice(picking.shape, picking.count) || "")
  readonly property var pickerSections: {
    if (!picking) return []
    var first
    if (picking.kind === "monitor") {
      first = [{ spec: "none", caption: "None", icon: 0xF073A, value: "", hint: "New workspaces on " + picking.name + " keep Omarchy's layout." }]
        .concat(["smart", "dwindle", "scrolling", "monocle"].map(function(spec) { return { spec: spec, value: spec } }))
    } else {
      var standard = Layout.smartSpec(picking.shape, picking.count, null)
      first = [{ spec: standard, caption: "Default", value: "", hint: "Quilt's own choice for " + picking.count + (picking.count === 1 ? " window: " : " windows: ") + standard + "." }]
    }
    var out = [{ title: "", presets: first }]
    builtInSections.forEach(function(section) {
      if (section.title === "ADAPTIVE") return
      out.push({ title: section.title, presets: section.presets.map(function(p) { return { spec: p.spec, label: p.label, value: p.spec } }) })
    })
    // Yours by label for a monitor (it brings its gaps and apps), by spec for Smart.
    var mine = yoursList.map(function(p) {
      var named = p.label && p.label !== p.spec
      return { spec: p.spec, label: p.label, caption: named ? p.label : p.spec, value: picking.kind === "monitor" && named ? p.label : p.spec }
    })
    if (mine.length) out.push({ title: "YOURS", presets: mine })
    return out
  }

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

  // The popup's rows as the arrow keys see them: the tabs, four presets to a
  // row in each section, then Edit | New, then Mirror | To main | Off.
  readonly property var navRows: {
    var rows = [{ items: [builtInTabIndex, yoursTabIndex, settingsTabIndex], columns: 3 }], start = 0
    if (tab === "settings" && !picking) {
      [builtInSettingIndex, dropAreasIndex, scrollIndex, overflowIndex].forEach(function(i) { rows.push({ items: [i], columns: 1 }) })
      monitors.forEach(function(m, i) { rows.push({ items: [monitorIndex(i)], columns: 1 }) })
      for (var n = 1; n <= 6; n++) rows.push({ items: [smartIndex(n)], columns: 1 })
    }
    if (tab === "settings" && picking) rows.push({ items: [backIndex], columns: 1 })
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
    if (i === builtInTabIndex) return "Quilt's own layouts: columns, main and stack, grids and rows, and the adaptive ones."
    if (i === yoursTabIndex) return yoursList.length
      ? "Layouts you saved from the editor or added to shell.json."
      : "Layouts you save from the editor show up here."
    if (i === settingsTabIndex) return "Settings: what the popup shows, drop areas, scrolling, extra windows, and layouts for new workspaces and Smart."
    if (i === builtInSettingIndex) return "Show Quilt's built-in layouts on the Built-in tab. Off leaves only the adaptive ones."
    if (i === dropAreasIndex) return "Outline empty tiles with a + you can click to open an app there."
    if (i === scrollIndex) return "Scroll on the bar icon to widen or narrow the focused window's column."
    if (i === overflowIndex) return "More windows than tiles: Tabs puts the extras in the last tile as tabs, Stack squeezes them in beside its window."
    if (i === backIndex) return "Back to the settings without changing anything."
    for (var m = 0; m < monitors.length; m++)
      if (i === monitorIndex(m)) return "New workspaces on " + monitors[m].name + " start with this layout, until you pick one there yourself."
    for (var n = 1; n <= 6; n++)
      if (i === smartIndex(n)) return "The layout Smart uses for " + n + (n === 1 ? " window" : " windows") + " on " + currentShape + " monitors. Default is Quilt's own choice."
    if (i >= 0 && i < flatPresets.length) return flatPresets[i].hint || describe(flatPresets[i])
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

  function shapeOf(m) {
    if (!m) return "standard"
    var w = m.width, h = m.height
    // Hyprland reports the mode size; odd transforms turn it a quarter.
    var info = m.lastIpcObject
    if (info && info.transform % 2 === 1) { var t = w; w = h; h = t }
    if (h > w) return "portrait"
    return w / h >= 2 ? "ultrawide" : "standard"
  }

  function monitorShape() { return shapeOf(Hyprland.focusedMonitor) }
  readonly property string currentShape: monitorShape()

  // Your Smart layouts for a monitor shape, by window count.
  function smartList(shape) {
    var mine = setting("smart", {})
    return mine && mine[shape] ? toArray(mine[shape]) : []
  }

  // Your Smart layout for this many windows, if you set a usable one.
  function smartChoice(shape, count) {
    var spec = smartList(shape)[count - 1]
    return typeof spec === "string" && Layout.parse(spec) ? spec.replace(/\s/g, "") : ""
  }

  function smartSpec(count) { return Layout.smartSpec(monitorShape(), count, smartList(monitorShape())) }

  function monitorDefault(name) {
    var all = setting("monitors", {})
    var value = all ? all[name] : ""
    return typeof value === "string" ? value : ""
  }

  // A monitor default names a spec, a Hyprland layout or one of your
  // presets by label; this is the spec to draw.
  function specFor(value) {
    var mine = yoursList.filter(function(p) { return p.label === value })[0]
    return mine ? mine.spec : value
  }

  // Settings are written only when they differ from the default.
  function saveSetting(name, value, fallback) {
    var change = {}
    change[name] = value === fallback ? undefined : value
    saveSettings(change)
  }

  function setMonitorDefault(name, value) {
    var all = Object.assign({}, setting("monitors", {}) || {})
    if (value) all[name] = value
    else delete all[name]
    saveSettings({ monitors: Object.keys(all).length ? all : undefined })
  }

  function setSmart(shape, count, spec) {
    var stored = setting("smart", {}) || {}
    var all = {}
    Object.keys(stored).forEach(function(key) { all[key] = toArray(stored[key]) })
    var list = (all[shape] || []).slice()
    while (list.length < count) list.push(null)
    list[count - 1] = spec || null
    while (list.length && !list[list.length - 1]) list.pop()
    if (list.length) all[shape] = list
    else delete all[shape]
    saveSettings({ smart: Object.keys(all).length ? all : undefined })
  }

  // A choice from the layout picker.
  function choose(item) {
    if (!picking) return
    if (picking.kind === "monitor") setMonitorDefault(picking.name, item.value)
    else setSmart(picking.shape, picking.count, item.value)
    closePicker()
  }

  function openPicker(what) {
    picking = what
    cursorIndex = backIndex
  }

  function closePicker() {
    var was = picking
    picking = null
    if (!was) return
    if (was.kind === "monitor") {
      var i = monitors.map(function(m) { return m.name }).indexOf(was.name)
      cursorIndex = i >= 0 ? monitorIndex(i) : builtInSettingIndex
    } else {
      cursorIndex = smartIndex(was.count)
    }
  }

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
    var homes = Object.keys(preset.apps || {}).sort(function(a, b) { return a - b }).map(function(tile) { return preset.apps[tile] + " in " + tile })
    if (homes.length) text += " · " + homes.join(", ") + ". The rocket (or O) also opens them"
    if (preset.custom) text += pendingDelete === preset.customIndex ? ". Right-click again to remove it." : ". Right-click to remove it."
    return text
  }

  function saveSettings(changes) {
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, Object.assign({}, root.settings || {}, changes))
  }

  // Lists in settings can arrive as Qt sequences, which Array.isArray turns
  // down; treating those as empty would hide your presets, and saving would
  // then write over them.
  function toArray(value) {
    if (!value || typeof value !== "object" || typeof value.length !== "number") return []
    return Array.prototype.slice.call(value)
  }

  function customPresets() { return toArray(setting("presets", [])) }

  // apps: { "2": "chromium", ... } to keep with the preset, or nothing.
  function savePreset(label, spec, apps) {
    var list = customPresets()
    var hasApps = apps && Object.keys(apps).length > 0
    var exists = list.some(function(entry) {
      var p = typeof entry === "string" ? { spec: entry } : entry
      return p && p.spec === spec && (p.label || "") === label && JSON.stringify(p.apps || {}) === JSON.stringify(hasApps ? apps : {})
    })
    if (!exists) {
      var entry = { spec: spec }
      if (label) entry.label = label
      if (hasApps) entry.apps = apps
      list.push(label || hasApps ? entry : spec)
    }
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

  // Everything the preset says, so the script doesn't fill gaps or apps in
  // from another preset with the same spec ("-" and "{}" mean none).
  function presetArgs(preset) {
    var gap = function(value) { return value !== undefined && value !== null ? String(value) : "-" }
    return ["set", preset.spec, gap(preset.gapsIn), gap(preset.gapsOut), JSON.stringify(preset.apps || {})]
  }

  function applyPreset(preset) {
    run(presetArgs(preset))
    root.close()
  }

  function hasApps(preset) { return !!preset && !!preset.apps && Object.keys(preset.apps).length > 0 }

  // Apply a preset, then open its apps that aren't on the workspace yet.
  function launchPreset(preset) {
    Quickshell.execDetached(["sh", "-c", '"$0" "$@" && "$0" launch', root.script].concat(presetArgs(preset)))
    root.close()
  }

  function setTab(name) {
    tab = name
    picking = null
    pendingDelete = -1
  }

  function activate(index) {
    if (index === builtInTabIndex) setTab("builtin")
    else if (index === yoursTabIndex) setTab("yours")
    else if (index === settingsTabIndex) setTab("settings")
    else if (index === backIndex) closePicker()
    else if (index === builtInSettingIndex) saveSetting("builtInPresets", !showBuiltIn, true)
    else if (index === dropAreasIndex) saveSetting("dropAreas", !dropAreasOn, true)
    else if (index === scrollIndex) saveSetting("scrollResize", !scrollOn, true)
    else if (index === overflowIndex) saveSetting("overflow", overflowMode === "tabs" ? "stack" : "tabs", "tabs")
    else if (index <= monitorIndex(0) && index > monitorIndex(monitors.length)) openPicker({ kind: "monitor", name: monitors[monitorIndex(0) - index].name })
    else if (index <= smartIndex(1) && index >= smartIndex(6)) openPicker({ kind: "smart", shape: currentShape, count: smartIndex(0) - index })
    else if (picking && index >= 0 && index < flatPresets.length) choose(flatPresets[index])
    else if (index >= 0 && index < flatPresets.length) applyPreset(flatPresets[index])
    else if (index === editIndex) { if (canEdit) startEdit() }
    else if (index === newIndex) startNew()
    else if (index === mirrorIndex) { run(["mirror"]); root.close() }
    else if (index === mainIndex) { run(["main"]); root.close() }
    else if (index === offIndex) { run(["off"]); root.close() }
  }

  function moveCursor(dx, dy) {
    if (cursorIndex === -1) { cursorIndex = flatPresets.length ? 0 : editIndex; return }
    // Left and right walk the popup in reading order.
    if (dx !== 0) {
      var order = []
      navRows.forEach(function(row) { row.items.forEach(function(i) { order.push(i) }) })
      var at = order.indexOf(cursorIndex)
      cursorIndex = at < 0 ? order[0] : order[Math.max(0, Math.min(order.length - 1, at + dx))]
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
    var mine = customPresets().map(function(entry, index) {
      var p = typeof entry === "string" ? { spec: entry } : entry
      if (!p || typeof p.spec !== "string" || !Layout.parse(p.spec.replace(/\s/g, ""))) return null
      return { spec: p.spec.replace(/\s/g, ""), label: p.label || p.spec, gapsIn: p.gapsIn, gapsOut: p.gapsOut, apps: p.apps, custom: true, customIndex: index }
    }).filter(Boolean)
    var showBuiltIn = setting("builtInPresets", true) !== false
    builtInList = (builtIn || []).filter(function(s) { return showBuiltIn || s.title === "ADAPTIVE" })
    yoursList = mine
  }

  property var builtInSections: []
  onBuiltInSectionsChanged: buildSections(builtInSections)
  onSettingsChanged: {
    buildSections(builtInSections)
    configureTimer.restart()
  }

  // Your Smart layouts and monitor defaults reach the engine through the
  // script, which reads them from shell.json once the shell has written it.
  Timer {
    id: configureTimer
    interval: 500
    onTriggered: root.run(["configure"])
  }

  onOpenedChanged: {
    pendingDelete = -1
    picking = null
    if (!opened) return
    // Open on the tab that holds the current layout.
    if (yoursList.some(isCurrent)) tab = "yours"
    else if (builtInList.some(function(section) { return section.presets.some(isCurrent) })) tab = "builtin"
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
    onSaveRequested: function(label, spec, apps) { root.savePreset(label, spec, apps) }
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

  // Preset sections in a 4-wide grid; each tab has one. Only the shown tab
  // (`active`) takes the cursor and clicks. With `pick` set it's a picker:
  // a click hands the item to pick(), and `chosen` marks the current value.
  component PresetSections: Column {
    id: presetSections
    property var model: []
    property bool active: false
    property var pick: null
    property string chosen: ""

    spacing: Style.space(10)
    opacity: active ? 1 : 0
    enabled: active

    Repeater {
      model: presetSections.model

      Column {
        id: sectionColumn
        required property var modelData
        required property int index
        readonly property int offset: {
          var n = 0
          for (var i = 0; i < index; i++) n += presetSections.model[i].presets.length
          return n
        }

        width: presetSections.width
        spacing: Style.space(6)

        PanelSectionHeader {
          visible: sectionColumn.modelData.title !== ""
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
              readonly property int icon: modelData.icon || root.builtInLayouts[modelData.spec] || 0
              readonly property bool builtIn: icon !== 0

              width: presetGrid.cellWidth
              height: Style.space(62)
              bordered: true
              selected: presetSections.pick ? modelData.value === presetSections.chosen : root.isCurrent(modelData)
              tooltipText: modelData.label || modelData.spec
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              hasCursor: presetSections.active && root.cursorIndex === flatIndex
              onClicked: presetSections.pick ? presetSections.pick(modelData) : root.applyPreset(modelData)
              // Your own presets: right-click twice to remove.
              onRightClicked: {
                if (presetSections.pick || !modelData.custom) return
                root.cursorIndex = flatIndex
                if (root.pendingDelete === modelData.customIndex) root.removePreset(modelData.customIndex)
                else root.pendingDelete = modelData.customIndex
              }
              onHovered: function(h) { if (h && presetSections.active) root.cursorIndex = presetButton.flatIndex }
              onHasCursorChanged: if (hasCursor) root.ensureVisible(this)

              Thumb {
                visible: !presetButton.builtIn
                x: (parent.width - width) / 2
                y: Style.space(8)
                width: parent.width - Style.space(18)
                height: Style.space(28)
                spec: root.previewSpec(presetButton.modelData.spec)
                windows: presetSections.pick ? -1 : root.activeWindows
                color: root.bar.foreground
              }

              // Presets with app homes: apply and open their apps.
              Text {
                visible: !presetSections.pick && root.hasApps(presetButton.modelData)
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.margins: Style.space(4)
                textFormat: Text.PlainText
                text: root.glyph(0xF14DE) // md-rocket-launch
                color: root.bar.foreground
                opacity: launchMouse.containsMouse ? 1 : 0.55
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body

                MouseArea {
                  id: launchMouse
                  anchors.fill: parent
                  anchors.margins: -Style.space(4)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onContainsMouseChanged: if (containsMouse) root.cursorIndex = presetButton.flatIndex
                  onClicked: root.launchPreset(presetButton.modelData)
                }
              }

              Text {
                visible: presetButton.builtIn
                x: (parent.width - width) / 2
                y: Style.space(6)
                textFormat: Text.PlainText
                text: root.glyph(presetButton.icon || 0xF0574)
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
                text: removing ? "Remove?" : presetButton.modelData.caption
                  || (presetButton.modelData.custom === true && presetButton.modelData.label !== presetButton.modelData.spec ? presetButton.modelData.label : presetButton.modelData.spec)
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
  }

  // A settings row whose value is a layout: its name on the left, a picture
  // and name of the layout on the right; a click opens the picker.
  component ChoiceRow: Button {
    id: choiceRow
    property string title: ""
    property string value: ""
    property string caption: ""
    property string spec: ""
    property int cursorIdx: 0
    readonly property int icon: spec === "" ? 0xF073A : (root.builtInLayouts[spec] || 0)

    height: Style.space(40)
    leftAlign: true
    text: title
    bordered: true
    foreground: root.bar.foreground
    fontFamily: root.bar.fontFamily
    hasCursor: root.cursorIndex === cursorIdx
    onClicked: root.activate(cursorIdx)
    onHovered: function(h) { if (h) root.cursorIndex = choiceRow.cursorIdx }
    onHasCursorChanged: if (hasCursor) root.ensureVisible(this)

    Row {
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)

      Thumb {
        visible: choiceRow.icon === 0
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(36)
        height: Style.space(18)
        spec: root.previewSpec(choiceRow.spec)
        color: root.bar.foreground
      }

      Text {
        visible: choiceRow.icon !== 0
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: root.glyph(choiceRow.icon)
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: choiceRow.caption
        color: root.bar.foreground
        opacity: 0.7
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: root.glyph(0xF0142) // md-chevron-right
        color: root.bar.foreground
        opacity: 0.5
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
      }
    }
  }

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
      + (root.resizable && root.scrollOn ? "\nScroll to resize · right-click for the next preset" : "\nRight-click for the next preset")
    onPressed: function(b) {
      if (b === Qt.RightButton) root.run(["next"])
      else root.toggle()
    }
    // One notch is one column; a touchpad swipe adds up to whole notches.
    onWheelMoved: function(delta) {
      if (!root.resizable || !root.scrollOn) return
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
      // e edits the layout, n draws a new one, o applies the preset under the
      // cursor and opens its apps, m mirrors, s swaps the focused window
      // into the main tile, x turns Quilt off here. (h, j, k and l move.)
      onTextKey: function(t) {
        if (t === "e") root.activate(root.editIndex)
        else if (t === "n") root.activate(root.newIndex)
        else if (t === "o" && root.hasApps(root.flatPresets[root.cursorIndex])) root.launchPreset(root.flatPresets[root.cursorIndex])
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

          // Built-in | Yours. Both tabs keep one height, so the buttons
          // below don't jump when you switch.
          Row {
            id: tabRow
            width: parent.width
            spacing: Style.space(6)

            // The gear is a square; the two named tabs share the rest.
            readonly property real gearWidth: Style.space(40)
            readonly property real cellWidth: (width - gearWidth - spacing * 2) / 2

            Repeater {
              model: [
                { name: "builtin", label: "Built-in", index: root.builtInTabIndex },
                { name: "yours", label: "Yours", index: root.yoursTabIndex },
                { name: "settings", icon: 0xF0493, index: root.settingsTabIndex } // md-cog
              ]

              Button {
                required property var modelData
                width: modelData.icon ? tabRow.gearWidth : tabRow.cellWidth
                text: modelData.icon ? "" : modelData.label + (modelData.name === "yours" && root.yoursList.length ? " · " + root.yoursList.length : "")
                iconText: modelData.icon ? root.glyph(modelData.icon) : ""
                tooltipText: modelData.icon ? "Settings" : ""
                bordered: true
                selected: root.tab === modelData.name
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                hasCursor: root.cursorIndex === modelData.index
                onClicked: root.setTab(modelData.name)
                onHovered: function(h) { if (h) root.cursorIndex = modelData.index }
                onHasCursorChanged: if (hasCursor) root.ensureVisible(this)
              }
            }
          }

          Item {
            width: parent.width
            implicitHeight: Math.max(builtInTab.implicitHeight, yoursTab.implicitHeight, settingsTab.implicitHeight)

            PresetSections {
              id: builtInTab
              width: parent.width
              model: root.builtInList
              active: root.tab === "builtin"
            }

            Column {
              id: yoursTab
              width: parent.width
              spacing: Style.space(10)
              opacity: root.tab === "yours" ? 1 : 0
              enabled: root.tab === "yours"

              PresetSections {
                width: parent.width
                model: root.yoursList.length ? [{ title: "", presets: root.yoursList }] : []
                active: root.tab === "yours"
              }

              Text {
                visible: root.yoursList.length === 0
                width: parent.width
                topPadding: Style.space(8)
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
                textFormat: Text.PlainText
                text: "No layouts of your own yet. Edit this one or draw a New one below, then save it as a preset."
                color: root.bar.foreground
                opacity: 0.6
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

            Column {
              id: settingsTab
              width: parent.width
              spacing: Style.space(6)
              opacity: root.tab === "settings" ? 1 : 0
              enabled: root.tab === "settings"

              // The settings list.
              Column {
                visible: !root.picking
                width: parent.width
                spacing: Style.space(6)

                PanelSectionHeader {
                  text: "GENERAL"
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                }

                Repeater {
                  model: [
                    { label: "Show built-in layouts", on: root.showBuiltIn, index: root.builtInSettingIndex },
                    { label: "Drop areas on empty tiles", on: root.dropAreasOn, index: root.dropAreasIndex },
                    { label: "Scroll on the bar icon to resize", on: root.scrollOn, index: root.scrollIndex }
                  ]

                  Toggle {
                    required property var modelData
                    width: parent.width
                    label: modelData.label
                    checked: modelData.on
                    titleSize: Style.font.body
                    foreground: root.bar.foreground
                    fontFamily: root.bar.fontFamily
                    hasCursor: root.cursorIndex === modelData.index
                    onClicked: root.activate(modelData.index)
                    onHovered: function(h) { if (h) root.cursorIndex = modelData.index }
                    onHasCursorChanged: if (hasCursor) root.ensureVisible(this)
                  }
                }

                // Extra windows: Tabs | Stack.
                Item {
                  id: overflowRow
                  width: parent.width
                  height: Math.max(overflowLabel.implicitHeight, overflowChoice.implicitHeight)
                  readonly property bool hasCursor: root.cursorIndex === root.overflowIndex
                  onHasCursorChanged: if (hasCursor) root.ensureVisible(this)

                  Text {
                    id: overflowLabel
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: "Extra windows"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.body
                  }

                  ButtonGroup {
                    id: overflowChoice
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    focusable: false
                    options: [{ value: "tabs", label: "Tabs" }, { value: "stack", label: "Stack" }]
                    value: root.overflowMode
                    foreground: root.bar.foreground
                    fontFamily: root.bar.fontFamily
                    cursorIndex: overflowRow.hasCursor ? (root.overflowMode === "tabs" ? 1 : 0) : -1
                    onChanged: function(value) { root.saveSetting("overflow", value, "tabs") }
                    onHovered: function(index, h) { if (h) root.cursorIndex = root.overflowIndex }
                  }
                }

                PanelSectionHeader {
                  text: "NEW WORKSPACES START WITH"
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                }

                Repeater {
                  model: root.monitors

                  ChoiceRow {
                    required property var modelData
                    required property int index
                    width: parent.width
                    title: modelData.label
                    value: root.monitorDefault(modelData.name)
                    caption: value === "" ? "None" : value
                    spec: root.specFor(value)
                    cursorIdx: root.monitorIndex(index)
                  }
                }

                PanelSectionHeader {
                  text: "SMART ON " + root.currentShape.toUpperCase() + " MONITORS"
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                }

                Repeater {
                  model: 6

                  ChoiceRow {
                    required property int index
                    readonly property int count: index + 1
                    readonly property string mine: root.smartChoice(root.currentShape, count)
                    width: parent.width
                    title: count + (count === 1 ? " window" : " windows")
                    value: mine
                    caption: mine || "Default"
                    spec: mine || Layout.smartSpec(root.currentShape, count, null)
                    cursorIdx: root.smartIndex(count)
                  }
                }
              }

              // The layout picker.
              Column {
                visible: root.picking !== null
                width: parent.width
                spacing: Style.space(10)

                Item {
                  width: parent.width
                  height: backButton.implicitHeight

                  Button {
                    id: backButton
                    anchors.left: parent.left
                    iconText: root.glyph(0xF004D) // md-arrow-left
                    text: "Back"
                    foreground: root.bar.foreground
                    fontFamily: root.bar.fontFamily
                    hasCursor: root.cursorIndex === root.backIndex
                    onClicked: root.closePicker()
                    onHovered: function(h) { if (h) root.cursorIndex = root.backIndex }
                    onHasCursorChanged: if (hasCursor) root.ensureVisible(this)
                  }

                  Text {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - backButton.width - Style.space(12)
                    horizontalAlignment: Text.AlignRight
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: !root.picking ? ""
                      : root.picking.kind === "monitor" ? "New workspaces on " + root.picking.name
                      : "Smart · " + root.picking.count + (root.picking.count === 1 ? " window" : " windows")
                    color: root.bar.foreground
                    opacity: 0.7
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }

                PresetSections {
                  width: parent.width
                  model: root.pickerSections
                  active: root.tab === "settings" && root.picking !== null
                  pick: root.choose
                  chosen: root.pickingValue
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
    visible: emptyTiles.length > 0 && monitor !== null && editor.mode === "" && root.dropAreasOn
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
            text: "Tile " + dropArea.modelData.index + (dropArea.modelData.home
              ? " · click to open " + dropArea.modelData.home + " · right-click for another app"
              : " · click to open an app here")
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
          acceptedButtons: Qt.LeftButton | Qt.RightButton
          // A home tile opens its own app; right-click (or no home) offers them all.
          onClicked: function(mouse) {
            var home = dropArea.modelData.home && mouse.button === Qt.LeftButton
            root.run([home ? "launch" : "target", String(dropArea.modelData.index), dropLayer.key])
          }
        }
      }
    }
  }
}
