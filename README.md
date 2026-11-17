# What is it?

This is a simple DCS World script that shows the (DCS) names of controls being 
pressed live. Very handy for telling/showing others what you're doing!

<img width="3440" height="1440" alt="image" src="https://github.com/user-attachments/assets/d1469595-f175-4203-8590-b149643b8908" />


The UI can be toggled on/off with `CTRL`+`SHIFT`+`V`.

In the F/A-18C, display pushbuttons also show what they do on the current
page, e.g. `Left MDI PB 12 (WYPT up)` or `UFC Option Select Pushbutton 3 (BALT)`.
Once the display has reacted, the line shows what changed:
`Right MDI PB 6 (1B -> 2B)`, and options the display boxes get a frame
around their name, solid when boxed and dashed when not (like `WYPT` on the
HSI). This needs the `Export.lua` line below.

# Installing

Copy the contents of the `mod` directory into `Saved Games\DCS\Scripts`. The
resulting directory should look like this:
```
Saved Games/DCS/
└── Scripts/
    ├── Hooks/
    │   └── ControlsVisualizer.lua      ← the hook DCS loads
    └── ControlsVisualizer/             ← the modules and overlay layout it uses
        ├── aircraft_dirs.lua
        ├── button_followup.lua
        ├── clickables.lua
        ├── cockpit_watch.lua
        ├── export_indications.lua
        ├── feed.lua
        ├── indication_debug.lua
        ├── indications.lua
        ├── input_watch.lua
        ├── mfd_labels.lua
        ├── overlay.dlg
        ├── overlay.lua
        └── overrides.lua
```

To name F/A-18C MFD and UFC buttons, also add this line to the end of
`Saved Games\DCS\Scripts\Export.lua` (create the file if it doesn't exist).
Hooks can't read cockpit display text, so this sends it to the hook over local
UDP (127.0.0.1, port 47833):
```lua
pcall(function() local lfs=require('lfs'); dofile(lfs.writedir()..'Scripts/ControlsVisualizer/export_indications.lua') end)
```

# AI Disclosure

This script was vibe coded. I have confirmed functionality but have not reviewed
the code. Draw your own conclusions from that.
