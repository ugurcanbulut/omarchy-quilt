-- Quilt: tile layout presets for Hyprland's Lua config (Hyprland 0.55+).
--
-- The bar widget loads this file with `hyprctl eval` when the shell starts
-- and again after every Hyprland config reload, since a reload starts a fresh
-- Lua state. Nothing is written to the user's Hyprland config.
--
-- A layout is a spec in one of two forms:
--   columns: widths on a 10- or 12-column grid, "4|8" or "3|6|3". ":n" splits
--            a column into n equal tiles ("8|4:2"); ":a/b/..." into tiles of
--            those heights on a 10- or 12-row grid ("4:8/4").
--   drawn:   "@12x12:x,y,w,h;x,y,w,h;..." - rectangles on a W x H grid, as
--            the visual editor draws them; parts of the grid can stay empty.
-- Tiles are numbered by their top-left corner: left to right, then top to
-- bottom among tiles that start in the same column. Each window keeps its
-- tile; a closed window leaves an empty tile that the next window fills.
-- "smart" instead picks a column spec from the window count and the
-- monitor's shape, and fills its tiles in order.

quilt = quilt or {}
local Q = quilt

local HOME = os.getenv("HOME") or ""
local STATE_HOME = os.getenv("XDG_STATE_HOME") or (HOME .. "/.local/state")
Q.state_dir = STATE_HOME .. "/quilt"
Q.runtime_dir = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/quilt"

-- Drawn grids can be this fine: the editor refines a 10- or 12-row grid up to
-- 12 times so uneven rows (like "12:5") keep their edges on grid lines.
local MAX_GRID = 144

-- How long a tile picked from a drop area waits for its app, in seconds.
local PENDING_SECONDS = 60

-- Smart specs by window count, per monitor shape. Past the end of a list the
-- layout becomes an even grid.
local SMART = {
  standard = { "12", "6|6", "6|6:2", "6:2|6:2", "4|4:2|4:2", "4:2|4:2|4:2" },
  ultrawide = { "2|8|2", "6|6", "3|6|3", "3|6|3:2", "3:2|6|3:2", "4:2|4:2|4:2" },
  portrait = { "12", "12:2", "12:3", "6:2|6:2", "6:2|6:3", "6:3|6:3" },
}

local LAYOUTS = { dwindle = true, scrolling = true, master = true, monocle = true }

---------------------------------------------------------------- serialization

local function lua_literal(v)
  local t = type(v)
  if t == "string" then return string.format("%q", v) end
  if t == "number" or t == "boolean" then return tostring(v) end
  if t ~= "table" then return "nil" end
  local parts = {}
  for k, val in pairs(v) do
    local key = type(k) == "number" and ("[" .. k .. "]") or ("[" .. string.format("%q", k) .. "]")
    parts[#parts + 1] = key .. "=" .. lua_literal(val)
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function json(v)
  local t = type(v)
  if t == "string" then return '"' .. v:gsub('[%c"\\]', function(c) return string.format("\\u%04x", c:byte()) end) .. '"' end
  if t == "number" then return (v == math.floor(v)) and string.format("%d", v) or string.format("%.4f", v) end
  if t == "boolean" then return tostring(v) end
  if t ~= "table" then return "null" end
  if #v > 0 then
    local parts = {}
    for _, val in ipairs(v) do parts[#parts + 1] = json(val) end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  local parts = {}
  for k, val in pairs(v) do parts[#parts + 1] = json(tostring(k)) .. ":" .. json(val) end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function write_file(path, text)
  local f = io.open(path .. ".tmp", "w")
  if not f then return end
  f:write(text)
  f:close()
  os.rename(path .. ".tmp", path)
end

local function tiles_file(key) return Q.runtime_dir .. "/" .. key:gsub("[/:]", "_") .. ".json" end

------------------------------------------------------------------------ state

local function ws_key(ws)
  if not ws then return nil end
  if ws.id and ws.id > 0 then return tostring(ws.id) end
  if ws.name and ws.name:match("^special:") then return ws.name end
  return "name:" .. (ws.name or "")
end

local function ws_state(key)
  Q.state.workspaces[key] = Q.state.workspaces[key] or { assign = {}, order = {} }
  local s = Q.state.workspaces[key]
  s.assign = s.assign or {}
  s.order = s.order or {}
  return s
end

-- Shell-facing summary: which layout each workspace uses.
local function write_summary()
  local out = {}
  for key, s in pairs(Q.state.workspaces) do
    if s.spec then out[key] = { spec = s.spec, gapsIn = s.gaps_in, gapsOut = s.gaps_out } end
  end
  write_file(Q.runtime_dir .. "/state.json", json({ workspaces = out, loaded = true }) .. "\n")
end

function Q.save()
  write_file(Q.state_dir .. "/state.lua", "return " .. lua_literal(Q.state) .. "\n")
  write_summary()
end

local function load_state()
  local ok, data = pcall(dofile, Q.state_dir .. "/state.lua")
  Q.state = (ok and type(data) == "table") and data or {}
  Q.state.workspaces = Q.state.workspaces or {}
  -- Window ids start over with a new Hyprland session, so remembered tiles
  -- from the last one mean nothing.
  local session = os.getenv("HYPRLAND_INSTANCE_SIGNATURE") or ""
  if Q.state.session ~= session then
    for _, s in pairs(Q.state.workspaces) do s.assign, s.order, s.pending = {}, {}, nil end
    Q.state.session = session
  end
end

------------------------------------------------------------------------ specs

-- ":3" -> three equal heights; ":8/4" -> heights on a 10- or 12-row grid.
local function parse_rows(text)
  if text == "" then return { 1 }, 1 end
  if text:match("^%d+$") then
    local n = tonumber(text)
    if n < 1 or n > 8 then return nil end
    local rows = {}
    for i = 1, n do rows[i] = 1 end
    return rows, n
  end
  if not text:match("^%d[%d/]*%d$") or text:find("//", 1, true) then return nil end
  local rows, total = {}, 0
  for part in text:gmatch("[^/]+") do
    local size = tonumber(part)
    if not size or size < 1 then return nil end
    rows[#rows + 1] = size
    total = total + size
  end
  if total ~= 10 and total ~= 12 then return nil end
  return rows, total
end

-- A spec as tiles in fractions of the area, in tile-number order. Column
-- specs also keep their columns, which grow and mirror work on.
function Q.parse(spec)
  if type(spec) ~= "string" then return nil end
  spec = spec:gsub("%s", "")
  local tiles = {}

  local gw, gh, list = spec:match("^@(%d+)x(%d+):(.+)$")
  if gw then
    gw, gh = tonumber(gw), tonumber(gh)
    if gw < 1 or gh < 1 or gw > MAX_GRID or gh > MAX_GRID then return nil end
    local rects = {}
    for rect in list:gmatch("[^;]+") do
      local x, y, w, h = rect:match("^(%d+),(%d+),(%d+),(%d+)$")
      x, y, w, h = tonumber(x), tonumber(y), tonumber(w), tonumber(h)
      if not x or w < 1 or h < 1 or x + w > gw or y + h > gh then return nil end
      -- Overlapping tiles would stack windows on top of each other.
      for _, r in ipairs(rects) do
        if math.min(x + w, r.x + r.w) > math.max(x, r.x) and math.min(y + h, r.y + r.h) > math.max(y, r.y) then return nil end
      end
      rects[#rects + 1] = { x = x, y = y, w = w, h = h }
      tiles[#tiles + 1] = { x = x / gw, y = y / gh, w = w / gw, h = h / gh }
    end
    if #tiles == 0 then return nil end
    table.sort(tiles, function(a, b)
      if math.abs(a.x - b.x) > 1e-6 then return a.x < b.x end
      return a.y < b.y
    end)
    return { tiles = tiles, grid = { w = gw, h = gh } }
  end

  local cols, total = {}, 0
  for part in (spec .. "|"):gmatch("([^|]*)|") do
    local span, rows = part:match("^(%d+)$"), ""
    if not span then span, rows = part:match("^(%d+):([%d/]+)$") end
    span = tonumber(span)
    if not span or span < 1 then return nil end
    local sizes, row_total = parse_rows(rows)
    if not sizes then return nil end
    cols[#cols + 1] = { span = span, rows = rows, sizes = sizes, row_total = row_total }
    total = total + span
  end
  if #cols == 0 or (total ~= 10 and total ~= 12) then return nil end
  local x = 0
  for ci, col in ipairs(cols) do
    local y = 0
    for _, size in ipairs(col.sizes) do
      tiles[#tiles + 1] = { x = x / total, y = y / col.row_total, w = col.span / total, h = size / col.row_total, col = ci }
      y = y + size
    end
    x = x + col.span
  end
  return { tiles = tiles, cols = cols, total = total }
end

local function format_columns(layout)
  local parts = {}
  for _, c in ipairs(layout.cols) do parts[#parts + 1] = c.rows ~= "" and (c.span .. ":" .. c.rows) or tostring(c.span) end
  return table.concat(parts, "|")
end

-- An even grid for n windows: about as many columns as rows, at most 8 rows
-- to a column. Past 96 windows the last tile takes the rest.
local function grid_spec(n)
  local least = math.min(math.ceil(math.sqrt(n)), 4)
  local cols = 12
  for _, c in ipairs({ 1, 2, 3, 4, 6, 12 }) do
    if c >= least and c * 8 >= n then cols = c break end
  end
  local span = tostring(math.floor(12 / cols))
  local parts, left = {}, n
  for c = 1, cols do
    local rows = math.max(1, math.min(8, math.ceil(left / (cols - c + 1))))
    parts[#parts + 1] = span .. ":" .. rows
    left = left - rows
  end
  return table.concat(parts, "|")
end

-- Hyprland reports a monitor's mode size; odd transforms turn it a quarter.
local function rotated(monitor) return (tonumber(monitor.transform) or 0) % 2 == 1 end

local function monitor_shape(monitor)
  if not monitor then return "standard" end
  local w, h = monitor.width, monitor.height
  if rotated(monitor) then w, h = h, w end
  if h > w then return "portrait" end
  if w / h >= 2.0 then return "ultrawide" end
  return "standard"
end

local function smart_spec(n, monitor)
  local list = SMART[monitor_shape(monitor)]
  return list[math.max(n, 1)] or grid_spec(n)
end

-- Tiles placed in the area, plus the order they fill in: biggest (the main
-- tile) first, then tile number.
local function tiles_for(area, layout)
  local tiles = {}
  for i, t in ipairs(layout.tiles) do
    tiles[i] = { x = area.x + t.x * area.w, y = area.y + t.y * area.h, w = t.w * area.w, h = t.h * area.h, col = t.col, unit = t }
  end
  local order = {}
  for i in ipairs(tiles) do order[i] = i end
  table.sort(order, function(a, b)
    local sa, sb = tiles[a].unit.w * tiles[a].unit.h, tiles[b].unit.w * tiles[b].unit.h
    if math.abs(sa - sb) > 1e-6 then return sa > sb end
    return a < b
  end)
  return tiles, order
end

local function overlap(a, b)
  local w = math.min(a.x + a.w, b.x + b.w) - math.max(a.x, b.x)
  local h = math.min(a.y + a.h, b.y + b.h) - math.max(a.y, b.y)
  return (w > 0 and h > 0) and w * h or 0
end

-- Where a window in this tile ends up: Hyprland insets inner edges by the
-- inner gap and every edge by the border.
local function window_rect(tile, area, s)
  local gaps = s.gaps_in and { top = s.gaps_in, right = s.gaps_in, bottom = s.gaps_in, left = s.gaps_in }
    or hl.get_config("general.gaps_in") or {}
  if type(gaps) == "number" then gaps = { top = gaps, right = gaps, bottom = gaps, left = gaps } end
  local border = tonumber(hl.get_config("general.border_size")) or 0
  local function inset(edge, at_boundary) return border + (at_boundary and 0 or (gaps[edge] or 0)) end
  local left = inset("left", math.abs(tile.x - area.x) < 1)
  local right = inset("right", math.abs(tile.x + tile.w - area.x - area.w) < 1)
  local top = inset("top", math.abs(tile.y - area.y) < 1)
  local bottom = inset("bottom", math.abs(tile.y + tile.h - area.y - area.h) < 1)
  return { x = tile.x + left, y = tile.y + top, w = tile.w - left - right, h = tile.h - top - bottom }
end

local function write_tiles(key, s, spec, area, tiles, filled, count)
  local out = {}
  for i, t in ipairs(tiles) do
    out[i] = { index = i, filled = filled[i] ~= nil, app = filled[i] or "", rect = window_rect(t, area, s) }
  end
  write_file(tiles_file(key), json({
    workspace = key, spec = spec, smart = s.spec == "smart", windows = count,
    area = { x = area.x, y = area.y, w = area.w, h = area.h }, tiles = out,
  }) .. "\n")
  hl.dispatch(hl.dsp.event("quilt>>" .. key))
end

-- The area a workspace's tiles share, for a workspace with no windows to ask:
-- its monitor minus the bar and the outer gaps.
local function area_for(key, s)
  local okw, ws = pcall(hl.get_workspace, key)
  local monitor = (okw and ws and ws.monitor) or hl.get_active_monitor()
  if not monitor then return nil end
  local gaps_out = (s and s.gaps_out) and { top = s.gaps_out, right = s.gaps_out, bottom = s.gaps_out, left = s.gaps_out }
    or hl.get_config("general.gaps_out") or {}
  if type(gaps_out) == "number" then gaps_out = { top = gaps_out, right = gaps_out, bottom = gaps_out, left = gaps_out } end
  local r = type(monitor.reserved) == "table" and monitor.reserved or {}
  local scale = monitor.scale or 1
  local width, height = monitor.width, monitor.height
  if rotated(monitor) then width, height = height, width end
  return {
    x = monitor.x + (r.left or 0) + (gaps_out.left or 0),
    y = monitor.y + (r.top or 0) + (gaps_out.top or 0),
    w = width / scale - (r.left or 0) - (r.right or 0) - (gaps_out.left or 0) - (gaps_out.right or 0),
    h = height / scale - (r.top or 0) - (r.bottom or 0) - (gaps_out.top or 0) - (gaps_out.bottom or 0),
  }, monitor
end

----------------------------------------------------------------------- layout

local function tiled_ids(key)
  local ids = {}
  local ok, windows = pcall(hl.get_workspace_windows, key)
  if ok and windows then
    for _, w in ipairs(windows) do
      if not w.floating then ids[tostring(w.stable_id)] = true end
    end
  end
  return ids
end

local function recalculate(ctx)
  local first = ctx.targets[1] and ctx.targets[1].window
  local key = first and ws_key(first.workspace)
  if not key then return end
  local s = ws_state(key)
  local smart = s.spec == "smart"
  local spec = smart and smart_spec(#ctx.targets, first.monitor) or s.spec
  local layout = Q.parse(spec) or Q.parse("6|6")
  local tiles, fill = tiles_for(ctx.area, layout)

  -- Windows Hyprland hands over now; during a layout switch this can be a
  -- partial list, so a window only loses its tile when it is really gone.
  local present, targets = {}, {}
  for _, t in ipairs(ctx.targets) do
    if t.window then
      local id = tostring(t.window.stable_id)
      present[id] = true
      targets[id] = t
    end
  end
  local alive = tiled_ids(key)
  for id in pairs(present) do alive[id] = true end

  local placed = {}
  if smart then
    -- Smart: windows keep their order; the order fills the tiles.
    local order, known = {}, {}
    for _, id in ipairs(s.order) do
      if alive[id] and not known[id] then order[#order + 1], known[id] = id, true end
    end
    for _, t in ipairs(ctx.targets) do
      local id = t.window and tostring(t.window.stable_id)
      if id and not known[id] then order[#order + 1], known[id] = id, true end
    end
    if #order ~= #s.order then Q.dirty = true end
    s.order = order
    local slot = 0
    for _, id in ipairs(order) do
      if targets[id] then
        slot = slot + 1
        local tile = fill[slot] or fill[#fill]
        placed[tile] = placed[tile] or {}
        table.insert(placed[tile], targets[id])
      end
    end
  else
    local assign, used = s.assign, {}
    for id, tile in pairs(assign) do
      if not alive[id] or tile < 1 or tile > #tiles then assign[id], Q.dirty = nil, true else used[tile] = true end
    end
    local overflow = {}
    -- A tile picked from a drop area holds for the app launched from it, not
    -- for whatever opens much later.
    if s.pending and os.time() - (s.pending_at or 0) > PENDING_SECONDS then s.pending, s.pending_at = nil, nil end
    for _, t in ipairs(ctx.targets) do
      local id = t.window and tostring(t.window.stable_id)
      if id and not assign[id] then
        local want = s.pending
        if want and (used[want] or want > #tiles) then want = nil end
        if not want then
          for _, i in ipairs(fill) do if not used[i] then want = i break end end
        end
        s.pending, s.pending_at = nil, nil
        if want then assign[id], used[want], Q.dirty = want, true, true else overflow[#overflow + 1] = t end
      end
    end
    for id, tile in pairs(assign) do
      if targets[id] then
        placed[tile] = placed[tile] or {}
        table.insert(placed[tile], targets[id])
      end
    end
    -- More windows than tiles: the extras share the last tile to fill.
    local last = fill[#fill]
    for _, t in ipairs(overflow) do
      placed[last] = placed[last] or {}
      table.insert(placed[last], t)
    end
  end

  local filled = {}
  for i, list in pairs(placed) do
    local b = tiles[i]
    for k, t in ipairs(list) do
      t:place({ x = b.x, y = b.y + (k - 1) * b.h / #list, w = b.w, h = b.h / #list })
    end
    filled[i] = list[1].window and list[1].window.class or "?"
  end

  write_tiles(key, s, smart and spec or s.spec, ctx.area, tiles, filled, #ctx.targets)
  if Q.dirty then Q.dirty = false Q.save() end
end

---------------------------------------------------------------------- control

-- Point a workspace at a layout (nil: drop Quilt's rule). Hyprland can only
-- disable a rule, not remove it, so a new one is made only when the rule in
-- place says something else or something newer (like Omarchy's Super+L)
-- overrides it.
local function set_rule(key, layout, gaps_in, gaps_out)
  Q.rules = Q.rules or {}
  local current = Q.rules[key]
  -- Quilt 0.1.1 kept the bare rule; take those over on an in-place reload.
  if current and type(current) ~= "table" then current = { rule = current } end
  local sig = layout and table.concat({ layout, tostring(gaps_in), tostring(gaps_out) }, "|")
  if current and sig and current.sig == sig then
    local ok, ws = pcall(hl.get_workspace, key)
    local now = ok and ws and ws.tiled_layout
    if not now or now == layout or "lua:" .. now == layout then return end
  end
  if current then
    pcall(function() current.rule:set_enabled(false) end)
    Q.rules[key] = nil
  end
  if not layout then return end
  local rule = { workspace = key, layout = layout }
  if gaps_in then rule.gaps_in = gaps_in end
  if gaps_out then rule.gaps_out = gaps_out end
  Q.rules[key] = { rule = hl.workspace_rule(rule), sig = sig }
end

local function apply_rule(key)
  local s = Q.state.workspaces[key]
  if not s or not s.spec then return set_rule(key, nil) end
  set_rule(key, LAYOUTS[s.spec] and s.spec or "lua:quilt", s.gaps_in, s.gaps_out)
end

-- The layout a workspace had before Quilt: what Omarchy's Super+L saved for
-- it, or the configured default.
local function omarchy_layout(key)
  local f = key:match("^%d+$") and io.open(STATE_HOME .. "/omarchy/workspace-layouts/" .. key .. ".lua")
  if f then
    local saved = f:read("a"):match('layout%s*=%s*"([%w_:%-]+)"')
    f:close()
    if saved then return saved end
  end
  return hl.get_config("general.layout") or "dwindle"
end

-- All-empty tiles, for a workspace with no tiled windows to lay out.
local function write_empty(key)
  local s = Q.state.workspaces[key]
  if not s or not s.spec or LAYOUTS[s.spec] then return end
  local area, monitor = area_for(key, s)
  if not area then return end
  local spec = s.spec == "smart" and smart_spec(0, monitor) or s.spec
  write_tiles(key, s, spec, area, tiles_for(area, Q.parse(spec) or Q.parse("6|6")), {}, 0)
end

-- Make Hyprland lay the workspace out again: a zero-pixel resize of one of
-- its tiled windows does that without moving anything.
function Q.refresh(key)
  local ok, windows = pcall(hl.get_workspace_windows, key)
  if ok and windows then
    for _, w in ipairs(windows) do
      if not w.floating then
        hl.dispatch(hl.dsp.window.resize({ window = "address:" .. w.address, x = 0, y = 0, relative = true }))
        return
      end
    end
  end
  write_empty(key)
end

-- When the last tiled window leaves a workspace (closed, floated or moved
-- away), Hyprland doesn't lay it out again, so its tiles are marked empty
-- here. `gone` is the window leaving, which may still be listed.
local function settle(key, gone)
  local left = tiled_ids(key)
  left[gone] = nil
  if next(left) == nil then write_empty(key) end
end

local function forget(s, id)
  local had = s.assign[id] ~= nil
  s.assign[id] = nil
  for i, o in ipairs(s.order) do
    if o == id then
      table.remove(s.order, i)
      return true
    end
  end
  return had
end

local function active_in(key)
  local w = hl.get_active_window()
  if w and not w.floating and ws_key(w.workspace) == key then return tostring(w.stable_id), w end
end

-- Windows follow their tiles to a new layout: each one goes to the free tile
-- that overlaps its old tile most.
local function remap(s, old, new)
  if not old or not new then
    s.assign = {}
    return
  end
  local taken, moved = {}, {}
  local ids = {}
  for id in pairs(s.assign) do ids[#ids + 1] = id end
  table.sort(ids, function(a, b) return s.assign[a] < s.assign[b] end)
  for _, id in ipairs(ids) do
    local from = old.tiles[s.assign[id]]
    local best, best_area = nil, 0
    for j, t in ipairs(new.tiles) do
      local a = from and overlap(from, t) or 0
      -- Ties (within rounding) go to the lower tile number.
      if not taken[j] and a > best_area + 1e-9 then best, best_area = j, a end
    end
    if best then moved[id], taken[best] = best, true end
  end
  s.assign = moved
end

-- spec: a column or drawn spec, "smart", a built-in Hyprland layout, or "off".
function Q.set(key, spec, gaps_in, gaps_out)
  local s = ws_state(key)
  if spec == "off" then
    Q.state.workspaces[key] = nil
    -- Disabling Quilt's rule alone doesn't switch the workspace back; a rule
    -- naming its old layout does.
    set_rule(key, omarchy_layout(key))
    os.remove(tiles_file(key))
    Q.save()
    return "ok"
  end
  local new = Q.parse(spec)
  if not (spec == "smart" or LAYOUTS[spec] or new) then return "bad spec" end
  remap(s, Q.parse(s.spec or ""), new)
  s.spec = new and spec:gsub("%s", "") or spec
  s.gaps_in, s.gaps_out = tonumber(gaps_in), tonumber(gaps_out)
  apply_rule(key)
  Q.save()
  Q.refresh(key)
  return "ok"
end

-- Grow (+1) or shrink (-1) the column holding the focused window by one grid
-- unit. A middle column trades with both neighbours so it stays centered.
function Q.grow(key, delta)
  local s = Q.state.workspaces[key]
  if not s or not s.spec then return "This workspace doesn't use a Quilt layout" end
  if s.spec == "smart" then return "Smart sizes its own columns. Pick a column layout to resize it." end
  if LAYOUTS[s.spec] then return "Resizing works on Quilt's column layouts" end
  local layout = Q.parse(s.spec)
  if not layout then return "not a grid layout" end
  if not layout.cols then return "Use Edit to resize a drawn layout" end
  if #layout.cols < 2 then return "nothing to resize" end
  local id = active_in(key)
  local tile = id and s.assign[id]
  local col = 1
  if tile and layout.tiles[tile] then
    col = layout.tiles[tile].col
  else
    for i, c in ipairs(layout.cols) do if c.span > layout.cols[col].span then col = i end end
  end
  local cols = layout.cols
  local neighbours = {}
  if col > 1 then neighbours[#neighbours + 1] = col - 1 end
  if col < #cols then neighbours[#neighbours + 1] = col + 1 end
  for _, n in ipairs(neighbours) do
    if delta > 0 and cols[n].span <= 1 then return "at the limit" end
  end
  if delta < 0 and cols[col].span - #neighbours < 1 then return "at the limit" end
  for _, n in ipairs(neighbours) do
    cols[n].span = cols[n].span - delta
    cols[col].span = cols[col].span + delta
  end
  s.spec = format_columns(layout)
  Q.save()
  Q.refresh(key)
  return "ok"
end

-- Flip the layout left to right; windows go with their tiles.
function Q.mirror(key)
  local s = Q.state.workspaces[key]
  local layout = s and Q.parse(s.spec or "")
  if not layout then return "not a grid layout" end
  local spec
  if layout.cols then
    local reversed = {}
    for i = #layout.cols, 1, -1 do reversed[#reversed + 1] = layout.cols[i] end
    spec = format_columns({ cols = reversed })
  else
    local g, rects = layout.grid, {}
    for _, t in ipairs(layout.tiles) do
      rects[#rects + 1] = string.format("%d,%d,%d,%d",
        math.floor((1 - t.x - t.w) * g.w + 0.5), math.floor(t.y * g.h + 0.5), math.floor(t.w * g.w + 0.5), math.floor(t.h * g.h + 0.5))
    end
    spec = string.format("@%dx%d:%s", g.w, g.h, table.concat(rects, ";"))
  end
  local new = Q.parse(spec)
  local map = {}
  for i, t in ipairs(layout.tiles) do
    for j, u in ipairs(new.tiles) do
      if math.abs((1 - t.x - t.w) - u.x) < 1e-6 and math.abs(t.y - u.y) < 1e-6 then map[i] = j end
    end
  end
  for id, tile in pairs(s.assign) do s.assign[id] = map[tile] or tile end
  s.spec = spec
  Q.save()
  Q.refresh(key)
  return "ok"
end

-- Put the focused window in tile n ("main" = the biggest tile, "empty" = the
-- first empty one), swapping with the window already there.
function Q.move(key, n)
  local s = Q.state.workspaces[key]
  if not s or not s.spec or LAYOUTS[s.spec] then return "not a Quilt workspace" end
  local id = active_in(key)
  if not id then return "no focused tiled window" end
  if s.spec == "smart" then
    local order = s.order
    for i, o in ipairs(order) do if o == id then table.remove(order, i) break end end
    table.insert(order, math.max(1, math.min(n == "main" and 1 or tonumber(n) or 1, #order + 1)), id)
    Q.save()
    Q.refresh(key)
    return "ok"
  end
  local tiles, fill = tiles_for({ x = 0, y = 0, w = 1, h = 1 }, Q.parse(s.spec))
  local target
  if n == "main" then
    target = fill[1]
  elseif n == "empty" then
    local used = {}
    for _, t in pairs(s.assign) do used[t] = true end
    for _, i in ipairs(fill) do if not used[i] then target = i break end end
    if not target then return "no empty tile" end
  else
    target = tonumber(n)
  end
  if not target or target < 1 or target > #tiles then return "no such tile" end
  return Q.swap(key, s.assign[id] or 0, target, id)
end

-- Swap the windows in tiles a and b (either may be empty).
function Q.swap(key, a, b, id_in_a)
  local s = Q.state.workspaces[key]
  if not s or not Q.parse(s.spec or "") then return "not a grid layout" end
  a, b = tonumber(a), tonumber(b)
  for other, tile in pairs(s.assign) do
    if tile == a and other ~= id_in_a then s.assign[other] = b
    -- With no tile of its own to trade, the window in b looks for a new one.
    elseif tile == b then s.assign[other] = (a and a >= 1) and a or nil end
  end
  if id_in_a then s.assign[id_in_a] = b end
  Q.save()
  Q.refresh(key)
  return "ok"
end

-- The next window that opens on this workspace goes to tile n.
function Q.target(key, n)
  local s = Q.state.workspaces[key]
  if not s or not Q.parse(s.spec or "") then return "not a grid layout" end
  s.pending, s.pending_at = tonumber(n), os.time()
  return "ok"
end

-- The specs from a list that Quilt can use, one per line, so cycling skips a
-- broken preset instead of stopping at it.
function Q.usable(...)
  local out = {}
  for _, spec in ipairs({ ... }) do
    if spec == "smart" or LAYOUTS[spec] or Q.parse(spec) then out[#out + 1] = spec end
  end
  return table.concat(out, "\n")
end

function Q.status(key)
  local s = Q.state.workspaces[key]
  return json({ workspace = key, spec = s and s.spec or nil, pending = s and s.pending or nil })
end

-- The tile area of a workspace, for the editor on a workspace with no windows.
function Q.area(key)
  local area = area_for(key, Q.state.workspaces[key])
  return area and json(area) or "{}"
end

------------------------------------------------------------------------- load

function Q.load()
  os.execute("mkdir -p '" .. Q.state_dir .. "' '" .. Q.runtime_dir .. "'")
  load_state()
  -- Hyprland keeps the first layout registered under a name until the next
  -- config reload, so register a pass-through once and point it at whatever
  -- engine code was loaded last.
  Q.recalculate = function(ctx)
    local ok, err = pcall(recalculate, ctx)
    if not ok then
      Q.last_error = tostring(err)
      for i, t in ipairs(ctx.targets) do t:place(ctx:column(i, #ctx.targets)) end
    end
  end
  if not Q.registered then
    hl.layout.register("quilt", { recalculate = function(ctx) return quilt.recalculate(ctx) end })
    Q.registered = true
  end

  if Q.hooks then for _, h in ipairs(Q.hooks) do pcall(function() h:remove() end) end end
  Q.hooks = {
    hl.on("window.close", function(w)
      if not w then return end
      local id = tostring(w.stable_id)
      for key, s in pairs(Q.state.workspaces) do
        if forget(s, id) then settle(key, id) end
      end
      Q.dirty = true
    end),
    hl.on("window.move_to_workspace", function(w)
      if not w or not w.workspace then return end
      local id, here = tostring(w.stable_id), ws_key(w.workspace)
      for key, s in pairs(Q.state.workspaces) do
        if key ~= here and forget(s, id) then settle(key, id) end
      end
      Q.dirty = true
    end),
    -- Hyprland has no event for a window starting to float; this one fires
    -- then (and often otherwise, so it only looks things up).
    hl.on("window.update_rules", function(w)
      if not w or not w.floating or not w.workspace then return end
      local key, id = ws_key(w.workspace), tostring(w.stable_id)
      local s = Q.state.workspaces[key]
      if s and forget(s, id) then
        Q.dirty = true
        settle(key, id)
      end
    end),
  }

  for key in pairs(Q.state.workspaces) do apply_rule(key) end
  Q.save()
  for key in pairs(Q.state.workspaces) do Q.refresh(key) end
  Q.loaded = true
  return "ok"
end
