# Quilt

An [Omarchy](https://omarchy.org) bar widget for tiling layouts. Pick a layout from the popup and the windows on your current workspace arrange into it. They stay tiled, new windows flow into the layout, and empty tiles turn into drop areas you can click to open an app right there.

## Layouts on a grid

Every layout is written as column widths on a **10- or 12-column grid**, separated by `|`. The total tells Quilt which grid you mean:

| Spec | Grid | Result |
|---|---|---|
| `6|6` | 12 | Two halves |
| `4|8` | 12 | One third, two thirds |
| `4|4|4` | 12 | Three equal columns |
| `3|6|3` | 12 | A wide center column, great on ultrawide monitors |
| `4|6` | 10 | 40% and 60% |
| `2|6|2` | 10 | 20% · 60% · 20% |

Add `:n` to split a column into `n` stacked tiles:

| Spec | Result |
|---|---|
| `8|4:2` | A main window with two stacked on the right |
| `3|6|3:2` | A centered main window, two stacked on the right |
| `6:2|6:2` | A 2 × 2 grid |
| `12:3` | Three rows, for vertical monitors |

The popup has 25 built-in layouts in four groups (columns, main + stack, grids and rows, adaptive), each shown as a small picture of your current number of windows.

## Features

- **Windows keep their tiles.** Close a window and its tile stays empty instead of the others shifting around. The next window you open fills it.
- **Drop areas.** Empty tiles show an outline with a "+". Click one to open the app launcher; the app you pick opens in that tile.
- **Main first.** Windows fill the biggest tile first, so a single window in `3|6|3` sits in the middle.
- **Smart layout.** Picks the layout from the number of windows and the monitor's shape, and never leaves tiles empty:

  | Windows | Standard | Ultrawide | Vertical |
  |---|---|---|---|
  | 1 | `12` | `2|8|2` | `12` |
  | 2 | `6|6` | `6|6` | `12:2` |
  | 3 | `6|6:2` | `3|6|3` | `12:3` |
  | 4 | `6:2|6:2` | `3|6|3:2` | `6:2|6:2` |

- **Live control.** Scroll on the bar icon to widen or narrow the focused window's column by one grid column (a centered column grows on both sides). Right-click the icon for the next layout. In the popup, **Mirror** flips the layout and **To main** swaps the focused window into the biggest tile.
- **Per workspace, remembered.** Each workspace keeps its own layout across Hyprland reloads and reboots. The bar icon draws the current workspace's layout.
- **Hyprland's own layouts too.** Dwindle (Omarchy's default), scrolling and monocle are one click away, and **Off** hands the workspace back to Omarchy's default.
- **Nothing written to your Hyprland config.** Quilt registers its layout while Hyprland runs and registers it again after every config reload. Removing the plugin leaves no trace in your config.

## Install

```bash
omarchy plugin add https://github.com/ugurcanbulut/omarchy-quilt.git --enable
```

The widget is added to the right section of the bar. To move it:

```bash
omarchy bar move ugurcanbulut.quilt --section right --index 0
```

## Custom layouts

Add a `presets` list to the Quilt entry in your bar layout in `~/.config/omarchy/shell.json`. They show up in a **YOURS** section and work in the next/previous cycle:

```json
{ "id": "ugurcanbulut.quilt",
  "presets": [
    "5|7",
    { "spec": "2|8|2", "label": "Focus", "gapsOut": 40 },
    { "spec": "3|6|3:3", "label": "Center + three", "gapsIn": 2 }
  ] }
```

- A preset is a spec string, or an object with `spec` and optional `label`, `gapsIn` and `gapsOut` (in pixels) for that layout.
- Add `"builtInPresets": false` to show only your own layouts plus the adaptive ones.

## Key bindings

Quilt doesn't add key bindings itself. To add some, put lines like these in `~/.config/hypr/bindings.lua`:

```lua
local quilt = os.getenv("HOME") .. "/.config/omarchy/plugins/ugurcanbulut.quilt/quilt"
o.bind("SUPER + CTRL + ALT + RIGHT", "Next layout", quilt .. " next")
o.bind("SUPER + CTRL + ALT + LEFT", "Previous layout", quilt .. " prev")
o.bind("SUPER + CTRL + ALT + EQUAL", "Widen column", quilt .. " grow")
o.bind("SUPER + CTRL + ALT + MINUS", "Narrow column", quilt .. " shrink")
o.bind("SUPER + CTRL + ALT + RETURN", "Window to main tile", quilt .. " main")
o.bind("SUPER + CTRL + ALT + 1", "Window to tile 1", quilt .. " move 1")
```

Check `omarchy menu keybindings --print` first for chords you already use.

## Command line

```bash
quilt set <spec>        # 4|8, 3|6|3:2, smart, dwindle, scrolling, monocle, off
quilt next | prev       # cycle through the layouts
quilt grow | shrink     # widen or narrow the focused window's column
quilt mirror            # flip the layout left to right
quilt main              # swap the focused window into the main tile
quilt move <n|empty>    # move the focused window to tile n, or the first empty tile
quilt target <n>        # open the app launcher; the new app goes to tile n
quilt status            # the active workspace's layout, as JSON
```

Tiles are numbered left to right, top to bottom.

## Requirements

- Omarchy 4 with Hyprland 0.55 or newer (Hyprland's Lua config)
- `jq`, part of a standard Omarchy install

## How it works, and its limits

- Quilt is a Hyprland layout written in Lua (`engine.lua`), loaded into the running Hyprland by the bar widget. Hyprland reloads its config whenever you save a Hyprland config file, which starts a fresh Lua state; the widget notices and loads Quilt again within a moment, and windows return to their tiles.
- Dragging the border between two tiled windows doesn't resize a Quilt layout. Scroll on the bar icon (or `quilt grow` / `quilt shrink`) instead.
- Omarchy's Super+L toggles between dwindle and scrolling on its own. On a Quilt workspace, pick Dwindle or Off in Quilt instead, or Quilt brings its layout back after the next config reload.
- Hyprland's Lua layout API is new and Hyprland describes it as not yet stable, so a future Hyprland release may need a Quilt update.
- The state lives in `~/.local/state/quilt/`. Deleting that folder forgets every workspace's layout.

## License

MIT
