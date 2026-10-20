-- balance.lua: every number that tunes the economy, in one place.
-- Money is in the company's own currency units; they are roughly euros (a 12 m diesel
-- city bus new costs about 320,000). Change a value here, save the file, and the game
-- reloads the plugin.

local B = {}

-- ---------------------------------------------------------------------------------------
-- Vehicle classes. `price` is a new diesel bus; `capacity` seats plus a sensible standing
-- load; `fuel` litres per 100 km (diesel); `kwh` kWh per 100 km (electric); `maint` money
-- per km for a bus in good condition; `insurance` per day; `wear` condition points lost
-- per 100 km; `service` the base price of a workshop visit.
-- ---------------------------------------------------------------------------------------
B.classes = {
  minibus  = { label = "Minibus",        price = 175000, capacity = 40,  fuel = 21, kwh = 70,  maint = 0.17, insurance = 18, wear = 0.40, service = 450 },
  midi     = { label = "Midi bus",       price = 240000, capacity = 65,  fuel = 26, kwh = 95,  maint = 0.22, insurance = 24, wear = 0.38, service = 600 },
  standard = { label = "Standard 12 m",  price = 320000, capacity = 95,  fuel = 33, kwh = 130, maint = 0.30, insurance = 32, wear = 0.36, service = 800 },
  artic    = { label = "Articulated",    price = 455000, capacity = 150, fuel = 46, kwh = 180, maint = 0.42, insurance = 46, wear = 0.40, service = 1150 },
  double   = { label = "Double-decker",  price = 385000, capacity = 120, fuel = 38, kwh = 150, maint = 0.36, insurance = 40, wear = 0.38, service = 950 },
  coach    = { label = "Coach",          price = 400000, capacity = 55,  fuel = 28, kwh = 110, maint = 0.28, insurance = 34, wear = 0.30, service = 900 },
}
B.class_order = { "minibus", "midi", "standard", "artic", "double", "coach" }

-- A powertrain changes price, running costs and what the bus burns.
B.powertrains = {
  diesel   = { label = "Diesel",   price = 1.00, maint = 1.00, energy = "diesel" },
  hybrid   = { label = "Hybrid",   price = 1.25, maint = 0.95, energy = "diesel", fuel = 0.75 },
  electric = { label = "Electric", price = 1.55, maint = 0.80, energy = "electric" },
}

-- Energy prices (per litre / per kWh). They drift a little every day.
B.energy = {
  diesel   = { start = 1.55, lo = 1.05, hi = 2.60, drift = 0.015 },
  electric = { start = 0.28, lo = 0.18, hi = 0.45, drift = 0.008 },
}

-- ---------------------------------------------------------------------------------------
-- Ageing, wear, used market
-- ---------------------------------------------------------------------------------------
B.depreciation_per_year = 0.88      -- value kept after one year
B.value_floor = 0.10                -- of the new price
B.resale_margin = 0.92              -- the dealer pays this share of a bus's value
B.used_margin = 1.06                -- the dealer asks this much over its value
B.used_offers_per_week = 7
B.used_age_range = { 2, 14 }        -- years
B.km_per_year = 52000

B.service_threshold_default = 55    -- auto-service below this condition (setting)
B.service_hours = 4                 -- a service takes the bus off the road this long
B.breakdown_base = 0.004            -- chance per trip for a bus in perfect condition
B.towing_cost = 350

-- ---------------------------------------------------------------------------------------
-- Demand and fares (the AI-run services)
-- ---------------------------------------------------------------------------------------
-- The share of a full day's peak demand for each hour (0 to 23).
B.demand_by_hour = {
  [0] = 0.08, 0.05, 0.04, 0.04, 0.10, 0.28, 0.55, 0.95, 1.00, 0.75, 0.55, 0.55,
  0.62, 0.62, 0.65, 0.80, 0.95, 1.00, 0.80, 0.55, 0.40, 0.30, 0.20, 0.12,
}
B.weekday_demand = { 1.0, 1.0, 1.0, 1.0, 1.05, 0.72, 0.55 }  -- Monday .. Sunday
B.line_base_pax = 55                -- people one trip of an average line carries at peak demand
B.peak_load_share = 0.45            -- the busiest stretch holds this share of them at once
B.line_demand_range = { 0.65, 1.35 }
B.fare_min, B.fare_max = 0.5, 1.5   -- the fare level the player may set
B.fare_elasticity = 0.8             -- demand lost per unit of fare level above 1
B.fare_evasion = 0.04
B.default_fare = 2.60               -- when the map sells no ticket the plugin can read
B.subsidy_per_km = 1.35             -- the transit authority pays this per service km
B.punctuality = {                   -- share of the subsidy by how late the trip ended (s)
  { upto = 180, share = 1.00 },
  { upto = 360, share = 0.60 },
  { upto = math.huge, share = 0.25 },
}
B.on_time_limit = 180
B.overcrowd_ratio = 1.3             -- demand above this many times the capacity: unhappy people
B.urban_speed_kmh = 17              -- converts a trip's duration into kilometres when unseen

-- ---------------------------------------------------------------------------------------
-- Player-driven services
-- ---------------------------------------------------------------------------------------
B.player_subsidy_per_km = 1.35
B.pedestrian_fine = 5000
B.red_light_fine = 150
B.crash_cost_per_kj = 6.0
B.insurance_deductible = 400
B.insurance_cover = 0.70            -- of what a crash costs beyond the deductible
B.missed_trip_fine = 120
B.refuel_markup = 1.0
B.wash_cost = 25
B.repair_base = 150
B.repair_per_minute = 12

-- ---------------------------------------------------------------------------------------
-- Staff
-- ---------------------------------------------------------------------------------------
B.pool_size = 6
B.wage_base, B.wage_per_skill = 11.0, 0.14
B.hire_fee_days = 5                 -- of wages
B.severance_days = 3
B.shift_hours_regular = 8
B.shift_hours_limit = 9.5           -- beyond it drivers tire (more accidents)
B.overtime_rate = 1.5
B.idle_retainer = 0.4               -- an idle driver still costs this share of a shift
B.training_cost = 1500
B.training_gain = 4
B.skill_cap = 96
B.xp_per_day = 0.03
B.accident_per_100km = 0.035        -- at skill 50; falls as skill rises
B.accident_cost = { 700, 4800 }
B.accident_reputation = 2.0

-- ---------------------------------------------------------------------------------------
-- Company
-- ---------------------------------------------------------------------------------------
B.start_cash_default = 400000
B.overhead_base, B.overhead_per_bus = 120, 28
B.tax_rate = 0.20
B.loan_amounts = { 50000, 100000, 250000, 500000 }
B.loan_rate = 0.06                  -- per year, plus the risk surcharge below
B.loan_risk_surcharge = 0.04        -- at reputation 0, falling to 0 at 100
B.overdraft_rate = 0.14
B.overdraft_limit = 50000
B.bankrupt_days = 3
B.credit_base = 100000
B.credit_per_fleet_value = 0.6
B.credit_per_reputation = 1000

B.reputation_start = 55
B.reputation_pull = 0.08            -- daily share of the gap to the target it closes
B.demand_by_reputation = { 0.75, 1.25 }  -- demand factor at reputation 0 and 100

-- Difficulty scales income and costs (setting `difficulty`).
B.difficulty = {
  Easy   = { income = 1.25, cost = 0.85 },
  Normal = { income = 1.00, cost = 1.00 },
  Hard   = { income = 0.90, cost = 1.15 },
}

-- Economy pace: one day of play earns and costs this many days of realistic money, so a
-- game day (an hour or two of play at a sped-up clock) moves the books noticeably. Fines
-- and crash costs grow with it, but less (exponent below). The setting `pace` overrides.
B.pace_default = 8
B.event_pace_exponent = 0.6

B.history_days = 60
B.ledger_rows = 80
B.notable_amount = 2000             -- a booking this large gets its own ledger row

return B
