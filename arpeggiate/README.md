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
        A4 B4 E5 G5   (whole note)  →  A4 B4  E5 A5 | … | A4 B4  G5 A5 | …
```

The figure is root–third–fifth–octave with a 7th (A) as a neighbour in group 3.
Over A major the same degrees give A–C#–E–A, with the key's G as the 7th. The
second chord has no third but does have a B (sus2) and a G: the figure's third
becomes that B and its 7th uses the chord's own G.

## How the figure is mapped

- **Each chord is analysed** for its root by stacking thirds (with a bonus for
  the bass note), so inversions and sus chords are read correctly.
- **Each figure note becomes a scale degree** above the figure's own root, with
  its octave. A chromatic note keeps its alteration (B–A#–B over Bm becomes
  E–D#–E over Em).
- **The target chord's own notes win.** Whatever degrees it spells — a
  chromatic third, a sus2 or sus4 standing in for the third, a 7th — are used
  as written. Degrees it does not spell come from the Key Snap key, so the
  result stays in the key signature.
- **Chord tones and non-chord tones.** The figure is split into the notes
  that spell its chord (root, third, fifth, plus anything it dwells on, such as
  an arpeggiated 7th) and its non-chord tones, each read as a *passing* note
  (a step in and a step on the same way), a *neighbour* (a step away and back)
  or a *leap* (approached or left by a jump). Each block chord is read the same
  way: its own notes are its chord tones, plus a third and fifth from the key
  if it does not play them.
- **Chord tones stay chord tones.** A figure chord tone always lands on a tone
  of the new chord. An arpeggiated maj7 over a plain triad moves to a triad
  tone rather than becoming a dissonance it never was in the figure.
- **Decorations stay decorations.** Non-chord tones keep their scale-step
  relation to the notes around them, so a passing note still passes and a
  neighbour still neighbours. One that lands on a note the chord plays (a
  passing C over Dm7) simply becomes a chord tone.
- **No chord is mostly outside notes.** A chord never gets a bigger share of
  non-chord tones, by duration, than the figure had, nor more than
  `MAX_NCT_SHARE` (half, by default). Over that, the decorations that can
  become chord tones with the least disturbance to the line go first (no
  repeated notes, no change of direction), leaps before neighbours before
  passing notes, so the line keeps moving rather than turning into a
  mechanical broken chord.
- **Up and down always follow the figure.** Every step goes the same way as
  the figure's step: up stays up, down stays down, a repeat stays a repeat.
  The mapping almost always does this by itself; where it would not (over a
  sus chord the figure's 3rd and 4th land on the same note, and an inversion
  can squeeze a gap), a final repair moves as few notes as possible, as
  little as possible. Notes on a correct step are never touched, and a chord
  tone only ever moves to another chord tone. The steps either side of a
  repaired note keep the figure's own size counted in chord tones, so a step
  to the next chord tone stays one, rather than leaping over a chord tone or
  an octave.
- **Anchoring.** The figure's first note is the anchor. Every figure is moved
  by octaves so it starts as near the anchor as possible. If that is still more
  than `MAX_ANCHOR_JUMP` semitones away, the figure is rebuilt on the inversion
  that starts nearest: C–E–G–C followed by a G chord becomes B–D–G–B, not a
  jump down to G. Chord tones move along the chord; decorations keep their
  step from the note before them, or from the next chord tone, so they still
  sit between the notes they connect. One with no room left becomes a chord
  tone.

## Which notes are replaced

- The **chords** are the unselected notes at least a quarter note long
  (`CHORD_MIN_LENGTH_QN`) that start after the figure ends. Shorter
  unselected notes are ignored and left untouched.
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
| `CHORD_MIN_LENGTH_QN` | `0.75` | Unselected notes at least this long are chords; shorter ones are ignored. `0.75` also catches a slightly short quarter note. |
| `KEYSWITCH_MAX_PITCH` | `11` | Notes at or below this pitch are ignored and left alone. |
| `ONSET_TOLERANCE_QN` | `0.03` | Chord notes starting within this many quarter notes count as one chord. |
| `RESPECT_TIME_SELECTION` | `true` | Limit the chords replaced to the time selection, when there is one. |
| `MAX_LENGTH_UNIT_QN` | `1` | The figure's span is rounded up to this, or to the grid if finer. |

## Things worth knowing

- **Scales other than seven-note ones** (pentatonic, blues, chromatic) are
  replaced by the major or natural minor scale on the same root, whichever
  their third suggests: the degree mapping thinks in thirds.
- **A sus chord with a figure that uses both the 2nd and the 3rd** maps both to
  the chord's sus note, so two neighbouring figure notes can come out the same.
- **A full scale run over an inverted chord** cannot keep one note per scale
  step, since the inversion changes the gaps between chord tones; the passing
  note with no room becomes a chord tone, which can turn the line briefly.
  Set `ALLOW_INVERSIONS = false` if you want runs kept strictly stepwise.
- **The figure is read as one chord.** A figure that itself changes harmony
  part way through will be read as one larger chord.

## Tests

The mapping logic is pure Lua and the script returns it as a module when loaded
outside REAPER:

```sh
lua5.4 tests/test_arpeggiate.lua
```

82 checks covering key snap parsing, root detection, degree reading, sus and
chromatic chords, chord and non-chord tone analysis, the non-chord budget,
up/down order (including a sweep of random figures over 13 chords that must
never change a step's direction), anchoring and inversions, block-chord
selection, chord splitting and tiling, and the example above.
