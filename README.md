# ⬡ noted_propattacher

> **A FiveM developer tool for visually placing and attaching props to ped bones.**
> Built as a standalone debug utility — designed to feed into a larger project down the road.

---

## What It Is

`noted_propattacher` is an in-game prop attachment editor for FiveM. Instead of guessing offset and rotation values by hand and restarting your server fifty times, you spawn a prop, drag it into place with your mouse, and export the exact `AttachEntityToEntity` values ready to paste into your script.

It's a developer tool — not a framework resource, not a production system. No syncing, no database, no permissions. Just you, your ped, and a prop that needs to be in the right place.

---

## Features

- **Spawn any prop by model name** and attach it to any ped bone
- **Live gizmo** — translation arrows (X/Y/Z) and rotation rings drawn in world space on the prop
- **Freecam** — hold RMB outside the panel to fly the camera around; release to return to the UI
- **Bone search** by name or raw index number
- **Nudge buttons + typeable inputs** with configurable step sizes (0.001 to 0.1 for offset, 1° to 45° for rotation)
- **Presets** for common carry positions (back rifle, hip holster, chest sling, thigh)
- **Recalibrate** — attempts to find the nearest bone to the prop's current world position and compute equivalent offset/rotation values for it
- **Two export formats:**
  - Full `AttachEntityToEntity` Lua snippet
  - Compact `{bone, pos = vec3(...), rot = vec3(...)}` table format
- **Attached props list** with individual delete and detach-all
- Minimize (`_`) releases NUI focus so you can look around — `/propattacher` or clicking the button restores it with all state intact
- Escape / ✕ to close

---

## Installation

1. Drop the `noted_propattacher` folder into your server's `resources` directory
2. Add `ensure noted_propattacher` to your `server.cfg`
3. Connect and run `/propattacher` in game

No dependencies. No framework required.

---

## Usage

### Basic flow

```
/propattacher          → open the tool
SPAWN tab              → type model name, pick bone, hit SPAWN
ADJUST tab             → drag gizmo arrows to move, drag rings to rotate
                         hold RMB outside panel to enter freecam (WASD to fly)
CONFIRM ✓              → locks the prop in place
EXPORT tab             → generate copy-pasteable Lua
_ button               → minimize, keep looking around, /propattacher to restore
```

### Controls (while a prop is active)

| Input | Action |
|---|---|
| LMB drag on axis arrow | Move offset along that axis |
| LMB drag on rotation ring | Rotate on that axis |
| RMB hold outside panel | Freecam (WASD + mouse look) |
| RMB release | Exit freecam, cursor returns |
| Scroll wheel | Z offset nudge |
| E | Confirm attach |
| Escape | Close UI |

### Export formats

**AttachEntityToEntity:**
```lua
local hash = GetHashKey("w_lr_rpg")
RequestModel(hash); while not HasModelLoaded(hash) do Wait(0) end
local prop = CreateObject(hash, 0,0,0, true,true,false)
SetEntityCollision(prop, false, false)
AttachEntityToEntity(
    prop, ped, GetPedBoneIndex(ped, 24818),
    0.1800, -0.0800, -0.1000,
    0.0000, 0.0000, 190.0000,
    true, true, false, true, 1, true
)
```

**Compact:**
```lua
{bone = 24818, pos = vec3(0.1800, -0.0800, -0.1000), rot = vec3(0.0000, 0.0000, 190.0000)},
```

---

## Known Limitations

- **Recalibration is approximate.** The ⟳ RECAL button finds the nearest bone and attempts to compute equivalent offset/rotation values, but the result is not 1:1 — expect some drift when switching bones, particularly for rotation. It's a useful starting point, not a perfect transform. This is a known issue that will be addressed in the larger project this tool is being rolled into.

- **Gizmo axis directions** are computed from bone rotation at spawn time and cached. If your ped's skeleton is heavily animated, the visual arrows may not perfectly align with the actual offset axes. Standing still gives the most accurate results.

- **Freecam** releases NUI input entirely. Your cursor disappears — use the panel before entering freecam or minimize/restore to get it back.

- This is a **single-player debug tool**. No multiplayer sync, no server persistence beyond the current session's console output.

---

## Roadmap

This resource is being released early while development continues on a larger project that will incorporate prop attachment as one of several features. That project is taking time to get right, so this standalone version is going out now in case it's useful to others in the meantime.

Things that will likely land in the bigger project:
- Accurate bone-to-bone recalibration
- Saving/loading attachment configurations
- Multi-ped support
- Better freecam feel

---

## Console Output

Every confirmed attachment prints a ready-to-use snippet to the server console:

```
[prop_attacher] AttachEntityToEntity(prop,ped,GetPedBoneIndex(ped,24818),0.1800,-0.0800,-0.1000,0.0000,0.0000,190.0000,true,true,false,true,1,true)
```

---

## Credits

Built by **noted**. Released as-is.

If you find it useful or fix the recalibration, feel free to improve on it.
