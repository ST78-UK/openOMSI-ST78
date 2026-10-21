# Bus Company Simulator

An add-on for openOMSI: found a company on any map, buy buses from the ones you have
installed, hire AI drivers, take over the map's timetable tours and run them - with AI drivers
or by driving them yourself - and keep the books in the black.

It is a Lua plugin (`plugins/bus_company/`) on top of a small engine addition, the
`omsi.fleet` API (see [Engine changes](#engine-changes)).

## Install

Copy the folder `plugins/bus_company` into the `plugins` folder of your openOMSI game (so that
`plugins/bus_company/main.lua` exists) and start a map with a bus. **Ctrl+B** shows and hides
the company window; **Ctrl+L** opens it on the Livery tab; **F10** gives it the mouse (its buttons also answer a plain click). The
plugin settings (currency, difficulty, economy pace, starting cash, ...) are under *Finance →
Settings*.

Needs an openOMSI with the `omsi.fleet` functions to swap buses and to choose the bus an AI
tour runs with. On a build without them the plugin still works: the market offers the buses
you have driven, AI-run tours are settled from the timetable, and *Drive* asks you to pick the
bus in the game menu.

## How it plays

**One company per map.** Every map has its own company: its own books, fleet, staff and
tours, saved under the map's name. Load another map and you run another company; come back and
yours is as you left it. (A save made before this was added is adopted by the first map you
play.)

**You start** with 400,000 (a setting), a used starter bus (the one you sit in), one driver and
a pool of driver candidates.

| Tab | What you do |
| --- | --- |
| Overview | cash, today's and this week's result, reputation, a chart of daily profit, what needs attention |
| Fleet | your buses: age, odometer, condition, value; service (a few hours in the workshop) or sell |
| Market | **every installed bus** new, plus seven used ones a week (older, worn, cheaper); filter by class |
| Routes | the map's timetable tours: staffed automatically or by hand, with a bus and driver you pick for each, the trips you can drive yourself, the fare level and the expected profit |
| Staff | hire from the candidates (they differ in skill, punctuality, courtesy and wage), train, grant raises, dismiss |
| Finance | profit and loss by category, energy prices, loans, last big bookings, settings, a fresh start |
| Livery | repaint the bus you sit in, live, and set the company's liveries (Ctrl+L) |

**A tour** is one line's tour in the map's timetable. One bus and one driver run all of its
trips.

**Staffing the tours.** With *Auto-allocate buses and AI drivers to every tour* on (the default),
the company gives every tour that runs today a free bus and a free AI driver: at the start of a
session, at the start of each day and whenever you buy a bus or hire a driver. The busiest and
longest tours get the biggest buses and the best drivers. If there are fewer buses or drivers
than tours, the Routes tab and the Overview say how many tours are still open. The *Allocate
all* button does it on demand. A tour you stop by hand stays stopped (until you press *Allocate
all*), and one whose bus or driver you chose yourself is never touched.

**Choosing who runs a tour.** Select a tour in the Routes tab: *Next* beside the bus and the
driver steps through the free ones (and the present ones), *Apply bus / driver* changes the
tour, *I drive it all day* hands it to you and *Hand to AI driver* hands it back.

**Driving any service.** Every operated tour lists its trips. *Drive* on a trip gets you into
the tour's bus (swapping it in, in its livery) and takes the duty at that trip. On a tour the AI
runs, that trip is yours today: the AI model skips it, the cash desk's fares and the authority's
per-kilometre pay for the trip are yours, and the AI carries on with the rest. A duty you start
from the game menu in a company bus on one of the company's tours counts the same way.

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

**Liveries.** The Livery tab lists the liveries (paint schemes) of the bus you sit in; a click
puts it on at once: the game reads the bus again and puts it where it stands (so speed, doors
and switches start afresh, as with the menu's reload). A company bus remembers its livery, so
it is placed in it again and the timetable's AI runs its tours in it from the next departure;
*Paint all ... buses of this model* does the whole model, and the Fleet tab cycles the livery of
a bus you are not in. Needs the engine addition `omsi.fleet.repaint`.

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
| `omsi.fleet.liveries([file])` | the liveries (paint schemes) of a vehicle, by name (default: the one driven) |
| `omsi.fleet.livery()` | the livery the driven vehicle wears (`nil`: the model's own textures) |
| `omsi.fleet.repaint([livery])` | puts the driven vehicle in another livery, live (it is read again and put where it stands; `nil`: the model's own textures) |

Files: `crates/omsi-plugin` (`io.rs`: `PluginIo::fleet_*`, `api/fns/fleet.rs`, `api/docs.rs`),
`crates/omsi-sim` (`timetable_run/sim/choice.rs`: `ScheduleSim::choose` consults the tour's
assigned vehicle first, so the fleet read-ahead uploads it too), `crates/omsi-app`
(`plugins.rs`: the game's side, `app_impl/menus.rs`: `ensure_vehicle_list`,
`app_impl/vehicles.rs`: `reread_driven_vehicle`, the menu's reload with a livery of your choice,
`game_lists.rs`: `bus_liveries`).

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
balanced to the cent, clock jumps, loans, tax and bankruptcy, driving a tour yourself, driving
one trip of an AI tour, the allocation of buses and drivers, a company per map (and the move of
an old save), saving and loading, liveries, a game without the fleet API, and a click on every
button.

## Known limits

* The Rust changes were written without a compiler available and have **not been built or run**;
  the Lua plugin is tested only against the mock. Expect to fix a compile error or two and to
  tune the economy by playing.
* An AI-run tour's money is a model, not the AI's real passengers.
* Trips that end after midnight are not paid; a tour is one bus for the whole day.
* A repaint reads the bus again: it comes back where it stood, but with the speed, doors and
  switches of a freshly placed bus. On a game without `omsi.fleet.repaint` the Livery tab says so.
* When you take a trip over from the AI, the timetable's AI bus of that trip may still run beside
  you: the plugin only leaves it out of the books.
* Not LAN-aware: in a LAN game every player would run their own company.
* `fleet.assign` needs the timetable's buses switched on for the map.
