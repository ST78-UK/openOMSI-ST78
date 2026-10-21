-- Bus Company Simulator for openOMSI.
--
-- Build a company on any map: buy buses from the ones installed, hire AI drivers, take over
-- the map's timetable tours and run them with AI drivers - or drive them yourself - and
-- keep the books in the black. Ctrl+B opens the company window (F10 gives it the mouse; its
-- buttons also answer a plain click).
--
-- This file only wires the game's events to game.lua (the rules) and views.lua (the panels).

local U = require("util")
local Cat = require("catalog")
local R = require("routes")
local G = require("game")
local V = require("views")

local VERSION = "1.0.0"

local settings = omsi.plugin.settings({
  { key = "company_name", type = "text", label = "Company name (new company)", default = "Bus Company" },
  { key = "currency", type = "choice", label = "Currency", choices = { "EUR", "GBP", "USD", "PLN", "CHF", "SEK", "CZK" }, default = "EUR" },
  { key = "difficulty", type = "choice", label = "Difficulty", choices = { "Easy", "Normal", "Hard" }, default = "Normal" },
  { key = "pace", type = "number", label = "Economy pace (days of money per day played)", default = 8, min = 1, max = 60, step = 1 },
  { key = "start_cash", type = "number", label = "Starting cash (new company)", default = 400000, min = 50000, max = 5000000, step = 50000 },
  { key = "auto_service", type = "number", label = "Overnight service below condition % (0 = off)", default = 55, min = 0, max = 90, step = 5 },
  { key = "hud", type = "bool", label = "Show the small cash display", default = true },
  { key = "bankruptcy", type = "bool", label = "Bankruptcy ends the company", default = true },
  { key = "toasts", type = "bool", label = "Notifications", default = true },
  { key = "auto_allocate", type = "bool", label = "Auto-allocate buses and AI drivers to every tour", default = true },
}, "Bus Company")

local shown = true
local last_save = 0

-- One company per map: the save is kept under the map's name, so every map has its own
-- books, fleet and staff. (A save from before this existed, under the plain key "company",
-- is adopted by the first map that is played and then removed.)
local current_map

local function map_name() return tostring(omsi.map.name() or "?") end
local function company_key(map) return "company:" .. (map or current_map or map_name()) end

local function save()
  if G.S and current_map then omsi.storage.set(company_key(current_map), G.S) end
  last_save = omsi.time()
end

local function load_overrides()
  if omsi.files.exists("vehicles.json") then
    local text = omsi.files.read("vehicles.json")
    local ok, t = pcall(omsi.json.decode, text or "")
    if ok and type(t) == "table" then Cat.set_overrides(t.overrides) end
  else
    omsi.files.write("vehicles.json", omsi.json.encode({
      note = "Correct how the company sees a bus: the key is a lower-case piece of its name, class one of minibus, midi, standard, artic, double, coach, powertrain one of diesel, hybrid, electric, price optional.",
      overrides = {},
    }, true))
  end
end

local function flush_notes()
  for _, n in ipairs(G.notes) do
    if settings.toasts then
      local o = n.opts or {}
      omsi.ui.toast(n.text, { title = o.title or "Bus Company", icon = o.icon, color = o.color, seconds = o.seconds or 6 })
    end
  end
  G.notes = {}
end

local function refresh()
  if not G.S then return end
  if shown then omsi.ui.set("bc", V.panel()) else omsi.ui.remove("bc") end
  if settings.hud and not shown then omsi.ui.set("bc_hud", V.hud()) else omsi.ui.remove("bc_hud") end
  flush_notes()
end

local function start()
  load_overrides()
  R.reset_cache()
  current_map = map_name()
  local saved = omsi.storage.get(company_key(current_map))
  if saved == nil then
    local legacy = omsi.storage.get("company")
    if legacy ~= nil then
      saved = legacy
      omsi.storage.set("company", nil)
    end
  end
  G.init(settings, saved)
  G.remember_vehicle()
  G.autofill()
  G.sync_engine()
  save()
  omsi.log("Bus Company " .. VERSION .. " on " .. current_map .. ": " .. G.S.name .. ", " .. #G.S.fleet .. " buses, cash " .. string.format("%.0f", G.S.cash))
  refresh()
end

omsi.on("start", start)

omsi.on("setting", function(key, value)
  settings[key] = value
  G.cfg = settings
  refresh()
end)

omsi.on("minute", function()
  if not G.S then return end
  G.tick_minute()
  refresh()
end)

omsi.every(5, function()
  if G.S then G.poll_buses() end
end)

omsi.every(2, function()
  if not G.S then return end
  -- another map was loaded without the plugin being started again: save this company and
  -- open the other map's
  if current_map and map_name() ~= current_map and map_name() ~= "?" then
    save()
    start()
    return
  end
  G.poll_player()
  G.check_pending()
end)

omsi.every(1, function()
  if not G.S then return end
  refresh()
  if omsi.time() - last_save > 30 then save() end
end)

omsi.on("ticket_sold", function(name, price) if G.S then G.on_ticket(name, price); end end)
omsi.on("crash", function(kj, speed) if G.S then G.on_crash(kj, speed) end end)
omsi.on("pedestrian", function() if G.S then G.on_pedestrian() end end)
omsi.on("red_light", function() if G.S then G.on_red_light() end end)
omsi.on("service", function(kind, by, amount) if G.S then G.on_service(kind, by, amount) end end)
omsi.on("vehicle", function(name) if G.S then G.on_vehicle(name); refresh() end end)
omsi.on("stop_arrive", function(...) if G.S then G.on_stop_event(...) end end)
omsi.on("stop_depart", function(...) if G.S then G.on_stop_event(...) end end)
omsi.on("trip_start", function() if G.S then G.on_trip_start() end end)
omsi.on("duty_start", function(line, tour) if G.S then G.on_duty_start(line, tour) end end)
omsi.on("duty_end", function() if G.S then G.on_duty_end() end end)
omsi.on("trip_done", function(...) if G.S then G.on_trip_done(...); refresh() end end)

omsi.on("ui_change", function(panel, element, value)
  if panel ~= "bc" or not G.S then return end
  V.change(element, value)
  refresh()
end)

omsi.on("ui_click", function(panel, element)
  if panel ~= "bc" or not G.S or not element then return end
  V.click(element, function() omsi.plugin.show_settings(true) end)
  refresh()
end)

omsi.on("stop", save)

omsi.input.hotkey("Ctrl+KeyB", function()
  shown = not shown
  refresh()
end)

-- Ctrl+L: the company window on its Livery tab (repaint the bus you sit in, live)
omsi.input.hotkey("Ctrl+KeyL", function()
  if not G.S then return end
  if shown and V.tab == V.LIVERY_TAB then
    shown = false
  else
    shown = true
    V.tab = V.LIVERY_TAB
  end
  refresh()
end)
