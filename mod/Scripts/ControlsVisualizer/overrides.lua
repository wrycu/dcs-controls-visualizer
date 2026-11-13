-- Manual fixes for controls whose clickabledata hint doesn't describe their
-- positions (it lists mouse actions instead), keyed by DCS unit type, then
-- cockpit arg. `positions` are listed from the lowest arg value to the highest,
-- like hints; `positions = false` removes the position labels.

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
        -- hint: "IFF Mode 4 Switch, DIS/AUD /DIS/OFF"; DCS-BIOS COM_IFF_MODE4_SW
        [355] = { name = "IFF Mode 4 Switch", positions = { "DIS/AUD", "DIS", "OFF" } },
    },
}
