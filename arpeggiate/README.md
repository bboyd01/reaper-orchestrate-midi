# Arpeggiate selected pattern over the following chords

A REAPER ReaScript for the MIDI editor. Play a figure (an arpeggio, a broken
chord, an Alberti bass) over one chord, block in the chords that follow, select
the figure and run the action. Every following chord is replaced by the figure,
rebuilt on that chord: same rhythm, velocities and contour, new pitches.

Stock REAPER only — no SWS functions are called.

## Install

1. Copy `Arpeggiate_selected_pattern_over_following_chords.lua` somewhere
   REAPER can see it (`Options → Show REAPER resource path → Scripts/`).
2. **Actions → Show action list**, switch the *Section* dropdown to **MIDI
   Editor**.
3. **New action → Load ReaScript…**, pick the file.
4. Select it in the list and assign a shortcut.

## Use

1. Set the MIDI editor's **Key Snap** key and scale (the dropdowns at the
   bottom of the editor). The chosen key is read even while snapping is off.
2. Write the figure, then the chords after it as block chords (quarter, half
   or whole notes).
3. Select the figure's notes and fire the action.

Unselected notes shorter than that (8ths and below) are not chords: anything
like that between the figure and the chords, or elsewhere, is ignored and left
as it is.

Everything happens under one undo point.

### Example

Key snap D major (or B minor), measure 1 selected:

```
figure  B4 D5 F#5 B5 | B4 D5 F#5 B5 | B4 D5 A5 B5 | B4 D5 F#5 B5     (Bm, 16ths)
chords  A4 C#5 E5 A5  (whole note)  →  A4 C#5 E5 A5 | … | A4 C#5 G5 A5 | …
        A4 B4 E5 G5   (whole note)  →  A4 B4  E5 G5 | … | A4 B4 F#5 G5 | …
```

The figure climbs B–D–F#–B one chord tone at a time, with an A as a neighbour
below the top B in group 3. Over A major it climbs A–C#–E–A, and the neighbour
is the G below the top A. The second chord plays A, B, E and G, so the figure
climbs those four notes one at a time — A–B–E–G — instead of leaping over the
G to an A, and the neighbour becomes the F# below the top G.

## How the figure is mapped

- **Chord tones and non-chord tones.** The figure is split into the notes
  that spell its chord (root, third, fifth, plus a 7th it dwells on, as in an
  arpeggiated maj7) and its non-chord tones, each read as a *passing* note
  (a step in and a step on the same way), a *neighbour* (a step away and back)
  or a *leap* (approached or left by a jump).
- **Each chord's tones are the notes it plays** — 7ths, 6ths, 9ths, 11ths and
  sus notes included, in any voicing or inversion; doublings change nothing.
  A chord of only one or two pitch classes (a bare fifth) gets a third and
  fifth from the Key Snap key.
- **Chord tones climb the chord's own notes.** Think of a chord's notes as the
  rungs of a ladder, all the way up the keyboard. A figure chord tone that is
  one rung above the previous one in the figure is one rung above it in the
  copy, two rungs is two, and so on. So a figure that steps through its chord
  one note at a time steps through every chord one note at a time, taking in
  whatever the chord plays rather than leaping over its 7th or 9th. Over a
  plain triad this is the same as mapping root to root, third to third.
- **Decorations stay decorations.** A non-chord tone keeps its distance in key
  steps from the chord tone it leans on (of the chord tones either side of it,
  the nearer one; the one it resolves to on a tie), so a passing note still
  passes and a neighbour still neighbours. Chromatic notes keep their
  alteration (B–A#–B over Bm becomes E–D#–E over Em).
- **Same note in, same note out.** Every time the figure plays a given note,
  the copy plays the same note, so a figure built from repeated groups comes
  out as repeated groups.
- **Up and down always follow the figure.** Every step goes the same way as
  the figure's step: up stays up, down stays down, a repeat stays a repeat.
  Where the mapping would bend that (two decorations squeezed into one gap,
  say), the fewest notes move, as little as possible, keeping the figure's
  step sizes in chord tones; a chord tone only ever moves to another chord
  tone.
- **No chord is mostly outside notes.** A chord never gets a bigger share of
  non-chord tones, by duration, than the figure had, nor more than
  `MAX_NCT_SHARE` (half, by default). Over that, the decorations that can
  become chord tones with the least disturbance to the line go first, leaps
  before neighbours before passing notes.
- **Anchoring.** The figure's first chord tone is the anchor. The copy starts
  on the chord tone with the same role (root for root, third for third) in
  the octave nearest the anchor. If that is more than `MAX_ANCHOR_JUMP`
  semitones away, it starts on whichever of the chord's notes is nearest
  instead: C–E–G–C followed by a G chord becomes B–D–G–B, not a jump down to
  G.

## Which notes are replaced

- The **chords** are the unselected notes at least a quarter note long
  (`CHORD_MIN_LENGTH_QN`) that start after the figure ends. Shorter
  unselected notes are ignored and left untouched. Chord notes starting
  within a 16th of each other (`CHORD_ONSET_TOLERANCE_QN`) are one chord, so a
  humanized or rolled chord is not split into a one-note chord and the rest.
  A chord lasts until the next chord starts, or until its notes end if there is
  a rest. A note held under a chord change counts toward both chords.
- With a **time selection** that ends after the figure, only chords starting
  inside it are replaced, and the last one is cut off at its end. Without one,
  every chord after the figure in the item is replaced.
- A chord **longer than the figure** gets the figure repeated; a shorter chord
  cuts it off. The figure's length is its span rounded up to the grid (at most
  a quarter note), so a staccato last note still repeats on the beat.
- Notes **before** the figure, and **keyswitches** (pitch 11 and below), are
  never touched. New notes take their velocity, channel and mute state from the
  figure note they copy.

## Configuration

The `CONFIG` table at the top of the script:

| Setting | Default | What it does |
|---|---|---|
| `MAX_ANCHOR_JUMP` | `2` | Semitones a figure may start from the anchor before it is inverted. Raise it to invert less often. |
| `ALLOW_INVERSIONS` | `true` | `false` keeps every figure on the chord role it was written on, moving only by octaves. |
| `MAX_NCT_SHARE` | `0.5` | Most of each chord, by duration, that may be non-chord tones (and never more than the figure had). Lower it to hear the chords more plainly; `0` makes every note a chord tone, `1` keeps the figure as mapped. |
| `CHORD_ONSET_TOLERANCE_QN` | `0.25` | Chord notes starting within this many quarter notes of each other are one chord. |
| `CHORD_MIN_LENGTH_QN` | `0.75` | Unselected notes at least this long are chords; shorter ones are ignored. `0.75` also catches a slightly short quarter note. |
| `KEYSWITCH_MAX_PITCH` | `11` | Notes at or below this pitch are ignored and left alone. |
| `ONSET_TOLERANCE_QN` | `0.03` | Chord notes starting within this many quarter notes count as one chord. |
| `RESPECT_TIME_SELECTION` | `true` | Limit the chords replaced to the time selection, when there is one. |
| `MAX_LENGTH_UNIT_QN` | `1` | The figure's span is rounded up to this, or to the grid if finer. |

## Things worth knowing

- **Scales other than seven-note ones** (pentatonic, blues, chromatic) are
  replaced by the major or natural minor scale on the same root, whichever
  their third suggests: reading the figure's chord thinks in thirds.
- **The figure is read as one chord.** A figure that itself changes harmony
  part way through will be read as one larger chord.

## Tests

The mapping logic is pure Lua and the script returns it as a module when loaded
outside REAPER:

```sh
lua5.4 tests/test_arpeggiate.lua
```

88 checks covering key snap parsing, root detection, chord and non-chord tone
analysis, chords with 7ths, 6ths, 9ths and 11ths in several voicings and
inversions, decorations, the non-chord budget, up/down order and repeated
groups, anchoring and inversions, rolled chords, block-chord selection, chord
splitting and tiling, and the example above.
