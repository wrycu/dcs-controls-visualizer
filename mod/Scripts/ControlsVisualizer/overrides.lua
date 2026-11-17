-- Manual fixes for controls whose clickabledata hint doesn't describe their
-- positions (it lists mouse actions instead) and that have no per-position
-- input bindings (clickables.apply_bindings), keyed by DCS unit type, then
-- cockpit arg. `positions` are listed from the lowest arg value to the highest;
-- `positions = false` removes the position labels; `switch = true` treats a
-- control the cockpit defines as a button as a switch that stays where it's
-- put (reported on every change, with its position).

return {
    ["FA-18C_hornet"] = {
        -- hint: "Landing Gear Control Handle, (RMB)UP/(LMB)DOWN/(MW)EMERGENCY DOWN".
        -- 0 = DOWN: at spawn on the ground the handle rests at 0, and a gear-up
        -- press shows it moving to 1 and bouncing back (weight-on-wheels lock).
        [226] = { name = "Landing Gear Control Handle", positions = { "DOWN", "UP" } },
        [228] = { name = "Landing Gear Emergency Down Rotate", positions = false },
        -- hint: "Wing Fold Control Handle, (RMB)CW/(LMB)CCW/ (MW)PULL/STOW"; DCS-BIOS WING_FOLD_ROTATE
        [295] = { name = "Wing Fold Control Handle", positions = { "FOLD", "HOLD", "UNFOLD" } },
        [296] = { name = "Wing Fold Control Handle", positions = { "STOW", "PULL" } },
        -- hint: "IFF Mode 4 Switch, DIS/AUD /DIS/OFF" (top to bottom); the
        -- bindings set OFF = -1 and DIS = 0, none sets DIS/AUD.
        [355] = { name = "IFF Mode 4 Switch", positions = { "OFF", "DIS", "DIS/AUD" } },
        -- Video record panel: no bindings (device 0), hints list top to
        -- bottom, the reverse of the arg values.
        [175] = { name = "Selector Switch", positions = { "RDDI", "LDDI", "HMD" } },
        [176] = { name = "Selector Switch", positions = { "RDDI", "LDIR", "HUD" } },
        -- Latching switches defined as buttons (default_button2); positions
        -- from their bindings ("AV COOL Switch - EMERG/NORM": down 1, up 0).
        [297] = { name = "AV COOL Switch", switch = true, positions = { "NORM", "EMERG" } },
        [375] = { name = "APU Control Switch", switch = true, positions = { "OFF", "ON" } },
        [233] = { name = "Launch Bar Control Switch", switch = true, positions = { "RETRACT", "EXTEND" } },
        [344] = { name = "Fuel Dump Switch", switch = true, positions = { "OFF", "ON" } },
    },
}
