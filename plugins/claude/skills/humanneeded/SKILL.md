---
name: humanneeded
description: Control the HumanNeeded desk puck (the USB light/chime that shows when Claude is working, done, or needs the user). Use when the user asks to test the puck, mute or unmute it, change its colours, light modes, durations, brightness, sounds or volume, or asks whether it is connected.
---

# HumanNeeded puck

The puck is run by the HumanNeeded app on the user's computer. Talk to it with the `hn` command
(installed by the app, on PATH). Run it with the Bash tool; on Windows, `hn` works from any shell.

| User says | Run |
|---|---|
| "is my puck connected?" / "what's it doing?" | `hn status` (JSON: app, puck, sessions) |
| "test my puck" | `hn status`, then `hn test needs` |
| "show me done/working/idle" | `hn test done` (or `working`, `idle`) |
| "mute for an hour" | `hn mute 60` (`hn mute 0` unmutes; sound only, the light still works) |
| "make needs purple" | `hn set needs.color #9B5BFF`, then `hn test needs` |
| "make done blink" | `hn set done.light blink`, then `hn test done` |
| "keep green on longer" | `hn set done.duration 10` (seconds, 1-3600) |
| "dimmer" / "brighter" | `hn set brightness <0-100>` |
| "turn the light off when idle" | `hn set idle.light off` |
| "louder alert when it needs me" | `hn set needs.sound beeps`, `hn set needs.repeat 3` |
| "which version?" | `hn version` |

Settings, `hn set <key> <value>`:

- Global: `brightness`, `volume` (0-100). Each state's own brightness/volume is a share of these.
- Per state (`needs`, `done`, `working`, `idle`): `<state>.color` `#RRGGBB`; `<state>.light`
  `off|solid|breathe|pulse|blink|heartbeat|flicker|spin`; `<state>.brightness` 0-100;
  `<state>.duration` seconds; `<state>.sound` `none|ding|chime|rising|arpeggio|bell|beeps|bloop|bright|clock|doorbell|fanfare|ripple|call|lullaby|harp`;
  `<state>.volume` 0-100; `<state>.repeat` 1-5. Idle has no sound.

Pick a hex value for named colours (purple `#9B5BFF`, red `#FF3B30`, pink `#FF5FA2`,
teal `#2EC4B6`, white `#FFFFFF`). After a change, run `hn test <state>` so the user sees it.
For anything else, point the user to the HumanNeeded app's settings window.

If `hn` is not found: the HumanNeeded app isn't installed or this session runs in the cloud.
Cloud sessions (claude.ai/code, Cowork) can't reach the puck's settings; they still light it
through the HumanNeeded relay when the user turned on the cloud link in the app.

Never send `hn event ...` yourself: the plugin's hooks do that.
