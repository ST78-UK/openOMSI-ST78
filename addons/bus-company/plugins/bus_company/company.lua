-- company.lua: the company's books. Cash, the ledger, loans, tax, reputation, and the
-- closing of days, weeks and months. Nothing here knows about buses, drivers or the game:
-- it works on one plain table (the company state) that is saved between sessions.

local U = require("util")
local B = require("balance")

local Co = {}

-- Which bookings make up the profit and loss (everything else is capital: buying and
-- selling buses, borrowing, repaying).
Co.INCOME = { fares = true, subsidy = true, bonus = true }
Co.CAPITAL = { purchase = true, sale = true, loan = true, repayment = true }
Co.LABELS = {
  fares = "Fares", subsidy = "Authority payments", bonus = "Bonuses",
  fuel = "Fuel and energy", maintenance = "Maintenance", wages = "Wages", staff = "Hiring and training",
  insurance = "Insurance", overhead = "Depot and admin", interest = "Interest", fines = "Fines",
  accidents = "Accidents and breakdowns", tax = "Tax",
  purchase = "Buses bought", sale = "Buses sold", loan = "Loans taken", repayment = "Loans repaid",
}
Co.ORDER = { "fares", "subsidy", "bonus", "fuel", "maintenance", "wages", "staff", "insurance", "overhead", "interest", "fines", "accidents", "tax", "purchase", "sale", "loan", "repayment" }

local function empty_totals() return {} end

--- A fresh company.
function Co.new(opts)
  opts = opts or {}
  return {
    version = 1,
    name = opts.name or "Bus Company",
    cash = opts.cash or B.start_cash_default,
    reputation = B.reputation_start,
    day_idx = nil,
    days_played = 0,
    energy = { diesel = B.energy.diesel.start, electric = B.energy.electric.start },
    loans = {},
    loss_carry = 0,
    neg_days = 0,
    bankrupt = false,
    today = empty_totals(), week = empty_totals(), month = empty_totals(), life = empty_totals(),
    day_stats = { trips = 0, ontime = 0, missed = 0, accidents = 0, rating_sum = 0, rating_n = 0, km = 0 },
    stats = { trips = 0, km = 0, pax = 0, ontime = 0, late = 0, missed = 0, accidents = 0, breakdowns = 0 },
    history = {},
    ledger = {},
    fleet = {}, drivers = {}, candidates = {}, assignments = {},
    market = { week = -1, used = {} },
    next_id = { bus = 1, driver = 1, loan = 1 },
    last_month_report = nil,
  }
end

-- ---------------------------------------------------------------------------------------
-- Bookings
-- ---------------------------------------------------------------------------------------

--- Books `amount` (income positive, cost negative) under `cat`; the cash moves at once.
--- Big bookings, and any with `note`, get a ledger row.
function Co.book(S, cat, amount, memo, note)
  if amount == 0 or amount ~= amount then return end
  S.cash = S.cash + amount
  for _, t in ipairs({ S.today, S.week, S.month, S.life }) do
    t[cat] = (t[cat] or 0) + amount
  end
  if note or math.abs(amount) >= B.notable_amount then
    U.push(S.ledger, { day = S.days_played, cat = cat, amount = U.round(amount, 2), memo = memo or "" }, B.ledger_rows)
  end
end

--- The profit (or loss) of a totals table: income minus costs, capital left out.
function Co.net(t)
  local n = 0
  for cat, v in pairs(t) do
    if not Co.CAPITAL[cat] then n = n + v end
  end
  return n
end

function Co.income(t)
  local n = 0
  for cat, v in pairs(t) do
    if Co.INCOME[cat] then n = n + v end
  end
  return n
end

function Co.costs(t) return Co.net(t) - Co.income(t) end  -- negative

-- ---------------------------------------------------------------------------------------
-- Loans
-- ---------------------------------------------------------------------------------------

function Co.debt(S)
  local d = 0
  for _, l in ipairs(S.loans) do d = d + l.principal end
  return d
end

--- How much the bank lets the company owe in total.
function Co.credit_limit(S, fleet_value)
  return U.round(B.credit_base + B.credit_per_fleet_value * (fleet_value or 0) + B.credit_per_reputation * S.reputation, -3)
end

function Co.loan_rate(S)
  return B.loan_rate + B.loan_risk_surcharge * (1 - S.reputation / 100)
end

--- Takes a loan; false and the reason when the bank says no.
function Co.borrow(S, amount, fleet_value)
  if S.bankrupt then return false, "The company is insolvent" end
  local room = Co.credit_limit(S, fleet_value) - Co.debt(S)
  if amount > room then return false, "The bank will lend at most " .. U.thousands(math.max(0, room)) .. " more" end
  S.loans[#S.loans + 1] = { id = "L" .. S.next_id.loan, principal = amount, rate = Co.loan_rate(S), since = S.days_played }
  S.next_id.loan = S.next_id.loan + 1
  Co.book(S, "loan", amount, "Loan taken", true)
  return true
end

--- Repays up to `amount` (oldest loan first); false and the reason when there is no cash.
function Co.repay(S, amount)
  local debt = Co.debt(S)
  if debt <= 0 then return false, "No loans" end
  amount = math.min(amount, debt)
  if S.cash < amount then return false, "Not enough cash" end
  local left = amount
  for _, l in ipairs(S.loans) do
    local pay = math.min(l.principal, left)
    l.principal = l.principal - pay
    left = left - pay
    if left <= 0 then break end
  end
  U.remove_if(S.loans, function(l) return l.principal < 0.5 end)
  Co.book(S, "repayment", -amount, "Loan repaid", true)
  return true
end

-- ---------------------------------------------------------------------------------------
-- Prices that drift
-- ---------------------------------------------------------------------------------------

function Co.drift_energy(S, rng)
  for kind, cfg in pairs(B.energy) do
    local p = S.energy[kind] or cfg.start
    -- a random step, pulled gently back towards the starting price
    local step = rng:normal(0, cfg.drift) + (cfg.start - p) / cfg.start * 0.02
    S.energy[kind] = U.clamp(U.round(p * (1 + step), 3), cfg.lo, cfg.hi)
  end
end

-- ---------------------------------------------------------------------------------------
-- Reputation
-- ---------------------------------------------------------------------------------------

--- A one-off change (a crash, a missed trip), kept between 0 and 100.
function Co.reputation_hit(S, delta)
  S.reputation = U.clamp(S.reputation + delta, 0, 100)
end

function Co.demand_factor(S)
  local lo, hi = B.demand_by_reputation[1], B.demand_by_reputation[2]
  return U.lerp(lo, hi, S.reputation / 100)
end

--- Reputation moves a share of the way towards how the day went.
function Co.update_reputation(S, fleet_condition)
  local d = S.day_stats
  if d.trips == 0 and d.missed == 0 then return end
  local punctual = d.ontime / math.max(1, d.trips)
  local incidents = math.min(1, (d.accidents * 3 + d.missed) / math.max(3, d.trips))
  local service = d.rating_n > 0 and (d.rating_sum / d.rating_n / 100) or 0.7
  local target = 100 * (0.40 * punctual + 0.20 * (fleet_condition / 100) + 0.20 * (1 - incidents) + 0.20 * service)
  S.reputation = U.clamp(U.round(S.reputation + (target - S.reputation) * B.reputation_pull, 2), 0, 100)
end

-- ---------------------------------------------------------------------------------------
-- Closing the day
-- ---------------------------------------------------------------------------------------

--- The part of the daily close that is about money itself: interest, the overdraft, tax at
--- the turn of a month, the history, the next day's prices. The caller has booked the
--- day's other costs (wages, insurance, overhead) first. `date` is { day, weekday }.
--- Returns a table of things worth telling the player: { week = bool, month = bool, ... }.
function Co.close_day(S, rng, date, fleet_condition)
  local out = {}
  -- interest on loans, and on an overdraft
  for _, l in ipairs(S.loans) do
    Co.book(S, "interest", -U.round(l.principal * l.rate / 365, 2), "Loan interest")
  end
  if S.cash < 0 then
    Co.book(S, "interest", -U.round(-S.cash * B.overdraft_rate / 365, 2), "Overdraft interest")
  end
  Co.update_reputation(S, fleet_condition or 80)
  Co.drift_energy(S, rng)

  -- the day goes into the history
  local t = S.today
  U.push(S.history, {
    day = S.days_played, revenue = U.round(Co.income(t), 0), costs = U.round(-Co.costs(t), 0),
    net = U.round(Co.net(t), 0), cash = U.round(S.cash, 0), rep = U.round(S.reputation, 1),
  }, B.history_days)
  out.net = Co.net(t)

  -- insolvency: cash below the overdraft limit for several days in a row
  if S.cash < -B.overdraft_limit then
    S.neg_days = S.neg_days + 1
    out.warning = S.neg_days
    if S.neg_days >= B.bankrupt_days then out.bankrupt = true end
  else
    S.neg_days = 0
  end

  S.today = empty_totals()
  S.day_stats = { trips = 0, ontime = 0, missed = 0, accidents = 0, rating_sum = 0, rating_n = 0, km = 0 }
  S.days_played = S.days_played + 1

  if date and date.weekday == 1 then
    out.week = true
    out.week_net = Co.net(S.week)
    S.week = empty_totals()
  end
  if date and date.day == 1 then
    out.month = true
    local result = Co.net(S.month)
    local tax = 0
    if result < 0 then
      S.loss_carry = S.loss_carry - result
    else
      local use = math.min(S.loss_carry, result)
      S.loss_carry = S.loss_carry - use
      tax = (result - use) * B.tax_rate
    end
    if tax > 0 then Co.book(S, "tax", -U.round(tax, 2), "Tax on last month's profit", true) end
    S.last_month_report = { result = U.round(result, 0), tax = U.round(tax, 0), cash = U.round(S.cash, 0) }
    out.month_result, out.tax = result, tax
    S.month = empty_totals()
  end
  return out
end

return Co
