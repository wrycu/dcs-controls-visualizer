# What is it?

This is a simple DCS World script that shows the (DCS) names of controls being 
pressed live. Very handy for telling/showing others what you're doing!

The UI can be toggled on/off with `CTRL`+`SHIFT`+`V`.

# Installing

Copy the contents of the `mod` directory into `Saved Games\DCS\Scripts`. The
resulting directory should look like this:
```
Saved Games/DCS/
└── Scripts/
    ├── Hooks/
    │   └── ControlsVisualizer.lua      ← the hook DCS loads
    └── ControlsVisualizer/             ← the modules and overlay layout it uses
        ├── clickables.lua
        ├── cockpit_watch.lua
        ├── feed.lua
        ├── input_watch.lua
        ├── overlay.dlg
        ├── overlay.lua
        └── overrides.lua
```

# AI Disclosure

This script was vibe coded. I have confirmed functionality but have not reviewed
the code. Draw your own conclusions from that.