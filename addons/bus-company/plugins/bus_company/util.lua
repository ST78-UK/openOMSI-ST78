-- util.lua: small helpers shared by every module of the Bus Company add-on.
-- Plain Lua (5.1 to 5.4): no integer division, no bit operators, no goto.

local U = {}

function U.clamp(x, lo, hi)
  if x < lo then return lo end
  if x > hi then return hi end
  return x
end

function U.round(x, decimals)
  local m = 10 ^ (decimals or 0)
  if x >= 0 then return math.floor(x * m + 0.5) / m end
  return -math.floor(-x * m + 0.5) / m
end

function U.lerp(a, b, t) return a + (b - a) * t end

function U.copy(t)
  if type(t) ~= "table" then return t end
  local out = {}
  for k, v in pairs(t) do out[k] = U.copy(v) end
  return out
end

function U.find(list, pred)
  for i, v in ipairs(list) do
    if pred(v) then return v, i end
  end
  return nil
end

function U.remove_if(list, pred)
  local n = 0
  for i = #list, 1, -1 do
    if pred(list[i]) then table.remove(list, i); n = n + 1 end
  end
  return n
end

function U.sum(list, f)
  local s = 0
  for _, v in ipairs(list) do s = s + (f and f(v) or v) end
  return s
end

--- Appends to `list`, dropping the oldest entries beyond `max`.
function U.push(list, v, max)
  list[#list + 1] = v
  while #list > max do table.remove(list, 1) end
end

-- A seedable generator (Lua's own differs between versions, and the tests need the same
-- numbers every run). Park-Miller "minimal standard" in doubles: exact, portable.
local RNG = {}
RNG.__index = RNG

function U.rng(seed)
  seed = math.floor(seed or 1) % 2147483647
  if seed <= 0 then seed = seed + 2147483646 end
  return setmetatable({ s = seed }, RNG)
end

function RNG:next()
  self.s = (self.s * 48271) % 2147483647
  return self.s / 2147483647
end

--- A number in [lo, hi) (floats), or a whole number from lo to hi with `int`.
function RNG:range(lo, hi, int)
  local r = self:next()
  if int then return lo + math.floor(r * (hi - lo + 1)) end
  return lo + r * (hi - lo)
end

--- A normal deviate (Box-Muller), mean `mu`, standard deviation `sigma`.
function RNG:normal(mu, sigma)
  local u1, u2 = self:next(), self:next()
  if u1 < 1e-9 then u1 = 1e-9 end
  return (mu or 0) + (sigma or 1) * math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)
end

function RNG:chance(p) return self:next() < p end

function RNG:pick(list) return list[self:range(1, #list, true)] end

--- A stable 0..1 number for a text (the same line always gets the same demand).
function U.hash01(text)
  local h = 5381
  for i = 1, #text do h = (h * 33 + text:byte(i)) % 4294967291 end
  return (h % 100000) / 100000
end

-- Calendar: whole days since 1970-01-01 (days_from_civil), so the clock's date can be
-- compared across months and years.
function U.day_index(y, m, d)
  if m <= 2 then y = y - 1 end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local mp = (m + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

function U.hhmm(sec)
  sec = math.floor(sec) % 86400
  return string.format("%02d:%02d", math.floor(sec / 3600), math.floor(sec % 3600 / 60))
end

--- 12345.6 -> "12,346"
function U.thousands(n, sep)
  sep = sep or ","
  local neg = n < 0
  local s = tostring(math.floor(math.abs(n) + 0.5))
  local out = s:reverse():gsub("(%d%d%d)", "%1" .. sep):reverse()
  if out:sub(1, #sep) == sep then out = out:sub(#sep + 1) end
  return (neg and "-" or "") .. out
end

--- A short text cut to `n` characters with an ellipsis.
function U.cut(s, n)
  s = tostring(s or "")
  if #s <= n then return s end
  return s:sub(1, n - 1) .. "…"
end

--- Lower-case text with every non-alphanumeric run turned into one space (for matching
--- vehicle names such as "MAN_SD202" and "Lion's City G").
function U.words(s)
  return (" " .. tostring(s or ""):lower():gsub("[^%w]+", " ") .. " ")
end

return U
