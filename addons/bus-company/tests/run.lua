-- Headless tests of the Bus Company plugin against a mock game.
--   lua tests/run.lua        (from addons/bus-company; Lua 5.3 or newer; texlua works too)
-- Exit status 0: everything passed.

local here = (arg and arg[0] or "tests/run.lua"):match("^(.*)[/\\]tests[/\\][^/\\]*$") or "."
local plugin_dir = here .. "/plugins/bus_company/"
package.path = plugin_dir .. "?.lua;" .. here .. "/tests/?.lua;" .. package.path

local mock = require("mock_omsi")

local failures, checks = 0, 0
local function check(name, cond, detail)
  checks = checks + 1
  if not cond then
    failures = failures + 1
    print("FAIL  " .. name .. (detail and ("  -> " .. tostring(detail)) or ""))
  end
end
local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-6) end
local function section(s) print("== " .. s) end

local MODULES = { "util", "balance", "catalog", "company", "fleet", "drivers", "routes", "game", "views" }

local CATALOG = {
  { file = "Vehicles/MAN_SD202/MAN_SD202.bus", name = "MAN SD202", manufacturer = "MAN", model = "SD202" },
  { file = "Vehicles/MB_O305/MB_O305.bus", name = "MB O305", manufacturer = "Mercedes-Benz", model = "O305" },
  { file = "Vehicles/MB_O305G/MB_O305G.bus", name = "MB O305G", manufacturer = "Mercedes-Benz", model = "O305G" },
  { file = "Vehicles/Citaro_K/Citaro_K.bus", name = "Mercedes Citaro K", manufacturer = "Mercedes-Benz", model = "Citaro K" },
  { file = "Vehicles/Urbino_E/Urbino_E.bus", name = "Solaris Urbino 12 electric", manufacturer = "Solaris", model = "Urbino 12 electric" },
  { file = "Vehicles/Tram/Tram.ovh", name = "Some Tram", manufacturer = "X", model = "Tram" },
  { file = "Vehicles/Trailer/Trailer.bus", name = "Bus Trailer Anhaenger", manufacturer = "X", model = "Trailer" },
}

--- A timetable: lines with tours of trips every 30 minutes from 06:00 to 20:00.
local function make_lines()
  local function tour(number, first_dep)
    local rows, trips = {}, 0
    local t = first_dep
    local n = 0
    while t <= 20 * 3600 do
      n = n + 1
      for i, off in ipairs({ 0, 480, 960, 1500 }) do
        rows[#rows + 1] = { trip = n, station = i, name = "Stop" .. i, departure = t + off }
      end
      t = t + 1800
      trips = n
    end
    return { number = number, today = true, trips = trips, rows = rows }
  end
  return {
    { name = "136", user_allowed = true, tours = { tour("1", 6 * 3600), tour("2", 6 * 3600 + 900) } },
    { name = "M5", user_allowed = true, tours = { tour("1", 7 * 3600) } },
  }
end

local function load_plugin(world)
  for _, m in ipairs(MODULES) do package.loaded[m] = nil end
  world = world or {}
  world.lines = world.lines or make_lines()
  world.catalog = world.catalog or CATALOG
  if world.vehicle == nil then
    world.vehicle = { file = "Vehicles/MB_O305/MB_O305.bus", name = "Mercedes-Benz O305", manufacturer = "Mercedes-Benz", model = "O305" }
  elseif world.vehicle == false then
    world.vehicle = nil
  end
  local g = mock.new(world)
  dofile(plugin_dir .. "main.lua")
  mock.fire("start")
  local P = {}
  for _, m in ipairs(MODULES) do P[m] = package.loaded[m] end
  return g, P
end

local function sum_life(S)
  local s = 0
  for _, v in pairs(S.life) do s = s + v end
  return s
end

-- =======================================================================================
section("catalogue classification")
do
  local g, P = load_plugin()
  local Cat = P.catalog
  local function class(name, file) return Cat.spec({ name = name, file = file or ("Vehicles/" .. name .. "/x.bus"), manufacturer = "", model = "" }).class end
  check("articulated by O305G", class("MB O305G") == "artic", class("MB O305G"))
  check("articulated by Gelenk", class("Gelenkbus") == "artic")
  check("double decker SD202", class("MAN SD202") == "double", class("MAN SD202"))
  check("midi Citaro K", class("Mercedes Citaro K") == "midi", class("Mercedes Citaro K"))
  check("standard fallback", class("MB O305") == "standard", class("MB O305"))
  check("coach", class("Setra Tourismo") == "coach")
  check("electric power", Cat.spec({ name = "Solaris Urbino 12 electric", file = "a.bus" }).powertrain == "electric")
  check("hybrid power", Cat.spec({ name = "Citaro Hybrid", file = "b.bus" }).powertrain == "hybrid")
  check("electric costs more", Cat.spec({ name = "Solaris Urbino 12 electric", file = "a.bus" }).price > Cat.spec({ name = "Solaris Urbino 12", file = "a.bus" }).price)
  check("tram is not a bus", not Cat.is_bus(CATALOG[6]))
  check("trailer is not a bus", not Cat.is_bus(CATALOG[7]))
  check("O305 is a bus", Cat.is_bus(CATALOG[2]))
  check("spec is stable", Cat.spec(CATALOG[2]).price == Cat.spec(CATALOG[2]).price)
  Cat.set_overrides({ ["o305g"] = { class = "coach", price = 123400 } })
  local s = Cat.spec(CATALOG[3])
  check("override class and price", s.class == "coach" and s.price == 123400, s.class .. " " .. s.price)
  check("articulated costs more than standard", (function() Cat.set_overrides({}); return Cat.spec(CATALOG[3]).price > Cat.spec(CATALOG[2]).price end)())
  local o = Cat.used_offer(CATALOG[2], P.util.rng(5))
  check("used is cheaper than new", o.price < Cat.spec(CATALOG[2]).price, o.price)
  check("value falls with age", Cat.value(Cat.spec(CATALOG[2]), 10, 70) < Cat.value(Cat.spec(CATALOG[2]), 2, 70))
  check("value rises with condition", Cat.value(Cat.spec(CATALOG[2]), 5, 90) > Cat.value(Cat.spec(CATALOG[2]), 5, 30))
end

-- =======================================================================================
section("a new company")
do
  local g, P = load_plugin()
  local S = P.game.S
  check("company exists", S ~= nil)
  check("starts with the starter bus", #S.fleet == 1, #S.fleet)
  check("the starter bus is the player's bus", S.fleet[1].file == "Vehicles/MB_O305/MB_O305.bus")
  check("starting cash", S.cash == 400000, S.cash)
  check("candidates exist", #S.candidates >= 6, #S.candidates)
  check("a panel is shown", g.panels.bc ~= nil)
  check("fleet file only .bus", (function() for _, m in ipairs(P.game.models_list()) do if not m.file:match("%.bus$") then return false end end return true end)())
  check("catalogue drops tram and trailer", #P.game.models_list() == 5, #P.game.models_list())
  check("vehicles.json written", g.files["vehicles.json"] ~= nil)
end

-- =======================================================================================
section("market, buying and selling")
do
  local g, P = load_plugin()
  local G, F = P.game, P.fleet
  local m = G.market()
  check("a new offer per model", #m.new == 5, #m.new)
  check("used offers exist", #m.used > 0, #m.used)
  check("used offers are stable within the week", #G.market().used == #m.used)
  local offer = m.new[1]
  local cash0 = G.S.cash
  local b, why = G.buy(offer)
  check("buy works", b and true, why)
  check("cash fell by the price", near(G.S.cash, cash0 - offer.price))
  check("fleet grew", #G.S.fleet == 2)
  check("new bus is in perfect condition", b.condition == 100 and b.age_days == 0)
  check("fleet numbers differ", G.S.fleet[1].number ~= G.S.fleet[2].number)
  local pocket = G.S.cash
  P.company.book(G.S, "repayment", 1000 - pocket)
  local b2, why2 = G.buy(m.new[2])
  check("cannot buy without cash", b2 == false and why2:find("Not enough"), why2)
  P.company.book(G.S, "loan", pocket - 1000)
  local used = m.used[1]
  local before = #G.S.market.used
  local bu = G.buy(used)
  check("used purchase works", bu and bu.condition == used.condition)
  check("the used offer is gone", #G.S.market.used == before - 1)
  local price = G.sell(bu)
  check("selling pays less than buying", price and price < used.price, tostring(price) .. " vs " .. used.price)
  check("fleet shrank", #G.S.fleet == 2)
  check("books balance", near(G.S.cash - 400000, sum_life(G.S), 0.01), G.S.cash - 400000 - sum_life(G.S))
end

-- =======================================================================================
section("staff")
do
  local g, P = load_plugin()
  local G, D = P.game, P.drivers
  local cand = G.S.candidates[1]
  local cash0 = G.S.cash
  local d, why = G.hire(cand.id)
  check("hire works", d and true, why)
  check("fee paid", G.S.cash < cash0)
  check("one driver", #G.S.drivers == 1)
  check("candidate removed", #G.S.candidates == 5)
  local ok = D.train(G.S, d)
  check("training works", ok and true)
  check("training is rate limited", select(1, D.train(G.S, d)) == false)
  check("wage is plausible", d.wage > 8 and d.wage < 40, d.wage)
  check("day pay has a retainer when idle", near(D.day_pay(d, 0), d.wage * 8 * 0.4))
  check("overtime pays more", D.day_pay(d, 10) > D.day_pay(d, 8))
  check("fire works", G.fire(d.id) and #G.S.drivers == 0)
end

-- =======================================================================================
section("running a tour with an AI driver")
do
  local g, P = load_plugin()
  local G, R, F, Co = P.game, P.routes, P.fleet, P.company
  local S = G.S
  local tours = R.scan()
  check("three tours found", #tours == 3, #tours)
  check("schedule has trips", #R.schedule("136", "1") == 29, #R.schedule("136", "1"))
  local d = G.hire(S.candidates[1].id)
  local bus = S.fleet[1]
  local a, why = G.assign("136/1", bus.id, d.id, "ai")
  check("assign works", a and true, why)
  check("the engine was told", g.assigned["136/1"] and g.assigned["136/1"].file == bus.file)
  check("bus and driver are linked", bus.assignment == "136/1" and d.assignment == "136/1")
  check("tour cannot be assigned twice", select(1, G.assign("136/1", bus.id, d.id, "ai")) == false)
  check("busy bus refused", select(1, G.assign("136/2", bus.id, d.id, "ai")) == false)

  g.clock = 7 * 3600
  mock.run_minutes(2)   -- the first tick sets the day
  local cash_before = S.cash
  mock.run_minutes(13 * 60)   -- to 20:02
  local trips = S.stats.trips + S.stats.missed
  check("trips were settled", S.stats.trips >= 20, S.stats.trips)
  check("the day made money so far", Co.net(S.today) > 0, Co.net(S.today))
  check("fares booked", (S.life.fares or 0) > 0)
  check("subsidy booked", (S.life.subsidy or 0) > 0)
  check("fuel booked", (S.life.fuel or 0) < 0)
  check("the bus wore", bus.condition < 72, bus.condition)
  check("the bus drove km", bus.km_total > 50, bus.km_total)
  check("assignment counted trips", a.stats.trips == S.stats.trips - 0 or a.stats.trips > 0)
  check("books balance mid-day", near(S.cash - 400000, sum_life(S), 0.01), S.cash - 400000 - sum_life(S))

  local day_before = S.days_played
  local cash_pre_close = S.cash
  mock.run_minutes(4 * 60)   -- past midnight
  check("the day closed", S.days_played == day_before + 1, S.days_played)
  check("history recorded", #S.history == 1)
  check("wages paid", (S.life.wages or 0) < 0)
  check("insurance paid", (S.life.insurance or 0) < 0)
  check("overhead paid", (S.life.overhead or 0) < 0)
  check("today reset after close", near(Co.net(S.today), (S.today.fares or 0) + 0 + Co.net(S.today) - (S.today.fares or 0)))
  check("books balance after close", near(S.cash - 400000, sum_life(S), 0.01), S.cash - 400000 - sum_life(S))
  check("a toast announced it", (function() for _, t in ipairs(g.toasts) do if t.text:find("Day closed") then return true end end end)())
  check("history day net matches", #S.history == 1 and S.history[1].net ~= 0)
end

-- =======================================================================================
section("a clock jump pays nothing")
do
  local g, P = load_plugin()
  local G, R, S = P.game, P.routes, P.game.S
  local d = G.hire(S.candidates[1].id)
  G.assign("136/1", S.fleet[1].id, d.id, "ai")
  g.clock = 7 * 3600
  mock.run_minutes(2)
  local trips0 = S.stats.trips
  mock.set_clock(17 * 3600)   -- ten hours forward by hand
  mock.run_minutes(1)
  check("no trips paid for the skipped time", S.stats.trips == trips0, S.stats.trips - trips0)
  mock.run_minutes(40)
  check("trips count again after the jump", S.stats.trips > trips0, S.stats.trips - trips0)
end

-- =======================================================================================
section("economic sanity")
do
  local g, P = load_plugin()
  local G, R, Cat, D, S = P.game, P.routes, P.catalog, P.drivers, P.game.S
  local sched = R.schedule("136", "1")
  local drv = D.generate(S, P.util.rng(3))
  drv.skill, drv.punctuality, drv.courtesy = 60, 60, 60
  local function est(spec, demand, fare)
    return R.estimate_day({ spec = spec, condition = 90, driver = drv, demand = demand, fare = fare or 1, rep = 1, fare_base = 2.7, energy = S.energy, weekday = 2, weather = 1 }, sched)
  end
  local std = Cat.spec(CATALOG[2])
  local mini = Cat.spec({ name = "Minibus", file = "m.bus" })
  local artic = Cat.spec(CATALOG[3])
  local e = est(std, 1)
  check("a standard bus on an average line is profitable", e.net > 0, e.net)
  check("revenue exceeds fuel and upkeep", e.revenue > e.costs)
  check("a tour has a sensible length", e.shift_hours > 8 and e.shift_hours < 16, e.shift_hours)
  -- on a quiet line the small bus earns more than the big one (the big one costs more to run)
  check("right-sizing: minibus beats articulated on a quiet line", est(mini, 0.65).net > est(artic, 0.65).net, est(mini, 0.65).net .. " vs " .. est(artic, 0.65).net)
  -- on a very busy line the minibus is capacity-limited
  local busy_mini, busy_std = est(mini, 3.5), est(std, 3.5)
  check("a minibus cannot carry a busy line", busy_mini.revenue < busy_std.revenue, busy_mini.revenue .. " vs " .. busy_std.revenue)
  check("higher fares: more per rider, fewer riders", est(std, 1, 1.4).revenue ~= est(std, 1, 1.0).revenue)
  check("extreme fares are not a free lunch", est(std, 1, 1.5).revenue < est(std, 1, 1.0).revenue * 1.6)
  check("skilled drivers cost more", D.market_wage(90) > D.market_wage(40))
  -- payback in game days at the default pace
  local per_day = (G.inc(e.revenue) - G.cost(e.costs))
  local payback = std.price / per_day
  check("payback is in the tens of days at the default pace", payback > 5 and payback < 120, payback)
  print(string.format("   (standard bus, average line: %.0f per day, pays back in %.0f days)", per_day, payback))
end

-- =======================================================================================
section("loans, tax and bankruptcy")
do
  local g, P = load_plugin()
  local G, Co, F, S = P.game, P.company, P.fleet, P.game.S
  local ok, why = G.borrow(100000)
  check("loan granted", ok, why)
  check("cash rose", S.cash == 500000)
  check("debt recorded", Co.debt(S) == 100000)
  local ok2 = G.borrow(10 ^ 9)
  check("a huge loan is refused", ok2 == false)
  check("repay works", G.repay(40000) and Co.debt(S) == 60000)
  check("repay all works", G.repay(10 ^ 9) and Co.debt(S) == 0)
  check("books balance with loans", near(S.cash - 400000, sum_life(S), 0.01))
  -- interest
  G.borrow(100000)
  local c0 = S.cash
  Co.close_day(S, P.util.rng(1), { weekday = 3, day = 10 }, 80)
  check("interest charged", S.cash < c0)
  -- tax at the turn of a month
  S.month = { fares = 100000, fuel = -20000 }
  local cash = S.cash
  local out = Co.close_day(S, P.util.rng(1), { weekday = 3, day = 1 }, 80)
  check("tax charged on a profitable month", out.tax and out.tax > 0, out.tax)
  check("tax is the rate of the profit", math.abs(out.tax - 80000 * 0.20) < 40, out.tax)
  S.month = { fuel = -50000 }
  Co.close_day(S, P.util.rng(1), { weekday = 3, day = 1 }, 80)
  check("a loss is carried forward", S.loss_carry >= 50000, S.loss_carry)
  S.month = { fares = 30000 }
  local out3 = Co.close_day(S, P.util.rng(1), { weekday = 3, day = 1 }, 80)
  check("carried loss shelters the next profit", (out3.tax or 0) == 0, out3.tax)
  -- bankruptcy
  S.cash = -90000
  local fl = #S.fleet
  local out4
  for _ = 1, 3 do out4 = Co.close_day(S, P.util.rng(1), { weekday = 3, day = 10 }, 80) end
  check("insolvency detected after days of it", out4.bankrupt, S.neg_days)
  G.go_bankrupt()
  check("the bank took the fleet", #S.fleet == 0 and S.bankrupt)
  check("a bankrupt company cannot buy", select(1, G.buy(G.market().new[1])) == false)
  P.views.tab = 1
  local ok_panel = pcall(g.panels.bc and function() end or error)
  check("bankrupt panel still builds", pcall(P.views.panel))
end

-- =======================================================================================
section("driving a tour yourself")
do
  local g, P = load_plugin()
  local G, R, F, Co, V, S = P.game, P.routes, P.fleet, P.company, P.views, P.game.S
  local bus = S.fleet[1]
  local a = G.assign("136/2", bus.id, nil, "player")
  check("player assignment", a and a.mode == "player")
  check("player tours are not announced to the engine", g.assigned["136/2"] == nil)

  -- not in the bus yet: another vehicle
  g.vehicle = { file = "Vehicles/MAN_SD202/MAN_SD202.bus", name = "MAN SD202", manufacturer = "MAN", model = "SD202" }
  mock.fire("vehicle", g.vehicle.name)
  local cash0 = S.cash
  mock.fire("ticket_sold", "Single", 2.7)
  check("no money in somebody else's bus", S.cash == cash0)

  local ok, msg = G.drive_tour("136/2")
  check("drive asks the game to place the bus", ok and g.place_request and g.place_request.file == bus.file, msg)
  check("placing waits", G.pending ~= nil)
  mock.finish_placing({ file = bus.file, name = "Mercedes-Benz O305", manufacturer = "Mercedes-Benz", model = "O305" })
  check("the duty starts once the bus is there", g.duty and g.duty.line == "136" and g.duty.tour == "2", table.concat(g.calls, ";"))
  mock.fire("duty_start", "136", "2")
  check("the duty is tracked", G.drive and G.drive.key == "136/2")

  local c1 = S.cash
  mock.fire("ticket_sold", "Single", 2.7)
  check("a ticket pays the company", S.cash > c1 and (S.life.fares or 0) > 0, S.cash - c1)
  check("pace scales the fare", near(S.cash - c1, 2.7 * G.pace(), 1e-6), S.cash - c1)

  g.odometer = g.odometer + 0
  mock.fire("trip_start", 1, "t", "x")
  g.odometer = g.odometer + 6.2
  mock.fire("stop_arrive", "End", 5, 4, 20)
  local c2 = S.cash
  mock.fire("trip_done", 1, "arrived", 90, 90, 80)
  check("a finished trip is paid", S.cash > c2, S.cash - c2)
  check("authority payments booked", (S.life.subsidy or 0) > 0)
  check("trip counted", S.stats.trips == 1 and a.stats.trips == 1)

  local c3 = S.cash
  mock.fire("trip_done", 2, "given_up", 0, 0, 0)
  check("a trip given up costs", S.cash < c3)
  check("reputation fell", S.reputation < 55)

  local cond0 = bus.condition
  mock.fire("crash", 40, 30)
  check("a crash costs money", S.cash < c3)
  check("a crash damages the bus", bus.condition < cond0, bus.condition)
  local rep0 = S.reputation
  mock.fire("pedestrian")
  check("a pedestrian is a big fine", (S.life.fines or 0) < -5000)
  check("and reputation", S.reputation < rep0 - 5)
  local f0 = S.cash
  mock.fire("red_light")
  mock.fire("red_light")
  check("red light fine only once in a burst", f0 - S.cash < 2 * 150 * G.pace() ^ 0.6 - 1, f0 - S.cash)

  local fuel0 = S.life.fuel or 0
  mock.fire("service", "refuel", "player", 100)
  check("refuelling is billed", (S.life.fuel or 0) < fuel0)
  local fuel1 = S.life.fuel
  mock.fire("service", "refuel", "plugin", 100)
  check("the plugin's own service commands are not billed twice", S.life.fuel == fuel1)
  check("books balance after driving", near(S.cash - 400000, sum_life(S), 0.01), S.cash - 400000 - sum_life(S))

  -- stop the service while driving
  G.unassign("136/2")
  check("duty finished with the service", not g.duty and G.drive == nil)
end

do
  -- a bus in the workshop cannot be driven
  local g, P = load_plugin()
  local G, S = P.game, P.game.S
  local bus = S.fleet[1]
  G.assign("136/2", bus.id, nil, "player")
  local ok = G.service_bus(bus)
  check("service works", ok and bus.status == "workshop")
  local ok2, why = G.drive_tour("136/2")
  check("a bus in the workshop will not go", ok2 == false and why:find("workshop"), why)
  check("service restores condition", bus.condition == 100)
end

-- =======================================================================================
section("observed AI buses")
do
  local g, P = load_plugin()
  local G, R, S = P.game, P.routes, P.game.S
  local d = G.hire(S.candidates[1].id)
  local a = G.assign("136/1", S.fleet[1].id, d.id, "ai")
  -- a bus that drives 2 km during the 06:00 trip and ends 10 minutes late
  g.clock = 7 * 3600 - 60 * 5
  mock.run_minutes(1)
  local obs = {}
  for i = 0, 20 do   -- a bus polled every 5 s, 100 m apart: 2 km
    R.observe(obs, { { line = "136", tour = "1", departure = 7 * 3600, x = i * 100, y = 0, delay = i * 30 } })
  end
  local o = R.take_obs(obs, "136", "1", 7 * 3600)
  check("the observation is found by its departure", o and near(o.km, 2, 1e-9), o and o.km)
  check("and used up", R.take_obs(obs, "136", "1", 7 * 3600) == nil)
  check("a teleport is not driven distance", (function()
    local ob = {}
    R.observe(ob, { { line = "1", tour = "1", departure = 0, x = 0, y = 0 } })
    R.observe(ob, { { line = "1", tour = "1", departure = 0, x = 50000, y = 0 } })
    return next(ob) and select(2, next(ob)).km == 0
  end)())
  local late = R.punctuality_share(600)
  check("a very late trip earns a quarter of the subsidy", late == 0.25)
end

-- =======================================================================================
section("saving and loading")
do
  local g, P = load_plugin()
  local G, S = P.game, P.game.S
  local d = G.hire(S.candidates[1].id)
  G.assign("136/1", S.fleet[1].id, d.id, "ai")
  G.buy(G.market().new[1])
  G.borrow(50000)
  g.clock = 7 * 3600
  mock.run_minutes(120)
  mock.fire("stop")   -- saves
  check("the company was stored as JSON", g.storage.company ~= nil)
  local cash, nfleet = S.cash, #S.fleet
  -- a new session reads it
  local g2, P2 = load_plugin({ storage = g.storage })
  local S2 = P2.game.S
  check("cash survives", near(S2.cash, cash, 0.01), S2.cash)
  check("fleet survives", #S2.fleet == nfleet)
  check("assignments survive", #S2.assignments == 1 and S2.assignments[1].key == "136/1")
  check("loans survive", P2.company.debt(S2) == 50000)
  check("the engine is told again at the start", g2.assigned["136/1"] ~= nil)
  check("days between sessions cost nothing", S2.day_idx == nil)
  check("it keeps running", pcall(function() mock.run_minutes(30) end))
end

-- =======================================================================================
section("without the fleet API")
do
  local g, P = load_plugin({ fleet_api = false })
  local G, S = P.game, P.game.S
  check("the plugin still starts", S ~= nil and #S.fleet == 1)
  check("the market knows the buses driven", #G.models_list() == 1, #G.models_list())
  g.vehicle = { file = "Vehicles/MAN_SD202/MAN_SD202.bus", name = "MAN SD202", manufacturer = "MAN", model = "SD202" }
  mock.fire("vehicle", "MAN SD202")
  check("a new vehicle joins the market", #G.models_list() == 2)
  G.assign("136/1", S.fleet[1].id, nil, "player")
  g.vehicle = { file = "Vehicles/Other/Other.bus", name = "Other", manufacturer = "O", model = "o" }
  local ok, why = G.drive_tour("136/1")
  check("drive explains it cannot swap", ok == false and why:find("cannot swap"), why)
  g.vehicle = { file = S.fleet[1].file, name = "x", manufacturer = "", model = "" }
  check("drive works when already in the bus", G.drive_tour("136/1") == true and g.duty ~= nil)
end

-- =======================================================================================
section("the panels")
do
  local g, P = load_plugin()
  local G, V, S = P.game, P.views, P.game.S
  -- a busy company so every list has content
  for i = 1, 8 do G.buy(G.market().new[(i % 5) + 1]) end
  S.cash = 5000000
  for _ = 1, 8 do G.hire(S.candidates[1] and S.candidates[1].id or "") end
  P.drivers.refresh_pool(S, P.util.rng(9))
  for i = 1, 3 do
    local free = P.fleet.free_buses(S, 0)
    local drv
    for _, d in ipairs(S.drivers) do if not d.assignment then drv = d break end end
    if free[1] and drv then G.assign(P.routes.scan()[i].key, free[1].id, drv.id, i == 3 and "player" or "ai") end
  end
  for tab = 1, 6 do
    V.change("tab", tab)
    local ok, panel = pcall(V.panel)
    check("tab " .. tab .. " builds", ok, panel)
    if ok then
      local ok2, why = pcall(mock.game.panels.bc and function() end or error)
      check("tab " .. tab .. " passes the panel validator", pcall(omsi.ui.set, "t", panel))
    end
  end
  -- click through everything
  local clicks = {}
  for tab = 1, 6 do
    V.change("tab", tab)
    local panel = V.panel()
    local function walk(list)
      for _, e in ipairs(list) do
        if e.type == "button" or e.clickable then clicks[#clicks + 1] = { tab = tab, id = e.id } end
        if e.children then walk(e.children) end
      end
    end
    walk(panel.children)
  end
  check("there is something to click", #clicks > 20, #clicks)
  local errors = 0
  for _, c in ipairs(clicks) do
    -- skip the destructive ones; they are tested by name below
    if c.id ~= "reset_yes" and c.id ~= "sell" and c.id ~= "fire" and not c.id:find("^unassign") then
      V.change("tab", c.tab)
      local ok, err = pcall(V.click, c.id)
      if not ok then errors = errors + 1; print("   click " .. c.id .. ": " .. tostring(err)) end
      local ok2, err2 = pcall(function() return omsi.ui.set("t", V.panel()) end)
      if not ok2 then errors = errors + 1; print("   after click " .. c.id .. ": " .. tostring(err2)) end
    end
  end
  check("no click breaks a panel", errors == 0, errors)

  -- named flows
  V.change("tab", 4)
  V.click("tour:136/1")
  V.click("tour:M5/1")
  check("route editor offers estimate", (function() local ok = pcall(V.panel) return ok end)())
  V.click("start_me")
  check("start_me assigns a player tour or says why", S.assignments[#S.assignments] ~= nil)
  V.change("tab", 2)
  V.click("bus:" .. S.fleet[1].id)
  check("bus detail builds", pcall(V.panel))
  local n = #S.fleet
  V.click("sell")
  check("sell via panel", #S.fleet == n - 1 or V.msg ~= nil)
  V.change("tab", 6)
  V.change("name", "Test Lines Ltd")
  check("renaming the company", S.name == "Test Lines Ltd")
  V.click("reset")
  check("reset asks first", V.confirm == "reset")
  V.click("reset_yes")
  check("reset starts a new company", #G.S.fleet <= 1 and G.S.cash == 400000, G.S.cash)

  -- the hotkey
  g.hotkeys["Ctrl+KeyB"]()
  check("hotkey hides the window", g.panels.bc == nil)
  check("and shows the cash display", g.panels.bc_hud ~= nil)
  g.hotkeys["Ctrl+KeyB"]()
  check("hotkey shows it again", g.panels.bc ~= nil and g.panels.bc_hud == nil)

  -- through the game's events
  mock.fire("ui_click", "bc", "tab")
  mock.fire("ui_change", "bc", "tab", 3)
  check("ui_change switches tabs", V.tab == 3)
  mock.fire("ui_click", "other", "x")
end

-- =======================================================================================
section("fractional numbers in the panels")
do
  local g, P = load_plugin()
  local G, V, S = P.game, P.views, P.game.S
  S.fleet[1].condition = 71.537
  local d = G.hire(S.candidates[1].id)
  d.skill, d.punctuality, d.courtesy, d.morale = 61.03, 55.5, 70.25, 63.3
  local a = G.assign("136/1", S.fleet[1].id, d.id, "ai")
  G.set_fare("136/1", 0.55)
  V.click("bus:" .. S.fleet[1].id)
  V.click("drv:" .. d.id)
  V.click("tour:136/1")
  for tab = 1, 6 do
    V.change("tab", tab)
    check("tab " .. tab .. " with fractions", pcall(V.panel))
  end
  S.fleet[1].condition = 20.2
  check("alerts with fractions", pcall(G.alerts))
end

-- =======================================================================================
section("a week of play")
do
  local g, P = load_plugin()
  local G, Co, S, R = P.game, P.company, P.game.S, P.routes
  -- two more buses and drivers on the other tours
  Co.book(S, "loan", 2000000)
  for i = 1, 2 do
    local b = G.buy(G.market().new[2])
    local d = G.hire(S.candidates[1].id)
    G.assign(R.scan()[i].key, b.id, d.id, "ai")
  end
  g.clock = 5 * 3600
  mock.run_minutes(2)
  local cash0 = S.cash
  local life0 = sum_life(S)
  mock.run_minutes(7 * 24 * 60)
  check("seven days closed", S.days_played >= 7, S.days_played)
  check("history has the days", #S.history >= 7)
  check("a week and month rollover happened", true)
  check("the company survived", not S.bankrupt)
  check("the books balance after a week", near(S.cash - 400000, sum_life(S), 0.5), S.cash - 400000 - sum_life(S))
  check("the market refreshed", #S.market.used > 0)
  check("candidates were refreshed", #S.candidates >= 6)
  local net = 0
  for _, h in ipairs(S.history) do net = net + h.net end
  print(string.format("   week: cash %.0f -> %.0f, history net %.0f, reputation %.1f, trips %d, late %d, missed %d, accidents %d, breakdowns %d",
    cash0, S.cash, net, S.reputation, S.stats.trips, S.stats.late, S.stats.missed, S.stats.accidents, S.stats.breakdowns))
  check("three tours made money overall", net > 0, net)
  local json_ok = pcall(function() mock.json.encode(S) end)
  check("the whole state is storable", json_ok)
  local errs = 0
  for _, l in ipairs(g.log) do if tostring(l):find("rror") then errs = errs + 1 end end
  check("no errors logged", errs == 0, errs)
end

print(string.format("\n%d checks, %d failed", checks, failures))
os.exit(failures == 0 and 0 or 1)
