-- fleet.lua: the company's buses: buying, selling, wear, workshop.

local U = require("util")
local B = require("balance")
local Co = require("company")
local Cat = require("catalog")

local F = {}

local function abs_minutes(S, minute_of_day)
  return S.days_played * 1440 + math.floor((minute_of_day or 0))
end
F.abs_minutes = abs_minutes

--- A fleet number nobody in the fleet has: 101, 102, ...
function F.next_number(S)
  local used = {}
  for _, b in ipairs(S.fleet) do used[b.number] = true end
  local n = 101
  while used[tostring(n)] do n = n + 1 end
  return tostring(n)
end

function F.get(S, id)
  return U.find(S.fleet, function(b) return b.id == id end)
end

--- Adds a bus to the fleet without paying (the starter bus, or the one a purchase delivers).
function F.add(S, offer, extra)
  local b = {
    id = "B" .. string.format("%03d", S.next_id.bus),
    file = offer.file,
    name = offer.name,
    spec = U.copy(offer.spec),
    age_days = math.floor((offer.age or 0) * 365),
    odometer = offer.odometer or 0,
    condition = offer.condition or 100,
    number = F.next_number(S),
    status = "ready",
    workshop_until = 0,
    assignment = nil,
    bought_day = S.days_played,
    km_total = 0,
  }
  S.next_id.bus = S.next_id.bus + 1
  for k, v in pairs(extra or {}) do b[k] = v end
  S.fleet[#S.fleet + 1] = b
  return b
end

function F.age_years(b) return b.age_days / 365 end

function F.value(b) return Cat.value(b.spec, F.age_years(b), b.condition) end
function F.resale(b) return Cat.resale(b.spec, F.age_years(b), b.condition) end

function F.total_value(S)
  local v = 0
  for _, b in ipairs(S.fleet) do v = v + F.value(b) end
  return v
end

function F.avg_condition(S)
  if #S.fleet == 0 then return 100 end
  return U.sum(S.fleet, function(b) return b.condition end) / #S.fleet
end

--- Buys an offer from the dealer. Returns the bus, or false and the reason.
function F.buy(S, offer)
  if S.bankrupt then return false, "The company is insolvent" end
  if S.cash < offer.price then
    return false, "Not enough cash: " .. U.thousands(offer.price - S.cash) .. " short (a loan helps)"
  end
  Co.book(S, "purchase", -offer.price, "Bought " .. offer.name .. (offer.kind == "used" and " (used)" or ""), true)
  local b = F.add(S, offer)
  return b
end

--- Sells a bus to the dealer (not while it runs a service). Returns the price, or false and why.
function F.sell(S, b)
  if b.assignment then return false, "Take it off its route first" end
  local price = F.resale(b)
  Co.book(S, "sale", price, "Sold " .. b.name .. " (" .. b.number .. ")", true)
  U.remove_if(S.fleet, function(x) return x == b end)
  return price
end

function F.in_workshop(b, now_abs)
  return b.status == "workshop" and now_abs < b.workshop_until
end

--- Refreshes a bus's status against the clock (the workshop lets go of it).
function F.refresh(b, now_abs)
  if b.status == "workshop" and now_abs >= b.workshop_until then b.status = "ready" end
end

function F.service_cost(b)
  return U.round(b.spec.service * (1 + (100 - b.condition) / 50), 0)
end

--- A workshop visit: restores the bus, which is out of service for a few hours.
--- Returns the cost, or false and why.
function F.service(S, b, now_abs, hours)
  if b.status == "workshop" then return false, "Already in the workshop" end
  local cost = F.service_cost(b)
  if S.cash < cost then return false, "Not enough cash" end
  Co.book(S, "maintenance", -cost, "Workshop: " .. b.name .. " (" .. b.number .. ")")
  b.condition = 100
  b.status = "workshop"
  b.workshop_until = now_abs + (hours or B.service_hours) * 60
  return cost
end

--- Kilometres driven: the odometer and the wear.
function F.drive(b, km)
  b.odometer = b.odometer + km
  b.km_total = b.km_total + km
  b.condition = U.clamp(b.condition - b.spec.wear * km / 100, 0, 100)
end

--- Damage in condition points (a crash).
function F.damage(b, points)
  b.condition = U.clamp(b.condition - points, 0, 100)
end

--- A day older: age.
function F.age_day(S)
  for _, b in ipairs(S.fleet) do b.age_days = b.age_days + 1 end
end

--- The standing cost of the fleet per day (insurance), before the difficulty factor.
function F.insurance_per_day(S)
  return U.sum(S.fleet, function(b) return b.spec.insurance * (1 + F.age_years(b) * 0.02) end)
end

function F.overhead_per_day(S)
  return B.overhead_base + B.overhead_per_bus * #S.fleet
end

--- The cheapest list: buses ready to take a new route (not in the workshop, not assigned).
function F.free_buses(S, now_abs)
  local out = {}
  for _, b in ipairs(S.fleet) do
    F.refresh(b, now_abs)
    if not b.assignment and b.status ~= "workshop" then out[#out + 1] = b end
  end
  return out
end

--- The bus the player is sitting in, found by its `.bus` file among the assigned-to-player
--- buses first, then among all.
function F.by_file(S, file, prefer)
  if not file then return nil end
  local lf = file:lower():gsub("\\", "/")
  local match
  for _, b in ipairs(S.fleet) do
    if b.file:lower():gsub("\\", "/") == lf then
      if prefer and prefer(b) then return b end
      match = match or b
    end
  end
  return match
end

return F
