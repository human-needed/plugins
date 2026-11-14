---
name: humanneeded
description: Control the HumanNeeded desk puck (the USB light/chime that shows when Claude is working, done, or needs the user). Use when the user asks to test the puck, mute or unmute it, change its colours, light modes, durations, brightness, sounds or volume, or asks whether it is connected.
---

# HumanNeeded puck

The puck is run by the HumanNeeded app on the user's computer, which listens on
`http://127.0.0.1:24816`. Talk to it with `curl` from the Bash tool (always bypass
proxies, as below). Define this once per command:

```
HN="curl -s --noproxy 127.0.0.1 -m 3 -H Content-Type:application/json http://127.0.0.1:24816/v1"
```

| User says | Run |
|---|---|
| "is my puck connected?" / "what's it doing?" | `$HN/status` (JSON: app, puck, sessions) |
| "test my puck" | `$HN/status`, then `$HN/test/needs -X POST` |
| "show me done/working/idle" | `$HN/test/done -X POST` (or `working`, `idle`) |
| "mute for an hour" | `$HN/mute/60 -X POST` (`/mute/0` unmutes; sound only) |
| "make needs purple" | `$HN/set -d '{"key":"needs.color","value":"#9B5BFF"}'`, then `$HN/test/needs -X POST` |
| "make done blink" | `$HN/set -d '{"key":"done.light","value":"blink"}'`, then `$HN/test/done -X POST` |
| "keep green on longer" | `$HN/set -d '{"key":"done.duration","value":10}'` (seconds, 1-3600) |
| "dimmer" / "brighter" | `$HN/set -d '{"key":"brightness","value":40}'` (0-100) |
| "turn the light off when idle" | `$HN/set -d '{"key":"idle.light","value":"off"}'` |
| "louder alert when it needs me" | set `needs.sound` `beeps`, then `needs.repeat` `3` |
| "the light is stuck" / "clear the puck" | `$HN/clear -X POST` |

Settings keys:

- Global: `brightness`, `volume` (0-100). Each state's own brightness/volume is a share of these.
- Per state (`needs`, `done`, `working`, `idle`): `<state>.color` `#RRGGBB`; `<state>.light`
  `off|solid|breathe|pulse|blink|heartbeat|flicker|spin`; `<state>.brightness` 0-100;
  `<state>.duration` seconds; `<state>.sound` `none|ding|chime|rising|arpeggio|bell|beeps|bloop|bright|clock|doorbell|fanfare|ripple|call|lullaby|harp`;
  `<state>.volume` 0-100; `<state>.repeat` 1-5. Idle has no sound.

Pick a hex value for named colours (purple `#9B5BFF`, red `#FF3B30`, pink `#FF5FA2`,
teal `#2EC4B6`, white `#FFFFFF`). After a change, test that state so the user sees it.
For anything else, point the user to the HumanNeeded app's settings window.

No answer from `127.0.0.1:24816`: the HumanNeeded app isn't running (or this session runs in
the cloud, where the puck's settings can't be reached; cloud sessions still light it through
the HumanNeeded relay when the user turned on the cloud link in the app).

Never post to `/v1/event/...` yourself: the plugin's hooks do that.
