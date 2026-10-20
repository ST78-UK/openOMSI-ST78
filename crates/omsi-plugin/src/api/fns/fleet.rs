//! `fleet.*`: the vehicles installed, getting into one, and choosing which vehicle the
//! timetable's AI runs a tour with (the bus-company add-on's hooks, usable by any plugin).

use super::{def, o, p, rec};
use crate::api::{ApiError, ApiFn, Value};
use crate::io::FleetVehicle;

const NEW: &str = crate::api::VERSION;

fn vehicle(v: &FleetVehicle) -> Value {
    rec(vec![
        ("file", v.file.clone().into()),
        ("name", v.name.clone().into()),
        ("manufacturer", v.manufacturer.clone().into()),
        ("model", v.model.clone().into()),
    ])
}

/// `{ paint = "...", number = "...", swap = true }`: the keys a call may give.
fn opt_text(opts: Option<&Value>, key: &str) -> Result<Option<String>, ApiError> {
    match opts.and_then(|o| o.get(key)).filter(|v| !v.is_nil()) {
        None => Ok(None),
        Some(v) => v.to_text().map(Some).ok_or_else(|| ApiError(format!("omsi.fleet: `{key}` must be a string"))),
    }
}

pub static FNS: &[ApiFn] = &[
    def!("fleet.catalog", "fleet", [], "list of tables", "The vehicles installed, as the game menu's vehicle list offers them: `{file, name, manufacturer, model}` (`file` is what `fleet.place` and `fleet.assign` take; trailers, trams and other `.ovh` files are in it too: keep the `.bus` ones for buses).", NEW, None, false, |c, a| {
        Ok::<_, ApiError>(Value::List(c.io().fleet_catalog().iter().map(vehicle).collect()))
    }),
    def!("fleet.place", "fleet", [p("file", "string"), o("opts", "table")], "true, or false and the reason", "Gets the player into the vehicle `file` (a `file` of `fleet.catalog`). `opts`: `swap` (default `true`: in the place of the vehicle driven now, which goes; `false`: beside it) and `paint` (a livery's name; default at random). The vehicle is read in the background and is in the world some frames later: `fleet.busy` says so meanwhile and the `vehicle` event announces it.", NEW, WorldWrite, true, |c, a| {
        let file = a.str(0)?;
        let opts = a.opt_table(1)?;
        let paint = opt_text(opts, "paint")?;
        let swap = opts.and_then(|o| o.get("swap")).map_or(true, |v| v.truthy());
        Ok::<_, ApiError>(super::core::ok_or_reason(c.io().fleet_place(&file, paint.as_deref(), swap)))
    }),
    def!("fleet.busy", "fleet", [], "boolean", "Whether a vehicle that `fleet.place` asked for is still being read.", NEW, None, false, |c, a| Ok::<_, ApiError>(c.io().fleet_busy())),
    def!("fleet.assign", "fleet", [p("line", "string"), p("tour", "string"), p("file", "string"), o("opts", "table")], "true, or false and the reason", "From the tour's next departure on, the timetable's AI runs line `line`, tour `tour` (as `timetable.lines` names them) with the vehicle `file` instead of the map's own vehicles. `opts`: `number` (the fleet number the bus shows) and `paint` (a livery's name; default at random). A bus already on the road keeps running as it is. Not for a tour the player drives.", NEW, WorldWrite, true, |c, a| {
        let line = a.str(0)?;
        let tour = a.str(1)?;
        let file = a.str(2)?;
        let opts = a.opt_table(3)?;
        let number = opt_text(opts, "number")?.unwrap_or_default();
        let paint = opt_text(opts, "paint")?;
        Ok::<_, ApiError>(super::core::ok_or_reason(c.io().fleet_assign(&line, &tour, &file, &number, paint.as_deref())))
    }),
    def!("fleet.unassign", "fleet", [p("line", "string"), p("tour", "string")], "boolean", "Takes `fleet.assign` back: the map's own vehicles run the tour again from its next departure. `true` when there was an assignment.", NEW, WorldWrite, false, |c, a| {
        let line = a.str(0)?;
        let tour = a.str(1)?;
        Ok::<_, ApiError>(c.io().fleet_unassign(&line, &tour))
    }),
    def!("fleet.assignments", "fleet", [], "list of tables", "The tours that have an assignment: `{line, tour, file, number}`.", NEW, None, false, |c, a| {
        Ok::<_, ApiError>(Value::List(c.io().fleet_assignments().into_iter().map(|x| rec(vec![("line", x.line.into()), ("tour", x.tour.into()), ("file", x.file.into()), ("number", x.number.into())])).collect()))
    }),
];
