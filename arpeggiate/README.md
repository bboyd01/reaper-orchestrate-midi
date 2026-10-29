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
2. Write the figure, then the chords after it as block chords.
3. Select the figure's notes and fire the action.

Everything happens under one undo point.

### Example

Key snap D major (or B minor), measure 1 selected:

```
figure  B4 D5 F#5 B5 | B4 D5 F#5 B5 | B4 D5 A5 B5 | B4 D5 F#5 B5     (Bm, 16ths)
chords  A4 C#5 E5 A5  (whole note)  →  A4 C#5 E5 A5 | … | A4 C#5 E5 A5 | …
        A4 B4 E5 G5   (whole note)  →  A4 B4  E5 A5 | … | A4 B4  G5 A5 | …
```

The figure is root–third–fifth–octave with a 7th (A) as a neighbour in group 3.
Over A major the same degrees give A–C#–E–A. The A chord has no G, so chord
tones win and the neighbour lands on E. The second chord has no third but does
have a B (sus2) and a G: the figure's third becomes that B, and its neighbour
becomes the chord's own G.

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
- **Chord tones win over the exact shape** (`PRIORITIZE_CHORD_TONES`). After
  that mapping, every note moves to a tone of the new chord: its own notes,
  plus a third and fifth from the key if it does not play them. The whole line
  is chosen at once, keeping it as close as possible to the mapped figure while
  every step goes the way the figure's step went (up stays up, down stays down,
  a repeat stays a repeat). Passing and neighbour notes become chord tones, so
  the chord is clearly heard even under a long, busy figure. Because a step now
  moves by a chord tone instead of a scale step, a stepwise run covers a
  slightly wider range than in the original.
- **Long figures** are read by how long each note sounds in total, so the notes
  the figure keeps returning to decide its chord, not a passing note that
  happens to be the lowest.
- **Anchoring.** The figure's first note is the anchor. Every figure is moved
  by octaves so it starts as near the anchor as possible. If that is still more
  than `MAX_ANCHOR_JUMP` semitones away, the figure is rebuilt on the inversion
  that starts nearest: C–E–G–C followed by a G chord becomes B–D–G–B, not a
  jump down to G. Neighbour and passing notes travel with the chord tone they
  decorate.

## Which notes are replaced

- The **chords** are the unselected notes that start after the figure ends.
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
| `PRIORITIZE_CHORD_TONES` | `true` | Snap every note to the chord's tones while keeping the figure's direction. `false` keeps the figure's exact scale degrees, passing and neighbour notes included. |
| `KEYSWITCH_MAX_PITCH` | `11` | Notes at or below this pitch are ignored and left alone. |
| `ONSET_TOLERANCE_QN` | `0.03` | Chord notes starting within this many quarter notes count as one chord. |
| `RESPECT_TIME_SELECTION` | `true` | Limit the chords replaced to the time selection, when there is one. |
| `MAX_LENGTH_UNIT_QN` | `1` | The figure's span is rounded up to this, or to the grid if finer. |

## Things worth knowing

- **Scales other than seven-note ones** (pentatonic, blues, chromatic) are
  replaced by the major or natural minor scale on the same root, whichever
  their third suggests: the degree mapping thinks in thirds.
- **The figure is read as one chord.** A figure that itself changes harmony
  part way through will be read as one larger chord.

## Tests

The mapping logic is pure Lua and the script returns it as a module when loaded
outside REAPER:

```sh
lua5.4 tests/test_arpeggiate.lua
```

72 checks covering key snap parsing, root detection, degree reading, sus and
chromatic chords, chord-tone snapping, anchoring and inversions, chord
splitting and tiling, and the example above.
