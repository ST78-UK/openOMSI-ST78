-- routes.lua: the map's timetable as the company's network, the assignments of a bus and a
-- driver to a tour, and the model that turns an AI-run trip into money.
--
-- A *tour* (line + tour number in the timetable) is the unit the company operates: one bus
-- and one driver run all of its trips. Two ways to run one:
--   "ai"      an AI driver on payroll runs it. Each trip, once its timetable time has passed,
--             is settled by `settle_ai_trip` (using the real AI bus's distance and delay
--             where the plugin saw the bus, the timetable otherwise).
--   "player"  you drive it: the money is what the cash desk really sells, plus the
--             authority's payment per kilometre when a trip is driven to its end.

local U = require("util")
local B = require("balance")

local R = {}

-- ---------------------------------------------------------------------------------------
-- The network
-- ---------------------------------------------------------------------------------------

--- How busy a line is, 0.65 to 1.35, the same every time for the same line name.
function R.line_demand(line)
  local lo, hi = B.line_demand_range[1], B.line_demand_range[2]
  return U.lerp(lo, hi, U.hash01("line:" .. tostring(line)))
end

function R.demand_label(d)
  if d < 0.85 then return "Low" end
  if d < 1.15 then return "Medium" end
  return "High"
end

function R.key(line, tour) return tostring(line) .. "/" .. tostring(tour) end

local cache = { map = nil, tours = nil, sched = {} }

--- Forget what was read of the timetable (another map, or a new timetable).
function R.reset_cache() cache = { map = nil, tours = nil, sched = {} } end

--- The tours of the map's timetable: { key, line, tour, today, trips, user_allowed }.
function R.scan()
  local map = omsi.map.name()
  if cache.tours and cache.map == map then return cache.tours end
  cache = { map = map, tours = {}, sched = {} }
  local lines = omsi.timetable.lines() or {}
  for _, l in ipairs(lines) do
    for _, t in ipairs(l.tours or {}) do
      cache.tours[#cache.tours + 1] = {
        key = R.key(l.name, t.number), line = tostring(l.name), tour = tostring(t.number),
        today = t.today ~= false, trips = t.trips or 0, user_allowed = l.user_allowed ~= false,
      }
    end
  end
  table.sort(cache.tours, function(a, b)
    if a.line ~= b.line then
      local na, nb = tonumber(a.line), tonumber(b.line)
      if na and nb and na ~= nb then return na < nb end
      return a.line < b.line
    end
    local na, nb = tonumber(a.tour), tonumber(b.tour)
    if na and nb then return na < nb end
    return a.tour < b.tour
  end)
  return cache.tours
end

function R.find_tour(key)
  for _, t in ipairs(R.scan()) do
    if t.key == key then return t end
  end
  return nil
end

--- The trips of a tour: { n, start, finish, stops, duration } in the order they leave
--- (seconds of the day). Cached for the map.
function R.schedule(line, tour)
  R.scan()
  local key = R.key(line, tour)
  if cache.sched[key] then return cache.sched[key] end
  local rows = omsi.timetable.stops(line, tour) or {}
  local by_trip, order = {}, {}
  for _, r in ipairs(rows) do
    local t = by_trip[r.trip]
    if not t then
      t = { n = r.trip, start = math.huge, finish = -math.huge, stops = 0 }
      by_trip[r.trip] = t
      order[#order + 1] = t
    end
    local dep = tonumber(r.departure)
    if dep then
      if dep < t.start then t.start = dep end
      if dep > t.finish then t.finish = dep end
    end
    t.stops = t.stops + 1
  end
  local trips = {}
  for _, t in ipairs(order) do
    if t.start ~= math.huge and t.finish > t.start then
      t.duration = t.finish - t.start
      trips[#trips + 1] = t
    end
  end
  table.sort(trips, function(a, b) return a.start < b.start end)
  for i, t in ipairs(trips) do t.idx = i end
  cache.sched[key] = trips
  return trips
end

--- What a tour comes to over a day: how many trips, the span of the shift, the distance.
function R.summary(line, tour)
  local trips = R.schedule(line, tour)
  local s = { trips = #trips, stops = 0, km = 0, first = nil, last = nil, shift_hours = 0 }
  for _, t in ipairs(trips) do
    s.stops = s.stops + t.stops
    s.km = s.km + t.duration / 3600 * B.urban_speed_kmh
    s.first = s.first and math.min(s.first, t.start) or t.start
    s.last = s.last and math.max(s.last, t.finish) or t.finish
  end
  if s.first then s.shift_hours = (s.last - s.first) / 3600 + 0.5 end
  s.avg_stops = #trips > 0 and s.stops / #trips or 0
  return s
end

-- ---------------------------------------------------------------------------------------
-- Assignments
-- ---------------------------------------------------------------------------------------

function R.get(S, key)
  return U.find(S.assignments, function(a) return a.key == key end)
end

--- Puts a bus (and a driver) on a tour. mode is "ai" or "player".
--- Returns the assignment, or false and the reason.
function R.assign(S, tour, bus, driver, mode, now_info, auto)
  if S.bankrupt then return false, "The company is insolvent" end
  if R.get(S, tour.key) then return false, "That tour is already operated" end
  if bus.assignment then return false, "That bus is already on a route" end
  if bus.status == "workshop" then return false, "That bus is in the workshop" end
  if mode == "ai" then
    if not driver then return false, "Hire a driver first" end
    if driver.assignment then return false, "That driver already has a route" end
  else
    driver = nil
  end
  local sum = R.summary(tour.line, tour.tour)
  local a = {
    key = tour.key, line = tour.line, tour = tour.tour, mode = mode,
    bus = bus.id, driver = driver and driver.id or nil,
    fare = 1.0,
    demand = R.line_demand(tour.line),
    since_day = now_info.day_idx, since_time = now_info.time,
    shift_hours = sum.shift_hours,
    settled = {},
    taken = {},   -- trips the player drove instead of the AI: trip number -> day index
    auto = auto and true or nil,
    stats = { trips = 0, revenue = 0, costs = 0, ontime = 0, late = 0, missed = 0 },
    today = { trips = 0, revenue = 0, costs = 0 },
    week = {},   -- net per recent day
  }
  S.assignments[#S.assignments + 1] = a
  bus.assignment = a.key
  if driver then driver.assignment = a.key end
  return a
end

--- Takes the bus and driver off a tour.
function R.unassign(S, a)
  for _, b in ipairs(S.fleet) do
    if b.id == a.bus then b.assignment = nil end
  end
  for _, d in ipairs(S.drivers) do
    if d.id == a.driver then d.assignment = nil end
  end
  U.remove_if(S.assignments, function(x) return x == a end)
end

--- Changes the bus and/or the driver of an assignment. `bus` and `driver` are the new ones
--- (nil keeps the present one). Returns true, or false and the reason.
function R.reassign(S, a, bus, driver)
  local old_bus = U.find(S.fleet, function(b) return b.id == a.bus end)
  local old_driver = a.driver and U.find(S.drivers, function(d) return d.id == a.driver end) or nil
  bus = bus or old_bus
  if not bus then return false, "Choose a bus" end
  if bus ~= old_bus then
    if bus.assignment then return false, "That bus is already on a route" end
    if bus.status == "workshop" then return false, "That bus is in the workshop" end
  end
  if a.mode == "ai" then
    driver = driver or old_driver
    if not driver then return false, "Choose a driver" end
    if driver ~= old_driver and driver.assignment then return false, "That driver already has a route" end
  else
    driver = nil
  end
  if bus ~= old_bus then
    if old_bus then old_bus.assignment = nil end
    bus.assignment = a.key
    a.bus = bus.id
  end
  if driver ~= old_driver then
    if old_driver then old_driver.assignment = nil end
    if driver then driver.assignment = a.key end
    a.driver = driver and driver.id or nil
  end
  a.auto = nil     -- chosen by hand now: the automatic allocation leaves it alone
  return true
end

--- Hands an assignment from the AI to the player (`"player"`) or back (`"ai"`, with a driver).
function R.set_mode(S, a, mode, driver)
  if mode == a.mode then return true end
  if mode == "player" then
    local d = a.driver and U.find(S.drivers, function(x) return x.id == a.driver end)
    if d then d.assignment = nil end
    a.driver, a.mode = nil, "player"
  else
    if not driver then return false, "Choose a driver" end
    if driver.assignment then return false, "That driver already has a route" end
    driver.assignment = a.key
    a.driver, a.mode = driver.id, "ai"
  end
  a.auto = nil
  return true
end

--- Whether the player may take a duty in the bus of this assignment today: a tour of their
--- own, or one of the AI's from which they have taken a trip over.
function R.player_can(a, day_idx)
  if a.mode == "player" then return true end
  for _, d in pairs(a.taken or {}) do
    if d == day_idx then return true end
  end
  return false
end

--- The player drives trip `n` of an AI-run tour: the AI model leaves it out today.
function R.take_trip(a, n, day_idx)
  a.taken = a.taken or {}
  a.taken[tostring(n)] = day_idx
  a.settled = a.settled or {}
  a.settled[tostring(n)] = day_idx
end

--- Who runs what when the company allocates its AI drivers by itself: the busiest and
--- longest tours get the biggest buses and the best drivers. `tours` is a list of
--- { key, line, tour }, `buses` and `drivers` the free ones. Pure: returns the pairs
--- { tour, bus, driver } for as many tours as there are buses and drivers for, and the
--- tours left without.
function R.plan_allocation(tours, buses, drivers)
  local scored = {}
  for _, t in ipairs(tours) do
    local sum = R.summary(t.line, t.tour)
    scored[#scored + 1] = { tour = t, score = sum.km * R.line_demand(t.line), key = t.key }
  end
  table.sort(scored, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.key < b.key
  end)
  local bs = {}
  for _, b in ipairs(buses) do bs[#bs + 1] = b end
  table.sort(bs, function(a, b)
    if a.spec.capacity ~= b.spec.capacity then return a.spec.capacity > b.spec.capacity end
    if a.condition ~= b.condition then return a.condition > b.condition end
    return a.id < b.id
  end)
  local ds = {}
  for _, d in ipairs(drivers) do ds[#ds + 1] = d end
  table.sort(ds, function(a, b)
    if a.skill ~= b.skill then return a.skill > b.skill end
    return a.id < b.id
  end)
  local pairs_, left = {}, {}
  for i, sc in ipairs(scored) do
    if bs[i] and ds[i] then
      pairs_[#pairs_ + 1] = { tour = sc.tour, bus = bs[i], driver = ds[i] }
    else
      left[#left + 1] = sc.tour
    end
  end
  return pairs_, left
end

-- ---------------------------------------------------------------------------------------
-- Which trips are due
-- ---------------------------------------------------------------------------------------

--- The trips of an AI-run assignment whose time has come, and that nobody has settled.
--- `jumped`: the clock was moved forward (set by hand): the trips it skipped over pay nothing.
function R.due_trips(a, trips, day_idx, now, jumped)
  local due = {}
  for _, t in ipairs(trips) do
    local id = tostring(t.n)
    local taken = a.taken and a.taken[id] == day_idx
    if a.settled[id] ~= day_idx and t.finish <= now then
      a.settled[id] = day_idx
      local counts = not taken and (day_idx > a.since_day or t.start >= a.since_time)
      if counts and not jumped then due[#due + 1] = t end
    end
  end
  return due
end

--- A day's end for the assignment's per-trip memory.
function R.new_day(a)
  a.settled = {}
  a.taken = {}
  U.push(a.week, U.round(a.today.revenue - a.today.costs, 0), 7)
  a.today = { trips = 0, revenue = 0, costs = 0 }
end

-- ---------------------------------------------------------------------------------------
-- Observing the real AI buses (their distance and their delay)
-- ---------------------------------------------------------------------------------------

--- Folds the rows of `omsi.timetable.buses()` into `obs` (km driven so far, last delay).
function R.observe(obs, rows)
  for _, r in ipairs(rows or {}) do
    local key = tostring(r.line) .. "/" .. tostring(r.tour) .. "@" .. tostring(math.floor((tonumber(r.departure) or 0) / 60))
    local o = obs[key]
    if not o then
      o = { line = tostring(r.line), tour = tostring(r.tour), dep = tonumber(r.departure) or 0, km = 0, ticks = 0 }
      obs[key] = o
    end
    if o.x and r.x and r.y then
      local d = math.sqrt((r.x - o.x) ^ 2 + (r.y - o.y) ^ 2)
      if d < 300 then o.km = o.km + d / 1000 end    -- a bigger jump is a bus that was put elsewhere
    end
    o.x, o.y = r.x, r.y
    o.delay = tonumber(r.delay) or o.delay
    o.ticks = o.ticks + 1
  end
end

--- The observation that belongs to a trip of a tour (matched by its departure), or nil.
--- It is removed from `obs`.
function R.take_obs(obs, line, tour, start)
  local best, best_key, best_gap
  for key, o in pairs(obs) do
    if o.line == tostring(line) and o.tour == tostring(tour) then
      local gap = math.abs(o.dep - start)
      if gap <= 120 and (not best_gap or gap < best_gap) then best, best_key, best_gap = o, key, gap end
    end
  end
  if best then obs[best_key] = nil end
  return best
end

--- Drops observations that were never used (a bus that left the road long ago).
function R.prune_obs(obs, now)
  for key, o in pairs(obs) do
    if o.dep < now - 4 * 3600 then obs[key] = nil end
  end
end

-- ---------------------------------------------------------------------------------------
-- The money of a trip
-- ---------------------------------------------------------------------------------------

local function punctuality_share(delay)
  for _, p in ipairs(B.punctuality) do
    if delay <= p.upto then return p.share end
  end
  return 0.25
end
R.punctuality_share = punctuality_share

--- What a trip of a tour earns and costs. `p` is a table:
---   spec, condition   the bus
---   driver            the AI driver (skill, punctuality, courtesy)
---   trip              { start, finish, stops, duration }
---   demand            the line's demand factor
---   fare              the fare level (0.5 to 1.5)
---   rep               the company's demand factor from its reputation
---   fare_base         the ticket price the map sells
---   energy            { diesel = price, electric = price }
---   weekday           1 Monday .. 7 Sunday
---   weather           demand factor of the weather (1 = no effect)
---   observed          { km, delay } of the real AI bus, when seen
---   rng               when given, the trip is random (noise, breakdown, accident); without
---                     it, the result is the expected trip (for the estimates)
--- The amounts are before the pace and the difficulty. Returns a table with the pieces.
function R.settle_ai_trip(p)
  local spec, trip, driver = p.spec, p.trip, p.driver
  local rng = p.rng
  local out = { km = 0, pax = 0, lost = 0, fares = 0, subsidy = 0, fuel = 0, maint = 0, delay = 0, ontime = false }

  local km = p.observed and p.observed.km and p.observed.km > 0.4 * (trip.duration / 3600 * B.urban_speed_kmh) and p.observed.km
    or (trip.duration / 3600 * B.urban_speed_kmh)
  out.km = km

  -- how late the trip ended: what the AI bus did if we saw it, else what a driver of this
  -- quality typically manages (a bit late on average, worse with a poor punctuality)
  local delay
  if p.observed and p.observed.delay then
    delay = p.observed.delay
  elseif rng then
    delay = rng:normal(30 + (100 - driver.punctuality) * 1.2, 50 + (100 - driver.punctuality) * 2.2)
  else
    delay = 30 + (100 - driver.punctuality) * 1.2
  end
  out.delay = delay
  out.ontime = delay <= B.on_time_limit

  -- a bus in bad shape may not make it
  if rng then
    local bad = (100 - p.condition) / 25
    local p_break = B.breakdown_base * (1 + bad * bad)
    if rng:chance(p_break) then
      out.breakdown = true
      out.km = km * rng:range(0.15, 0.8)
      return out
    end
  end

  -- passengers: the line's demand at that hour of that day, against what the bus carries
  local mid = ((trip.start + trip.finish) / 2) / 3600
  local hour = math.floor(mid) % 24
  local peak = B.line_base_pax * (B.demand_by_hour[hour] or 0.5)
  local stops_factor = 0.6 + 0.4 * math.min(1.5, trip.stops / 10)
  local elasticity = math.max(0.15, 1 - B.fare_elasticity * (p.fare - 1))
  local courtesy = 1 + (driver.courtesy - 60) / 400
  local pax = peak * stops_factor * p.demand * (B.weekday_demand[p.weekday] or 1) * p.rep * elasticity * courtesy * (p.weather or 1)
  if rng then pax = pax * math.max(0.5, rng:normal(1, 0.10)) end
  -- the busiest part of the trip carries a share of everyone who rides
  local max_load = pax * B.peak_load_share
  local cap = spec.capacity
  if max_load > cap then
    out.lost = (max_load - cap) / B.peak_load_share
    pax = cap / B.peak_load_share
  end
  out.overcrowded = max_load > cap * B.overcrowd_ratio
  out.pax = pax

  out.fares = pax * p.fare_base * p.fare * (1 - B.fare_evasion)
  out.subsidy = km * B.subsidy_per_km * punctuality_share(delay)

  -- running costs of the kilometres
  local eco = 1.06 - driver.skill / 800    -- a skilled driver uses a little less (about -6 %)
  local per_km = spec.consumption / 100 * eco
  local price = (p.energy and p.energy[spec.energy]) or 1
  out.fuel = km * per_km * price
  out.maint = km * require("catalog").maint_per_km(spec, p.condition)

  if rng then
    local hours = p.hours or B.shift_hours_regular
    local rate = require("drivers").accident_rate(driver, hours) * km / 100
    if rng:chance(rate) then
      out.accident = rng:range(B.accident_cost[1], B.accident_cost[2])
    end
  end
  return out
end

--- The same for a trip the player drove to its end: the authority pays per kilometre by
--- how punctual it was, and a bonus by how it was driven. Everything else (the fares) was
--- booked at the cash desk as it happened. Returns the payment.
function R.player_trip_pay(km, delay, driving, comfort)
  local base = km * B.player_subsidy_per_km * punctuality_share(delay or 0)
  local quality = 0.8 + 0.4 * (((driving or 70) + (comfort or 70)) / 200)
  return base * quality, quality
end

--- What a day of a tour is expected to bring in (before pace and difficulty): used by the
--- Routes tab to show what a bus and a driver would earn. { revenue, costs, net, trips }.
function R.estimate_day(p, sched)
  local rev, cost, trips = 0, 0, 0
  for _, t in ipairs(sched) do
    local q = {}
    for k, v in pairs(p) do q[k] = v end
    q.trip = t
    local r = R.settle_ai_trip(q)
    rev = rev + r.fares + r.subsidy
    cost = cost + r.fuel + r.maint
    trips = trips + 1
  end
  local d = p.driver
  local shift = sched[1] and ((sched[#sched].finish - sched[1].start) / 3600 + 0.5) or 0
  local wage = require("drivers").day_pay(d, shift)
  local fixed = p.spec.insurance + 0
  return { revenue = rev, costs = cost + wage + fixed, net = rev - cost - wage - fixed, trips = trips, shift_hours = shift }
end

return R
