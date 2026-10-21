-- mock_omsi.lua: a stand-in for the `omsi` table, enough for the Bus Company plugin to run
-- headlessly (any Lua 5.3 or newer: `lua tests/run.lua`, or `texlua tests/run.lua`).
-- It also checks what the plugin hands the game: panels are validated against the limits
-- of the real panel API, and the stored company goes through a JSON round trip like the
-- real storage does.

local M = {}

-- ---------------------------------------------------------------------------------------
-- A small JSON, strict about what the real one would refuse
-- ---------------------------------------------------------------------------------------
local json = {}

local function is_array(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" then return false end
    n = n + 1
  end
  if n == 0 then return true end
  for i = 1, n do if t[i] == nil then return false end end
  return true
end

function json.encode(v, pretty)
  local t = type(v)
  if t == "nil" then return "null" end
  if t == "boolean" then return tostring(v) end
  if t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then error("JSON cannot hold " .. tostring(v)) end
    if math.type and math.type(v) == "integer" then return tostring(v) end
    return string.format("%.17g", v)
  end
  if t == "string" then
    return '"' .. v:gsub('[%c"\\]', function(c)
      if c == '"' then return '\\"' elseif c == "\\" then return "\\\\" elseif c == "\n" then return "\\n" end
      return string.format("\\u%04x", c:byte())
    end) .. '"'
  end
  if t == "table" then
    if is_array(v) then
      local out = {}
      for i = 1, #v do out[i] = json.encode(v[i]) end
      return "[" .. table.concat(out, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do
      if type(k) ~= "string" then error("JSON object with a non-string key: " .. tostring(k)) end
      keys[#keys + 1] = k
    end
    table.sort(keys)
    local out = {}
    for _, k in ipairs(keys) do out[#out + 1] = json.encode(k) .. ":" .. json.encode(v[k]) end
    return "{" .. table.concat(out, ",") .. "}"
  end
  error("JSON cannot hold a " .. t)
end

function json.decode(s)
  local i = 1
  local function ws() i = s:find("%S", i) or #s + 1 end
  local value
  local function str()
    local j = i + 1
    local out = {}
    while true do
      local c = s:sub(j, j)
      if c == '"' then break end
      if c == "\\" then
        local n = s:sub(j + 1, j + 1)
        if n == "u" then out[#out + 1] = utf8 and utf8.char(tonumber(s:sub(j + 2, j + 5), 16)) or "?"; j = j + 6
        else out[#out + 1] = ({ n = "\n", t = "\t" })[n] or n; j = j + 2 end
      else out[#out + 1] = c; j = j + 1 end
    end
    i = j + 1
    return table.concat(out)
  end
  function value()
    ws()
    local c = s:sub(i, i)
    if c == "{" then
      local t = {}
      i = i + 1; ws()
      if s:sub(i, i) == "}" then i = i + 1; return t end
      while true do
        ws(); local k = str(); ws(); i = i + 1 -- :
        t[k] = value(); ws()
        local d = s:sub(i, i); i = i + 1
        if d == "}" then return t end
      end
    elseif c == "[" then
      local t = {}
      i = i + 1; ws()
      if s:sub(i, i) == "]" then i = i + 1; return t end
      while true do
        t[#t + 1] = value(); ws()
        local d = s:sub(i, i); i = i + 1
        if d == "]" then return t end
      end
    elseif c == '"' then return str()
    elseif s:sub(i, i + 3) == "true" then i = i + 4; return true
    elseif s:sub(i, i + 4) == "false" then i = i + 5; return false
    elseif s:sub(i, i + 3) == "null" then i = i + 4; return nil
    else
      local num = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", i)
      i = i + #num
      return tonumber(num)
    end
  end
  return value()
end

M.json = json

-- ---------------------------------------------------------------------------------------
-- The panel validator (the real limits: 200 elements, known types, ids where needed)
-- ---------------------------------------------------------------------------------------
local KNOWN = { text = 1, icon = 1, row = 1, bar = 1, badge = 1, box = 1, stops = 1, divider = 1, space = 1, button = 1, image = 1, checkbox = 1, slider = 1, input = 1, tabs = 1, chart = 1, table = 1 }
local NEED_ID = { button = 1, checkbox = 1, slider = 1, input = 1, tabs = 1 }

local function validate(panel, path, counter, ids)
  for i, e in ipairs(panel.children or {}) do
    local p = path .. ".children[" .. i .. "]"
    if type(e) ~= "table" then return false, p .. " is not a table" end
    if not KNOWN[e.type] then return false, p .. ": unknown type " .. tostring(e.type) end
    counter.n = counter.n + 1
    if counter.n > 200 then return false, "more than 200 elements" end
    if NEED_ID[e.type] and not e.id then return false, p .. ": " .. e.type .. " needs an id" end
    if e.id then
      if #e.id > 64 then return false, p .. ": id longer than 64 characters" end
      if ids[e.id] then return false, p .. ": duplicate id " .. e.id end
      ids[e.id] = true
    end
    if e.type == "text" and (type(e.text) ~= "string" or #e.text > 500) then return false, p .. ": text must be a string of at most 500 characters" end
    if e.type == "badge" and type(e.text) ~= "string" then return false, p .. ": badge text must be a string" end
    if e.type == "tabs" then
      if type(e.tabs) ~= "table" or #e.tabs == 0 then return false, p .. ": tabs need a list" end
      if type(e.selected) ~= "number" or e.selected < 1 or e.selected > #e.tabs then return false, p .. ": selected out of range" end
    end
    if e.type == "chart" and (type(e.values) ~= "table" or #e.values > 512) then return false, p .. ": chart values" end
    if e.type == "table" then
      for _, r in ipairs(e.rows or {}) do
        if #r ~= #e.columns then return false, p .. ": a row has " .. #r .. " cells for " .. #e.columns .. " columns" end
      end
    end
    if e.children then
      local ok, why = validate(e, p, counter, ids)
      if not ok then return false, why end
    end
  end
  return true
end

-- ---------------------------------------------------------------------------------------
-- The game
-- ---------------------------------------------------------------------------------------
--- Creates the fake game and installs it as the global `omsi`. `world` describes it.
function M.new(world)
  world = world or {}
  local g = {
    t = 0,                    -- game seconds since the plugin started
    clock = world.clock or 8 * 3600,
    date = world.date or { year = 2026, month = 10, day = 5, weekday = 1 },
    map = world.map or "TestCity",
    handlers = {}, timers = {}, hotkeys = {},
    storage = world.storage or {}, files = {},
    panels = {}, toasts = {}, log = {}, calls = {},
    vehicle = world.vehicle, odometer = 12345, delay_seen = 0,
    lines = world.lines, buses = world.timetable_buses or {},
    catalog = world.catalog, placing = false, assigned = {},
    duty = nil, precip = { "none", 0 },
    tickets = world.tickets or { { name = "Single", price = 2.7, day_ticket = false }, { name = "Day", price = 7, day_ticket = true } },
    settings_values = world.settings_values or {},
  }
  M.game = g

  local omsi = {}
  omsi.json = json

  function omsi.on(ev, fn)
    g.handlers[ev] = g.handlers[ev] or {}
    table.insert(g.handlers[ev], fn)
    return #g.handlers[ev]
  end
  function omsi.every(sec, fn) g.timers[#g.timers + 1] = { every = sec, fn = fn, acc = 0 }; return #g.timers end
  function omsi.after(sec, fn) g.timers[#g.timers + 1] = { once = sec, fn = fn, acc = 0 }; return #g.timers end
  function omsi.time() return g.t end
  function omsi.log(s) g.log[#g.log + 1] = s end
  function omsi.message(s) g.log[#g.log + 1] = s end
  function omsi.has_vehicle() return g.vehicle ~= nil end
  function omsi.vehicle() return g.vehicle and g.vehicle.name end
  function omsi.vehicle_manufacturer() return g.vehicle and g.vehicle.manufacturer end
  function omsi.vehicle_model() return g.vehicle and g.vehicle.model end
  function omsi.command(c) g.calls[#g.calls + 1] = "command " .. c; return true end

  omsi.util = { now = function() return 1700000000 end }

  omsi.plugin = {
    settings = function(defs)
      local out = {}
      for _, d in ipairs(defs) do out[d.key] = d.default end
      for k, v in pairs(g.settings_values) do out[k] = v end
      g.settings_table = out
      return out
    end,
    show_settings = function() g.calls[#g.calls + 1] = "show_settings" end,
  }

  omsi.storage = {
    get = function(k)
      local v = g.storage[k]
      if v == nil then return nil end
      return json.decode(v)
    end,
    set = function(k, v)
      if v == nil then g.storage[k] = nil else g.storage[k] = json.encode(v) end
    end,
  }

  omsi.files = {
    exists = function(p) return g.files[p] ~= nil end,
    read = function(p) return g.files[p] end,
    write = function(p, s) g.files[p] = s; return true end,
  }

  omsi.ui = {
    set = function(id, panel)
      local ok, why = validate(panel, "panel", { n = 0 }, {})
      if not ok then error("ui.set(" .. id .. "): " .. why) end
      g.panels[id] = panel
      return true
    end,
    remove = function(id) local had = g.panels[id] ~= nil; g.panels[id] = nil; return had end,
    toast = function(text, opts) g.toasts[#g.toasts + 1] = { text = text, opts = opts }; return true end,
  }

  omsi.input = { hotkey = function(keys, fn) g.hotkeys[keys] = fn; return 1 end }

  omsi.world = {
    time = function() return g.clock end,
    date = function() if g.nodate then return nil end; return g.date end,
  }
  omsi.map = { name = function() return g.map end }
  omsi.weather = { precipitation = function() return g.precip[1], g.precip[2] end }

  omsi.bus = {
    file = function() return g.vehicle and g.vehicle.file end,
    odometer = function() return g.vehicle and g.odometer end,
    tickets = function() return g.tickets end,
  }

  omsi.timetable = {
    lines = function() return g.lines or {} end,
    stops = function(line, tour, trip)
      local out = {}
      for _, l in ipairs(g.lines or {}) do
        if l.name == line then
          for _, t in ipairs(l.tours) do
            if tostring(t.number) == tostring(tour) then
              for _, row in ipairs(t.rows or {}) do
                if not trip or row.trip == trip then out[#out + 1] = row end
              end
            end
          end
        end
      end
      return out
    end,
    buses = function() return g.buses end,
  }

  omsi.duty = {
    start = function(line, tour, trip)
      g.calls[#g.calls + 1] = "duty.start " .. line .. "/" .. tour .. (trip and ("#" .. trip) or "")
      if g.duty_fails then return false, g.duty_fails end
      g.duty = { line = line, tour = tour, trip = trip or 1 }
      return true
    end,
    get = function() return g.duty end,
    finish = function() g.calls[#g.calls + 1] = "duty.finish"; g.duty = nil; return true end,
  }

  if world.fleet_api ~= false then
    omsi.fleet = {
      catalog = function() return g.catalog or {} end,
      busy = function() return g.placing end,
      place = function(file, opts)
        g.calls[#g.calls + 1] = "fleet.place " .. file
        g.place_request = { file = file, opts = opts }
        g.livery = opts and opts.paint or nil
        g.placing = true
        return true
      end,
      assign = function(line, tour, file, opts)
        g.assigned[line .. "/" .. tour] = { file = file, number = opts and opts.number, paint = opts and opts.paint }
        return true
      end,
      liveries = function(file)
        local l = g.liveries and g.liveries[file]
        local out = {}
        for _, n in ipairs(l or {}) do out[#out + 1] = n end
        return out
      end,
      livery = function() return g.livery end,
      repaint = function(name)
        if g.placing then return false, "a vehicle is still loading" end
        g.calls[#g.calls + 1] = "fleet.repaint " .. tostring(name)
        g.livery = name
        g.placing = true
        g.repaint_request = name
        return true
      end,
      unassign = function(line, tour) local had = g.assigned[line .. "/" .. tour] ~= nil; g.assigned[line .. "/" .. tour] = nil; return had end,
    }
  end

  _G.omsi = omsi
  return g
end

--- Fires an event to the plugin's handlers.
function M.fire(name, ...)
  for _, fn in ipairs(M.game.handlers[name] or {}) do fn(...) end
end

--- Runs the timers for `sec` game seconds, in steps of one second.
function M.advance(sec)
  local g = M.game
  for _ = 1, sec do
    g.t = g.t + 1
    for _, t in ipairs(g.timers) do
      t.acc = t.acc + 1
      if t.every and t.acc >= t.every then t.acc = 0; t.fn() end
    end
  end
end

--- Moves the clock `minutes` forward, firing `minute` events and (at midnight) the date.
function M.run_minutes(minutes, per_minute)
  local g = M.game
  for _ = 1, minutes do
    g.clock = g.clock + 60
    if g.clock >= 86400 then
      g.clock = g.clock - 86400
      local d = g.date
      local dim = ({ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 })[d.month]
      d.day = d.day + 1
      d.weekday = d.weekday % 7 + 1
      if d.day > dim then d.day = 1; d.month = d.month + 1 end
      if d.month > 12 then d.month = 1; d.year = d.year + 1 end
      M.fire("day", d.year, d.month, d.day)
    end
    M.fire("minute", math.floor(g.clock / 3600), math.floor(g.clock % 3600 / 60))
    M.advance(60)
    if per_minute then per_minute() end
  end
end

--- Sets the clock to a time of day without firing events (a jump).
function M.set_clock(sec) M.game.clock = sec end

--- Makes the game finish placing a bus: the player is now in it.
function M.finish_placing(vehicle)
  local g = M.game
  g.placing = false
  g.vehicle = vehicle
  M.fire("vehicle", vehicle.name)
end

return M
