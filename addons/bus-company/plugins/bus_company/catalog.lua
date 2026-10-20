-- catalog.lua: what a bus is worth and costs to run, and what the dealers offer.
--
-- openOMSI tells the plugin which buses are installed (omsi.fleet.catalog) but not how big
-- they are, so the class (minibus, standard, articulated, double-decker, coach), the
-- powertrain and from them the price and running costs are worked out from the bus's name.
-- A file `vehicles.json` in the plugin's data folder can correct any of it:
--   { "overrides": { "citaro g": { "class": "artic", "powertrain": "diesel", "price": 430000 } } }
-- (the key is a lower-case piece of the bus's name; the first match wins).

local U = require("util")
local B = require("balance")

local C = {}

-- Name patterns, tried in this order. Words are lower-case, separated by single spaces
-- (U.words), so " g " means the word "g" on its own. Mods name their buses in countless ways:
-- the lists are generous, and the override file is the cure for the rest.
local PATTERNS = {
  double = { "double decker", "doppeldecker", "doubledecker", " dd ", " sd200 ", " sd202 ", " sd 200 ", " sd 202 ", "routemaster", "enviro400", "enviro 400", "olympian", "trident", " dl ", "b5tl", "alx400", "gemini", "ad 270", "ad270" },
  artic = { "articulated", "gelenk", " ng 2", " ng 3", " ng2", " ng3", " sg 2", " sg 3", " sg2", " sg3", " ag 3", " ag3", "o305g", "o 305 g", "o405g", "o 405 g", " citaro g ", "citaro g", " lion s city g ", "lions city g", "lion s city 18", "urbino 18", " capacity ", "capacity", " gl 2", " gl2", " lf 18", " 18m ", " 18 m ", "crealis", "irisbus agora l", "van hool ag", " ng272 ", " ng313 ", " ng 272 ", " ng 313 " },
  coach = { "reisebus", " coach ", "tourismo", "travego", "setra s 4", "setra s4", " hdh ", "intercity", " ul 4", "overland", "contrast", "flixbus", " fernbus" },
  minibus = { "minibus", " mini ", "sprinter", "daily ", " a45 ", " a 45 ", "city 8", "kleinbus", " 8 m ", " 8m " },
  midi = { " midi ", "citaro k", " o530 k", " o 530 k", "solo 8", "solo 9", "urbino 8", "urbino 9", "urbino 10", " 10 m ", " 10m ", " sl8 ", " a66 ", " a76 ", " compact", "city 10" },
}
local ELECTRIC = { "elektro", "electric", " ecitaro ", "e citaro", " ebus ", " e bus ", "urbino electric", "battery", " ev ", "bev ", " e mobility", "trolley" }
local HYBRID = { "hybrid", " hev ", "hybrido" }
-- Things that are not road buses (trams, trains, trailers): never sold.
-- (trailers and trams are never road buses; "train", "bahn" and the like give way to a name
-- that says "bus", such as a "Bahnhofsbus")
local NEVER_A_BUS = { "tram", "strassenbahn", "straßenbahn", "locomotive", "trailer", "anhanger", "anhänger", "anhaenger" }
local NOT_A_BUS = { "train", " zug ", "bahn", "metro" }

local function has_any(words, list)
  for _, p in ipairs(list) do
    if words:find(p, 1, true) then return true end
  end
  return false
end

--- Whether a catalogue entry is a road bus the company can run.
function C.is_bus(v)
  local file = (v.file or ""):lower()
  if not file:match("%.bus$") then return false end
  local words = U.words((v.manufacturer or "") .. " " .. (v.model or "") .. " " .. (v.name or ""))
  -- "bahn" etc. only exclude when the bus is not also named a bus
  if has_any(words, NEVER_A_BUS) then return false end
  if has_any(words, NOT_A_BUS) and not words:find(" bus ", 1, true) then return false end
  return true
end

local overrides = {}

--- Reads the override file's table (see the top of this file).
function C.set_overrides(t)
  overrides = {}
  if type(t) ~= "table" then return end
  for key, o in pairs(t) do
    if type(key) == "string" and type(o) == "table" then
      overrides[#overrides + 1] = { key = key:lower(), o = o }
    end
  end
  table.sort(overrides, function(a, b) return a.key < b.key end)
end

--- The class, powertrain, price and the numbers behind them for a catalogue entry.
--- Pure: the same entry always gives the same spec.
function C.spec(v)
  local text = (v.manufacturer or "") .. " " .. (v.model or "") .. " " .. (v.name or "")
  local words = U.words(text)
  local class = "standard"
  for _, cls in ipairs({ "double", "artic", "coach", "minibus", "midi" }) do
    if has_any(words, PATTERNS[cls]) then class = cls; break end
  end
  local power = "diesel"
  if has_any(words, ELECTRIC) then power = "electric"
  elseif has_any(words, HYBRID) then power = "hybrid" end
  local price_override
  local lower = text:lower()
  for _, ov in ipairs(overrides) do
    if lower:find(ov.key, 1, true) then
      local o = ov.o
      if B.classes[o.class] then class = o.class end
      if B.powertrains[o.powertrain] then power = o.powertrain end
      price_override = tonumber(o.price)
      break
    end
  end
  local cls, pt = B.classes[class], B.powertrains[power]
  -- A little variety between models of one class, stable per model (+-8 %).
  local wobble = 0.92 + 0.16 * U.hash01(v.file or text)
  local price = U.round(cls.price * pt.price * wobble, -2)
  if price_override and price_override > 0 then price = price_override end
  local fuel_mult = pt.fuel or 1
  return {
    class = class,
    class_label = cls.label,
    powertrain = power,
    power_label = pt.label,
    price = price,
    capacity = cls.capacity,
    energy = pt.energy,
    -- litres or kWh per 100 km
    consumption = (pt.energy == "electric" and cls.kwh or cls.fuel * fuel_mult) * (0.95 + 0.1 * U.hash01("c" .. (v.file or text))),
    maint = cls.maint * pt.maint,
    insurance = cls.insurance * (power == "electric" and 1.2 or 1),
    wear = cls.wear,
    service = cls.service * (power == "electric" and 0.9 or 1),
  }
end

-- ---------------------------------------------------------------------------------------
-- Value of a bus
-- ---------------------------------------------------------------------------------------

--- What a bus of this age (years) and condition (0 to 100) is worth.
function C.value(spec, age_years, condition)
  local f = math.max(B.value_floor, B.depreciation_per_year ^ age_years)
  return U.round(spec.price * f * (0.55 + 0.45 * U.clamp(condition, 0, 100) / 100), -1)
end

--- What the dealer pays for the bus.
function C.resale(spec, age_years, condition)
  return U.round(C.value(spec, age_years, condition) * B.resale_margin, -1)
end

--- Per-km running cost without fuel (maintenance, scaled by condition).
function C.maint_per_km(spec, condition)
  return spec.maint * (1 + (100 - U.clamp(condition, 0, 100)) / 100)
end

-- ---------------------------------------------------------------------------------------
-- The dealers
-- ---------------------------------------------------------------------------------------

--- A new bus: every model is always available at its price.
function C.new_offer(v)
  local spec = C.spec(v)
  return { kind = "new", file = v.file, name = v.name, spec = spec, age = 0, condition = 100, odometer = 0, price = spec.price }
end

--- A used bus of a random model: its age, wear and price.
function C.used_offer(v, rng)
  local spec = C.spec(v)
  local age = rng:range(B.used_age_range[1], B.used_age_range[2], true) + rng:range(0, 0.99)
  local condition = U.clamp(U.round(97 - age * 3.2 - rng:range(0, 16), 0), 20, 92)
  local odometer = U.round(age * B.km_per_year * rng:range(0.75, 1.25), -2)
  return {
    kind = "used", file = v.file, name = v.name, spec = spec,
    age = U.round(age, 1), condition = condition, odometer = odometer,
    price = U.round(C.value(spec, age, condition) * B.used_margin, -1),
  }
end

--- The week's offers: `models` is the catalogue's list of buses.
function C.weekly_used(models, rng)
  local out = {}
  if #models == 0 then return out end
  for _ = 1, math.min(B.used_offers_per_week, #models * 2) do
    out[#out + 1] = C.used_offer(rng:pick(models), rng)
  end
  table.sort(out, function(a, b) return a.price < b.price end)
  return out
end

return C
