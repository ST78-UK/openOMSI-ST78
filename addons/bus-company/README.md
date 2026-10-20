# Bus Company Simulator

An add-on for openOMSI: found a company on any map, buy buses from the ones you have
installed, hire AI drivers, take over the map's timetable tours and run them - with AI drivers
or by driving them yourself - and keep the books in the black.

It is a Lua plugin (`plugins/bus_company/`) on top of a small engine addition, the
`omsi.fleet` API (see [Engine changes](#engine-changes)).

## Install

Copy the folder `plugins/bus_company` into the `plugins` folder of your openOMSI game (so that
`plugins/bus_company/main.lua` exists) and start a map with a bus. **Ctrl+B** shows and hides
the company window; **F10** gives it the mouse (its buttons also answer a plain click). The
plugin settings (currency, difficulty, economy pace, starting cash, ...) are under *Finance →
Settings*.

Needs an openOMSI with the `omsi.fleet` functions to swap buses and to choose the bus an AI
tour runs with. On a build without them the plugin still works: the market offers the buses
you have driven, AI-run tours are settled from the timetable, and *Drive* asks you to pick the
bus in the game menu.

## How it plays

**You start** with 400,000 (a setting), a used starter bus (the one you sit in) and a pool of
driver candidates.

| Tab | What you do |
| --- | --- |
| Overview | cash, today's and this week's result, reputation, a chart of daily profit, what needs attention |
| Fleet | your buses: age, odometer, condition, value; service (a few hours in the workshop) or sell |
| Market | **every installed bus** new, plus seven used ones a week (older, worn, cheaper); filter by class |
| Routes | the map's timetable tours: give a tour a bus and either an AI driver or yourself; set the fare level; see the expected profit before you commit |
| Staff | hire from the candidates (they differ in skill, punctuality, courtesy and wage), train, grant raises, dismiss |
| Finance | profit and loss by category, energy prices, loans, last big bookings, settings, a fresh start |

**A tour** is one line's tour in the map's timetable. One bus and one driver run all of its
trips.

* **AI driver.** Every trip is settled when its timetable time has passed. The model looks at
  the line's demand (stable per line, shown as Low/Medium/High), the hour and weekday, the
  weather, your reputation, the fare level and the bus's capacity: a minibus on a busy line
  turns people away, an articulated bus on a quiet line burns money. Fares come from the map's
  own ticket price. The authority pays per kilometre, less if the trip ends late. Fuel and
  upkeep follow the kilometres, scaled by the bus's condition. If the plugin saw the real AI bus
  on the road (`omsi.timetable.buses`) it uses the bus's real distance and delay; otherwise
  the timetable's. With the engine addition the AI really drives *your* bus type on the tour
  from its next departure on.
* **You drive.** *Drive it* puts you in the tour's bus (`omsi.fleet.place`) and takes the duty.
  The cash desk's real ticket sales are the company's fares; the authority pays per
  kilometre for a trip driven to its end, by punctuality and by your driving and comfort
  ratings. Crashes, red lights and hurt pedestrians cost money and reputation; refuelling,
  washing and repairing through the game menu are billed to the company. Nothing counts while
  you sit in a bus that is not yours.

**Money.** Daily: insurance per bus, depot and admin, wages (overtime above 8 hours, a retainer
for idle drivers), loan and overdraft interest. Monthly: tax on the profit, with losses carried
forward. Fuel and electricity prices drift. Loans are limited by your fleet's value and your
reputation. Cash below the overdraft limit for three days ends the company (the bank takes the
fleet) - switch that off in the settings for a sandbox.

**Reputation** (0 to 100) follows punctuality, fleet condition, accidents and the ratings of
your service, and moves demand by up to +-25 %.

**Economy pace** (default 8): one day of play earns and costs this many days of realistic
money, since a game day is an hour or two of play at a sped-up clock. Fines and crash costs
grow with it, but more slowly. `plugins/bus_company/balance.lua` holds every other number.

**Bus classes and prices** are worked out from a bus's name (minibus, midi, standard,
articulated, double-decker, coach; diesel, hybrid, electric), because the game does not tell the
plugin a bus's size. Mods name buses in countless ways: the file `vehicles.json` in the plugin's
data folder corrects any of them:

```json
{ "overrides": { "citaro g": { "class": "artic", "powertrain": "diesel", "price": 430000 } } }
```

(the key is a lower-case piece of the bus's name; the first match wins).

Fixed costs run only while you play: days between sessions cost nothing, and moving the game
clock forward by hand pays nothing for the skipped trips.

## Engine changes

The plugin API could read the timetable and the AI traffic but could not list installed
buses, swap the player's bus or choose a tour's vehicle. The patch adds the group `fleet`:

| Function | |
| --- | --- |
| `omsi.fleet.catalog()` | installed vehicles `{file, name, manufacturer, model}` (the game menu's list) |
| `omsi.fleet.place(file, [{swap, paint}])` | get into a vehicle (read in the background, then the `vehicle` event) |
| `omsi.fleet.busy()` | whether a placed vehicle is still loading |
| `omsi.fleet.assign(line, tour, file, [{number, paint}])` | the timetable's AI runs the tour with this vehicle from its next departure |
| `omsi.fleet.unassign(line, tour)` / `omsi.fleet.assignments()` | take it back / list |

Files: `crates/omsi-plugin` (`io.rs`: `PluginIo::fleet_*`, `api/fns/fleet.rs`, `api/docs.rs`),
`crates/omsi-sim` (`timetable_run/sim/choice.rs`: `ScheduleSim::choose` consults the tour's
assigned vehicle first, so the fleet read-ahead uploads it too), `crates/omsi-app`
(`plugins.rs`: the game's side, `app_impl/menus.rs`: `ensure_vehicle_list`).

After building, regenerate the API reference once:
`OMSI_API_BLESS=1 cargo test -p omsi-plugin api_manifest` (it rewrites `docs/plugin-api.json`
and the tables in `docs/PLUGINS.md`).

## Tests

```sh
lua tests/run.lua        # from this folder; Lua 5.3+ (texlua works too)
cargo test -p omsi-plugin --test fleet
```

`tests/run.lua` runs the plugin against a mock game (`tests/mock_omsi.lua`) that checks every
panel against the real panel limits and passes the saved company through a JSON round trip. It
covers classification, market, buying and selling, staff, a week of AI-run tours with the books
balanced to the cent, clock jumps, loans, tax and bankruptcy, driving a tour yourself, saving
and loading, a game without the fleet API, and a click on every button.

## Known limits

* The Rust changes were written without a compiler available and have **not been built or run**;
  the Lua plugin is tested only against the mock. Expect to fix a compile error or two and to
  tune the economy by playing.
* An AI-run tour's money is a model, not the AI's real passengers.
* Trips that end after midnight are not paid; a tour is one bus for the whole day.
* Not LAN-aware: in a LAN game every player would run their own company.
* `fleet.assign` needs the timetable's buses switched on for the map.
