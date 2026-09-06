# Orchestrate + legato to the next tracks

A REAPER ReaScript that does everything
[`../orchestrate/`](../orchestrate/) does — takes a polyphonic sketch played
into a string *ensemble* patch and distributes it by pitch across the tracks
below it — and then runs a legato pass over each part it writes.

The point of the legato pass is to make a sample library play its **legato
transitions** instead of a fresh attack on every note.

Stock REAPER only — no SWS functions are called, though it runs fine alongside
SWS.

## Install

1. Copy `Orchestrate_and_legato_selected_notes_to_next_tracks.lua` somewhere
   REAPER can see it (`Options → Show REAPER resource path → Scripts/`).
2. **Actions → Show action list**, switch the *Section* dropdown to **MIDI
   Editor**.
3. **New action → Load ReaScript…**, pick the file.
4. Select it in the list and assign a shortcut.

Running it from the Main section will just tell you no MIDI editor is open — it
is a MIDI Editor action.

## Use

1. Make sure the next tracks below your source each hold a MIDI item lined up
   with the source item.
2. Open the source item in the MIDI editor and select the notes you want.
3. Fire the action.

Everything happens under one undo point. Re-running replaces the previous
result rather than stacking a second copy on top, so you can tweak the sketch
and re-run as often as you like.

This script is a **superset** of the orchestrator. Run one or the other, not
both — running both would distribute the material twice.

## What the legato pass does

For every note that continues a phrase — so, every note but the first of each
phrase:

- its **start moves 1/24 note earlier**, leaving it overlapping the note it is
  slurred from. That overlap is what triggers the legato transition;
- its **end is left where it was**, so the note simply gets longer and nothing
  downstream of it moves;
- its **velocity becomes 127**, which is where most libraries put the legato
  layer.

The first note of each phrase is not touched at all — it keeps its position and
its own velocity, so it plays the library's normal attack.

```
before   |--C--||--D--||--E--|
after    |--C--|
              |----D----|
                     |----E----|
         64      127      127
```

## What counts as one phrase

Two notes belong to the same phrase when **the first is still sounding as the
second attacks** and **the pitch changes**.

That means a phrase is broken by:

| | |
|---|---|
| **Any gap at all** | The notes have to touch or overlap. Raise `MAX_LEGATO_GAP_QN` if you play parts in by hand and your releases land a little early. |
| **A repeated pitch** | A repeat is rebowed, not slurred, so it starts a new phrase and keeps its own position and velocity. |
| **A simultaneous attack** | Two notes starting together on one part are a chord, not a line. |

Phrases are traced **per part**, after the distribution has decided which notes
each part plays. So the Vla line is followed as the Vla line, not as whatever
happens to be next in the source item.

A part that has gone divisi is traced as two lines. At each attack the script
pairs the new notes against the notes still sounding, closest in pitch first,
so a divided part's two lines stay separate instead of crossing. A note can
only be slurred from once, so two continuations never claim the same
predecessor.

## Guards

Three things stop the offset producing nonsense, in order of how badly they
would otherwise break the take:

- **The offset never eats more than half the note it is slurring from**
  (`MAX_OFFSET_FRACTION`). In a run of 32nd notes the notes are shorter than
  the offset, and without this each attack would land on — or before — the
  previous one. Because the cap is proportional, the run stays evenly spaced;
  it just shifts.
- **Nothing is pulled out of the front of its item.** A phrase starting at the
  item boundary is clamped there.
- **An attack is never pulled back over an earlier note of the same pitch**,
  which would leave two same-pitch notes overlapping — something samplers and
  REAPER's own editor both dislike.

A note held back by a guard still gets the legato velocity: it is still a
continuation, it just could not move as far as it wanted to.

## Keyswitches

Notes at or below `KEYSWITCH_MAX_PITCH` (everything under C0 by default) are
read as articulation switches, not music. They take no part in the voice
distribution or the phrase tracing, and are copied verbatim to every part.

They are, however, **pulled earlier by `KEYSWITCH_LEAD_QN`** (a 24th note, same
as the offset). A keyswitch sitting exactly on a note's attack would otherwise
end up *after* that attack once the note moved, and select the wrong
articulation. Whole keyswitch notes move, so their lengths and their order
survive. Set `KEYSWITCH_LEAD_QN = 0` to leave them alone.

## Configuration

The `CONFIG` table at the top of the script. The legato settings:

| Setting | Default | What it does |
|---|---|---|
| `LEGATO_OFFSET_QN` | `1/6` | How far earlier a continuation is pulled, in quarter notes. `1/6` of a quarter note is a 24th note — about 83 ms at 120 bpm. |
| `OFFSET_MODE` | `"qn"` | `"qn"` keeps the offset musical, scaling with tempo. `"ms"` keeps it physical, which is closer to how a recorded transition behaves — worth switching at very slow or very fast tempos. |
| `LEGATO_OFFSET_MS` | `80` | The offset in milliseconds, used when `OFFSET_MODE` is `"ms"`. |
| `LEGATO_VELOCITY` | `127` | Velocity given to every continuation. Set it to wherever your library's legato layer sits. |
| `MAX_LEGATO_GAP_QN` | `0` | How large a gap may sit between two notes and still leave them in one phrase. `0` means they must touch. `0.25` is a sixteenth note. |
| `MAX_OFFSET_FRACTION` | `0.5` | Never eat more than this much of the note being slurred from. |
| `KEYSWITCH_LEAD_QN` | `1/6` | How far earlier keyswitches are pulled. Keep at or above `LEGATO_OFFSET_QN`. |

Everything from the orchestrator is here too and behaves identically:
`MAX_TARGET_TRACKS`, `KEYSWITCH_MAX_PITCH`, `ONSET_TOLERANCE_QN`,
`DIVISI_ORDER`, `COPY_CC`, `COPY_TEXT_SYSEX`, `CLEAR_TARGETS` and
`ITEM_MATCH_TOLERANCE_SEC`. See [the orchestrator's
README](../orchestrate/README.md) for how the voice distribution decides which
part a note belongs to — the bass anchor, the divisi order and the rest.

## Things worth knowing

- **The pass reads the original geometry.** Slots and phrases are both worked
  out from where the notes actually sit, and the offset is applied as a final
  transform, so the offsets never feed back into the overlap detection. Running
  the script twice on the same source gives the same result.
- **CC is not moved.** CC1 / CC11 dynamics are copied at their original
  positions. If your library wants the modwheel to lead the attack, ride it in
  the source item.
- **A note entering over a held note on the same part is treated as continuing
  it.** In a divided part where one voice sustains and another enters above it,
  the entering note is slurred from the sustaining one. Usually what you want;
  rewrite the sketch's voice leading if it is not.
- **The divisi pairing is greedy**, closest pitch first. With two lines in one
  part and an awkward set of intervals it can occasionally pair a note with a
  line other than its own, or leave one attack starting a fresh phrase. It only
  affects which note the guards measure against, not whether the part is
  playable.
- **The source track is left exactly as it was.** Mute it yourself once you are
  happy with the result.

## Tests

The voicing and legato cores are pure Lua with no REAPER dependency, and the
script returns them as a module when loaded outside REAPER, so they can be
tested from a terminal:

```sh
lua5.4 tests/test_legato.lua
```

49 checks covering what keeps a phrase going, phrase tracing through repeats
and gaps and divisi, the offset and velocity rules, all three guards,
re-running stability, and the distribution and legato halves working together.
