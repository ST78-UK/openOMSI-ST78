-- drivers.lua: the company's AI drivers: the candidates, hiring, wages, morale, training.

local U = require("util")
local B = require("balance")
local Co = require("company")

local D = {}

local FIRST = { "Anna", "Ben", "Carla", "David", "Elena", "Farid", "Greta", "Hugo", "Ines", "Jakub", "Katrin", "Luca", "Maria", "Nils", "Olga", "Pavel", "Rosa", "Stefan", "Tamara", "Umar", "Vera", "Wojciech", "Yasmin", "Zoran", "Aisha", "Bruno", "Chloe", "Dmitri", "Emre", "Fiona", "George", "Helga", "Ivan", "Julia", "Kemal", "Lena", "Marek", "Nadia", "Oskar", "Petra" }
local LAST = { "Schmidt", "Novak", "Kowalski", "Rossi", "Hughes", "Petrov", "Yilmaz", "Larsen", "Costa", "Weber", "Nowak", "Dubois", "Horvat", "Silva", "Becker", "Jansen", "Popescu", "Murphy", "Kaya", "Fischer", "Lindqvist", "Marino", "Ivanov", "Walker", "Brandt", "Haddad", "Svoboda", "Keller", "Moreau", "Okafor", "Berg", "Santos", "Wagner", "Dvorak", "Clarke", "Hoffmann", "Farkas", "Meyer", "Kovacs", "Lehmann" }

--- What the market pays a driver of this skill, per hour.
function D.market_wage(skill)
  return U.round(B.wage_base + B.wage_per_skill * skill, 1)
end

--- A candidate for the job.
function D.generate(S, rng)
  local skill = U.clamp(U.round(rng:normal(58, 15), 0), 25, 92)
  local d = {
    id = "D" .. string.format("%02d", S.next_id.driver),
    name = rng:pick(FIRST) .. " " .. rng:pick(LAST),
    age = rng:range(23, 61, true),
    skill = skill,
    punctuality = U.clamp(U.round(skill + rng:normal(0, 10), 0), 20, 95),
    courtesy = U.clamp(U.round(skill + rng:normal(0, 12), 0), 20, 95),
    wage = 0,
    morale = 70,
    exp_days = 0,
    hours_today = 0,
    hours_week = 0,
    trained_day = -99,
    raise_weeks = 0,
  }
  S.next_id.driver = S.next_id.driver + 1
  d.wage = U.round(D.market_wage(skill) * rng:range(0.94, 1.06), 1)
  return d
end

--- Refills the pool of candidates (some stay a few weeks, some go).
function D.refresh_pool(S, rng)
  -- a third leave each week
  U.remove_if(S.candidates, function() return rng:chance(0.34) end)
  while #S.candidates < B.pool_size do
    S.candidates[#S.candidates + 1] = D.generate(S, rng)
  end
  table.sort(S.candidates, function(a, b) return a.skill > b.skill end)
end

function D.get(S, id)
  return U.find(S.drivers, function(d) return d.id == id end)
end

function D.hire_fee(d) return U.round(d.wage * B.shift_hours_regular * B.hire_fee_days, 0) end

--- Hires a candidate. Returns the driver, or false and the reason.
function D.hire(S, id)
  if S.bankrupt then return false, "The company is insolvent" end
  local d, i = U.find(S.candidates, function(c) return c.id == id end)
  if not d then return false, "That candidate has gone" end
  local fee = D.hire_fee(d)
  if S.cash < fee then return false, "Not enough cash for the agency fee" end
  Co.book(S, "staff", -fee, "Hired " .. d.name)
  table.remove(S.candidates, i)
  d.hired_day = S.days_played
  S.drivers[#S.drivers + 1] = d
  return d
end

--- Lets a driver go (severance pay). The caller takes them off their route first.
function D.fire(S, d)
  local pay = U.round(d.wage * B.shift_hours_regular * B.severance_days, 0)
  Co.book(S, "staff", -pay, "Severance: " .. d.name)
  U.remove_if(S.drivers, function(x) return x == d end)
  return pay
end

function D.can_train(S, d)
  return S.days_played - d.trained_day >= 14 and d.skill < B.skill_cap
end

--- Training: more skill. Returns the cost, or false and why.
function D.train(S, d)
  if d.skill >= B.skill_cap then return false, "Already as good as they get" end
  if S.days_played - d.trained_day < 14 then return false, "Trained recently" end
  if S.cash < B.training_cost then return false, "Not enough cash" end
  Co.book(S, "staff", -B.training_cost, "Training: " .. d.name)
  d.skill = math.min(B.skill_cap, d.skill + B.training_gain)
  d.punctuality = math.min(B.skill_cap, d.punctuality + B.training_gain / 2)
  d.courtesy = math.min(B.skill_cap, d.courtesy + B.training_gain / 2)
  d.trained_day = S.days_played
  d.morale = math.min(100, d.morale + 6)
  return B.training_cost
end

--- Grants the raise a driver asked for: the wage becomes the market's.
function D.grant_raise(S, d)
  d.wage = math.max(d.wage, D.market_wage(d.skill))
  d.raise_weeks = 0
  d.morale = math.min(100, d.morale + 8)
end

function D.wants_raise(d)
  return D.market_wage(d.skill) > d.wage * 1.08
end

--- What a driver costs for a day in which they worked `hours`.
function D.day_pay(d, hours)
  local reg = math.min(hours, B.shift_hours_regular)
  local over = math.max(0, hours - B.shift_hours_regular)
  local pay = d.wage * (reg + B.overtime_rate * over)
  if hours < B.shift_hours_regular then
    pay = pay + B.idle_retainer * d.wage * (B.shift_hours_regular - hours)
  end
  return pay
end

--- Chance of an accident per 100 km for this driver (tired drivers are worse).
function D.accident_rate(d, hours)
  local base = B.accident_per_100km * (1.5 - d.skill / 100) / 1.0
  if hours and hours > B.shift_hours_limit then base = base * (1 + (hours - B.shift_hours_limit) * 0.6) end
  return base
end

--- A day's end for the drivers: pay, morale, experience. Returns the total wages (positive).
--- `cost_mult` is the difficulty's factor.
function D.close_day(S, rng, cost_mult)
  local total = 0
  for _, d in ipairs(S.drivers) do
    local h = d.hours_today
    local pay = D.day_pay(d, h) * (cost_mult or 1)
    total = total + pay
    Co.book(S, "wages", -U.round(pay, 2), d.name)
    if h > 0 then d.exp_days = d.exp_days + 1 end
    if h > 0 and d.skill < B.skill_cap then d.skill = math.min(B.skill_cap, d.skill + B.xp_per_day) end
    -- morale: drifts towards 70, hurt by overwork and low pay, helped by a decent shift
    local m = d.morale + (70 - d.morale) * 0.05
    if h > B.shift_hours_limit then m = m - 4 end
    if d.wage < D.market_wage(d.skill) * 0.95 then m = m - 1.2 end
    if h >= 4 and h <= B.shift_hours_regular then m = m + 0.8 end
    d.morale = U.clamp(m, 0, 100)
    d.hours_week = d.hours_week + h
    d.hours_today = 0
  end
  return total
end

--- The turn of a week: raise requests, people who quit. Returns the list of drivers who
--- left (the caller takes their routes away) and those who ask for a raise.
function D.close_week(S, rng)
  local quit, ask = {}, {}
  for _, d in ipairs(S.drivers) do
    d.hours_week = 0
    if D.wants_raise(d) then
      d.raise_weeks = d.raise_weeks + 1
      if d.raise_weeks == 1 then ask[#ask + 1] = d end
      if d.raise_weeks >= 2 then d.morale = math.max(0, d.morale - 10) end
    else
      d.raise_weeks = 0
    end
    if d.morale < 25 and rng:chance(0.35) then quit[#quit + 1] = d end
  end
  for _, d in ipairs(quit) do U.remove_if(S.drivers, function(x) return x == d end) end
  return quit, ask
end

--- Words for a rating number.
function D.grade(v)
  if v >= 85 then return "Excellent" end
  if v >= 70 then return "Good" end
  if v >= 55 then return "Fair" end
  return "Poor"
end

return D
