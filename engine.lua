-- Quilt: tile layout presets for Hyprland's Lua config (Hyprland 0.55+).
--
-- The bar widget loads this file with `hyprctl eval` when the shell starts
-- and again after every Hyprland config reload, since a reload starts a fresh
-- Lua state. Nothing is written to the user's Hyprland config.
--
-- A preset is a column spec on a 10- or 12-column grid: "4|8", "3|6|3",
-- "8|4:2" (the 4-wide column holds 2 stacked tiles). Tiles are numbered in
-- reading order. Each window keeps its tile; a closed window leaves an empty
-- tile that the next window fills. "smart" picks a spec from the window count
-- and the monitor's shape instead, and never leaves tiles empty.

quilt = quilt or {}
local Q = quilt

local HOME = os.getenv("HOME") or ""
Q.state_dir = (os.getenv("XDG_STATE_HOME") or (HOME .. "/.local/state")) .. "/quilt"
Q.runtime_dir = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/quilt"

-- Smart specs by window count, per monitor shape. Past the end of a list the
-- layout becomes an even grid.
local SMART = {
  standard = { "12", "6|6", "6|6:2", "6:2|6:2", "4|4:2|4:2", "4:2|4:2|4:2" },
  ultrawide = { "2|8|2", "6|6", "3|6|3", "3|6|3:2", "3:2|6|3:2", "4:2|4:2|4:2" },
  portrait = { "12", "12:2", "12:3", "6:2|6:2", "6:2|6:3", "6:3|6:3" },
}

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
  if t == "number" then return (v == math.floor(v)) and string.format("%d", v) or string.format("%.2f", v) end
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

-- Shell-facing summary: which preset each workspace uses.
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

function Q.parse(spec)
  if type(spec) ~= "string" then return nil end
  local cols, total = {}, 0
  for part in spec:gmatch("[^|]+") do
    local span, rows = part:match("^%s*(%d+)%s*:?%s*(%d*)%s*$")
    span, rows = tonumber(span), tonumber(rows) or 1
    if not span or span < 1 or rows < 1 or rows > 8 then return nil end
    cols[#cols + 1] = { span = span, rows = rows }
    total = total + span
  end
  if #cols == 0 or (total ~= 10 and total ~= 12) then return nil end
  return { cols = cols, total = total }
end

local function format_spec(layout)
  local parts = {}
  for _, c in ipairs(layout.cols) do parts[#parts + 1] = c.rows > 1 and (c.span .. ":" .. c.rows) or tostring(c.span) end
  return table.concat(parts, "|")
end

local function grid_spec(n)
  local cols = math.ceil(math.sqrt(n))
  local spans = { [1] = "12", [2] = "6", [3] = "4", [4] = "3" }
  local span = spans[math.min(cols, 4)]
  cols = math.min(cols, 4)
  local parts, left = {}, n
  for c = 1, cols do
    local rows = math.ceil(left / (cols - c + 1))
    parts[#parts + 1] = span .. ":" .. rows
    left = left - rows
  end
  return table.concat(parts, "|")
end

local function monitor_shape(monitor)
  if not monitor then return "standard" end
  local w, h = monitor.width, monitor.height
  if monitor.transform == 1 or monitor.transform == 3 then w, h = h, w end
  if h > w then return "portrait" end
  if w / h >= 2.0 then return "ultrawide" end
  return "standard"
end

local function smart_spec(n, monitor)
  local list = SMART[monitor_shape(monitor)]
  return list[math.max(n, 1)] or grid_spec(n)
end

-- Tiles in reading order, plus the order they fill in: biggest (the main
-- tile) first, then reading order.
local function tiles_for(area, layout)
  local tiles, x = {}, area.x
  for ci, col in ipairs(layout.cols) do
    local w = area.w * col.span / layout.total
    for r = 1, col.rows do
      tiles[#tiles + 1] = { x = x, y = area.y + (r - 1) * area.h / col.rows, w = w, h = area.h / col.rows, col = ci }
    end
    x = x + w
  end
  local order = {}
  for i in ipairs(tiles) do order[i] = i end
  table.sort(order, function(a, b)
    local sa, sb = tiles[a].w * tiles[a].h, tiles[b].w * tiles[b].h
    if math.abs(sa - sb) > 1 then return sa > sb end
    return a < b
  end)
  return tiles, order
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
    out[i] = { index = i, filled = filled[i] and true or false, rect = window_rect(t, area, s) }
  end
  write_file(Q.runtime_dir .. "/" .. key:gsub("[/:]", "_") .. ".json",
    json({ workspace = key, spec = spec, smart = s.spec == "smart", windows = count, tiles = out }) .. "\n")
  hl.dispatch(hl.dsp.event("quilt>>" .. key))
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

  local placed, filled = {}, {}
  if smart then
    -- Smart: windows keep their order; the order fills the tiles.
    local order = {}
    for _, id in ipairs(s.order) do if alive[id] then order[#order + 1] = id end end
    for _, t in ipairs(ctx.targets) do
      local id = t.window and tostring(t.window.stable_id)
      local known = false
      for _, o in ipairs(order) do if o == id then known = true break end end
      if id and not known then order[#order + 1] = id end
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
      if not alive[id] or tile > #tiles then assign[id], Q.dirty = nil, true else used[tile] = true end
    end
    local overflow = {}
    for _, t in ipairs(ctx.targets) do
      local id = t.window and tostring(t.window.stable_id)
      if id and not assign[id] then
        local want = s.pending
        if want and (used[want] or want > #tiles) then want = nil end
        if not want then
          for _, i in ipairs(fill) do if not used[i] then want = i break end end
        end
        s.pending = nil
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

  for i, list in pairs(placed) do
    local b = tiles[i]
    for k, t in ipairs(list) do
      t:place({ x = b.x, y = b.y + (k - 1) * b.h / #list, w = b.w, h = b.h / #list })
    end
    filled[i] = true
  end

  write_tiles(key, s, smart and spec or s.spec, ctx.area, tiles, filled, #ctx.targets)
  if Q.dirty then Q.dirty = false Q.save() end
end

---------------------------------------------------------------------- control

local LAYOUTS = { dwindle = true, scrolling = true, master = true, monocle = true }

local function selector(key) return key end

local function apply_rule(key)
  local s = Q.state.workspaces[key]
  if Q.rules and Q.rules[key] then
    pcall(function() Q.rules[key]:set_enabled(false) end)
    Q.rules[key] = nil
  end
  if not s or not s.spec then return end
  local rule = { workspace = selector(key) }
  rule.layout = LAYOUTS[s.spec] and s.spec or "lua:quilt"
  if s.gaps_in then rule.gaps_in = s.gaps_in end
  if s.gaps_out then rule.gaps_out = s.gaps_out end
  Q.rules = Q.rules or {}
  Q.rules[key] = hl.workspace_rule(rule)
end

-- Make Hyprland lay the workspace out again: a zero-pixel resize of one of
-- its tiled windows does that without moving anything. An empty workspace has
-- nothing to lay out, so its (all empty) tiles are written directly.
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
  local s = Q.state.workspaces[key]
  if not s or not s.spec or LAYOUTS[s.spec] then return end
  local okw, ws = pcall(hl.get_workspace, key)
  local monitor = (okw and ws and ws.monitor) or hl.get_active_monitor()
  if not monitor then return end
  local gaps_out = s.gaps_out and { top = s.gaps_out, right = s.gaps_out, bottom = s.gaps_out, left = s.gaps_out }
    or hl.get_config("general.gaps_out") or {}
  if type(gaps_out) == "number" then gaps_out = { top = gaps_out, right = gaps_out, bottom = gaps_out, left = gaps_out } end
  local r = type(monitor.reserved) == "table" and monitor.reserved or {}
  local scale = monitor.scale or 1
  local area = {
    x = monitor.x + (r.left or 0) + (gaps_out.left or 0),
    y = monitor.y + (r.top or 0) + (gaps_out.top or 0),
    w = monitor.width / scale - (r.left or 0) - (r.right or 0) - (gaps_out.left or 0) - (gaps_out.right or 0),
    h = monitor.height / scale - (r.top or 0) - (r.bottom or 0) - (gaps_out.top or 0) - (gaps_out.bottom or 0),
  }
  local spec = s.spec == "smart" and smart_spec(0, monitor) or s.spec
  local tiles = tiles_for(area, Q.parse(spec) or Q.parse("6|6"))
  write_tiles(key, s, s.spec, area, tiles, {}, 0)
end

local function active_in(key)
  local w = hl.get_active_window()
  if w and not w.floating and ws_key(w.workspace) == key then return tostring(w.stable_id), w end
end

-- spec: a grid spec, "smart", a built-in Hyprland layout, or "off".
function Q.set(key, spec, gaps_in, gaps_out)
  local s = ws_state(key)
  if spec == "off" then
    Q.state.workspaces[key] = nil
    apply_rule(key)
    pcall(hl.workspace_rule, { workspace = selector(key), layout = hl.get_config("general.layout") or "dwindle" })
    os.remove(Q.runtime_dir .. "/" .. key:gsub("[/:]", "_") .. ".json")
    Q.save()
    return "ok"
  end
  if not (spec == "smart" or LAYOUTS[spec] or Q.parse(spec)) then return "bad spec" end
  -- A different number of tiles makes old tile numbers meaningless.
  local old = Q.parse(s.spec or "")
  local new = Q.parse(spec)
  if not (old and new and #tiles_for({ x = 0, y = 0, w = 1, h = 1 }, old) == #tiles_for({ x = 0, y = 0, w = 1, h = 1 }, new)) then
    s.assign = {}
  end
  s.spec = new and format_spec(new) or spec
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
  local layout = s and Q.parse(s.spec or "")
  if not layout or #layout.cols < 2 then return "nothing to resize" end
  local id = active_in(key)
  local tile = id and s.assign[id]
  local col = 1
  if tile then
    local tiles = tiles_for({ x = 0, y = 0, w = 1, h = 1 }, layout)
    col = tiles[tile] and tiles[tile].col or 1
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
  s.spec = format_spec(layout)
  Q.save()
  Q.refresh(key)
  return "ok"
end

-- Flip the layout left to right; windows go with their tiles.
function Q.mirror(key)
  local s = Q.state.workspaces[key]
  local layout = s and Q.parse(s.spec or "")
  if not layout then return "not a grid layout" end
  local old = tiles_for({ x = 0, y = 0, w = 1, h = 1 }, layout)
  local reversed = { cols = {}, total = layout.total }
  for i = #layout.cols, 1, -1 do reversed.cols[#reversed.cols + 1] = layout.cols[i] end
  local new = tiles_for({ x = 0, y = 0, w = 1, h = 1 }, reversed)
  local map = {}
  for i, t in ipairs(old) do
    for j, u in ipairs(new) do
      if math.abs((1 - t.x - t.w) - u.x) < 0.001 and math.abs(t.y - u.y) < 0.001 then map[i] = j end
    end
  end
  for id, tile in pairs(s.assign) do s.assign[id] = map[tile] or tile end
  s.spec = format_spec(reversed)
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
    table.insert(order, math.max(1, math.min(tonumber(n) or 1, #order + 1)), id)
    Q.save()
    Q.refresh(key)
    return "ok"
  end
  local layout = Q.parse(s.spec)
  local tiles, fill = tiles_for({ x = 0, y = 0, w = 1, h = 1 }, layout)
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
  local from = s.assign[id]
  for other, tile in pairs(s.assign) do
    if tile == target and other ~= id then s.assign[other] = from end
  end
  s.assign[id] = target
  Q.save()
  Q.refresh(key)
  return "ok"
end

-- The next window that opens on this workspace goes to tile n.
function Q.target(key, n)
  local s = Q.state.workspaces[key]
  if not s or not Q.parse(s.spec or "") then return "not a grid layout" end
  s.pending = tonumber(n)
  return "ok"
end

function Q.status(key)
  local s = Q.state.workspaces[key]
  return json({ workspace = key, spec = s and s.spec or nil, pending = s and s.pending or nil })
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
      for _, s in pairs(Q.state.workspaces) do
        s.assign[id] = nil
        for i, o in ipairs(s.order) do if o == id then table.remove(s.order, i) break end end
      end
      Q.dirty = true
    end),
    hl.on("window.move_to_workspace", function(w)
      if not w or not w.workspace then return end
      local id, here = tostring(w.stable_id), ws_key(w.workspace)
      for key, s in pairs(Q.state.workspaces) do
        if key ~= here then
          s.assign[id] = nil
          for i, o in ipairs(s.order) do if o == id then table.remove(s.order, i) break end end
        end
      end
      Q.dirty = true
    end),
  }

  for key in pairs(Q.state.workspaces) do apply_rule(key) end
  Q.save()
  for key in pairs(Q.state.workspaces) do Q.refresh(key) end
  Q.loaded = true
  return "ok"
end
