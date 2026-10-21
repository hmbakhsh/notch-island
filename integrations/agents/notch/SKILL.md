---
name: notch
description: "Notify the user on their Mac with a banner that drops out of the screen notch, using the `notch` CLI. Use when a long-running task finishes or fails, when you are blocked and need their input or approval, or when something happened that they would want to see without watching the terminal. Not for routine progress updates."
---

# notch

`notch` shows a short message in a black island that grows out of the MacBook
notch (or the top centre of whichever screen the mouse is on). It is on PATH at
`~/.local/bin/notch`. Messages queue, hide after 5 seconds, pause while hovered,
and are dismissed on click.

## When to send one

- A task they are waiting on is done: tests, builds, deploys, long runs, research.
- Something failed and needs them.
- You are blocked on a question or a permission and can't continue.

Send one message per event. Don't send progress ticks, and don't notify for work
they are clearly watching live in the chat.

## Usage

```sh
notch TITLE [BODY] [options]
```

| Option | Meaning |
|---|---|
| `-b, --body TEXT` | Second line, up to two lines |
| `-s, --source TEXT` | Small label top-right. Use `<agent> · <project>`, e.g. `Claude · backend` |
| `-i, --icon NAME` | SF Symbol name |
| `-a, --app NAME` | Use an app's icon, e.g. `Claude`, `Codex` |
| `-c, --color COLOR` | Icon tint: `red orange yellow green mint teal blue indigo purple pink gray` or `#RRGGBB` |
| `-t, --time SECONDS` | How long it stays (default 5) |
| `--sticky` | Stay until clicked or dismissed |
| `-o, --open URL\|PATH` | Open on click (a PR, a report, a file) |
| `-r, --run COMMAND` | Run a shell command on click |
| `--sound NAME` | System sound: `Glass`, `Ping`, `Submarine`, … |
| `--json JSON` / `--json -` | Same fields as JSON (`title body source icon app image color seconds open run sound`) |
| `--dismiss` | Hide the message on screen now |
| `--inbox` | Open/close the inbox: recent messages plus T3 threads waiting on the user |

Keep the title to a few words and the body to one line of facts. Include
numbers that matter (counts, durations, PR number) rather than adjectives.

## Conventions

| Event | Icon | Colour | Extra |
|---|---|---|---|
| Success | `checkmark.circle.fill` | `green` | |
| Failure | `xmark.octagon.fill` | `red` | `--sound Basso` |
| Needs input / approval | `questionmark.bubble.fill` | `orange` | `--sticky --sound Glass` |
| Info / FYI | `info.circle.fill` | `blue` | |
| PR opened or updated | `arrow.triangle.pull` | `purple` | `-o <PR URL>` |

If you sent a sticky "needs input" message and they have since answered, run
`notch --dismiss`.

## Examples

```sh
notch "Tests passed" -b "412 passed in 2m14s" -s "Claude · backend" \
  -i checkmark.circle.fill -c green

notch "Deploy failed" -b "railway: build step exited 1" -s "Claude · web-app" \
  -i xmark.octagon.fill -c red --sound Basso -o "https://railway.app/…"

notch "Need your call" -b "Drop the old jobs table or keep it?" -s "Claude · api" \
  -i questionmark.bubble.fill -c orange --sticky --sound Glass
```

Every message is also kept in `~/.local/state/notch/history.jsonl` (one JSON
entry per line, newest last), so the user can find it later from the bell in
the bar. T3 threads that finish or ask a question are announced automatically;
don't send a separate `notch` just to say a T3 turn ended.

If `notch` is not found, the machine isn't set up for it; skip the notification
rather than failing the task (it is installed with notch-island's
`just install`).
