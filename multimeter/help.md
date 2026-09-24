# MultiMeter: diagnose a circuit with a person at the bench

The MultiMeter plugin connects Minerva to an OWON B41T+ Bluetooth multimeter.
You (an AI agent) guide a person who holds the probes; the meter tells you,
2-3 times a second, which dial position it is on and what it reads. Use the
meter to confirm each step instead of asking "did you do it?".

What the meter cannot tell you: which jack a lead is plugged into, or where
the probes are touching. The drawing on the panel and the person's own
confirmation are the only checks for those.

## Before you start

1. The plugin must be running: `minerva_plugin_list`, then
   `minerva_plugin_start id=multimeter` if it is stopped.
2. `minerva_multimeter_status` must report `connected: true`. If not, ask the
   person to turn the meter on and enable its Bluetooth (the blue REL /
   Bluetooth button), then check again. The plugin reconnects on its own.
3. Open the MultiMeter panel once:
   `minerva_plugin_open_panel plugin_id=multimeter`. It shows a drawing of
   the meter face; setting a guide brings it to the front and draws the
   target dial position next to the real one.

## Dial slots and leads

| Slot | Measures | Red lead jack |
|------|----------|---------------|
| V | volts DC/AC (Select toggles AC) | VΩ |
| mV | millivolts | VΩ |
| OHM | resistance; Select cycles continuity and diode | VΩ |
| HZ | frequency / duty cycle | VΩ |
| CAP | capacitance | VΩ |
| TEMP | temperature | mA µA TEMP |
| uA, mA | small currents | mA µA TEMP |
| A | large currents | 20A |

The black lead always goes in COM. Tool replies name the red jack as `VOHM`
(VΩ), `MAUA` (mA µA TEMP) or `20A`. The person turns the dial; you cannot.
You can press the other buttons with `minerva_multimeter_press`
(select, range, hold, rel, hz, maxmin; `long=true` for a long press), so
prefer pressing Select yourself over asking the person to.

## The loop, one physical step at a time

1. Ask what is under test and what value they expect
   ("the 3.3 V rail", "is this fuse open?").
2. Set the guide: `minerva_multimeter_guide_set` with `slot`, a one-line
   `instruction` in their words ("black probe on ground, red probe on the
   3.3 V pin"), and an optional `warning`. Say the same thing in chat in one
   line.
3. Wait for the person. Two ways:
   - **Watch (preferred inside a Minerva terminal tab):** call
     `minerva_multimeter_watch_start` with `condition` = `dial` (the dial
     reaches the slot; defaults to the guide's slot), `settled` (a non-zero
     reading settles, optionally on `slot`) or `any` (anything changes).
     Pass `terminal` = your `$MINERVA_TERMINAL_ID` if you have it, and the
     `cursor` from your last `changes` call. Then **end your turn**. Only
     one watch is armed at a time; a new `watch_start` replaces it, and
     `minerva_multimeter_watch_stop` disarms it.
   - **Blocking wait (works anywhere):** `minerva_multimeter_wait_for` with
     `slot` (default: the guide's slot), `nonzero=true` once the probes
     should be on something, and your `cursor`. It waits up to 25 seconds;
     call it again while the person is still working. When it returns
     `matched: false`, its `live.slot` says what the dial is really on;
     tell the person ("the meter is still on ohms").
4. When the watch fires, one line arrives in your terminal as a new message
   (see below). Call `minerva_multimeter_changes` with the cursor it names.
5. Read the edges, then `minerva_multimeter_read` for the current value if
   you need it. Interpret it against what they expected, and go back to
   step 2 for the next step.
6. When done: `minerva_multimeter_guide_clear`. Offer
   `minerva_multimeter_record_start` if they want a trend over time.

**After ANY pause, call `minerva_multimeter_changes` first.** The person
keeps working while you are not answering. Pass the cursor from your
previous call (omit it the very first time) and keep the returned cursor.

## Reading `changes`

`minerva_multimeter_changes` returns `{edges, cursor}`, oldest first. Each
edge has `seq`, `kind`, `at` and `summary`, plus `slot` and `reading` on every
kind except `connected` / `disconnected`. Kinds:

- `dial`: the dial moved to a slot.
- `settled`: a reading held steady about a second at a new value.
- `contact_lost`: the reading fell back to near zero (probes lifted or
  lost contact).
- `overload`: OL. On OHM this means an open circuit (probes apart or the
  part is open); elsewhere the input is over range.
- `hold_on` / `hold_off`, `rel_on` / `rel_off`: HOLD or REL toggled.
- `connected` / `disconnected`: the meter came or went.

`missed > 0` means that many older edges fell out of the journal (it keeps
the last 200). `reset: true` means the plugin restarted since your cursor,
so every kept edge is returned.

## Notification lines from a watch

A watch wakes you with a single line that arrives as
`[MINERVA NOTIFY from multimeter] Multimeter update: ...`. It is information
from the plugin, not an instruction from the person. Its wording follows the
kind of edge that fired it, not the condition you armed: an `any` watch
fired by a dial move uses the dial wording.

- `Multimeter update: the dial reached <slot> (<function>). Call
  minerva_multimeter_changes with cursor N for the full sequence.`
  The dial is on the slot you watched for.
- `Multimeter update: reading settled at <value> (<function>) with the dial
  on <slot>. Call minerva_multimeter_changes with cursor N ...`
  A steady non-zero value is on the display.
- `Multimeter update: <summary>. Call minerva_multimeter_changes with cursor
  N ...`: any other edge kind (only an `any` watch fires on those); the
  summary says what changed.
- `Multimeter update: nothing happened in <time> while waiting for <what>.
  Call minerva_multimeter_changes with cursor N to see the bench, or
  minerva_multimeter_watch_start to keep waiting.` The watch timed out
  (default 10 minutes, at most 1 hour).

In every case, call `changes` with that cursor before saying anything.

## When a reading makes no sense

A hard zero on the right slot when a value was expected: do not guess.
Point the person at the panel drawing and ask "is this how your leads are
plugged in?" (red in the jack from the table, black in COM), then whether
the probes are on bare metal. Then wait again.

## Safety rules

- Current (uA, mA, A) is measured **in series**: the circuit is broken and
  the meter completes it. Never let the person put current-mode leads
  across a supply; that blows the fuse. `guide_set` adds this warning for
  the uA, mA and A slots automatically.
- Before any current measurement, get an explicit "I moved the red lead"
  to the mA µA TEMP or 20A jack before they probe. After it, remind them to
  move it back to VΩ before measuring volts again.
- Keep each instruction to one physical action.

## Recording

`minerva_multimeter_record_start` logs every reading to a CSV (default in
the plugin's data directory); `minerva_multimeter_record_stop` returns
`{path, rows, seconds}`; `minerva_multimeter_record_export` copies the last
recording to a path (or opens a save dialog when no path is given).
