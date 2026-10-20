//! `omsi.fleet`: the installed vehicles, getting into one, and giving a tour a vehicle.
mod common;

use common::{run, Game};
use omsi_plugin::FleetVehicle;

fn game() -> Game {
    let mut g = Game::new();
    g.fleet = vec![
        FleetVehicle { file: "Vehicles/MB_O305/MB_O305.bus".into(), name: "MB O305".into(), manufacturer: "Mercedes-Benz".into(), model: "O305".into() },
        FleetVehicle { file: "Vehicles/MAN_SD202/MAN_SD202.bus".into(), name: "MAN SD202".into(), manufacturer: "MAN".into(), model: "SD202".into() },
    ];
    g
}

fn check(tag: &str, body: &str, g: &mut Game) -> Vec<String> {
    let src = format!("local done = false\nfunction on_frame()\nif done then return end\ndone = true\n{body}\nend");
    run(tag, &src, g, 1);
    std::mem::take(&mut g.messages)
}

#[test]
fn the_catalogue_lists_the_installed_vehicles() {
    let mut g = game();
    let out = check(
        "fleet-catalog",
        r#"
        local list = omsi.fleet.catalog()
        assert(#list == 2, "two vehicles")
        assert(list[1].file == "Vehicles/MB_O305/MB_O305.bus" and list[1].manufacturer == "Mercedes-Benz" and list[1].model == "O305" and list[1].name == "MB O305")
        omsi.message("ok")
        "#,
        &mut g,
    );
    assert_eq!(out, ["ok"], "{out:?}");
}

#[test]
fn placing_a_vehicle_asks_the_game_and_reports_busy() {
    let mut g = game();
    let out = check(
        "fleet-place",
        r#"
        assert(omsi.fleet.busy() == false)
        local ok = omsi.fleet.place("Vehicles/MAN_SD202/MAN_SD202.bus", { paint = "Red", swap = false })
        assert(ok == true, "placed")
        assert(omsi.fleet.busy() == true)
        local ok2, why = omsi.fleet.place("Vehicles/MB_O305/MB_O305.bus")
        assert(ok2 == false and why:find("still loading"), tostring(why))
        local ok3, why3 = omsi.fleet.place("Vehicles/Nothing/Nothing.bus")
        assert(ok3 == false)
        omsi.message("ok")
        "#,
        &mut g,
    );
    assert_eq!(out, ["ok"], "{out:?}");
    assert_eq!(*g.log.borrow(), ["place Vehicles/MAN_SD202/MAN_SD202.bus Red false"]);
}

#[test]
fn swapping_is_the_default() {
    let mut g = game();
    check("fleet-swap", r#"assert(omsi.fleet.place("Vehicles/MB_O305/MB_O305.bus")); omsi.message("x")"#, &mut g);
    assert_eq!(*g.log.borrow(), ["place Vehicles/MB_O305/MB_O305.bus - true"]);
}

#[test]
fn a_tour_gets_a_vehicle_and_gives_it_back() {
    let mut g = game();
    let out = check(
        "fleet-assign",
        r#"
        assert(#omsi.fleet.assignments() == 0)
        assert(omsi.fleet.assign("136", "3", "Vehicles/MB_O305/MB_O305.bus", { number = "101" }))
        local a = omsi.fleet.assignments()
        assert(#a == 1 and a[1].line == "136" and a[1].tour == "3" and a[1].number == "101" and a[1].file:find("O305"))
        local ok, why = omsi.fleet.assign("999", "1", "Vehicles/MB_O305/MB_O305.bus")
        assert(ok == false and why:find("no line"), tostring(why))
        assert(omsi.fleet.unassign("136", "3") == true)
        assert(omsi.fleet.unassign("136", "3") == false)
        assert(#omsi.fleet.assignments() == 0)
        omsi.message("ok")
        "#,
        &mut g,
    );
    assert_eq!(out, ["ok"], "{out:?}");
}
