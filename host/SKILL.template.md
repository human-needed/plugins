---
name: humanneeded
description: Control the HumanNeeded desk puck (the USB light/chime that shows when Claude is working, done, or needs the user). Use when the user asks to test, mute/unmute, change colours, light modes, durations, brightness, sounds or volume of their puck, or asks whether it is connected.
---

# HumanNeeded puck

{{RUN}}

In a cloud session (Cowork, claude.ai/code) the script can't reach the puck. There, to show
the user a state, call the puck connector's `set_state` tool if it is available; settings can't
be changed from a cloud session, so point the user to https://human-needed.com/settings/.

Each command prints the puck's reply: `OK`, `ERR <msg>`, a JSON line, or
`HumanNeeded puck not found` (unplugged, or another program such as a serial monitor
or the settings page has its port open).

| User says | Command |
|---|---|
| "test my puck" / "is it connected?" | `hello`, then `test needs` |
| "show me done/working/idle" | `test done` (or `working`, `idle`, `hello`) |
| "mute for an hour" | `mute 60` (`mute 0` unmutes; sound only, the light still works) |
| "make needs purple" | `set needs.color #9B5BFF` then `test needs` |
| "make done blink" | `set done.light blink` then `test done` |
| "keep green on longer" | `set done.duration 60` (seconds; 0 = as long as the state lasts) |
| "dimmer" / "brighter" | `get brightness`, then `set brightness <0-100>` |
| "turn the light off when idle" | `set idle.light off` |
| "louder alert when it needs me" | `set needs.sound beeps`, `set needs.repeat 3` |
| "what are my settings?" | `get all` |
| "the light is stuck" / "clear the puck" | `clear` (forgets all sessions; agents relight it on their next event) |

Settings (saved on the puck). Global masters:

- `brightness`, `volume`: 0-100. Each state's own brightness/volume is a share of these.

Per state, keys `<state>.<name>` where state is `needs`, `done`, `working` or `idle`:

- `color`: `#RRGGBB`
- `light`: `off` | `solid` | `breathe` | `pulse` | `blink` | `heartbeat` | `flicker` | `spin`
- `brightness`: 0-100
- `duration`: seconds the light shows this state, 0-3600 (0 = as long as the state lasts)
- `sound`: `none` | `ding` | `chime` | `rising` | `arpeggio` | `bell` | `beeps` | `bloop`
- `volume`: 0-100
- `repeat`: 1-5 (how many times the sound plays)

Idle never plays a sound and has no duration. Pick a sensible hex value for named colours
(purple `#9B5BFF`, red `#FF3B30`, pink `#FF5FA2`, teal `#2EC4B6`, white `#FFFFFF`).
After a change, run `test <state>` so the user sees and hears it.

Defaults: needs `#FFA62B` pulse, rising; done `#22E04A` pulse for 3 s, chime;
working `#3366FF` breathe, silent; idle `#FFD2A0` solid at 20 % brightness.
For everything at once, point the user to https://human-needed.com/settings/ (Chrome or Edge).
Setup help and troubleshooting: https://human-needed.com/start/

Don't send `working`/`needs`/`done`/`end` events by hand — the plugin's hooks do that.

## Cloud sessions

Cloud Claude sessions (Cowork, claude.ai/code) reach the puck through the HumanNeeded relay,
routed by the user's Claude account, so nothing needs setting up.

- A `HumanNeeded desk light:` hook note appears once per session only when states aren't getting
  through (no computer listening, relay unreachable, or no account id in the session). Mention it
  only if the user asks about the puck.
- On the user's computer, `hn.log` lines starting `relay:` show the connection and each state
  that arrived. "no Claude account in .claude.json" means that computer isn't signed in to Claude.
