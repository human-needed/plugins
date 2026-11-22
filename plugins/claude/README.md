# HUMAN_NEEDED for Claude

Stop watching Claude work. With this plugin, the edges of your screen glow and a soft chime plays
when Claude needs you, for example to approve a step or answer a question. A short green glow
shows when Claude is done. If you have the optional HUMAN_NEEDED Puck, it lights up too.

It works in the Claude desktop app (Code tab and Cowork), in Claude Code in a terminal, and in
VS Code.

## You need the free app

The plugin only reports Claude's state. The free HUMAN_NEEDED app shows the glow and plays the
sound. Download and install it from https://github.com/human-needed/app. If the app
isn't running, the plugin does nothing and never slows Claude down.

In Claude Code you can also install it with:

```
/plugin marketplace add human-needed/plugins
/plugin install humanneeded@humanneeded
```

## What it sends, and where

- **On your computer:** each Claude hook event (for example "a prompt was sent" or "Claude
  stopped") goes to the HUMAN_NEEDED app on the same computer, at `127.0.0.1:24816`. The event is
  Claude's hook data, which can include the prompt you just sent, and it never leaves your computer.
- **In Cowork and other cloud sessions:** the cloud can't reach your computer, so the plugin sends
  only the state (working, needs you, done), a hashed chat id and a timestamp to
  `relay.human-needed.com`. The relay finds your app by a hash of your Claude account id, so the
  account id itself is never sent.
- **Never sent off your computer:** your chats, prompts, code or files.

You can also ask Claude to "test my glow", "mute for an hour" or "make needs purple". It changes
these settings in the app on your computer.

## Licence

FSL-1.1-ALv2. See [LICENSE](LICENSE).
