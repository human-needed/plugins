# humanneeded-lab (test build, Windows)

Tests a cloud link with no account key and no setup step. Install it **next to** `humanneeded`:
local sessions keep using `humanneeded`, and this plugin only acts inside cloud VMs.

## How it works

1. In a cloud session the hook makes a random 32-byte secret S and asks the model to call
   `set_state` once with `pair=S`. That call crosses Anthropic's bridge to this PC.
2. Both sides derive `channel = HMAC(S,"hn-lab-channel")[:32]` and `mac = HMAC(S,"hn-lab-mac")`.
3. Every state after that is signed by the VM hook and sent through the existing relay under the
   channel. The PC accepts only valid signatures, within 5 minutes, never the same nonce twice.

The relay sees only the channel. Someone who learns the channel can see message timing but can't
read the key, fake a state or replay one. No relay changes were needed.

## Local result (11-09, live relay, simulated VM): 19/19

Pairing, channel derivation, signed delivery, and rejection of replayed, forged, stale,
wrong-channel and malformed messages. Not tested locally: the parts only a cloud session has.

## Cloud test

1. Install `humanneeded-lab`, then quit and reopen the Claude desktop app.
   `%USERPROFILE%\.humanneeded\lab\lab.log` should show `started 0.2.0-lab.1`.
2. Start a new cloud Cowork task with:
   `Say hi. Then run: cat /tmp/hn-lab/lab.log`
3. Send one more message in it: `Run: sleep 5; cat /tmp/hn-lab/lab.log`
4. Paste both outputs into the Claude Code chat on the PC.

Pass: the VM log shows `PAIRED`; the PC log shows `call: set_state ... pair=channel xxxxxxxx`
(the model's call crossed the bridge) and `verified` lines for later states, including `done`.

What each failure would mean:
- No `asked the model to pair` in the VM log: hook output doesn't run or reach the model.
- Asked, but no `call:` on the PC: the model didn't call it, or the bridge dropped it.
- `call:` on the PC but `delivered:0` afterwards: the PC couldn't connect to the relay.
