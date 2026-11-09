---
name: humanneeded
description: Control the HumanNeeded desk puck (the USB light/chime that shows when Claude is working, done, or needs the user). Use when the user asks to test, mute/unmute, change colours, light modes, durations, brightness, sounds or volume of their puck, or asks whether it is connected.
---

# HumanNeeded puck

The puck is driven by `${CLAUDE_PLUGIN_ROOT}/scripts/hn.ps1` (Windows) — run it with:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/hn.ps1" <command> [args]
```

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

## Cloud sessions (relay, test)

Cloud Claude sessions (claude.ai/code, cloud Cowork) reach the puck through the HumanNeeded relay:
the cloud hook signs each state and the puck connector on the PC receives it over a WebSocket.
The pairing token `hn1.<channel>.<secret>` is created by the connector in
`%USERPROFILE%\.humanneeded\relay.json` (Mac/Linux: `~/.humanneeded/relay.json`).

- "Set up / pair the cloud relay", "what is my relay token": on the PC, read the `token` from
  that file and tell the user to paste it into the plugin's **relay** option (Desktop: plugin
  settings for humanneeded; CLI: `/plugin` → humanneeded → configure). For claude.ai/code it can
  also go in the cloud environment's variables as `HN_RELAY=<token>`. Treat it like a password:
  anyone with it can light this puck.
- "Reset the relay token": delete `relay.json` and restart the Claude app; a new token is made.
- In a cloud session, the first prompt shows a `HumanNeeded 0.1.17 relay:` line saying whether the
  state was delivered. On the PC, `hn.log` lines starting `relay:` show what arrived.
