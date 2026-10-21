-- game.lua: the game of the Bus Company add-on. It holds the company state, applies the
-- settings, turns what happens in openOMSI (the clock, tickets sold, trips driven, crashes,
-- the AI buses on the road) into bookings, and offers the actions the panels call.
-- No panel code in here: views.lua draws, main.lua wires the game's events to this file.

local U = require("util")
local B = require("balance")
local Co = require("company")
local Cat = require("catalog")
local F = require("fleet")
local D = require("drivers")
local R = require("routes")

local G = {}

G.S = nil             -- the company
G.cfg = {}            -- the settings (omsi.plugin.settings)
G.notes = {}          -- toasts waiting to be shown: { text, opts }
G.obs = {}            -- the AI buses seen on the road (routes.observe)
G.drive = nil         -- the player's duty in a company bus
G.pending = nil       -- a bus being placed, then the duty to start in it
G.rng = U.rng(1)
G.models = nil        -- the catalogue's buses, read once
G.last_now = nil
G.loaded_day = nil

local function api() return omsi end

function G.notify(text, opts)
  G.notes[#G.notes + 1] = { text = text, opts = opts or {} }
  if #G.notes > 12 then table.remove(G.notes, 1) end
end

-- ---------------------------------------------------------------------------------------
-- Settings and the flow of money
-- ---------------------------------------------------------------------------------------

function G.diff()
  return B.difficulty[G.cfg.difficulty or "Normal"] or B.difficulty.Normal
end

function G.pace() return math.max(0.1, tonumber(G.cfg.pace) or B.pace_default) end

--- Money earned over time (fares, pay from the authority): scaled by the pace and the
--- difficulty. Costs that run with time likewise (wages, fuel, insurance).
function G.inc(x) return x * G.pace() * G.diff().income end
function G.cost(x) return x * G.pace() * G.diff().cost end
--- A one-off cost (a crash, a fine) grows with the pace, but less than the income.
function G.event(x) return x * (G.pace() ^ B.event_pace_exponent) * G.diff().cost end

function G.currency() return G.cfg.currency or "EUR" end
local SYMBOL = { EUR = "€", GBP = "£", USD = "$", PLN = "zł", CHF = "CHF", SEK = "kr", CZK = "Kč" }
function G.symbol() return SYMBOL[G.currency()] or G.currency() end

--- 12345.6 -> "€12,346" (the symbol first; negative amounts get the minus before it).
function G.money(x, decimals)
  local neg = x < 0
  local body
  if decimals and decimals > 0 then
    body = string.format("%." .. decimals .. "f", math.abs(x))
    local int, frac = body:match("^(%d+)(%..*)$")
    body = U.thousands(tonumber(int)) .. frac
  else
    body = U.thousands(math.abs(x))
  end
  return (neg and "-" or "") .. G.symbol() .. body
end

-- ---------------------------------------------------------------------------------------
-- Starting up
-- ---------------------------------------------------------------------------------------

local function has_fleet_api() return api().fleet ~= nil end
G.has_fleet_api = has_fleet_api

--- Reads the saved company (or makes one) and sets everything up. `cfg` is the settings.
function G.init(cfg, saved, seed)
  G.cfg = cfg or {}
  G.rng = U.rng(seed or math.floor((api().util and api().util.now() or os.time()) % 2147483646) + 1)
  if type(saved) == "table" and saved.version == 1 then
    G.S = saved
    -- tables that older saves may lack
    G.S.day_stats = G.S.day_stats or { trips = 0, ontime = 0, missed = 0, accidents = 0, rating_sum = 0, rating_n = 0, km = 0 }
    G.S.known = G.S.known or {}
  else
    G.new_company()
  end
  G.S.known = G.S.known or {}
  G.S.declined = G.S.declined or {}
  for _, a in ipairs(G.S.assignments) do a.taken = a.taken or {} end
  G.S.map = api().map and api().map.name and api().map.name() or G.S.map
  G.liveries_cache = {}
  G.models = nil
  -- the clock moves on from here: the days between sessions cost nothing
  G.S.day_idx = nil
  G.last_now = nil
  G.obs = {}
  G.drive = nil
  G.pending = nil
  return G.S
end

--- A new company with the starting cash and a starter bus (the one the player sits in,
--- or the cheapest standard bus on offer).
function G.new_company(name)
  local cash = tonumber(G.cfg.start_cash) or B.start_cash_default
  G.S = Co.new({ name = name or G.cfg.company_name or "Bus Company", cash = cash })
  G.S.known = {}
  G.S.seed = math.floor(G.rng:range(1, 2000000000))
  D.refresh_pool(G.S, G.rng)
  D.refresh_pool(G.S, G.rng)
  G.give_starter_bus()
  G.give_starter_driver()
  return G.S
end

--- A company starts with one driver on the books (an average candidate, no agency fee), so
--- that its first bus has someone to run it.
function G.give_starter_driver()
  local S = G.S
  local pool = {}
  for _, c in ipairs(S.candidates) do pool[#pool + 1] = c end
  if #pool == 0 then return nil end
  table.sort(pool, function(a, b) return a.skill > b.skill end)
  local d = pool[math.ceil(#pool / 2)]
  U.remove_if(S.candidates, function(c) return c == d end)
  d.hired_day = 0
  S.drivers[#S.drivers + 1] = d
  S.candidates[#S.candidates + 1] = D.generate(S, G.rng)
  table.sort(S.candidates, function(a, b) return a.skill > b.skill end)
  return d
end

function G.give_starter_bus()
  local S = G.S
  local v
  if api().has_vehicle() then
    local file = api().bus.file and api().bus.file()
    if file then
      v = { file = file, name = api().vehicle() or file, manufacturer = api().vehicle_manufacturer and api().vehicle_manufacturer() or "", model = api().vehicle_model and api().vehicle_model() or "" }
    end
  end
  if not v then
    local models = G.models_list()
    -- the first standard bus of the catalogue
    for _, m in ipairs(models) do
      if Cat.spec(m).class == "standard" then v = m; break end
    end
    v = v or models[1]
  end
  if not v then return nil end
  local offer = Cat.used_offer(v, U.rng(S.seed or 7))
  offer.age = 8
  offer.condition = 72
  offer.odometer = 380000
  offer.price = 0
  local b = F.add(S, offer, { livery = G.current_livery() })
  G.notify("Your company starts with a " .. b.name .. " (No. " .. b.number .. ").", { icon = "directions_bus" })
  return b
end

-- ---------------------------------------------------------------------------------------
-- The catalogue and the market
-- ---------------------------------------------------------------------------------------

--- The buses the company may buy: the game's catalogue of installed buses, or - on a game
--- without the fleet API - those the player has been seen in.
function G.models_list(force)
  if G.models and not force then return G.models end
  local out = {}
  if has_fleet_api() then
    local ok, list = pcall(api().fleet.catalog)
    if ok and type(list) == "table" then
      for _, v in ipairs(list) do
        if Cat.is_bus(v) then out[#out + 1] = v end
      end
    end
  end
  if #out == 0 and G.S then
    for _, v in ipairs(G.S.known or {}) do out[#out + 1] = v end
  end
  table.sort(out, function(a, b) return (a.name or ""):lower() < (b.name or ""):lower() end)
  G.models = out
  return out
end

--- Remembers a bus the player was in (the market of a game without the fleet API).
function G.remember_vehicle()
  if not api().has_vehicle() or not api().bus.file then return end
  local file = api().bus.file()
  if not file then return end
  for _, v in ipairs(G.S.known) do
    if v.file == file then return end
  end
  G.S.known[#G.S.known + 1] = {
    file = file, name = api().vehicle() or file,
    manufacturer = api().vehicle_manufacturer and api().vehicle_manufacturer() or "",
    model = api().vehicle_model and api().vehicle_model() or "",
  }
  G.models = nil
end

local function week_of(day_idx) return math.floor(day_idx / 7) end

--- The offers for sale: every model new, and this week's used buses.
--- Returns { new = {...}, used = {...} }.
function G.market()
  local S = G.S
  local models = G.models_list()
  local day = S.day_idx or G.today_idx() or 0
  local week = week_of(day)
  if S.market.week ~= week then
    S.market.week = week
    S.market.used = Cat.weekly_used(models, U.rng((S.seed or 1) + week))
  end
  -- offers whose model is no longer installed go
  local have = {}
  for _, m in ipairs(models) do have[m.file] = true end
  if #models > 0 then
    U.remove_if(S.market.used, function(o) return not have[o.file] end)
  end
  local new = {}
  for _, m in ipairs(models) do new[#new + 1] = Cat.new_offer(m) end
  table.sort(new, function(a, b) return a.price < b.price end)
  return { new = new, used = S.market.used }
end

function G.buy(offer)
  local b, why = F.buy(G.S, offer)
  if not b then return false, why end
  if offer.kind == "used" then
    U.remove_if(G.S.market.used, function(o) return o == offer or (o.file == offer.file and o.price == offer.price and o.age == offer.age) end)
  end
  G.notify("Bought " .. b.name .. " (No. " .. b.number .. ") for " .. G.money(offer.price), { icon = "shopping_cart", color = "#2E7D32" })
  G.autofill()
  return b
end

function G.sell(bus)
  local price, why = F.sell(G.S, bus)
  if not price then return false, why end
  G.notify("Sold " .. bus.name .. " for " .. G.money(price), { icon = "sell" })
  return price
end

-- ---------------------------------------------------------------------------------------
-- Time
-- ---------------------------------------------------------------------------------------

function G.date()
  local d = api().world.date()
  if not d then return nil end
  return d
end

function G.today_idx()
  local d = G.date()
  if not d then return nil end
  return U.day_index(d.year, d.month, d.day)
end

function G.now_abs()
  local t = api().world.time() or 0
  return F.abs_minutes(G.S, t / 60)
end

local function weather_factor()
  local ok, kind, rate = pcall(api().weather.precipitation)
  if not ok then return 1 end
  rate = rate or 0
  if kind == "snow" and rate > 0.3 then return 0.88 end
  if kind == "rain" and rate > 0.3 then return 1.04 end
  return 1
end

--- The price of a ticket on this map, for the AI-run services: the first ordinary ticket
--- the player's bus sells (kept for the map, since on foot there is none to read).
local fare_cache = {}
function G.fare_base()
  local map = api().map.name() or "?"
  if fare_cache[map] then return fare_cache[map] end
  local ok, list = pcall(api().bus.tickets)
  if ok and type(list) == "table" then
    local best
    for _, t in ipairs(list) do
      if not t.day_ticket and t.price and t.price > 0 and (not best or t.price < best) then best = t.price end
    end
    if best then fare_cache[map] = best; return best end
  end
  return B.default_fare
end

-- ---------------------------------------------------------------------------------------
-- AI-run services
-- ---------------------------------------------------------------------------------------

local function book_flow(cat, x, memo, note) Co.book(G.S, cat, x, memo, note) end

--- Settles one trip of an AI-run tour.
function G.settle_trip(a, trip, jumped)
  local S = G.S
  local bus = F.get(S, a.bus)
  local driver = D.get(S, a.driver)
  if not bus or not driver then return end
  F.refresh(bus, G.now_abs())
  if bus.status == "workshop" then
    -- the bus is not there: the trip is not run
    S.day_stats.missed = S.day_stats.missed + 1
    S.stats.missed = S.stats.missed + 1
    a.stats.missed = a.stats.missed + 1
    Co.reputation_hit(S, -0.4)
    return
  end
  local obs = R.take_obs(G.obs, a.line, a.tour, trip.start)
  local date = G.date()
  local res = R.settle_ai_trip({
    spec = bus.spec, condition = bus.condition, driver = driver, trip = trip,
    demand = a.demand, fare = a.fare, rep = Co.demand_factor(S), fare_base = G.fare_base(),
    energy = S.energy, weekday = date and date.weekday or 1, weather = weather_factor(),
    observed = obs, rng = G.rng, hours = a.shift_hours,
  })
  local memo = "Line " .. a.line .. "/" .. a.tour
  F.drive(bus, res.km)
  S.stats.km = S.stats.km + res.km
  S.day_stats.km = S.day_stats.km + res.km

  if res.breakdown then
    local tow = G.event(B.towing_cost)
    book_flow("accidents", -tow, "Breakdown of " .. bus.name .. " on " .. memo, true)
    F.damage(bus, 3)
    bus.status = "workshop"
    bus.workshop_until = G.now_abs() + 180
    Co.reputation_hit(S, -1.2)
    S.stats.breakdowns = S.stats.breakdowns + 1
    S.stats.missed = S.stats.missed + 1
    S.day_stats.missed = S.day_stats.missed + 1
    a.stats.missed = a.stats.missed + 1
    a.today.costs = a.today.costs + tow
    G.notify("Breakdown: " .. bus.name .. " (No. " .. bus.number .. ") on line " .. a.line .. ". Towed to the workshop.", { icon = "build", color = "#C62828" })
    return
  end

  local fares, subsidy = G.inc(res.fares), G.inc(res.subsidy)
  local fuel, maint = G.cost(res.fuel), G.cost(res.maint)
  book_flow("fares", fares)
  book_flow("subsidy", subsidy)
  book_flow("fuel", -fuel)
  book_flow("maintenance", -maint)
  a.today.trips = a.today.trips + 1
  a.today.revenue = a.today.revenue + fares + subsidy
  a.today.costs = a.today.costs + fuel + maint
  a.stats.trips = a.stats.trips + 1
  a.stats.revenue = a.stats.revenue + fares + subsidy
  a.stats.costs = a.stats.costs + fuel + maint
  S.stats.trips = S.stats.trips + 1
  S.stats.pax = S.stats.pax + math.floor(res.pax + 0.5)
  S.day_stats.trips = S.day_stats.trips + 1
  if res.ontime then
    a.stats.ontime = a.stats.ontime + 1
    S.stats.ontime = S.stats.ontime + 1
    S.day_stats.ontime = S.day_stats.ontime + 1
  else
    a.stats.late = a.stats.late + 1
    S.stats.late = S.stats.late + 1
  end
  if res.overcrowded then Co.reputation_hit(S, -0.05) end
  -- the driver's courtesy shows in how people rate the service
  S.day_stats.rating_sum = S.day_stats.rating_sum + (driver.courtesy + driver.skill) / 2
  S.day_stats.rating_n = S.day_stats.rating_n + 1

  if res.accident then
    local cost = G.event(res.accident)
    local mine = math.min(cost, G.event(B.insurance_deductible)) + math.max(0, cost - G.event(B.insurance_deductible)) * (1 - B.insurance_cover)
    book_flow("accidents", -mine, "Accident of " .. driver.name .. " on " .. memo, true)
    F.damage(bus, 4)
    Co.reputation_hit(S, -B.accident_reputation)
    S.stats.accidents = S.stats.accidents + 1
    S.day_stats.accidents = S.day_stats.accidents + 1
    driver.morale = math.max(0, driver.morale - 6)
    G.notify(driver.name .. " had an accident on line " .. a.line .. " (" .. G.money(mine) .. " after insurance).", { icon = "warning", color = "#C62828" })
  end
end

--- Looks at the AI buses on the road (their distance and delay), twice a minute.
function G.poll_buses()
  if not G.S or not api().timetable then return end
  local ok, rows = pcall(api().timetable.buses)
  if ok then R.observe(G.obs, rows) end
end

--- The per-minute work: the books of the day, the trips that have ended.
function G.tick_minute()
  local S = G.S
  if not S then return end
  local date = G.date()
  if not date then return end
  local idx = U.day_index(date.year, date.month, date.day)
  if S.day_idx == nil then S.day_idx = idx end
  if idx > S.day_idx then
    local gap = math.min(3, idx - S.day_idx)
    for _ = 1, gap do G.close_day(date) end
    S.day_idx = idx
    G.last_now = nil
    G.autofill()
  elseif idx < S.day_idx then
    -- the date was set back: the books follow it without a close
    S.day_idx = idx
    G.last_now = nil
  end
  local now = api().world.time() or 0
  local jumped = G.last_now ~= nil and (now - G.last_now) > 300
  G.last_now = now
  if S.bankrupt then return end

  local now_abs = F.abs_minutes(S, now / 60)
  for _, b in ipairs(S.fleet) do F.refresh(b, now_abs) end

  for _, a in ipairs(S.assignments) do
    if a.mode == "ai" then
      local tour = R.find_tour(a.key)
      if tour and tour.today then
        local trips = R.schedule(a.line, a.tour)
        for _, t in ipairs(R.due_trips(a, trips, idx, now, jumped)) do
          G.settle_trip(a, t, jumped)
        end
      end
    end
  end
  R.prune_obs(G.obs, now)
end

--- A day ends: the fixed costs, the wages, the interest, tax at the turn of a month.
function G.close_day(date)
  local S = G.S
  if S.bankrupt then return end
  local diff = G.diff()
  F.age_day(S)
  local ins = G.cost(F.insurance_per_day(S))
  local over = G.cost(F.overhead_per_day(S))
  Co.book(S, "insurance", -U.round(ins, 2), "Insurance")
  Co.book(S, "overhead", -U.round(over, 2), "Depot and admin")
  for _, a in ipairs(S.assignments) do
    if a.mode == "ai" then
      local d = D.get(S, a.driver)
      if d and (a.today.trips > 0) then d.hours_today = a.shift_hours end
    end
  end
  D.close_day(S, G.rng, G.pace() * diff.cost)
  -- the workshop at night, for buses below the company's limit
  local limit = tonumber(G.cfg.auto_service) or B.service_threshold_default
  if limit > 0 then
    for _, b in ipairs(S.fleet) do
      if b.condition < limit and b.status ~= "workshop" then
        local cost = G.cost(F.service_cost(b))
        if S.cash >= cost then
          Co.book(S, "maintenance", -U.round(cost, 2), "Overnight service: " .. b.name .. " (" .. b.number .. ")")
          b.condition = 100
        end
      end
    end
  end
  for _, a in ipairs(S.assignments) do R.new_day(a) end

  local out = Co.close_day(S, G.rng, date, F.avg_condition(S))
  if out.week then
    local quit, ask = D.close_week(S, G.rng)
    for _, d in ipairs(quit) do
      local a = R.get(S, d.assignment or "")
      if a then R.unassign(S, a); G.engine_unassign(a) end
      G.notify(d.name .. " has quit: nobody pays well enough.", { icon = "person_remove", color = "#C62828" })
    end
    for _, d in ipairs(ask) do
      G.notify(d.name .. " asks for a raise to " .. G.money(D.market_wage(d.skill), 2) .. "/h.", { icon = "request_quote" })
    end
    D.refresh_pool(S, G.rng)
    S.market.week = -1
  end
  local text = "Day closed: " .. G.money(out.net or 0) .. " (cash " .. G.money(S.cash) .. ")"
  if out.month then
    text = text .. string.format(". Month: %s, tax %s.", G.money(out.month_result or 0), G.money(out.tax or 0))
  end
  G.notify(text, { icon = "account_balance", title = S.name, color = (out.net or 0) >= 0 and "#2E7D32" or "#C62828" })
  if out.warning then
    G.notify("The bank is watching: cash is below the overdraft limit (" .. out.warning .. "/" .. B.bankrupt_days .. " days).", { icon = "warning", color = "#C62828" })
  end
  if out.bankrupt and G.cfg.bankruptcy ~= false then G.go_bankrupt() end
end

function G.go_bankrupt()
  local S = G.S
  -- the bank takes the buses at their resale value
  local seized = 0
  for _, b in ipairs(S.fleet) do seized = seized + F.resale(b) end
  for _, a in ipairs(S.assignments) do G.engine_unassign(a) end
  S.fleet, S.assignments = {}, {}
  for _, d in ipairs(S.drivers) do d.assignment = nil end
  Co.book(S, "sale", seized, "Repossessed by the bank", true)
  S.bankrupt = true
  G.notify("The company is insolvent. The bank has taken the fleet.", { icon = "gavel", color = "#C62828", seconds = 15 })
end

-- ---------------------------------------------------------------------------------------
-- The player's own driving
-- ---------------------------------------------------------------------------------------

--- The company bus the player is sitting in, or nil.
function G.player_bus()
  if not G.S or not api().has_vehicle() then return nil end
  local file = api().bus.file and api().bus.file()
  if G.drive and G.drive.bus_id then
    local b = F.get(G.S, G.drive.bus_id)
    if b and file and b.file:lower():gsub("\\", "/") == file:lower():gsub("\\", "/") then return b end
  end
  local day = G.S.day_idx or G.today_idx() or 0
  return F.by_file(G.S, file, function(b)
    local a = b.assignment and R.get(G.S, b.assignment)
    return a and R.player_can(a, day)
  end)
end

--- Whether the plugin should count what the player earns now.
function G.player_operating()
  return G.S and not G.S.bankrupt and G.player_bus() ~= nil
end

function G.on_ticket(name, price)
  if not G.player_operating() then return end
  Co.book(G.S, "fares", G.inc(price))
end

function G.on_crash(kj, speed)
  if not G.player_operating() or (kj or 0) < 2 then return end
  local S = G.S
  local bus = G.player_bus()
  local cost = G.event(kj * B.crash_cost_per_kj)
  local ded = G.event(B.insurance_deductible)
  local mine = math.min(cost, ded) + math.max(0, cost - ded) * (1 - B.insurance_cover)
  Co.book(S, "accidents", -U.round(mine, 2), string.format("Crash of %s: %.0f kJ", bus.name, kj), mine >= 500)
  F.damage(bus, math.min(25, kj / 12))
  local heavy = kj > 50
  Co.reputation_hit(S, heavy and -1.5 or -0.3)
  S.stats.accidents = S.stats.accidents + 1
  S.day_stats.accidents = S.day_stats.accidents + 1
  G.notify(string.format("Crash: %.0f kJ. The repair costs you %s after insurance.", kj, G.money(mine)), { icon = "car_crash", color = "#C62828" })
end

function G.on_pedestrian()
  if not G.player_operating() then return end
  local fine = G.event(B.pedestrian_fine)
  Co.book(G.S, "fines", -fine, "Pedestrian hit", true)
  Co.reputation_hit(G.S, -8)
  G.S.stats.accidents = G.S.stats.accidents + 1
  G.S.day_stats.accidents = G.S.day_stats.accidents + 1
  G.notify("A pedestrian was hurt. Fine: " .. G.money(fine), { icon = "emergency", color = "#C62828" })
end

local last_red = -100
function G.on_red_light()
  if not G.player_operating() then return end
  local t = api().time()
  if t - last_red < 20 then return end
  last_red = t
  local fine = G.event(B.red_light_fine)
  Co.book(G.S, "fines", -fine, "Red light")
  Co.reputation_hit(G.S, -0.5)
  G.notify("Red light run: fine " .. G.money(fine), { icon = "traffic", color = "#C62828" })
end

--- The player refuels, washes or repairs by the game menu: the company pays the bill.
function G.on_service(kind, by, amount)
  if by == "plugin" or not G.player_operating() then return end
  local S = G.S
  local bus = G.player_bus()
  amount = amount or 0
  if kind == "refuel" and amount > 0 then
    local price = S.energy[bus.spec.energy] or 1
    Co.book(S, "fuel", -G.cost(amount * price * B.refuel_markup), "Refuelled " .. bus.name)
  elseif kind == "wash" then
    Co.book(S, "maintenance", -G.cost(B.wash_cost), "Wash")
  elseif kind == "repair" then
    local cost = G.event(B.repair_base + B.repair_per_minute * amount)
    Co.book(S, "maintenance", -cost, "Repair of " .. bus.name, cost >= B.notable_amount)
    bus.condition = math.min(100, bus.condition + 30)
  end
end

--- Keeps the odometer and the wear of the bus the player drives.
local last_odo
function G.poll_player()
  local bus = G.player_bus()
  if not bus or not api().bus.odometer then last_odo = nil; return end
  local odo = api().bus.odometer()
  if odo and last_odo and odo >= last_odo and odo - last_odo < 5 then
    local km = odo - last_odo
    F.drive(bus, km)
    G.S.stats.km = G.S.stats.km + km
  end
  last_odo = odo
end

function G.on_vehicle(name)
  last_odo = nil
  G.remember_vehicle()
  if G.pending and name and not (G.has_fleet_api() and api().fleet.busy and api().fleet.busy()) then
    local p = G.pending
    G.pending = nil
    G.start_duty(p.key, p.trip)
  end
end

function G.on_stop_event(name, id, number, delay)
  if G.drive then G.drive.last_delay = delay end
end

--- The player's duty is on a tour the AI runs: the trip under way is theirs, not the AI's.
function G.take_current_trip(a)
  if a.mode ~= "ai" or not api().duty.get then return end
  local d = api().duty.get()
  if not d or not d.trip then return end
  local t = R.schedule(a.line, a.tour)[d.trip]
  if t then R.take_trip(a, t.n, G.S.day_idx or G.today_idx() or 0) end
end

function G.on_trip_start()
  if G.drive then
    G.drive.odo0 = api().bus.odometer and api().bus.odometer() or nil
    local a = R.get(G.S, G.drive.key)
    if a then G.take_current_trip(a) end
  end
end

local function same_file(a, b)
  return a and b and a:lower():gsub("\\", "/") == b:lower():gsub("\\", "/")
end

function G.on_duty_start(line, tour)
  local a = R.get(G.S, R.key(line, tour))
  local file = api().bus.file and api().bus.file()
  local bus = a and F.get(G.S, a.bus)
  if a and bus and same_file(bus.file, file) then
    -- the company's bus on the company's tour (an AI tour: the trip is taken over)
    G.drive = { key = a.key, bus_id = bus.id, last_delay = 0 }
    G.on_trip_start()
  else
    G.drive = nil
    if api().has_vehicle() then
      G.notify("This duty is not one of your company's, or not in its bus: nothing is earned on it.", { icon = "info" })
    end
  end
end

function G.on_duty_end() G.drive = nil end

--- A trip of the duty ended: the authority pays by distance and punctuality.
function G.on_trip_done(trip, how, driving, comfort, tickets)
  local S = G.S
  if not G.drive or S.bankrupt then return end
  local a = R.get(S, G.drive.key)
  if not a then return end
  local bus = F.get(S, G.drive.bus_id)
  local memo = "Line " .. a.line .. "/" .. a.tour
  if how == "arrived" then
    local km
    local odo = api().bus.odometer and api().bus.odometer()
    if odo and G.drive.odo0 and odo > G.drive.odo0 then km = odo - G.drive.odo0 end
    if not km or km > 80 then
      local sched = R.schedule(a.line, a.tour)
      local t = sched[trip] or sched[1]
      km = t and (t.duration / 3600 * B.urban_speed_kmh) or 5
    end
    local delay = G.drive.last_delay or 0
    local pay, quality = R.player_trip_pay(km, delay, driving, comfort)
    pay = G.inc(pay)
    Co.book(S, "subsidy", pay, memo .. ": trip " .. trip)
    local ontime = delay <= B.on_time_limit
    S.stats.trips = S.stats.trips + 1
    S.day_stats.trips = S.day_stats.trips + 1
    a.stats.trips = a.stats.trips + 1
    a.stats.revenue = a.stats.revenue + pay
    a.today.trips = a.today.trips + 1
    a.today.revenue = a.today.revenue + pay
    if ontime then
      S.stats.ontime = S.stats.ontime + 1; S.day_stats.ontime = S.day_stats.ontime + 1; a.stats.ontime = a.stats.ontime + 1
    else
      S.stats.late = S.stats.late + 1; a.stats.late = a.stats.late + 1
    end
    S.day_stats.rating_sum = S.day_stats.rating_sum + ((driving or 70) + (comfort or 70)) / 2
    S.day_stats.rating_n = S.day_stats.rating_n + 1
    G.notify(string.format("Trip %s done: %s from the authority (%s).", tostring(trip), G.money(pay), ontime and "on time" or "late"), { icon = "payments", color = "#2E7D32" })
    if bus then
      bus.condition = bus.condition  -- wear is booked as the bus drives (poll_player)
    end
  else
    local fine = G.event(B.missed_trip_fine)
    Co.book(S, "fines", -fine, memo .. ": trip " .. trip .. " " .. tostring(how))
    Co.reputation_hit(S, -1.5)
    S.stats.missed = S.stats.missed + 1
    S.day_stats.missed = S.day_stats.missed + 1
    a.stats.missed = a.stats.missed + 1
    G.notify("Trip " .. trip .. " not driven: penalty " .. G.money(fine), { icon = "warning", color = "#C62828" })
  end
  G.drive.last_delay = 0
end

-- ---------------------------------------------------------------------------------------
-- Operating a tour: the actions of the Routes panel
-- ---------------------------------------------------------------------------------------

function G.engine_assign(a)
  local bus = F.get(G.S, a.bus)
  if a.mode ~= "ai" or not bus or not has_fleet_api() or not api().fleet.assign then return end
  pcall(api().fleet.assign, a.line, a.tour, bus.file, { number = bus.number, paint = bus.livery })
end

function G.engine_unassign(a)
  if has_fleet_api() and api().fleet.unassign then pcall(api().fleet.unassign, a.line, a.tour) end
end

--- Puts the engine's AI tours back in line with the company's assignments (at the start
--- of a session and after a map change: the game forgot them).
function G.sync_engine()
  if not G.S then return end
  for _, a in ipairs(G.S.assignments) do G.engine_assign(a) end
end

function G.now_info()
  return { day_idx = G.S.day_idx or G.today_idx() or 0, time = api().world.time() or 0 }
end

function G.assign(tour_key, bus_id, driver_id, mode)
  local S = G.S
  local tour = R.find_tour(tour_key)
  if not tour then return false, "No such tour on this map" end
  local bus = F.get(S, bus_id)
  if not bus then return false, "Choose a bus" end
  local driver = driver_id and D.get(S, driver_id) or nil
  local a, why = R.assign(S, tour, bus, driver, mode, G.now_info())
  if not a then return false, why end
 S.declined[tour_key] = nil
  G.engine_assign(a)
  G.notify("Line " .. a.line .. "/" .. a.tour .. " is now run " .. (mode == "ai" and ("by " .. driver.name) or "by you") .. " with No. " .. bus.number .. ".", { icon = "route" })
  return a
end

function G.unassign(key)
  local a = R.get(G.S, key)
  if not a then return false end
  if G.drive and G.drive.key == key then
    api().duty.finish()
    G.drive = nil
  end
  G.engine_unassign(a)
  R.unassign(G.S, a)
  G.S.declined[key] = true     -- stopped by hand: the automatic allocation leaves it alone
  return true
end

function G.set_fare(key, level)
  local a = R.get(G.S, key)
  if a then a.fare = U.round(U.clamp(level, B.fare_min, B.fare_max), 2) end
end

--- The trip of a tour that is next to leave (or running now): its index in the order they
--- leave, from 1.
function G.next_trip(a)
  local trips = R.schedule(a.line, a.tour)
  local now = api().world.time() or 0
  for i, t in ipairs(trips) do
    if t.finish > now then return i, t end
  end
  return #trips > 0 and #trips or nil, trips[#trips]
end

--- Drives a tour (or one trip of it, `trip` from 1 in the order they leave): gets into its
--- bus (placing it, with the fleet API), then takes the duty. On a tour the AI runs, the
--- trip is taken over from the AI for today; on a tour of the player's own, any trip is free.
function G.drive_tour(key, trip)
  local S = G.S
  local a = R.get(S, key)
  if not a then return false, "That tour is not operated by the company" end
  local bus = F.get(S, a.bus)
  if not bus then return false, "The tour has no bus" end
  F.refresh(bus, G.now_abs())
  if bus.status == "workshop" then return false, "The bus is in the workshop" end
  if not trip then trip = G.next_trip(a) end
  local trips = R.schedule(a.line, a.tour)
  if a.mode == "ai" and (not trip or not trips[trip]) then return false, "Choose a trip to drive" end
  local file = api().bus.file and api().bus.file()
  local same = file and file:lower():gsub("\\", "/") == bus.file:lower():gsub("\\", "/")
  G.drive = { key = key, bus_id = bus.id, last_delay = 0, trip = trip }
  if api().has_vehicle() and same then
    return G.start_duty(key, trip)
  end
  if has_fleet_api() and api().fleet.place then
    local ok, why = api().fleet.place(bus.file, { swap = api().has_vehicle(), paint = bus.livery })
    if not ok then G.drive = nil; return false, why or "The game could not place the bus" end
    G.pending = { key = key, trip = trip, since = api().time() }
    return true, "Getting into " .. bus.name .. " ..."
  end
  G.drive = nil
  return false, "This openOMSI cannot swap buses: choose " .. bus.name .. " in the game menu (Esc, Swap), then press Drive again"
end

function G.start_duty(key, trip)
  local S = G.S
  local a = R.get(S, key)
  if not a then return false end
  local day = S.day_idx or G.today_idx() or 0
  local took = false
  -- a trip of an AI-run tour is the player's from now on (the event that says the duty
  -- began comes at once, and needs it)
  if a.mode == "ai" and trip then
    local t = R.schedule(a.line, a.tour)[trip]
    if t then
      took = a.taken[tostring(t.n)] ~= day
      R.take_trip(a, t.n, day)
    end
  end
  local ok, why = api().duty.start(a.line, a.tour, trip)
  if not ok then
    if took then
      local t = R.schedule(a.line, a.tour)[trip]
      if t then a.taken[tostring(t.n)] = nil; a.settled[tostring(t.n)] = nil end
    end
    G.drive = nil
    G.notify("The duty could not start: " .. tostring(why), { icon = "warning", color = "#C62828" })
    return false, why
  end
  if took then
    G.notify("You take trip " .. tostring(trip) .. " of line " .. a.line .. "/" .. a.tour .. " over from the AI driver.", { icon = "swap_horiz" })
  end
  return true
end

--- Gives up waiting for a bus that never arrived.
function G.check_pending()
  if G.pending and api().time() - G.pending.since > 60 then
    G.pending = nil
    G.drive = nil
    G.notify("The bus did not arrive.", { icon = "warning" })
  end
end

-- ---------------------------------------------------------------------------------------
-- Who runs what: allocation by the company, and by hand
-- ---------------------------------------------------------------------------------------

--- Allocates free buses and drivers to the tours that run today and have nobody. Runs by
--- itself (setting "Auto-allocate tours") at the start of a session and day and when a bus
--- or a driver joins; `force` (the Routes tab's button) also takes back tours the player
--- stopped. Returns how many tours it staffed and how many are left without.
function G.autofill(force)
  local S = G.S
  if not S or S.bankrupt then return 0, 0 end
  if not force and G.cfg.auto_allocate == false then return 0, 0 end
  local tours = {}
  for _, t in ipairs(R.scan()) do
    if t.today and t.trips > 0 and not R.get(S, t.key) and (force or not S.declined[t.key]) then
      tours[#tours + 1] = t
    end
  end
  if #tours == 0 then return 0, 0 end
  if force then S.declined = {} end
  local drivers = {}
  for _, d in ipairs(S.drivers) do if not d.assignment then drivers[#drivers + 1] = d end end
  local plan, left = R.plan_allocation(tours, F.free_buses(S, G.now_abs()), drivers)
  local info = G.now_info()
  local n = 0
  for _, p in ipairs(plan) do
    local a = R.assign(S, p.tour, p.bus, p.driver, "ai", info, true)
    if a then n = n + 1; G.engine_assign(a) end
  end
  if n > 0 then
    G.notify(n .. " tour" .. (n == 1 and " is" or "s are") .. " staffed with a bus and an AI driver."
      .. (#left > 0 and (" " .. #left .. " more need a bus and a driver.") or ""), { icon = "route" })
  elseif force then
    G.notify("Nothing to allocate: every tour has a bus and driver, or you are out of free buses or drivers.", { icon = "info" })
  end
  return n, #left
end

--- How many of today's tours have no bus and driver.
function G.uncovered()
  local n = 0
  for _, t in ipairs(R.scan()) do
    if t.today and t.trips > 0 and not R.get(G.S, t.key) then n = n + 1 end
  end
  return n
end

--- Changes the bus and/or the driver of an operated tour (nil keeps the present one).
function G.reassign(key, bus_id, driver_id)
  local S = G.S
  local a = R.get(S, key)
  if not a then return false, "That tour is not operated" end
  local bus = bus_id and F.get(S, bus_id) or nil
  local driver = driver_id and D.get(S, driver_id) or nil
  local ok, why = R.reassign(S, a, bus, driver)
  if not ok then return false, why end
  G.engine_assign(a)
  return true
end

--- Hands a tour to the player (`"player"`) or back to an AI driver.
function G.set_mode(key, mode, driver_id)
  local S = G.S
  local a = R.get(S, key)
  if not a then return false, "That tour is not operated" end
  local ok, why = R.set_mode(S, a, mode, driver_id and D.get(S, driver_id) or nil)
  if not ok then return false, why end
  if mode == "player" then G.engine_unassign(a) else G.engine_assign(a) end
  return true
end

-- ---------------------------------------------------------------------------------------
-- Liveries
-- ---------------------------------------------------------------------------------------

function G.has_liveries()
  return has_fleet_api() and api().fleet.liveries ~= nil and api().fleet.repaint ~= nil
end

--- The liveries of a bus file (read once per file: the game reads the model's files for it).
function G.liveries(file)
  if not G.has_liveries() or not file then return {} end
  G.liveries_cache = G.liveries_cache or {}
  local key = file:lower()
  if G.liveries_cache[key] then return G.liveries_cache[key] end
  local ok, list = pcall(api().fleet.liveries, file)
  local out = {}
  if ok and type(list) == "table" then
    for _, n in ipairs(list) do out[#out + 1] = tostring(n) end
  end
  G.liveries_cache[key] = out
  return out
end

--- The livery the driven bus wears now (nil: the model's own textures, or no bus).
function G.current_livery()
  if not has_fleet_api() or not api().fleet.livery or not api().has_vehicle() then return nil end
  local ok, v = pcall(api().fleet.livery)
  return ok and v or nil
end

--- Repaints the bus the player sits in, live (the game reads it again and puts it where it
--- stands). `name` nil: the model's own textures. A company bus remembers it.
function G.repaint(name)
  if not G.has_liveries() then return false, "This openOMSI cannot repaint buses (it lacks omsi.fleet.repaint)" end
  if not api().has_vehicle() then return false, "Get into a bus first" end
  local ok, why = api().fleet.repaint(name)
  if not ok then return false, why or "The game could not repaint the bus" end
  local bus = G.player_bus() or (G.S and F.by_file(G.S, api().bus.file and api().bus.file()))
  if bus then bus.livery = name end
  G.notify(name and ("Repainting in " .. name .. " ...") or "Repainting in the original paint ...", { icon = "format_paint" })
  return true
end

--- The company's livery for one bus (it has it when it next runs a tour and is placed).
function G.set_livery(bus, name)
  bus.livery = name
  local a = bus.assignment and R.get(G.S, bus.assignment)
  if a and a.mode == "ai" then G.engine_assign(a) end
end

--- Every company bus of this model gets the livery.
function G.set_livery_model(file, name)
  local n = 0
  local lf = file:lower():gsub("\\", "/")
  for _, b in ipairs(G.S.fleet) do
    if b.file:lower():gsub("\\", "/") == lf then G.set_livery(b, name); n = n + 1 end
  end
  return n
end

-- ---------------------------------------------------------------------------------------
-- People, money
-- ---------------------------------------------------------------------------------------

function G.hire(id)
  local d, why = D.hire(G.S, id)
  if not d then return false, why end
  G.notify("Hired " .. d.name .. " at " .. G.money(d.wage, 2) .. "/h.", { icon = "person_add", color = "#2E7D32" })
  G.autofill()
  return d
end

function G.fire(driver_id)
  local d = D.get(G.S, driver_id)
  if not d then return false end
  if d.assignment then
    local a = R.get(G.S, d.assignment)
    if a then R.unassign(G.S, a); G.engine_unassign(a) end
  end
  local pay = D.fire(G.S, d)
  G.notify(d.name .. " left. Severance: " .. G.money(pay), { icon = "person_remove" })
  return true
end

function G.borrow(amount)
  local ok, why = Co.borrow(G.S, amount, F.total_value(G.S))
  if ok then G.notify("Loan of " .. G.money(amount) .. " at " .. string.format("%.1f %%", Co.loan_rate(G.S) * 100) .. " a year.", { icon = "account_balance" }) end
  return ok, why
end

function G.repay(amount)
  return Co.repay(G.S, amount)
end

--- Sends the player's own bus to the workshop (or, for a bus on the road, overnight): the
--- game's own service commands do the visible part.
function G.service_bus(bus)
  local cost = G.cost(F.service_cost(bus))
  if G.S.cash < cost then return false, "Not enough cash" end
  local was = bus.status
  local ok, why = F.service(G.S, bus, G.now_abs(), B.service_hours)
  if not ok then return false, why end
  -- F.service books the base price; the pace scales it
  local extra = cost - F.service_cost(bus)
  if extra ~= 0 then
    Co.book(G.S, "maintenance", -extra, "Workshop pace adjustment")
  end
  if G.player_bus() == bus then
    pcall(api().command, "repair")
    pcall(api().command, "wash")
    pcall(api().command, "refuel")
  end
  return true
end

function G.reset_company()
  for _, a in ipairs(G.S and G.S.assignments or {}) do G.engine_unassign(a) end
  local known = G.S and G.S.known or {}
  local name = G.S and G.S.name
  G.new_company(name)
  G.S.known = known
  G.S.day_idx = nil
  G.drive, G.pending, G.obs = nil, nil, {}
  G.models = nil
end

-- ---------------------------------------------------------------------------------------
-- What needs the player's attention
-- ---------------------------------------------------------------------------------------

function G.alerts()
  local S = G.S
  local out = {}
  if S.bankrupt then
    out[#out + 1] = { text = "The company is insolvent.", color = "#C62828" }
    return out
  end
  if S.cash < 0 then
    out[#out + 1] = { text = "You are overdrawn (" .. G.money(S.cash) .. "): interest runs at " .. string.format("%.0f %%", B.overdraft_rate * 100) .. " a year.", color = "#C62828" }
  end
  for _, b in ipairs(S.fleet) do
    if b.condition < 40 then
      out[#out + 1] = { text = string.format("No. %s %s is worn out (%.0f %%): service it.", b.number, U.cut(b.name, 22), b.condition), color = "#F9A825" }
    end
  end
  local idle_bus = #F.free_buses(S, G.now_abs())
  local free_drivers = 0
  for _, d in ipairs(S.drivers) do if not d.assignment then free_drivers = free_drivers + 1 end end
  local open = G.uncovered()
  if open > 0 then
    if idle_bus > 0 and free_drivers > 0 then
      out[#out + 1] = { text = open .. " tour" .. (open == 1 and "" or "s") .. " today without a bus and driver: Routes tab, Allocate all.", color = "#1E88E5" }
    else
      out[#out + 1] = { text = open .. " tour" .. (open == 1 and "" or "s") .. " today without a bus and driver: " .. (idle_bus == 0 and "buy a bus" or "hire a driver") .. ".", color = "#1E88E5" }
    end
  end
  for _, d in ipairs(S.drivers) do
    if D.wants_raise(d) then
      out[#out + 1] = { text = d.name .. " wants a raise (" .. G.money(D.market_wage(d.skill), 2) .. "/h).", color = "#F9A825" }
    end
  end
  if #out == 0 then out[1] = { text = "Everything runs smoothly.", color = "#2E7D32" } end
  return out
end

return G
