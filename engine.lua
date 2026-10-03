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

-- How long a tile picked from a drop area waits for its app, and an app
-- Quilt launched waits to be moved to its workspace, in seconds.
local PENDING_SECONDS = 60

-- Smart specs by window count, per monitor shape. Past the end of a list the
-- layout becomes an even grid.
local SMART = {
  standard = { "12", "6|6", "6|6:2", "6:2|6:2", "4|4:2|4:2", "4:2|4:2|4:2" },
  ultrawide = { "2|8|2", "6|6", "3|6|3", "3|6|3:2", "3:2|6|3:2", "4:2|4:2|4:2" },
  portrait = { "12", "12:2", "12:3", "6:2|6:2", "6:2|6:3", "6:3|6:3" },
}

local LAYOUTS = { dwindle = true, scrolling = true, master = true, monocle = true }

-- Settings from shell.json, handed over by the script (Lua can't read JSON):
-- your own Smart layouts per monitor shape, and default layouts per monitor.
Q.config = Q.config or { smart = {}, monitors = {}, overflow = "tabs" }

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
  -- Every entry has these, Off ones too: the hooks look through them all.
  -- (Quilt 0.1.2-0.1.4 left them out of Off entries.)
  for _, s in pairs(Q.state.workspaces) do
    s.assign, s.order = s.assign or {}, s.order or {}
  end
  -- Window ids start over with a new Hyprland session, so remembered tiles
  -- from the last one mean nothing.
  local session = os.getenv("HYPRLAND_INSTANCE_SIGNATURE") or ""
  if Q.state.session ~= session then
    for _, s in pairs(Q.state.workspaces) do s.assign, s.order, s.pending, s.tabbed, s.made_group = {}, {}, nil, nil, nil end
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

-- Yours where you set one for this many windows, else the built-in one.
local function smart_spec(n, monitor)
  local shape = monitor_shape(monitor)
  local mine = Q.config.smart[shape]
  local spec = type(mine) == "table" and mine[math.max(n, 1)]
  if type(spec) == "string" and Q.parse(spec) then return spec end
  return SMART[shape][math.max(n, 1)] or grid_spec(n)
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
    out[i] = { index = i, filled = filled[i] ~= nil, app = filled[i] or "", home = (s.homes or {})[i] or "",
      selected = s.pending == i and not filled[i], rect = window_rect(t, area, s) }
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

-- Hyprland swaps two windows (Super+Shift+arrows) by trading their places in
-- the list it hands the layout; the layout hears of it no other way. The two
-- windows, if `ids` is `before` with exactly one pair traded.
local function traded(before, ids)
  if not before or #before ~= #ids or #ids < 2 then return nil end
  local diff = {}
  for i = 1, #ids do
    if before[i] ~= ids[i] then
      diff[#diff + 1] = i
      if #diff > 2 then return nil end
    end
  end
  local a, b = diff[1], diff[2]
  if b and before[a] == ids[b] and before[b] == ids[a] then return before[a], before[b] end
end

local function app_of(window) return window and (window.class or ""):lower() or "" end

-- How long after a window is lifted (floated) a return to the layout still
-- counts as a drop, in seconds.
local DROP_SECONDS = 20

-- A Super+drag floats the window while it moves and hands it back to the
-- layout when it's dropped, as if it were new. If it was lifted from this
-- workspace moments ago and the pointer is on it, it was dropped: the tile
-- under the pointer (and where it was lifted from) are returned.
local function dropped_on(id, w, key, tiles)
  local lift = Q.lifted and Q.lifted[id]
  if not lift then return nil end
  Q.lifted[id] = nil
  if lift.key ~= key or os.time() - lift.at > DROP_SECONDS then return nil end
  local ok, c = pcall(hl.get_cursor_pos)
  local at, size = w.at, w.size
  if not ok or not c or not at or not size then return nil end
  local wx, wy, ww, wh = at.x or at[1], at.y or at[2], size.x or size[1], size.y or size[2]
  if not (wx and wy and ww and wh) or c.x < wx or c.x > wx + ww or c.y < wy or c.y > wy + wh then return nil end
  for i, b in ipairs(tiles) do
    if c.x >= b.x and c.x < b.x + b.w and c.y >= b.y and c.y < b.y + b.h then return i, lift end
  end
end

local function position(list, value)
  for i, v in ipairs(list) do if v == value then return i end end
end

------------------------------------------------------------------------- tabs

-- Hyprland hands a group of windows to the layout as one window: its first
-- member, whichever tab shows. The other members have no tile of their own.
local function group_members(w)
  if not w then return nil, nil end
  local ok, g = pcall(function() return w.group end)
  if not ok or not g then return nil, nil end
  local okm, members = pcall(function() return g.members end)
  return g, okm and type(members) == "table" and members or {}
end

-- Tabs leave in the order they came: each gets the next number.
local function next_tab(s)
  local n = 0
  for _, k in pairs(s.tabbed) do if k > n then n = k end end
  return n + 1
end

local function window_by_id(key, id)
  local ok, windows = pcall(hl.get_workspace_windows, key)
  for _, w in ipairs(ok and windows or {}) do
    if tostring(w.stable_id) == id then return w end
  end
end

-- Tile tabs: windows beyond the layout's tiles join the last tile's window as
-- tabs instead of squeezing in beside it, and leave again (in the order they
-- came) when a tile frees up. Only windows Quilt tabbed (s.tabbed) and groups
-- it made (s.made_group) are ever taken apart; your own groups are left alone.
local function tidy_tabs(key, overflow_ids, last_owner, free)
  local s = Q.state.workspaces[key]
  if not s or not Q.parse(s.spec or "") or s.spec == "smart" then return end
  s.tabbed, s.made_group = s.tabbed or {}, s.made_group or {}

  -- Out of their tabs first, one per free tile.
  if free > 0 then
    local waiting = {}
    for id, n in pairs(s.tabbed) do waiting[#waiting + 1] = { id = id, n = n } end
    table.sort(waiting, function(a, b) return a.n < b.n end)
    for _, item in ipairs(waiting) do
      if free == 0 then break end
      local w = window_by_id(key, item.id)
      local g, members = group_members(w)
      if g then
        -- If this tab holds the group's tile, another member takes it over.
        local tile = s.assign[item.id]
        if tile then
          for _, m in ipairs(members) do
            local other = tostring(m.stable_id)
            if other ~= item.id then s.assign[other], s.assign[item.id] = tile, nil break end
          end
        end
        if pcall(function() g:remove(w) end) then free = free - 1 end
      end
      s.tabbed[item.id] = nil
    end
  end

  -- Then extra windows into the last tile's group.
  local owner = last_owner and window_by_id(key, last_owner)
  -- An extra that is a whole group (after the layout shrank): the tile's
  -- own window joins that group instead, as its newest tab.
  if owner and not group_members(owner) then
    for _, id in ipairs(overflow_ids) do
      local g = group_members(window_by_id(key, id))
      if g and pcall(function() g:add(owner) end) then
        s.tabbed[last_owner] = next_tab(s)
        overflow_ids, owner = {}, nil
        break
      end
    end
  end
  if owner and #overflow_ids > 0 then
    local g = group_members(owner)
    if not g then
      hl.dispatch(hl.dsp.group.toggle({ window = "address:" .. owner.address }))
      owner = window_by_id(key, last_owner)
      g = group_members(owner)
      if g then s.made_group[last_owner] = true end
    end
    for _, id in ipairs(overflow_ids) do
      local w = window_by_id(key, id)
      -- Already a tab (a pass can come again before the group shows).
      if w and group_members(w) then w = nil end
      if g and w and pcall(function() g:add(w) end) then s.tabbed[id] = next_tab(s) end
    end
  end

  -- A group Quilt made or tabbed into, down to one window, needs no tab
  -- bar. Its last window can be any of them: the one it started from may be
  -- gone.
  local ok, windows = pcall(hl.get_workspace_windows, key)
  for _, w in ipairs(ok and windows or {}) do
    local id = tostring(w.stable_id)
    if s.made_group[id] or s.tabbed[id] then
      local g, members = group_members(w)
      if g and #members <= 1 then hl.dispatch(hl.dsp.group.toggle({ window = "address:" .. w.address })) end
      if not g or #members <= 1 then s.made_group[id], s.tabbed[id] = nil, nil end
    end
  end
  for id in pairs(s.made_group) do
    if not window_by_id(key, id) then s.made_group[id] = nil end
  end
  for id in pairs(s.tabbed) do
    if not window_by_id(key, id) then s.tabbed[id] = nil end
  end
  Q.save()
end

-- Group changes during a layout pass would start another one, so they wait
-- for the pass to end.
local function schedule_tabs(key, overflow_ids, last_owner, free)
  Q.busy = Q.busy or {}
  if Q.busy[key] then return end
  Q.busy[key] = true
  hl.timer(function()
    Q.busy[key] = nil
    local ok, err = pcall(tidy_tabs, key, overflow_ids, last_owner, free)
    if not ok then Q.last_error = tostring(err) end
  end, { timeout = 30, type = "oneshot" })
end

-- Let go of every tab Quilt made on a workspace (leaving Quilt's grids).
local function release_tabs(key, s)
  if not s or not (s.tabbed or s.made_group) then return end
  for id in pairs(s.tabbed or {}) do
    local w = window_by_id(key, id)
    local g = group_members(w)
    if g then pcall(function() g:remove(w) end) end
  end
  for head in pairs(s.made_group or {}) do
    local w = window_by_id(key, head)
    local g, members = group_members(w)
    if g and #members <= 1 then hl.dispatch(hl.dsp.group.toggle({ window = "address:" .. w.address })) end
  end
  s.tabbed, s.made_group = nil, nil
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
  local present, targets, ids, apps = {}, {}, {}, {}
  for _, t in ipairs(ctx.targets) do
    if t.window then
      local id = tostring(t.window.stable_id)
      present[id], targets[id], apps[id] = true, t, app_of(t.window)
      ids[#ids + 1] = id
    end
  end
  local alive = tiled_ids(key)
  for id in pairs(present) do alive[id] = true end
  -- A group reaches the layout as whichever tab showed last. Its tile is the
  -- one the member handed over last pass had (a newer member may still hold
  -- its own old tile); the members behind it have no tile of their own (one
  -- kept would stay empty for good).
  local inside, group_size, before = {}, {}, {}
  for _, id in ipairs((Q.seen or {})[key] or {}) do before[id] = true end
  for _, t in ipairs(ctx.targets) do
    local _, members = group_members(t.window)
    if members then
      local here = tostring(t.window.stable_id)
      local tile
      for _, m in ipairs(members) do
        local id = tostring(m.stable_id)
        group_size[id] = #members
        if id ~= here and before[id] and s.assign[id] then tile = s.assign[id] end
      end
      if not tile and not s.assign[here] then
        for _, m in ipairs(members) do
          local id = tostring(m.stable_id)
          if id ~= here and s.assign[id] then tile = s.assign[id] break end
        end
      end
      if tile and s.assign[here] ~= tile then s.assign[here], Q.dirty = tile, true end
      for _, m in ipairs(members) do
        local id = tostring(m.stable_id)
        if id ~= here then s.assign[id], inside[id], alive[id] = nil, true, nil end
      end
    end
  end

  Q.seen = Q.seen or {}
  local x, y = traded(Q.seen[key], ids)
  Q.seen[key] = ids

  local placed = {}
  if smart then
    -- Smart: windows keep their order; the order fills the tiles.
    if x then
      for i, id in ipairs(s.order) do
        if id == x then s.order[i] = y elseif id == y then s.order[i] = x end
      end
      Q.dirty = true
    end
    local order, known = {}, {}
    for _, id in ipairs(s.order) do
      if alive[id] and not known[id] then order[#order + 1], known[id] = id, true end
    end
    for _, t in ipairs(ctx.targets) do
      local id = t.window and tostring(t.window.stable_id)
      if id and not known[id] then
        order[#order + 1], known[id] = id, true
        -- Dropped: back to where it was lifted from, then trade places with
        -- the window in the tile under the pointer.
        local tile, lift = dropped_on(id, t.window, key, tiles)
        if tile and lift.slot then
          table.remove(order)
          table.insert(order, math.min(lift.slot, #order + 1), id)
          local here, there = position(order, id), position(fill, tile)
          if there and order[there] then order[here], order[there] = order[there], id end
        end
      end
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
    local assign, used, owner = s.assign, {}, {}
    if x then assign[x], assign[y], Q.dirty = assign[y], assign[x], true end
    for id, tile in pairs(assign) do
      if not alive[id] or tile < 1 or tile > #tiles then assign[id], Q.dirty = nil, true else used[tile], owner[tile] = true, id end
    end
    local homes = s.homes or {}
    local overflow = {}

    -- A new window's place: the tile picked from a drop area, then its app's
    -- home, then the first free tile, leaving other apps' empty homes free
    -- for as long as there's another choice.
    local function home_for(app)
      if app == "" then return nil end
      for _, i in ipairs(fill) do
        if homes[i] == app and not used[i] then return i end
      end
      -- Its home holds another app: that one moves to a free tile no app
      -- calls home, or joins the overflow if there is none.
      for _, i in ipairs(fill) do
        local stranger = owner[i]
        if homes[i] == app and stranger and apps[stranger] and apps[stranger] ~= app then
          owner[i], assign[stranger] = nil, nil
          for _, j in ipairs(fill) do
            if not used[j] and not homes[j] then
              assign[stranger], used[j], owner[j] = j, true, stranger
              return i
            end
          end
          overflow[#overflow + 1] = targets[stranger]
          return i
        end
      end
    end
    -- A tile picked from a drop area holds for the app launched from it, not
    -- for whatever opens much later.
    if s.pending and s.pending_at and os.time() - s.pending_at > PENDING_SECONDS then s.pending, s.pending_at, s.pending_nav = nil, nil, nil end
    for _, t in ipairs(ctx.targets) do
      local id = t.window and tostring(t.window.stable_id)
      if id and not assign[id] then
        local want = s.pending
        if want and (used[want] or want > #tiles) then want = nil end
        -- Dropped on a tile: it goes there, and that tile's window to the
        -- tile it was lifted from (or the overflow if that's gone).
        local drop, lift = dropped_on(id, t.window, key, tiles)
        if drop then
          local other = owner[drop]
          if other and other ~= id then
            local back = lift.tile and lift.tile <= #tiles and not used[lift.tile] and lift.tile or nil
            assign[other] = back
            if back then
              used[back], owner[back] = true, other
            elseif targets[other] then
              overflow[#overflow + 1] = targets[other]
            end
          end
          want, used[drop] = drop, false
          s.pending, s.pending_at, s.pending_nav = nil, nil, nil
        end
        want = want or home_for(apps[id])
        if not want then
          for _, i in ipairs(fill) do if not used[i] and not homes[i] then want = i break end end
        end
        if not want then
          for _, i in ipairs(fill) do if not used[i] then want = i break end end
        end
        s.pending, s.pending_at, s.pending_nav = nil, nil, nil
        if want then
          assign[id], used[want], owner[want], Q.dirty = want, true, id, true
        else
          overflow[#overflow + 1] = t
        end
      end
    end
    for id, tile in pairs(assign) do
      if targets[id] then
        placed[tile] = placed[tile] or {}
        table.insert(placed[tile], targets[id])
      end
    end
    -- More windows than tiles: the extras share the last tile to fill, and
    -- right after this pass become tabs there (unless overflow is "stack").
    local last = fill[#fill]
    for _, t in ipairs(overflow) do
      placed[last] = placed[last] or {}
      table.insert(placed[last], t)
    end
    if Q.config.overflow ~= "stack" then
      local free = 0
      for i = 1, #tiles do if not used[i] then free = free + 1 end end
      local lonely = false
      for head in pairs(s.made_group or {}) do
        if (group_size[head] or 0) <= 1 then lonely = true end
      end
      for id in pairs(s.tabbed or {}) do
        if group_size[id] == 1 then lonely = true end
      end
      if #overflow > 0 or (free > 0 and next(s.tabbed or {})) or lonely then
        local ids = {}
        for _, t in ipairs(overflow) do ids[#ids + 1] = tostring(t.window.stable_id) end
        schedule_tabs(key, ids, owner[last], free)
      end
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

  local behind = 0
  for _ in pairs(inside) do behind = behind + 1 end
  write_tiles(key, s, smart and spec or s.spec, ctx.area, tiles, filled, #ctx.targets + behind)
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

local function apply_rule(key)
  local s = Q.state.workspaces[key]
  if s and s.off then return set_rule(key, omarchy_layout(key)) end
  if not s or not s.spec then return set_rule(key, nil) end
  set_rule(key, LAYOUTS[s.spec] and s.spec or "lua:quilt", s.gaps_in, s.gaps_out)
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
-- here. `gone` is the window leaving, which may still be listed; so may
-- others closing at the same moment, hence the short wait.
local function settle(key, gone)
  hl.timer(function()
    local ok, err = pcall(function()
      local left = tiled_ids(key)
      left[gone] = nil
      if next(left) == nil then write_empty(key) end
    end)
    if not ok then Q.last_error = tostring(err) end
  end, { timeout = 150, type = "oneshot" })
end

local function forget(s, id)
  local had = s.assign[id] ~= nil
  s.assign[id] = nil
  if s.tabbed then s.tabbed[id] = nil end
  if s.made_group then s.made_group[id] = nil end
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

-- App homes: { [tile] = app }, apps as lowercase window classes, only for
-- tiles the layout has.
local function clean_homes(homes, layout)
  if type(homes) ~= "table" or not layout then return nil end
  local out, any = {}, false
  for key, app in pairs(homes) do
    local tile = tonumber(key)
    if tile and layout.tiles[tile] and type(app) == "string" and app ~= "" then out[tile], any = app:lower(), true end
  end
  return any and out or nil
end

-- Homes follow their tiles to a new layout, the way windows do.
local function remap_homes(homes, old, new)
  if not homes or not old or not new then return nil end
  local out, taken, any = {}, {}, false
  local tiles = {}
  for tile in pairs(homes) do tiles[#tiles + 1] = tile end
  table.sort(tiles)
  for _, tile in ipairs(tiles) do
    local from = old.tiles[tile]
    local best, best_area = nil, 0
    for j, t in ipairs(new.tiles) do
      local a = from and overlap(from, t) or 0
      if not taken[j] and a > best_area + 1e-9 then best, best_area = j, a end
    end
    if best then out[best], taken[best], any = homes[tile], true, true end
  end
  return any and out or nil
end

-- Move windows already on the workspace into their apps' homes, trading
-- places with whatever is there.
local function arrange(key, s)
  local homes = s.homes
  if not homes or not Q.parse(s.spec or "") then return end
  local apps, owner, ids = {}, {}, {}
  local ok, windows = pcall(hl.get_workspace_windows, key)
  for _, w in ipairs(ok and windows or {}) do
    if not w.floating then
      local id = tostring(w.stable_id)
      apps[id] = app_of(w)
      ids[#ids + 1] = id
    end
  end
  table.sort(ids)
  for id, tile in pairs(s.assign) do if apps[id] then owner[tile] = id end end
  local tiles = {}
  for tile in pairs(homes) do tiles[#tiles + 1] = tile end
  table.sort(tiles)
  for _, tile in ipairs(tiles) do
    local app, here = homes[tile], owner[tile]
    if not (here and apps[here] == app) then
      local pick
      for _, id in ipairs(ids) do
        local at = s.assign[id]
        if apps[id] == app and not (at and homes[at] == app) then pick = id break end
      end
      if pick then
        local from = s.assign[pick]
        if here then s.assign[here] = from end
        if from then owner[from] = here end
        s.assign[pick], owner[tile] = tile, pick
      end
    end
  end
end

-- spec: a column or drawn spec, "smart", a built-in Hyprland layout, or "off".
-- homes: { [tile] = app } for the new layout, "keep" to carry the current
-- ones over (the editor reshaping a layout), or nil for none.
function Q.set(key, spec, gaps_in, gaps_out, homes)
  local s = ws_state(key)
  s.from_default, s.off = nil, nil
  if spec == "off" then
    release_tabs(key, s)
    -- Remembered as your choice, so a monitor default doesn't bring Quilt
    -- back here.
    Q.state.workspaces[key] = { off = true, assign = {}, order = {} }
    -- Disabling Quilt's rule alone doesn't switch the workspace back; a rule
    -- naming its old layout does.
    set_rule(key, omarchy_layout(key))
    os.remove(tiles_file(key))
    Q.save()
    return "ok"
  end
  local new = Q.parse(spec)
  if not (spec == "smart" or LAYOUTS[spec] or new) then return "bad spec" end
  if not new or spec == "smart" then release_tabs(key, s) end
  local old = Q.parse(s.spec or "")
  if homes == "keep" then s.homes = remap_homes(s.homes, old, new) else s.homes = clean_homes(homes, new) end
  remap(s, old, new)
  s.spec = new and spec:gsub("%s", "") or spec
  s.gaps_in, s.gaps_out = tonumber(gaps_in), tonumber(gaps_out)
  arrange(key, s)
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
  if s.homes then
    local homes = {}
    for tile, app in pairs(s.homes) do homes[map[tile] or tile] = app end
    s.homes = homes
  end
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
  s.pending, s.pending_at, s.pending_nav = tonumber(n), os.time(), nil
  return "ok"
end

-- Quilt is about to launch an app for this workspace. Apps start through
-- uwsm, so Hyprland can't tell which launch a window came from; instead its
-- first window is moved to the workspace when it opens.
function Q.expect(key, app)
  Q.expected = Q.expected or {}
  table.insert(Q.expected, { key = key, app = app:lower(), at = os.time() })
  return "ok"
end

local function claim(w)
  if not Q.expected or not w then return end
  local app = app_of(w)
  for i = #Q.expected, 1, -1 do
    if os.time() - Q.expected[i].at > PENDING_SECONDS then table.remove(Q.expected, i) end
  end
  for i, e in ipairs(Q.expected) do
    if e.app == app then
      table.remove(Q.expected, i)
      if ws_key(w.workspace) ~= e.key then
        hl.dispatch(hl.dsp.window.move({ workspace = e.key, follow = false, window = "address:" .. w.address }))
      end
      return
    end
  end
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

-- Make tile n the home of an app: by default the focused window's app, and
-- the tile that window is in. "none" clears the tile's home. The app's
-- window moves there if it isn't in one of its homes already.
function Q.home(key, n, app)
  local s = Q.state.workspaces[key]
  local layout = s and Q.parse(s.spec or "")
  if not layout or s.spec == "smart" then return "App homes work on Quilt's grid layouts" end
  local id, w = active_in(key)
  local tile = tonumber(n) or (id and s.assign[id])
  if not tile then return "no focused tiled window" end
  if not layout.tiles[tile] then return "no such tile" end
  if app == nil then
    if not w then return "no focused tiled window" end
    app = app_of(w)
  end
  s.homes = s.homes or {}
  s.homes[tile] = (app ~= "none" and app ~= "") and app:lower() or nil
  if not next(s.homes) then s.homes = nil end
  arrange(key, s)
  Q.save()
  Q.refresh(key)
  return "ok"
end

-- Replace all of a workspace's homes at once (the editor's Remember apps).
function Q.homes(key, homes)
  local s = Q.state.workspaces[key]
  local layout = s and Q.parse(s.spec or "")
  if not layout or s.spec == "smart" then return "App homes work on Quilt's grid layouts" end
  s.homes = clean_homes(homes, layout)
  arrange(key, s)
  Q.save()
  Q.refresh(key)
  return "ok"
end

function Q.status(key)
  local s = Q.state.workspaces[key]
  local homes = {}
  for tile, app in pairs(s and s.homes or {}) do homes[tostring(tile)] = app end
  return json({ workspace = key, spec = s and s.spec or nil, pending = s and s.pending or nil, homes = homes })
end

-- The tile area of a workspace, for the editor on a workspace with no windows.
function Q.area(key)
  local area = area_for(key, Q.state.workspaces[key])
  return area and json(area) or "{}"
end

------------------------------------------------------------------- navigation

-- Omarchy's Super+arrow bindings, which Quilt takes over (and gives back).
local FOCUS_KEYS = {
  { "l", "SUPER + LEFT", "Focus on left window" },
  { "r", "SUPER + RIGHT", "Focus on right window" },
  { "u", "SUPER + UP", "Focus on above window" },
  { "d", "SUPER + DOWN", "Focus on below window" },
}

-- The nearest tile from tile `from` in a direction, overlapping it across
-- the other axis; on a tie, the one sharing the most of its edge.
local function neighbour(tiles, from, dir)
  local f, best, best_score = tiles[from], nil, nil
  for i, t in ipairs(tiles) do
    if i ~= from then
      local gap, shared
      if dir == "l" or dir == "r" then
        gap = dir == "r" and t.x - (f.x + f.w) or f.x - (t.x + t.w)
        shared = math.min(f.y + f.h, t.y + t.h) - math.max(f.y, t.y)
      else
        gap = dir == "d" and t.y - (f.y + f.h) or f.y - (t.y + t.h)
        shared = math.min(f.x + f.w, t.x + t.w) - math.max(f.x, t.x)
      end
      if gap > -1e-6 and shared > 1e-6 then
        local score = gap * 1000 - shared
        if not best or score < best_score - 1e-9 then best, best_score = i, score end
      end
    end
  end
  return best
end

-- Super+arrows on a Quilt grid workspace: tile to tile, empty tiles too.
-- A tile with a window focuses it; an empty one is selected, and the next
-- app opened on the workspace goes there. Anywhere else (other layouts, past
-- the last tile) it's Hyprland's own focus move.
function Q.navigate(dir)
  local fallback = function() hl.dispatch(hl.dsp.focus({ direction = dir })) end
  local monitor = hl.get_active_monitor()
  local key = monitor and ws_key(monitor.active_workspace)
  local s = key and Q.state.workspaces[key]
  local layout = s and s.spec ~= "smart" and Q.parse(s.spec or "")
  if not layout then return fallback() end

  local w = hl.get_active_window()
  local from
  if s.pending and s.pending_nav then
    from = s.pending
  elseif w and w.workspace and ws_key(w.workspace) == key then
    -- A floating window or an extra one beside a tile has no tile to move
    -- from.
    from = not w.floating and s.assign[tostring(w.stable_id)] or nil
    if not from then return fallback() end
  end
  local to
  if from then
    to = neighbour(layout.tiles, from, dir)
  else
    -- Nothing focused here yet: start at the main tile.
    local _, fill = tiles_for({ x = 0, y = 0, w = 1, h = 1 }, layout)
    to = fill[1]
  end
  if not to then
    if s.pending_nav then
      s.pending, s.pending_at, s.pending_nav = nil, nil, nil
      Q.refresh(key)
    end
    return fallback()
  end

  local owner
  for id, tile in pairs(s.assign) do
    if tile == to then owner = window_by_id(key, id) end
  end
  if owner then
    s.pending, s.pending_at, s.pending_nav = nil, nil, nil
    hl.dispatch(hl.dsp.focus({ window = "address:" .. owner.address }))
  else
    -- Remembers the window that keeps the focus meanwhile: focus coming back
    -- to it (say, when a launcher closes) leaves the selection be.
    s.pending, s.pending_at, s.pending_nav = to, nil, w and tostring(w.stable_id) or true
  end
  Q.save()
  Q.refresh(key)
end

-- Take Super+arrows over (on), or give Omarchy's bindings back (off) if
-- Quilt took them. The script only asks for this when they are Omarchy's.
local function set_navigation(on)
  if on == (Q.nav_on == true) then return end
  for _, k in ipairs(FOCUS_KEYS) do pcall(hl.unbind, k[2]) end
  for _, k in ipairs(FOCUS_KEYS) do
    local dir, chord, description = k[1], k[2], k[3]
    if on then
      hl.bind(chord, function()
        local ok, err = pcall(function() return quilt.navigate(dir) end)
        if not ok then
          quilt.last_error = tostring(err)
          hl.dispatch(hl.dsp.focus({ direction = dir }))
        end
      end, { description = description })
    else
      hl.bind(chord, hl.dsp.focus({ direction = dir }), { description = description })
    end
  end
  Q.nav_on = on
end

------------------------------------------------------------- monitor defaults

local function same_homes(a, b)
  a, b = a or {}, b or {}
  for tile, app in pairs(a) do if b[tile] ~= app then return false end end
  for tile, app in pairs(b) do if a[tile] ~= app then return false end end
  return true
end

-- A workspace on a monitor with a default layout uses it until you pick a
-- layout (or Off) there yourself; `from_default` marks the ones following it.
local function follow_default(key, ws)
  if not key or key:match("^special:") then return end
  local s = Q.state.workspaces[key]
  if s and not s.from_default then return end
  local monitor = ws and ws.monitor
  local d = monitor and Q.config.monitors[monitor.name]
  if not d then
    -- Its default is gone: back to Omarchy's layout.
    if s then
      Q.set(key, "off")
      Q.state.workspaces[key] = nil
      Q.save()
    end
    return
  end
  if s and s.spec == d.spec and s.gaps_in == d.gaps_in and s.gaps_out == d.gaps_out and same_homes(s.homes, d.homes) then return end
  if Q.set(key, d.spec, d.gaps_in, d.gaps_out, d.homes) == "ok" then
    Q.state.workspaces[key].from_default = true
    Q.save()
  end
end

-- Take your settings: { smart = { [shape] = { specs by window count } },
-- monitors = { [name] = { spec, gaps_in, gaps_out, homes } } }.
function Q.configure(config)
  config = type(config) == "table" and config or {}
  local smart, monitors = {}, {}
  for shape, list in pairs(type(config.smart) == "table" and config.smart or {}) do
    if SMART[shape] and type(list) == "table" then smart[shape] = list end
  end
  for name, d in pairs(type(config.monitors) == "table" and config.monitors or {}) do
    local spec = type(d) == "table" and type(d.spec) == "string" and d.spec:gsub("%s", "")
    if spec and (spec == "smart" or LAYOUTS[spec] or Q.parse(spec)) then
      monitors[name] = { spec = spec, gaps_in = tonumber(d.gaps_in), gaps_out = tonumber(d.gaps_out), homes = clean_homes(d.homes, Q.parse(spec)) }
    end
  end
  Q.config = { smart = smart, monitors = monitors, overflow = config.overflow == "stack" and "stack" or "tabs" }
  set_navigation(config.navigation == true)
  local ok, list = pcall(hl.get_workspaces)
  for _, ws in ipairs(ok and list or {}) do follow_default(ws_key(ws), ws) end
  -- Smart workspaces pick up your layouts.
  for key, s in pairs(Q.state.workspaces) do
    if s.spec == "smart" then Q.refresh(key) end
  end
  return "ok"
end

------------------------------------------------------------------------- load

function Q.load()
  Q.last_error = nil
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
    hl.on("window.open", function(w) claim(w) end),
    -- Focus moving to another window with a tile ends an arrow-key selection
    -- (a new window has no tile yet, so its arrival doesn't).
    hl.on("window.active", function(w)
      if not w or not w.workspace then return end
      local key, id = ws_key(w.workspace), tostring(w.stable_id)
      local s = Q.state.workspaces[key]
      if s and s.pending_nav and s.pending_nav ~= id and s.assign[id] then
        s.pending, s.pending_at, s.pending_nav = nil, nil, nil
        Q.save()
        Q.refresh(key)
      end
    end),
    hl.on("workspace.created", function(ws) follow_default(ws_key(ws), ws) end),
    -- Hyprland has no event for a window starting to float; this one fires
    -- then (and often otherwise, so it only looks things up).
    hl.on("window.update_rules", function(w)
      if not w or not w.floating or not w.workspace then return end
      local key, id = ws_key(w.workspace), tostring(w.stable_id)
      local s = Q.state.workspaces[key]
      -- Where it was, in case this is a Super+drag that ends in a drop.
      if s and (s.assign[id] or position(s.order, id)) then
        Q.lifted = Q.lifted or {}
        Q.lifted[id] = { key = key, tile = s.assign[id], slot = position(s.order, id), at = os.time() }
      end
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
