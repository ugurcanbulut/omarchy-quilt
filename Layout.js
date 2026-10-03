.pragma library

// Layout math shared by the popup and the editor; engine.lua does the same
// for Hyprland. A layout is a list of rectangles in grid units on a gw x gh
// grid, numbered by their top-left corner: left to right, then top to bottom.

var EPS = 1e-6

// Keep in sync with MAX_GRID and SMART in engine.lua.
var MAX_GRID = 144

var SMART = {
  standard: ["12", "6|6", "6|6:2", "6:2|6:2", "4|4:2|4:2", "4:2|4:2|4:2"],
  ultrawide: ["2|8|2", "6|6", "3|6|3", "3|6|3:2", "3:2|6|3:2", "4:2|4:2|4:2"],
  portrait: ["12", "12:2", "12:3", "6:2|6:2", "6:2|6:3", "6:3|6:3"]
}

function near(a, b) { return Math.abs(a - b) < 1e-4 }

// An even grid for n windows, as the engine's grid_spec builds it.
function gridSpec(n) {
  var least = Math.min(Math.ceil(Math.sqrt(n)), 4)
  var cols = [1, 2, 3, 4, 6, 12].filter(function(c) { return c >= least && c * 8 >= n })[0] || 12
  var parts = [], left = n
  for (var c = 1; c <= cols; c++) {
    var rows = Math.max(1, Math.min(8, Math.ceil(left / (cols - c + 1))))
    parts.push((12 / cols) + ":" + rows)
    left -= rows
  }
  return parts.join("|")
}

// The layout Smart picks for n windows on a monitor of this shape: from
// `mine` (your own list for the shape, by window count) when it has a usable
// one, else the built-in one.
function smartSpec(shape, n, mine) {
  var own = mine && mine[Math.max(n, 1) - 1]
  if (typeof own === "string" && parse(own)) return own.replace(/\s/g, "")
  var list = SMART[shape] || SMART.standard
  return list[Math.max(n, 1) - 1] || gridSpec(n)
}

function sortRects(rects) {
  return rects.slice().sort(function(a, b) {
    if (Math.abs(a.x - b.x) > EPS) return a.x - b.x
    return a.y - b.y
  })
}

// ":3" -> three equal heights; ":8/4" -> heights on a 10- or 12-row grid.
function parseRows(text) {
  if (!text) return { sizes: [1], total: 1 }
  if (text.indexOf("/") < 0) {
    var n = parseInt(text)
    if (!(n >= 1 && n <= 8)) return null
    var sizes = []
    for (var i = 0; i < n; i++) sizes.push(1)
    return { sizes: sizes, total: n }
  }
  var parts = text.split("/").map(Number)
  if (parts.some(function(p) { return !(p >= 1) })) return null
  var total = parts.reduce(function(a, b) { return a + b }, 0)
  return (total === 10 || total === 12) ? { sizes: parts, total: total } : null
}

// "4|8", "8|4:2", "4:8/4|8" or "@12x12:x,y,w,h;..." -> { gw, gh, rects }.
function parse(spec) {
  if (typeof spec !== "string") return null
  spec = spec.replace(/\s/g, "")
  var m = spec.match(/^@(\d+)x(\d+):(.+)$/)
  if (m) {
    var gw = parseInt(m[1]), gh = parseInt(m[2]), rects = []
    if (gw < 1 || gh < 1 || gw > MAX_GRID || gh > MAX_GRID) return null
    var parts = m[3].split(";").filter(function(part) { return part !== "" })
    for (var i = 0; i < parts.length; i++) {
      if (!/^\d+,\d+,\d+,\d+$/.test(parts[i])) return null
      var p = parts[i].split(",").map(Number)
      var r = { x: p[0], y: p[1], w: p[2], h: p[3] }
      if (r.w < 1 || r.h < 1 || r.x + r.w > gw || r.y + r.h > gh) return null
      // Overlapping tiles would stack windows on top of each other.
      if (rects.some(function(other) { return overlaps(r, other) })) return null
      rects.push(r)
    }
    return rects.length ? { gw: gw, gh: gh, rects: sortRects(rects) } : null
  }

  var cols = [], total = 0, tens = 0, twelves = 0
  var colParts = spec.split("|")
  for (var c = 0; c < colParts.length; c++) {
    var cm = colParts[c].match(/^(\d+)(?::([\d\/]+))?$/)
    if (!cm) return null
    var span = parseInt(cm[1]), rows = parseRows(cm[2] || "")
    if (!(span >= 1) || !rows) return null
    if (rows.total === 10) tens++
    if (rows.total === 12) twelves++
    cols.push({ span: span, rows: rows })
    total += span
  }
  if (!cols.length || (total !== 10 && total !== 12)) return null
  var gridH = (tens && !twelves) ? 10 : 12
  var out = [], x = 0
  cols.forEach(function(col) {
    var y = 0
    col.rows.sizes.forEach(function(size) {
      var h = size / col.rows.total * gridH
      out.push({ x: x, y: y, w: col.span, h: h })
      y += h
    })
    x += col.span
  })
  return { gw: total, gh: gridH, rects: out }
}

function whole(v) { return near(v, Math.round(v)) }

// The same layout on gh rows instead of from rows, or null if an edge would
// fall between rows.
function rescale(from, gh, rects) {
  var f = gh / from
  if (!rects.every(function(r) { return whole(r.y * f) && whole(r.h * f) })) return null
  return rects.map(function(r) { return { x: r.x, y: Math.round(r.y * f), w: r.w, h: Math.round(r.h * f) } })
}

// The shortest spec for a layout: columns when it is one, drawn otherwise.
function format(gw, gh, rects) {
  var sorted = sortRects(rects)
  var columns = columnsSpec(gw, gh, sorted)
  if (columns) return columns
  // Uneven rows are written on 12 or 10 rows.
  var rows = [12, 10]
  for (var i = 0; i < rows.length; i++) {
    var scaled = rows[i] === gh ? null : rescale(gh, rows[i], sorted)
    columns = scaled && columnsSpec(gw, rows[i], scaled)
    if (columns) return columns
  }
  if (gh > 12 && rescale(gh, 12, sorted)) { sorted = rescale(gh, 12, sorted); gh = 12 }
  return "@" + gw + "x" + gh + ":" + sorted.map(function(r) {
    return [r.x, r.y, r.w, r.h].map(function(v) { return Math.round(v) }).join(",")
  }).join(";")
}

// A layout on a grid fine enough that every edge sits on a grid line, for
// the editor: "12:5" has rows 2.4 rows tall on 12 rows, so it gets 60.
function editable(spec) {
  var layout = parse(spec)
  if (!layout || !layout.rects.every(function(r) { return whole(r.x) && whole(r.w) })) return null
  for (var k = 1; k <= 12; k++) {
    var rects = rescale(layout.gh, layout.gh * k, layout.rects)
    if (rects) return { gw: layout.gw, gh: layout.gh * k, rects: rects }
  }
  return null
}

// One way of writing each layout, so two specs can be compared.
function normalize(spec) {
  var layout = editable(spec)
  return layout ? format(layout.gw, layout.gh, layout.rects) : spec
}

function columnsSpec(gw, gh, sorted) {
  if (gw !== 10 && gw !== 12) return null
  var parts = [], x = 0, i = 0
  while (i < sorted.length) {
    var first = sorted[i]
    if (!near(first.x, x) || !near(first.w, Math.round(first.w))) return null
    var heights = [], y = 0
    while (i < sorted.length && near(sorted[i].x, first.x)) {
      if (!near(sorted[i].w, first.w) || !near(sorted[i].y, y)) return null
      heights.push(sorted[i].h)
      y += sorted[i].h
      i++
    }
    if (!near(y, gh)) return null
    var span = Math.round(first.w)
    if (heights.length === 1) parts.push(String(span))
    // ":n" goes up to 8 tiles; more than that need heights or a drawn spec.
    else if (heights.length <= 8 && heights.every(function(h) { return near(h, heights[0]) })) parts.push(span + ":" + heights.length)
    else if ((gh === 10 || gh === 12) && heights.every(function(h) { return near(h, Math.round(h)) }))
      parts.push(span + ":" + heights.map(Math.round).join("/"))
    else return null
    x += span
  }
  return near(x, gw) ? parts.join("|") : null
}

// Fill order: the biggest tile first, then tile number. ranks[i] is tile i's
// place in that order.
function fillRanks(rects) {
  var order = rects.map(function(r, i) { return i })
  order.sort(function(a, b) {
    var sa = rects[a].w * rects[a].h, sb = rects[b].w * rects[b].h
    return Math.abs(sa - sb) > EPS ? sb - sa : a - b
  })
  var ranks = []
  order.forEach(function(index, rank) { ranks[index] = rank })
  return ranks
}

// Tiles as fractions of the area, with their fill rank, for drawing.
function tilesFor(spec) {
  var layout = parse(spec)
  if (!layout) return []
  var ranks = fillRanks(layout.rects)
  return layout.rects.map(function(r, i) {
    return { x: r.x / layout.gw, y: r.y / layout.gh, w: r.w / layout.gw, h: r.h / layout.gh, rank: ranks[i] }
  })
}

// Pixel edges along one axis: the distinct tile edges (fractions 0..1), with
// `gap` pixels between neighbouring segments and the rest shared out by size.
// Leftover pixels go to the largest remainders, outer segments first on a
// tie, so a symmetric layout stays symmetric.
function pixelAxis(edges, size, gap) {
  edges = edges.slice().sort(function(a, b) { return a - b })
  var n = edges.length - 1
  if (size - gap * (n - 1) < n) gap = 0
  var room = size - gap * (n - 1)
  var exact = [], px = [], used = 0, k
  for (k = 0; k < n; k++) {
    exact.push((edges[k + 1] - edges[k]) * room)
    px.push(Math.max(1, Math.floor(exact[k] + EPS)))
    used += px[k]
  }
  // Every segment keeps a pixel, or a thin tile vanishes; the pixels that
  // takes come out of the biggest segments.
  while (used > room) {
    var big = 0
    for (k = 1; k < n; k++) if (px[k] > px[big]) big = k
    if (px[big] <= 1) break
    px[big]--
    used--
  }
  var order = px.map(function(_, k) { return k })
  order.sort(function(a, b) {
    var ra = exact[a] - px[a], rb = exact[b] - px[b]
    if (Math.abs(ra - rb) > 1e-6) return rb - ra
    var da = Math.abs(a - (n - 1) / 2), db = Math.abs(b - (n - 1) / 2)
    return Math.abs(da - db) > 1e-6 ? db - da : a - b
  })
  for (k = 0; k < room - used; k++) px[order[k % n]]++
  var starts = [], at = 0
  for (k = 0; k < n; k++) { starts.push(at); at += px[k] + gap }
  var index = function(e) {
    for (var i = 0; i < edges.length; i++) if (near(edges[i], e)) return i
    return 0
  }
  return {
    start: function(e) { var i = index(e); return i < n ? starts[i] : size },
    end: function(e) { var i = index(e); return i > 0 ? starts[i - 1] + px[i - 1] : 0 }
  }
}

// Tiles of a spec in whole pixels for a size x height picture, `gap` pixels
// apart, with their fill rank: crisp at the size of a bar icon.
function pixelTiles(spec, size, height, gap) {
  var layout = parse(spec)
  if (!layout) return []
  var xs = [0, 1], ys = [0, 1]
  var add = function(list, v) { if (!list.some(function(e) { return near(e, v) })) list.push(v) }
  layout.rects.forEach(function(r) {
    add(xs, r.x / layout.gw); add(xs, (r.x + r.w) / layout.gw)
    add(ys, r.y / layout.gh); add(ys, (r.y + r.h) / layout.gh)
  })
  var ax = pixelAxis(xs, size, gap), ay = pixelAxis(ys, height, gap)
  var ranks = fillRanks(layout.rects)
  return layout.rects.map(function(r, i) {
    var x0 = ax.start(r.x / layout.gw), x1 = ax.end((r.x + r.w) / layout.gw)
    var y0 = ay.start(r.y / layout.gh), y1 = ay.end((r.y + r.h) / layout.gh)
    return { x: x0, y: y0, w: x1 - x0, h: y1 - y0, rank: ranks[i] }
  })
}

function overlaps(a, b) {
  return Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x) > EPS
    && Math.min(a.y + a.h, b.y + b.h) - Math.max(a.y, b.y) > EPS
}

function valid(rects, gw, gh) {
  for (var i = 0; i < rects.length; i++) {
    var r = rects[i]
    if (r.w < 1 - 1e-4 || r.h < 1 - 1e-4 || r.x < -EPS || r.y < -EPS || r.x + r.w > gw + EPS || r.y + r.h > gh + EPS) return false
    for (var j = i + 1; j < rects.length; j++) if (overlaps(r, rects[j])) return false
  }
  return true
}

// Lines that can be dragged: where tile edges meet (or a tile edge meets
// empty space) inside the grid. Tiles joined along a line move together.
function dividers(rects, gw, gh) {
  var out = []
  ;["v", "h"].forEach(function(orient) {
    var vertical = orient === "v"
    var limit = vertical ? gw : gh
    var lead = function(r) { return vertical ? r.x : r.y }
    var trail = function(r) { return vertical ? r.x + r.w : r.y + r.h }
    var spanStart = function(r) { return vertical ? r.y : r.x }
    var spanEnd = function(r) { return vertical ? r.y + r.h : r.x + r.w }

    var positions = []
    rects.forEach(function(r) {
      ;[lead(r), trail(r)].forEach(function(p) {
        if (p > EPS && p < limit - EPS && !positions.some(function(q) { return near(q, p) })) positions.push(p)
      })
    })

    positions.forEach(function(p) {
      var before = [], after = []
      rects.forEach(function(r, i) {
        if (near(trail(r), p)) before.push(i)
        if (near(lead(r), p)) after.push(i)
      })
      // Group tiles that touch across the line.
      var group = {}
      var find = function(i) { while (group[i] !== undefined && group[i] !== i) i = group[i]; return i }
      before.concat(after).forEach(function(i) { group[i] = i })
      before.forEach(function(a) {
        after.forEach(function(b) {
          var shared = Math.min(spanEnd(rects[a]), spanEnd(rects[b])) - Math.max(spanStart(rects[a]), spanStart(rects[b]))
          if (shared > EPS) group[find(a)] = find(b)
        })
      })
      var parts = {}
      before.concat(after).forEach(function(i) {
        var root = find(i)
        parts[root] = parts[root] || { before: [], after: [] }
        if (before.indexOf(i) >= 0) parts[root].before.push(i)
        if (after.indexOf(i) >= 0) parts[root].after.push(i)
      })
      Object.keys(parts).forEach(function(k) {
        var part = parts[k]
        var members = part.before.concat(part.after)
        out.push({
          orient: orient, pos: p, before: part.before, after: part.after,
          from: Math.min.apply(null, members.map(function(i) { return spanStart(rects[i]) })),
          to: Math.max.apply(null, members.map(function(i) { return spanEnd(rects[i]) }))
        })
      })
    })
  })
  return out
}

// Rects with a divider moved to pos, or null if that breaks the layout.
function moveDivider(rects, gw, gh, divider, pos) {
  var vertical = divider.orient === "v"
  var next = rects.map(function(r) { return { x: r.x, y: r.y, w: r.w, h: r.h } })
  divider.before.forEach(function(i) {
    if (vertical) next[i].w = pos - next[i].x
    else next[i].h = pos - next[i].y
  })
  divider.after.forEach(function(i) {
    if (vertical) { var right = next[i].x + next[i].w; next[i].x = pos; next[i].w = right - pos }
    else { var bottom = next[i].y + next[i].h; next[i].y = pos; next[i].h = bottom - pos }
  })
  return valid(next, gw, gh) ? next : null
}

// Split tile i in two, side by side (vertical) or stacked.
function split(rects, i, vertical) {
  var r = rects[i]
  var size = vertical ? r.w : r.h
  if (size < 2 - 1e-4) return null
  var first = Math.floor(size / 2)
  var a = { x: r.x, y: r.y, w: r.w, h: r.h }, b = { x: r.x, y: r.y, w: r.w, h: r.h }
  if (vertical) { a.w = first; b.x = r.x + first; b.w = r.w - first }
  else { a.h = first; b.y = r.y + first; b.h = r.h - first }
  var next = rects.slice()
  next.splice(i, 1, a, b)
  return sortRects(next)
}
