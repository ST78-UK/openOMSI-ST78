-- views.lua: the panels. `V.panel()` builds the main window as a table for omsi.ui.set;
-- `V.click(id)` and `V.change(id, value)` carry out what the player pressed.
-- Lists are paged so a panel stays well under the game's 200-element limit.

local U = require("util")
local B = require("balance")
local Co = require("company")
local Cat = require("catalog")
local F = require("fleet")
local D = require("drivers")
local R = require("routes")
local G = require("game")

local V = {}

local ACCENT = "#F47F30"
local GOOD, BAD, WARN, MUTED = "#2E7D32", "#C62828", "#F9A825", "#9AA0A6"

V.tab = 1
V.page = { fleet = 1, market = 1, routes = 1, staff = 1, cands = 1 }
V.sel = { bus = nil, offer = nil, tour = nil, driver = nil, cand = nil }
V.market_kind = 1          -- 1 new, 2 used
V.market_class = 1         -- 1 all, then B.class_order
V.routes_filter = 1        -- 1 all, 2 operated
V.pick = { bus = nil, driver = nil }   -- what the route editor would assign
V.confirm = nil
V.msg = nil
V.msg_color = nil
V.rename = nil

local TABS = { "Overview", "Fleet", "Market", "Routes", "Staff", "Finance" }
local PER_PAGE = { fleet = 6, market = 6, routes = 7, staff = 5, cands = 4 }

local function say(text, ok)
  V.msg, V.msg_color = text, ok and GOOD or BAD
end

local function money(x, d) return G.money(x, d) end

local function line(a, b, color)
  return { type = "row", align = "between", children = {
    { type = "text", text = a, color = MUTED },
    { type = "text", text = b, weight = "bold", color = color },
  } }
end

local function pager(name, total)
  local pages = math.max(1, math.ceil(total / PER_PAGE[name]))
  V.page[name] = U.clamp(V.page[name], 1, pages)
  if pages == 1 then return nil end
  return { type = "row", align = "between", children = {
    { type = "button", id = "page:" .. name .. ":-1", text = "Prev", icon = "chevron_left" },
    { type = "text", text = V.page[name] .. " / " .. pages, align = "center" },
    { type = "button", id = "page:" .. name .. ":1", text = "Next", icon = "chevron_right" },
  } }
end

local function slice(list, name)
  local per = PER_PAGE[name]
  local from = (V.page[name] - 1) * per + 1
  local out = {}
  for i = from, math.min(#list, from + per - 1) do out[#out + 1] = list[i] end
  return out
end

local function bar(value, color)
  return { type = "bar", value = U.clamp(value, 0, 1), color = color, height = 6 }
end

local function cond_color(c)
  if c >= 70 then return GOOD end
  if c >= 40 then return WARN end
  return BAD
end

local function bus_status(b)
  if b.status == "workshop" then return "Workshop", WARN end
  if b.assignment then
    local a = R.get(G.S, b.assignment)
    return "Line " .. b.assignment .. (a and (a.mode == "player" and " (you)" or " (AI)") or ""), GOOD
  end
  return "Free", MUTED
end

-- ---------------------------------------------------------------------------------------
-- Overview
-- ---------------------------------------------------------------------------------------

local function overview()
  local S = G.S
  local c = {}
  c[#c + 1] = { type = "row", align = "between", children = {
    { type = "text", text = "Cash", size = 13, color = MUTED },
    { type = "text", text = money(S.cash), size = 22, weight = "bold", color = S.cash >= 0 and GOOD or BAD },
  } }
  c[#c + 1] = line("Today so far", money(Co.net(S.today)), Co.net(S.today) >= 0 and GOOD or BAD)
  c[#c + 1] = line("This week", money(Co.net(S.week)), Co.net(S.week) >= 0 and GOOD or BAD)
  c[#c + 1] = line("Fleet value", money(F.total_value(S)))
  c[#c + 1] = line("Loans", money(Co.debt(S)), Co.debt(S) > 0 and WARN or nil)
  c[#c + 1] = { type = "row", children = {
    { type = "text", text = "Reputation", color = MUTED },
    bar(S.reputation / 100, S.reputation >= 60 and GOOD or (S.reputation >= 35 and WARN or BAD)),
    { type = "text", text = string.format("%.0f", S.reputation), weight = "bold" },
  } }
  local pts = {}
  for _, h in ipairs(S.history) do pts[#pts + 1] = h.net end
  if #pts >= 2 then
    c[#c + 1] = { type = "text", text = "Profit per day", size = 12, color = MUTED }
    c[#c + 1] = { type = "chart", values = pts, style = "bars", height = 44 }
  end
  c[#c + 1] = { type = "divider" }
  for i, a in ipairs(G.alerts()) do
    if i <= 5 then c[#c + 1] = { type = "box", color = a.color, children = { { type = "text", text = a.text, size = 13 } } } end
  end
  -- the player's own tours: one click to drive
  local mine = {}
  for _, a in ipairs(S.assignments) do
    if a.mode == "player" then mine[#mine + 1] = a end
  end
  if #mine > 0 then
    c[#c + 1] = { type = "divider" }
    c[#c + 1] = { type = "text", text = "Drive one of your tours", weight = "bold" }
    for i, a in ipairs(mine) do
      if i <= 4 then
        c[#c + 1] = { type = "button", id = "drive:" .. a.key, icon = "play_arrow", text = "Line " .. a.line .. " / " .. a.tour }
      end
    end
  end
  return c
end

-- ---------------------------------------------------------------------------------------
-- Fleet
-- ---------------------------------------------------------------------------------------

local function bus_detail(b)
  local c = {}
  local status, color = bus_status(b)
  c[#c + 1] = { type = "divider" }
  c[#c + 1] = { type = "text", text = "No. " .. b.number .. "  " .. b.name, weight = "bold" }
  c[#c + 1] = line("Class", b.spec.class_label .. ", " .. b.spec.power_label:lower() .. ", about " .. b.spec.capacity .. " places")
  c[#c + 1] = line("Age / odometer", string.format("%.1f years / %s km", F.age_years(b), U.thousands(b.odometer)))
  c[#c + 1] = line("Condition", string.format("%.0f %%", b.condition), cond_color(b.condition))
  c[#c + 1] = bar(b.condition / 100, cond_color(b.condition))
  c[#c + 1] = line("Status", status, color)
  c[#c + 1] = line("Runs on", string.format("%.1f %s per 100 km, %s per km upkeep", b.spec.consumption, b.spec.energy == "electric" and "kWh" or "litres", money(Cat.maint_per_km(b.spec, b.condition), 2)))
  c[#c + 1] = line("Value / dealer pays", money(F.value(b)) .. " / " .. money(F.resale(b)))
  c[#c + 1] = { type = "row", children = {
    { type = "button", id = "service", text = "Service " .. money(G.cost(F.service_cost(b))), icon = "build", grow = true },
    { type = "button", id = "sell", text = "Sell", icon = "sell", grow = true, color = BAD },
  } }
  if b.assignment then
    c[#c + 1] = { type = "button", id = "unassign:" .. b.assignment, text = "Take off line " .. b.assignment, icon = "block" }
  end
  return c
end

local function fleet()
  local S = G.S
  local c = {}
  if #S.fleet == 0 then
    c[#c + 1] = { type = "text", text = "No buses. Buy one in the Market tab.", color = MUTED }
    return c
  end
  local rows = slice(S.fleet, "fleet")
  for _, b in ipairs(rows) do
    local status, color = bus_status(b)
    c[#c + 1] = { type = "row", id = "bus:" .. b.id, clickable = true, children = {
      { type = "badge", text = b.number, color = (V.sel.bus == b.id) and ACCENT or "#444A52" },
      { type = "text", text = U.cut(b.name, 20), grow = true, wrap = false, weight = (V.sel.bus == b.id) and "bold" or "regular" },
      { type = "text", text = string.format("%.0f%%", b.condition), color = cond_color(b.condition) },
      { type = "text", text = U.cut(status, 14), color = color, wrap = false },
    } }
  end
  local p = pager("fleet", #S.fleet)
  if p then c[#c + 1] = p end
  local b = V.sel.bus and F.get(S, V.sel.bus)
  if b then
    for _, e in ipairs(bus_detail(b)) do c[#c + 1] = e end
  else
    c[#c + 1] = { type = "text", text = "Click a bus for details.", color = MUTED, size = 12 }
  end
  return c
end

-- ---------------------------------------------------------------------------------------
-- Market
-- ---------------------------------------------------------------------------------------

local function market_list()
  local m = G.market()
  local list = V.market_kind == 1 and m.new or m.used
  if V.market_class > 1 then
    local want = B.class_order[V.market_class - 1]
    local out = {}
    for _, o in ipairs(list) do
      if o.spec.class == want then out[#out + 1] = o end
    end
    list = out
  end
  return list
end

local function offer_id(o) return o.kind .. ":" .. o.file .. ":" .. tostring(o.price) .. ":" .. tostring(o.age) end

local function market()
  local S = G.S
  local c = {}
  local labels = { "All" }
  for _, k in ipairs(B.class_order) do labels[#labels + 1] = B.classes[k].label:gsub(" 12 m", ""):gsub("%-decker", "") end
  c[#c + 1] = { type = "tabs", id = "mkind", tabs = { "New", "Used" }, selected = V.market_kind }
  c[#c + 1] = { type = "tabs", id = "mclass", tabs = labels, selected = V.market_class }
  local list = market_list()
  if #G.models_list() == 0 then
    c[#c + 1] = { type = "box", color = WARN, children = { { type = "text", text = G.has_fleet_api() and "No buses found." or "This openOMSI has no fleet API, so the market only knows the buses you have driven. Sit in a bus (Esc, Swap) and it shows up here.", size = 13 } } }
    return c
  end
  if #list == 0 then
    c[#c + 1] = { type = "text", text = "Nothing on offer.", color = MUTED }
  end
  for _, o in ipairs(slice(list, "market")) do
    local id = offer_id(o)
    c[#c + 1] = { type = "row", id = "offer:" .. id, clickable = true, children = {
      { type = "text", text = U.cut(o.name, 22), grow = true, wrap = false, weight = (V.sel.offer == id) and "bold" or "regular" },
      { type = "text", text = o.spec.class_label:gsub(" 12 m", ""), color = MUTED, size = 12, wrap = false },
      { type = "text", text = money(o.price), weight = "bold", color = (S.cash >= o.price) and GOOD or BAD },
    } }
  end
  local p = pager("market", #list)
  if p then c[#c + 1] = p end
  local sel
  for _, o in ipairs(list) do
    if offer_id(o) == V.sel.offer then sel = o end
  end
  if sel then
    c[#c + 1] = { type = "divider" }
    c[#c + 1] = { type = "text", text = sel.name, weight = "bold" }
    c[#c + 1] = line("Class", sel.spec.class_label .. ", " .. sel.spec.power_label:lower() .. ", about " .. sel.spec.capacity .. " places")
    if sel.kind == "used" then
      c[#c + 1] = line("Age / odometer", string.format("%.1f years / %s km", sel.age, U.thousands(sel.odometer)))
      c[#c + 1] = line("Condition", string.format("%.0f %%", sel.condition), cond_color(sel.condition))
    end
    c[#c + 1] = line("Uses", string.format("%.1f %s per 100 km, upkeep %s per km", sel.spec.consumption, sel.spec.energy == "electric" and "kWh" or "litres", money(Cat.maint_per_km(sel.spec, sel.condition), 2)))
    c[#c + 1] = line("Cash after buying", money(S.cash - sel.price), S.cash - sel.price >= 0 and nil or BAD)
    c[#c + 1] = { type = "button", id = "buy", text = "Buy for " .. money(sel.price), icon = "shopping_cart" }
  end
  return c
end

-- ---------------------------------------------------------------------------------------
-- Routes
-- ---------------------------------------------------------------------------------------

local function tour_rows()
  local out = {}
  for _, t in ipairs(R.scan()) do
    local a = R.get(G.S, t.key)
    if V.routes_filter == 1 or a then out[#out + 1] = { tour = t, a = a } end
  end
  return out
end

local function cycle(list, current_id)
  if #list == 0 then return nil end
  for i, x in ipairs(list) do
    if x.id == current_id then return list[(i % #list) + 1] end
  end
  return list[1]
end

local function route_editor(t, a)
  local S = G.S
  local c = { { type = "divider" } }
  local sum = R.summary(t.line, t.tour)
  c[#c + 1] = { type = "text", text = "Line " .. t.line .. " / tour " .. t.tour, weight = "bold" }
  c[#c + 1] = line("Day", string.format("%d trips, %s to %s, about %.0f km", sum.trips, sum.first and U.hhmm(sum.first) or "-", sum.last and U.hhmm(sum.last) or "-", sum.km))
  c[#c + 1] = line("Demand", R.demand_label(R.line_demand(t.line)))
  if not t.today then c[#c + 1] = { type = "text", text = "This tour does not run today.", color = WARN, size = 12 } end
  if a then
    local bus, drv = F.get(S, a.bus), D.get(S, a.driver)
    c[#c + 1] = line("Operated", a.mode == "ai" and "by AI driver" or "by you", GOOD)
    c[#c + 1] = line("Bus", bus and ("No. " .. bus.number .. " " .. U.cut(bus.name, 18)) or "-")
    if a.mode == "ai" then c[#c + 1] = line("Driver", drv and drv.name or "-") end
    c[#c + 1] = line("Trips run / on time", string.format("%d / %d", a.stats.trips, a.stats.ontime))
    c[#c + 1] = line("Today", money(a.today.revenue - a.today.costs), (a.today.revenue - a.today.costs) >= 0 and GOOD or BAD)
    c[#c + 1] = line("Fare level", string.format("%.0f %%", a.fare * 100))
    c[#c + 1] = { type = "slider", id = "fare", value = a.fare, min = B.fare_min, max = B.fare_max, step = 0.05 }
    c[#c + 1] = { type = "text", text = "Higher fares earn more per rider and lose riders.", size = 11, color = MUTED }
    local row = {}
    if a.mode == "player" then row[#row + 1] = { type = "button", id = "drive:" .. a.key, text = "Drive it", icon = "play_arrow", grow = true } end
    row[#row + 1] = { type = "button", id = "unassign:" .. a.key, text = "Stop service", icon = "block", grow = true, color = BAD }
    c[#c + 1] = { type = "row", children = row }
  else
    local buses = F.free_buses(S, G.now_abs())
    local drivers = {}
    for _, d in ipairs(S.drivers) do if not d.assignment then drivers[#drivers + 1] = d end end
    if not (V.pick.bus and F.get(S, V.pick.bus) and not F.get(S, V.pick.bus).assignment) then V.pick.bus = buses[1] and buses[1].id or nil end
    if not (V.pick.driver and D.get(S, V.pick.driver) and not D.get(S, V.pick.driver).assignment) then V.pick.driver = drivers[1] and drivers[1].id or nil end
    local bus, drv = V.pick.bus and F.get(S, V.pick.bus), V.pick.driver and D.get(S, V.pick.driver)
    c[#c + 1] = { type = "row", children = {
      { type = "text", text = bus and ("Bus: No. " .. bus.number .. " " .. U.cut(bus.name, 16)) or "No free bus", grow = true, wrap = false },
      { type = "button", id = "nextbus", text = "Next", icon = "swap_horiz" },
    } }
    c[#c + 1] = { type = "row", children = {
      { type = "text", text = drv and ("Driver: " .. drv.name .. " (" .. drv.skill .. ")") or "No free driver", grow = true, wrap = false },
      { type = "button", id = "nextdriver", text = "Next", icon = "swap_horiz" },
    } }
    if bus and drv and sum.trips > 0 then
      local e = R.estimate_day({
        spec = bus.spec, condition = bus.condition, driver = drv, demand = R.line_demand(t.line), fare = 1,
        rep = Co.demand_factor(S), fare_base = G.fare_base(), energy = S.energy, weekday = 2, weather = 1,
      }, R.schedule(t.line, t.tour))
      -- revenue scales with the income factor, costs with the cost factor, both with the pace
      local net = G.inc(e.revenue) - G.cost(e.costs)
      c[#c + 1] = line("Expected per day", money(net), net >= 0 and GOOD or BAD)
    end
    local row = {}
    row[#row + 1] = { type = "button", id = "start_ai", text = "AI driver runs it", icon = "smart_toy", grow = true }
    row[#row + 1] = { type = "button", id = "start_me", text = "I drive it", icon = "person", grow = true }
    c[#c + 1] = { type = "row", children = row }
  end
  return c
end

local function routes()
  local S = G.S
  local c = {}
  c[#c + 1] = { type = "tabs", id = "rfilter", tabs = { "All tours", "Operated" }, selected = V.routes_filter }
  local rows = tour_rows()
  if #rows == 0 then
    c[#c + 1] = { type = "text", text = (#R.scan() == 0) and "This map has no timetable lines." or "No operated tours yet.", color = MUTED }
  end
  for _, r in ipairs(slice(rows, "routes")) do
    local t, a = r.tour, r.a
    local right = a and (a.mode == "ai" and "AI" or "You") or (t.today and "" or "not today")
    c[#c + 1] = { type = "row", id = "tour:" .. t.key, clickable = true, children = {
      { type = "text", text = "Line " .. t.line .. " / " .. t.tour, grow = true, wrap = false, weight = (V.sel.tour == t.key) and "bold" or "regular" },
      { type = "text", text = t.trips .. " trips", color = MUTED, size = 12, wrap = false },
      { type = "badge", text = right ~= "" and right or "free", color = a and GOOD or "#444A52" },
    } }
  end
  local p = pager("routes", #rows)
  if p then c[#c + 1] = p end
  local t = V.sel.tour and R.find_tour(V.sel.tour)
  if t then
    for _, e in ipairs(route_editor(t, R.get(S, t.key))) do c[#c + 1] = e end
  end
  return c
end

-- ---------------------------------------------------------------------------------------
-- Staff
-- ---------------------------------------------------------------------------------------

local function skill_text(d)
  return string.format("skill %.0f  punctual %.0f  courtesy %.0f", d.skill, d.punctuality, d.courtesy)
end

local function staff()
  local S = G.S
  local c = {}
  c[#c + 1] = { type = "text", text = "Your drivers", weight = "bold" }
  if #S.drivers == 0 then c[#c + 1] = { type = "text", text = "Nobody yet. Hire from the candidates below.", color = MUTED } end
  for _, d in ipairs(slice(S.drivers, "staff")) do
    c[#c + 1] = { type = "row", id = "drv:" .. d.id, clickable = true, children = {
      { type = "text", text = U.cut(d.name, 18), grow = true, wrap = false, weight = (V.sel.driver == d.id) and "bold" or "regular" },
      { type = "text", text = d.assignment and ("Line " .. d.assignment) or "free", color = d.assignment and GOOD or MUTED, size = 12, wrap = false },
      { type = "text", text = money(d.wage, 2) .. "/h", size = 12, wrap = false },
    } }
  end
  local p = pager("staff", #S.drivers)
  if p then c[#c + 1] = p end
  local d = V.sel.driver and D.get(S, V.sel.driver)
  if d then
    c[#c + 1] = { type = "text", text = skill_text(d), size = 12, color = MUTED }
    c[#c + 1] = { type = "row", children = {
      { type = "text", text = "Morale", color = MUTED }, bar(d.morale / 100, cond_color(d.morale)),
    } }
    local row = {}
    row[#row + 1] = { type = "button", id = "train", text = "Train " .. money(B.training_cost), icon = "school", grow = true }
    if D.wants_raise(d) then row[#row + 1] = { type = "button", id = "raise", text = "Raise to " .. money(D.market_wage(d.skill), 2), icon = "trending_up", grow = true } end
    row[#row + 1] = { type = "button", id = "fire", text = "Dismiss", icon = "person_remove", grow = true, color = BAD }
    c[#c + 1] = { type = "row", children = row }
  end
  c[#c + 1] = { type = "divider" }
  c[#c + 1] = { type = "text", text = "Candidates", weight = "bold" }
  for _, k in ipairs(slice(S.candidates, "cands")) do
    c[#c + 1] = { type = "row", id = "cand:" .. k.id, clickable = true, children = {
      { type = "text", text = U.cut(k.name, 18), grow = true, wrap = false, weight = (V.sel.cand == k.id) and "bold" or "regular" },
      { type = "text", text = "skill " .. k.skill, size = 12, wrap = false },
      { type = "text", text = money(k.wage, 2) .. "/h", size = 12, wrap = false },
    } }
  end
  local p2 = pager("cands", #S.candidates)
  if p2 then c[#c + 1] = p2 end
  local k = V.sel.cand and U.find(S.candidates, function(x) return x.id == V.sel.cand end)
  if k then
    c[#c + 1] = { type = "text", text = skill_text(k) .. ", age " .. k.age, size = 12, color = MUTED }
    c[#c + 1] = { type = "button", id = "hire", text = "Hire (fee " .. money(D.hire_fee(k)) .. ")", icon = "person_add" }
  end
  return c
end

-- ---------------------------------------------------------------------------------------
-- Finance
-- ---------------------------------------------------------------------------------------

local function finance()
  local S = G.S
  local c = {}
  c[#c + 1] = { type = "input", id = "name", text = S.name, placeholder = "Company name", max = 32 }
  local rows = {}
  for _, cat in ipairs(Co.ORDER) do
    local d, w, m = S.today[cat], S.week[cat], S.month[cat]
    if d or w or m then
      local function cell(v) return { text = v and money(v) or "-", color = v and (v >= 0 and GOOD or BAD) or MUTED } end
      rows[#rows + 1] = { Co.LABELS[cat], cell(d), cell(w), cell(m) }
    end
  end
  rows[#rows + 1] = { "Profit", { text = money(Co.net(S.today)) }, { text = money(Co.net(S.week)) }, { text = money(Co.net(S.month)) } }
  c[#c + 1] = { type = "table", columns = { "", "Today", "Week", "Month" }, widths = { 3, 2, 2, 2 }, aligns = { "left", "right", "right", "right" }, rows = rows, size = 12 }
  c[#c + 1] = { type = "divider" }
  c[#c + 1] = line("Diesel / electricity", string.format("%s / %s", money(S.energy.diesel, 2), money(S.energy.electric, 2)))
  local limit = Co.credit_limit(S, F.total_value(S))
  c[#c + 1] = line("Loans (limit " .. money(limit) .. ")", money(Co.debt(S)), Co.debt(S) > 0 and WARN or nil)
  c[#c + 1] = line("Rate", string.format("%.1f %% a year", Co.loan_rate(S) * 100))
  local row = {}
  for _, amount in ipairs({ 50000, 100000, 250000 }) do
    row[#row + 1] = { type = "button", id = "borrow:" .. amount, text = "+" .. U.thousands(amount / 1000) .. "k", grow = true }
  end
  c[#c + 1] = { type = "row", children = row }
  if Co.debt(S) > 0 then
    c[#c + 1] = { type = "row", children = {
      { type = "button", id = "repay:50000", text = "Repay 50k", grow = true },
      { type = "button", id = "repay:all", text = "Repay all", grow = true },
    } }
  end
  if S.loss_carry > 0 then c[#c + 1] = line("Tax loss carried forward", money(S.loss_carry)) end
  local led = {}
  for i = #S.ledger, math.max(1, #S.ledger - 5), -1 do
    local e = S.ledger[i]
    led[#led + 1] = { U.cut(e.memo, 26), { text = money(e.amount), color = e.amount >= 0 and GOOD or BAD } }
  end
  if #led > 0 then
    c[#c + 1] = { type = "table", columns = { "Latest big bookings", "" }, widths = { 4, 2 }, aligns = { "left", "right" }, rows = led, size = 12 }
  end
  c[#c + 1] = { type = "divider" }
  c[#c + 1] = { type = "row", children = {
    { type = "button", id = "settings", text = "Settings", icon = "settings", grow = true },
    V.confirm == "reset"
      and { type = "button", id = "reset_yes", text = "Really start over?", icon = "warning", grow = true, color = BAD }
      or { type = "button", id = "reset", text = "New company", icon = "restart_alt", grow = true },
  } }
  return c
end

-- ---------------------------------------------------------------------------------------
-- The window
-- ---------------------------------------------------------------------------------------

local BODY = { overview, fleet, market, routes, staff, finance }

function V.panel()
  local S = G.S
  local children = {
    { type = "row", children = {
      { type = "icon", name = "directions_bus", color = ACCENT },
      { type = "text", text = S.name, size = 16, weight = "bold", grow = true, wrap = false },
      { type = "badge", text = money(S.cash), color = S.cash >= 0 and GOOD or BAD },
    } },
    { type = "tabs", id = "tab", tabs = TABS, selected = V.tab },
  }
  if S.bankrupt then
    children[#children + 1] = { type = "box", color = BAD, children = {
      { type = "text", text = "The company is insolvent and the bank has taken the buses.", weight = "bold" },
      { type = "text", text = "Start a new company from the Finance tab.", size = 13 },
    } }
    V.tab = 6
  end
  if V.msg then
    children[#children + 1] = { type = "box", color = V.msg_color, children = { { type = "text", text = V.msg, size = 13 } } }
  end
  for _, e in ipairs(BODY[V.tab]()) do children[#children + 1] = e end
  return { anchor = "top_left", x = 16, y = 64, width = 440, accent = ACCENT, draggable = true, grab = true, children = children }
end

function V.hud()
  local S = G.S
  local bus = G.player_bus()
  local c = {
    { type = "row", align = "between", children = {
      { type = "text", text = U.cut(S.name, 20), weight = "bold", wrap = false },
      { type = "text", text = money(S.cash), weight = "bold", color = S.cash >= 0 and GOOD or BAD },
    } },
    line("Today", money(Co.net(S.today)), Co.net(S.today) >= 0 and GOOD or BAD),
  }
  if bus then
    c[#c + 1] = line("Bus " .. bus.number, string.format("%.0f %%", bus.condition), cond_color(bus.condition))
  end
  return { anchor = "bottom_left", x = 16, y = 16, width = 230, accent = ACCENT, background = "#14161ACC", children = c }
end

-- ---------------------------------------------------------------------------------------
-- Input
-- ---------------------------------------------------------------------------------------

local function result(ok, why, okmsg)
  if ok then say(okmsg or "Done.", true) else say(why or "Not possible.", false) end
  return ok
end

function V.change(id, value)
  if id == "tab" then V.tab = value; V.msg = nil; V.confirm = nil
  elseif id == "mkind" then V.market_kind = value; V.page.market = 1; V.sel.offer = nil
  elseif id == "mclass" then V.market_class = value; V.page.market = 1; V.sel.offer = nil
  elseif id == "rfilter" then V.routes_filter = value; V.page.routes = 1
  elseif id == "fare" and V.sel.tour then G.set_fare(V.sel.tour, value)
  elseif id == "name" then
    local s = tostring(value or ""):gsub("^%s+", "")
    if #s > 0 then G.S.name = s:sub(1, 32) end
  end
end

--- `settings_fn` shows the settings panel (given by main.lua).
function V.click(id, settings_fn)
  if not id then return end
  local S = G.S
  V.msg = nil
  local kind, rest = id:match("^(%w+):(.*)$")
  if kind == "page" then
    local name, d = rest:match("^(%w+):(-?%d)$")
    V.page[name] = (V.page[name] or 1) + tonumber(d)
  elseif kind == "bus" then V.sel.bus = rest
  elseif kind == "offer" then V.sel.offer = rest
  elseif kind == "tour" then V.sel.tour = rest; V.pick = { bus = nil, driver = nil }
  elseif kind == "drv" then V.sel.driver = rest
  elseif kind == "cand" then V.sel.cand = rest
  elseif kind == "drive" then
    local ok, why = G.drive_tour(rest)
    result(ok, why, why or "Starting the duty.")
  elseif kind == "unassign" then
    G.unassign(rest)
    say("Service stopped.", true)
  elseif kind == "borrow" then
    result(G.borrow(tonumber(rest)))
  elseif kind == "repay" then
    local amount = rest == "all" and Co.debt(S) or tonumber(rest)
    result(G.repay(amount))
  elseif id == "buy" then
    local list = market_list()
    for _, o in ipairs(list) do
      if offer_id(o) == V.sel.offer then
        local b, why = G.buy(o)
        if b then V.sel.offer = nil; V.sel.bus = b.id end
        return result(b, why, "Bought No. " .. (b and b.number or "") .. ".")
      end
    end
  elseif id == "service" then
    local b = V.sel.bus and F.get(S, V.sel.bus)
    if b then result(G.service_bus(b)) end
  elseif id == "sell" then
    local b = V.sel.bus and F.get(S, V.sel.bus)
    if b then
      local price, why = G.sell(b)
      if price then V.sel.bus = nil end
      result(price, why, "Sold for " .. money(price or 0))
    end
  elseif id == "nextbus" then
    V.pick.bus = (function()
      local n = cycle(F.free_buses(S, G.now_abs()), V.pick.bus)
      return n and n.id
    end)()
  elseif id == "nextdriver" then
    local free = {}
    for _, d in ipairs(S.drivers) do if not d.assignment then free[#free + 1] = d end end
    local n = cycle(free, V.pick.driver)
    V.pick.driver = n and n.id
  elseif id == "start_ai" or id == "start_me" then
    if not V.sel.tour then return end
    local ok, why = G.assign(V.sel.tour, V.pick.bus, id == "start_ai" and V.pick.driver or nil, id == "start_ai" and "ai" or "player")
    result(ok, why, "Service started.")
  elseif id == "hire" then
    local ok, why = G.hire(V.sel.cand)
    if ok then V.sel.cand = nil end
    result(ok, why, "Hired.")
  elseif id == "fire" then
    if V.sel.driver then G.fire(V.sel.driver); V.sel.driver = nil; say("Dismissed.", true) end
  elseif id == "train" then
    local d = V.sel.driver and D.get(S, V.sel.driver)
    if d then result(D.train(S, d)) end
  elseif id == "raise" then
    local d = V.sel.driver and D.get(S, V.sel.driver)
    if d then D.grant_raise(S, d); say("Raise granted.", true) end
  elseif id == "settings" then
    if settings_fn then settings_fn() end
  elseif id == "reset" then V.confirm = "reset"
  elseif id == "reset_yes" then
    V.confirm = nil
    G.reset_company()
    V.sel = { bus = nil, offer = nil, tour = nil, driver = nil, cand = nil }
    say("A new company has started.", true)
  end
end

return V
