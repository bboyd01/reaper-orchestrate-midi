# Orchestrate selected notes to the next tracks

A REAPER ReaScript that takes a polyphonic sketch on one track — the kind you play
into a string *ensemble* patch — and distributes it by pitch across the tracks
below it, turning it into a Vln 1 / Vln 2 / Vla / Vcl / Db setup.

The highest sounding voice goes to the first track below the source, the next
highest to the second, and so on. The lowest sounding voice always lands on the
last part in use, so the bass line stays put when the texture thins.

Stock REAPER only — no SWS functions are called, though it runs fine alongside SWS.

## Install

1. Copy `Orchestrate_selected_notes_to_next_tracks.lua` somewhere REAPER can see it
   (`Options → Show REAPER resource path → Scripts/`).
2. **Actions → Show action list**, switch the *Section* dropdown to **MIDI Editor**.
3. **New action → Load ReaScript…**, pick the file.
4. Select it in the list and assign a shortcut.

Running it from the Main section will just tell you no MIDI editor is open — it is
a MIDI Editor action.

## Use

1. Make sure the next tracks below your source each hold a MIDI item lined up with
   the source item.
2. Open the source item in the MIDI editor and select the notes you want to
   orchestrate.
3. Fire the action.

Everything happens under one undo point, so a single Ctrl/Cmd+Z puts it all back.
Re-running replaces the previous result rather than stacking a second copy on top,
so you can tweak the sketch and re-run as often as you like.

## How many tracks get used

The script counts the thickest moment in your selection and uses that many tracks,
capped at five. Two-voice material writes to the next two tracks and leaves the
rest alone; five-or-more-voice material uses all five.

| Max simultaneous voices | Tracks written |
|---|---|
| 2 | +1, +2 |
| 4 | +1 … +4 |
| 5 or more | +1 … +5 |

Source on track 5 means targets on tracks 6–10 at most.

## How voices are assigned

A note's part is decided once, at its attack, from its pitch rank among
**everything sounding at that instant** — including notes still held from earlier.
A pedal tone keeps the bottom part while the line above it moves; an inner line
moving inside a held outer frame stays in the middle.

### Fewer voices than parts — top down, with a bass anchor

The upper voices fill from the top, and the lowest voice drops to the bottom part
in use. The parts in between are tacet.

```
5 voices, 5 parts:  A5  F5  C5  A4  F3
                    ↓   ↓   ↓   ↓   ↓
                   Vln1 Vln2 Vla Vcl Db

3 voices, 5 parts:  G5  D5      B3
                    ↓   ↓       ↓
                   Vln1 Vln2 —  —  Db
```

Without the anchor, `B3` would climb to Vla every time the chord thinned and drop
back to Db when it filled out again. With it, the bass line stays where it belongs.

### More voices than parts — inner parts divide first

Everyone gets one note, then the surplus is handed out cyclically as
**Vla → Vcl → Vln 2 → Vln 1 → Db**, so the inner parts go divisi while the outer
lines stay monophonic as long as possible. Db divides last.

| Voices | Vln 1 | Vln 2 | Vla | Vcl | Db |
|---|---|---|---|---|---|
| 6 | 1 | 1 | **2** | 1 | 1 |
| 7 | 1 | 1 | **2** | **2** | 1 |
| 8 | 1 | **2** | **2** | **2** | 1 |
| 9 | **2** | **2** | **2** | **2** | 1 |
| 10 | **2** | **2** | **2** | **2** | **2** |

Notes are handed out contiguously by pitch, so a doubled part always gets adjacent
voices — never a top note and a bottom note in the same item.

### A lone note

A single sounding note is simultaneously the top voice and the bottom one, so
neither rule decides it. It is compared against the midpoint of the selection's
overall pitch range: upper half goes to Vln 1, lower half to Db. That stops a solo
bass note jumping to Vln 1 whenever the upper parts rest, and stops an exposed
melodic fragment falling to Db.

## What else gets copied

- **CC, pitch bend, program change, channel and poly pressure** — copied to every
  track that receives notes, with CC curve shapes and Bézier tension preserved.
  Tracks that get no notes are not touched.
- **Keyswitches** — notes at or below MIDI pitch 11 (everything under C0) are read
  as articulation switches, not music. They take no part in the voice distribution
  and are copied verbatim to every part, so a low keyswitch is never mistaken for
  the bass voice. See `KEYSWITCH_MAX_PITCH` below if your library sits higher.
- **The source track** is left exactly as it was. Mute it yourself once you are
  happy with the result.

Velocity, channel, note length and per-note mute all survive the trip. PPQ
positions are converted through project time, so target items with a different
PPQ resolution, start offset or play rate still line up.

## Configuration

The `CONFIG` table at the top of the script:

| Setting | Default | What it does |
|---|---|---|
| `MAX_TARGET_TRACKS` | `5` | Most tracks to write to. |
| `KEYSWITCH_MAX_PITCH` | `11` | Notes at or below this pitch are keyswitches. Raise to `23` if your library keyswitches up to B0 **and** you never write below the bass's low C. |
| `ONSET_TOLERANCE_QN` | `0.03` | Chord-attack window in quarter notes (~15 ms at 120 bpm). Doubles as the release tolerance, so legato tails do not read as extra voices. Raise for loosely played input. |
| `DIVISI_ORDER` | `{3,4,2,1,5}` | Which parts take a second note first, once there are more voices than parts. |
| `COPY_CC` | `true` | Copy CC / PC / bend / pressure. |
| `COPY_TEXT_SYSEX` | `false` | Copy text and sysex events, REAPER notation events included. |
| `CLEAR_TARGETS` | `true` | Wipe each target item before writing. Turn off to layer passes instead of replacing them. |
| `ITEM_MATCH_TOLERANCE_SEC` | `0.001` | How far a target item's start may sit from the source item's and still count as an exact match. |

## Things worth knowing

- **Targets are validated before anything is written.** If a track below the source
  is missing, or has no MIDI item overlapping the source item, the script names the
  offenders and changes nothing — it will not leave you half orchestrated.
- **Item matching** prefers an exact positional match and otherwise takes the item
  with the greatest overlap, so slightly offset items still work.
- **A new note entering above a held one briefly doubles that part.** A sustaining
  note cannot change track partway through, so if you hold a top note and then
  attack a higher one over it, both sit in the Vln 1 item until the held note
  releases. Rewrite the sketch's voice leading if that matters.
- **Target tracks are simply the next ones by track number**, folder parents
  included. Keep your string section contiguous below the sketch track.

## Tests

The voicing logic is pure Lua with no REAPER dependency, and the script returns it
as a module when loaded outside REAPER, so it can be tested from a terminal:

```sh
lua5.4 tests/test_voicing.lua
```

76 checks covering the capacity tables, rank-to-part mapping, the bass anchor,
divisi order, onset clustering, legato tolerance and the degenerate cases.
