# clock — Agent Notes

`clock` is your alarm clock and timer. Use it to **schedule your own future work**:
set an alarm or start a timer, end your turn, and when it comes due clock fires a
`run` signal that **wakes you** for a new turn. The human sets alarms and timers too,
in the GUI — you share one state.

When installed through Clatch, `clock` is on your PATH. Read the manual first:

```sh
clock --help
```

Verbs:

```sh
clock now                              # current time
clock list                             # every alarm & timer: id, when, label, note, who set it
clock alarm <time> "<label>"           # wall-clock alarm; wakes you when it fires
clock alarm <time> "<label>" --note "<text>"   # ← the prompt you get when it wakes you
clock alarm <time> "<label>" --repeat <days>   # daily | weekdays | weekends | mon,wed,fri
clock alarm <time> "<label>" --quiet           # fire as context (do NOT wake you)
clock edit <id> [<time>]               # change one; omitted flags keep their value
    --time · --label · --note · --repeat · --quiet · --wake
clock timer <dur> "<label>"            # countdown; wakes you with timer.done when it ends
clock cancel <id>                      # remove an alarm (aN) or timer (tN)
clock toggle <id>                      # enable / disable an alarm
clock pause <id> / clock resume <id>   # pause / resume a timer
clock show / clock hide                # open the window / put it back in the background
clock close                            # quit — the only thing that stops the alarms
```

`<time>`: `7:30` · `07:30` · `7:30am` · `19:30`  (a wall-clock time — today, else tomorrow)
`<dur>`:  `45s` · `10m` · `1h30m` · `90s`  (a countdown from now)

`clock set <when> …` is a shorthand: a clock time makes an alarm, a duration a timer.

## The note is your prompt

This is the most important thing on this page. When a wake alarm fires you get a
**fresh turn with no memory of setting it** — the note is the only context that
survives the gap. It arrives as `note` in the `alarm.fired` payload and is, in
effect, the prompt for that turn.

So write the *whole instruction*, addressed to someone who wasn't there:

```sh
# useless — you will not remember what "that thing" was
clock alarm 9:00 "check" --note "check that thing"

# useful — a stranger could act on this
clock alarm 9:00 "standup" \
  --note "check CI on PR #42; if green, tag the release and post the diff to #eng"
```

The human can write notes too, in the GUI, and edit yours. Treat a note you did not
write as an instruction from them.

How to use it well:

- **Schedule follow-ups instead of blocking.** Don't wait in a turn for something
  that takes minutes. `clock timer 10m "re-check CI on PR #42"`, finish your turn,
  and act when it wakes you. Use `alarm` for a wall-clock moment (`9:00 standup`),
  `timer` for "N minutes from now".
- **The alarms and timers you set wake only you.** clock records your `CLATCH_AGENT`
  and, when one fires, targets you specifically — other agents sharing this clock are
  not disturbed. So schedule freely; it's your own timer, not a shared bell.
- **Put the instruction in `--note`, not the label.** The label is the short name on
  the row ("standup"); the note is what you actually have to do. See above.
- **Edit rather than delete-and-recreate.** `clock edit a1 --note "…"` keeps the
  alarm's id and its owner, so it still wakes *you*. Recreating it hands ownership to
  whoever ran the command.
- **`--quiet` when you only want a record, not a turn** (e.g. a heartbeat you'll
  read next time you're active anyway). Quiet alarms fire `alarm.quiet` (context).
- **When woken**: run `clock list` to see what's due, do the work, then cancel or
  re-schedule as needed. A one-shot alarm disables itself after firing; a repeating
  one stays on for its next day.
- **Don't take over the screen to set an alarm.** clock keeps time with no window at
  all. If it's already running you need nothing; scheduling never raises a window.
  Call `clock show` only when the human asked to see it, and `clock hide` to put it
  back. Never call `clock close` to "tidy up" — that stops every alarm, including
  other agents'.
- **If a command fails**: *"app is not running"* → `clatch run com.arfium.clock`;
  *"blocked by the sandbox"* → retry with escalated permissions (don't relaunch a
  healthy app).

One caveat you can't fix yourself: a wake signal (`alarm.fired` / `timer.done`, type
`run`) only starts a turn if your grant on this app is **run-open**. If run is cut on
your bind the signal is dropped and you get nothing — ask the human to open run on
your bind to `com.arfium.clock`. (A `--quiet` alarm is the separate `alarm.quiet`
signal, type `context`: it reaches your next turn, it never starts one.)
