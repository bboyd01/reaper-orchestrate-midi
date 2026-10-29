--[[
  Arpeggiate selected pattern over the following chords

  A ReaScript for REAPER, intended to be run as a MIDI Editor action.

  Select a figure in the active MIDI editor take (an arpeggio, an Alberti bass,
  a broken-chord riff: anything played over one chord).  The script reads the
  figure as scale degrees relative to the chord it outlines, then overwrites
  every chord that follows it in the take with the same figure, rebuilt on that
  chord: same rhythm, same velocities, same contour, new pitches.

    figure   B4 D5 F#5 B5 | B4 D5 A5 B5        (B minor, 7th as a neighbour)
    chords   A4 C#5 E5 A5 | A4 B4 E5 G5
    result   A4 C#5 E5 A5 | A4 C#5 G5 A5       over the A chord
             A4 B4  E5 A5 | A4 B4  G5 A5       over the Asus2(add7) chord

  - The chords are the unselected block chords after the figure: notes of a
    quarter note or longer.  Shorter unselected notes (8ths and smaller) are
    ignored and left alone.
  - The figure is split into chord tones and non-chord tones (passing notes,
    neighbours, leaps).  Chord tones always land on the new chord's tones;
    non-chord tones keep their scale-step relation to the chord tones around
    them, so a passing note still passes and a neighbour still neighbours.
  - No chord gets a larger share of non-chord tones than the figure itself
    had, and never more than MAX_NCT_SHARE.  When a chord would, the
    non-chord tones that can become chord tones with the least disturbance to
    the line turn into them, leaps before neighbours before passing notes.

  - The key comes from the MIDI editor's Key Snap setting.  Scale degrees the
    target chord does not spell are filled in from that key, so the figure
    stays in the key signature.
  - The target chord's own notes win over the key: a chromatic chord, or a
    sus chord with no third, is followed as written.
  - Every figure starts close to the first note of the selection.  If the
    chord's own version of that note would jump more than MAX_ANCHOR_JUMP
    semitones, the figure is rebuilt on the inversion that starts nearest.
  - A chord longer than the figure gets the figure repeated; a shorter one
    cuts it off.

  Requires only stock REAPER (no SWS functions are used).

  Usage:
    Actions -> Show action list -> MIDI Editor section -> New action ->
    Load ReaScript, then bind this file to a key.

  This file is also loadable as a plain Lua module (it returns its pure core
  and does nothing else when the `reaper` global is absent), which is what
  tests/test_arpeggiate.lua does.
]]

--=============================================================================
-- CONFIGURATION
--=============================================================================

local CONFIG = {
  -- The figure's first note is the anchor.  When a chord's own version of
  -- that note (same chord role, nearest octave) lands within this many
  -- semitones of the anchor, it is used as is.  Otherwise the figure moves to
  -- the inversion whose first note is nearest the anchor.  2 == a whole step.
  MAX_ANCHOR_JUMP = 2,

  -- Set to false to never invert: every figure keeps the chord role it was
  -- written on and only moves by octaves.
  ALLOW_INVERSIONS = true,

  -- The most of each rewritten chord, by duration, that may be non-chord
  -- tones.  A chord never gets more than the figure itself had either, so a
  -- figure of pure chord tones stays pure.  0.5 means a chord is never
  -- mostly outside notes, while a scale run (half passing notes) still runs.
  -- Lower it to hear the chords more plainly; 0 makes every note a chord
  -- tone, 1 keeps the figure's notes as mapped.
  MAX_NCT_SHARE = 0.5,

  -- Unselected notes at least this long (in quarter notes) are the chords to
  -- rewrite.  Shorter ones, 8ths and below, are ignored and left untouched.
  -- 0.75 also catches a quarter note played a little short.
  CHORD_MIN_LENGTH_QN = 0.75,

  -- Notes at or below this MIDI pitch are articulation keyswitches: they are
  -- neither read as part of the figure or a chord nor touched.
  -- 11 == B-1 in REAPER's default C-1 = 0 naming, i.e. everything below C0.
  KEYSWITCH_MAX_PITCH = 11,

  -- Onset clustering tolerance, in quarter notes.  Chord notes starting within
  -- this window of one another count as one chord, so humanized input still
  -- reads as block chords.  0.03 QN is about 15 ms at 120 bpm.
  ONSET_TOLERANCE_QN = 0.03,

  -- When a time selection is set and ends after the figure, only chords that
  -- start inside it are replaced, and the last one is cut off at its end.
  -- Without a time selection, every chord after the figure in the take is.
  RESPECT_TIME_SELECTION = true,

  -- The figure's length is its span rounded up to this many quarter notes, or
  -- to the MIDI editor's grid when that is finer.  That way a figure whose
  -- last note is played staccato still repeats on the beat.
  MAX_LENGTH_UNIT_QN = 1,
}

local SCRIPT_TITLE = "Arpeggiate selected pattern over following chords"

--=============================================================================
-- PURE CORE
--
-- Everything below this point up to the "REAPER GLUE" banner is free of any
-- reaper.* call, and is unit tested by tests/test_arpeggiate.lua.
--
-- Pitch classes (pc) are 0..11 with C = 0.  A "step" is a diatonic distance
-- above a chord's root, 0..6, in the 7-note key: 0 root, 2 third, 4 fifth,
-- 6 seventh, and 1 / 3 / 5 the notes in between.
--=============================================================================

local M = {}

local MAJOR_MASK = 0xAB5  -- 1 0 1 0 1 1 0 1 0 1 0 1  (C D E F G A B)
local MINOR_MASK = 0x5AD  -- 1 0 1 1 0 1 0 1 1 0 1 0  (C D Eb F G Ab Bb)

local function pcOf(n) return n % 12 end

-- Signed semitone difference a - b, folded into -6..5.
local function pcDiff(a, b)
  return (a - b + 6) % 12 - 6
end

-- A 7-note scale from REAPER's key snap: `root` 0..11 and a 12-bit `mask`
-- whose bit i means "i semitones above the root is in the scale".  The figure
-- logic thinks in thirds, which needs seven notes, so any other scale
-- (pentatonic, blues, chromatic, ...) is replaced by the major or natural
-- minor scale on the same root, whichever its third suggests.
function M.makeScale(root, mask)
  root = pcOf(root or 0)
  mask = mask or MAJOR_MASK
  local count = 0
  for i = 0, 11 do
    if mask & (1 << i) ~= 0 then count = count + 1 end
  end
  if count ~= 7 then
    local hasMinor3 = mask & (1 << 3) ~= 0
    local hasMajor3 = mask & (1 << 4) ~= 0
    mask = (hasMinor3 and not hasMajor3) and MINOR_MASK or MAJOR_MASK
  end

  local pcs = {}
  for i = 0, 11 do
    if mask & (1 << i) ~= 0 then pcs[#pcs + 1] = (root + i) % 12 end
  end
  return { root = root, pcs = pcs, fallback = count ~= 7 }
end

-- Parses REAPER's MIDI editor scale string, e.g. "102034050607": twelve
-- characters, one per semitone above the root, "0" meaning not in the scale.
function M.maskFromScaleString(s)
  if type(s) ~= "string" or #s < 12 then return nil end
  local mask = 0
  for i = 1, 12 do
    local c = s:sub(i, i)
    if c ~= "0" and c ~= " " then mask = mask | (1 << (i - 1)) end
  end
  if mask == 0 then return nil end
  return mask
end

-- Pitch class of scale index `i` (any integer, wraps).
local function scalePc(scale, i)
  return scale.pcs[(i % 7) + 1]
end

local function scaleIndexOf(scale, pc)
  for i = 1, 7 do
    if scale.pcs[i] == pc then return i - 1 end
  end
  return nil
end

-- How strongly an interval above a candidate root says "chord tone".
local ROOT_WEIGHTS = {
  [0] = 0, 0, 0.5, 2.5, 2.5, 0.5, 1, 3, 0, 0.5, 1, 1,
}
local BASS_BONUS = 2
local SELF_WEIGHT = 1

-- Picks the most likely root of a set of pitches by stacking thirds: every
-- candidate pitch class scores the intervals the others make above it, plus a
-- bonus for being in the bass.  Ties go to the bass, then to the candidate
-- that appears lowest.
--
-- `weights` (optional, parallel to `pitches`) is how much each note counts,
-- e.g. its duration.  A pitch class counts in proportion to its total weight
-- against the most heard one, and the bass bonus only as much as the bass is
-- heard, so in a figure the notes it keeps returning to decide the chord, not
-- a passing note that happens to be lowest.  With equal weights (a block
-- chord) this is plain interval scoring.
function M.weightShares(pitches, weights)
  local total, heaviest = {}, 0
  for i = 1, #pitches do
    local pc = pcOf(pitches[i])
    total[pc] = (total[pc] or 0) + (weights and weights[i] or 1)
    if total[pc] > heaviest then heaviest = total[pc] end
  end
  local share = {}
  for pc, w in pairs(total) do share[pc] = heaviest > 0 and w / heaviest or 1 end
  return share
end

function M.detectRoot(pitches, weights)
  if #pitches == 0 then return nil end
  local sorted = {}
  for i = 1, #pitches do sorted[i] = pitches[i] end
  table.sort(sorted)

  local pcs, seen = {}, {}
  for i = 1, #sorted do
    local pc = pcOf(sorted[i])
    if not seen[pc] then seen[pc] = true; pcs[#pcs + 1] = pc end
  end
  local bass = pcs[1]
  local share = M.weightShares(pitches, weights)

  local best, bestScore = nil, -math.huge
  for i = 1, #pcs do
    local cand = pcs[i]
    local score = SELF_WEIGHT * share[cand]
    if cand == bass then score = score + BASS_BONUS * share[bass] end
    for j = 1, #pcs do
      score = score + ROOT_WEIGHTS[(pcs[j] - cand) % 12] * share[pcs[j]]
    end
    if score > bestScore then best, bestScore = cand, score end
  end
  return best
end

local function isChordStep(step)
  return step == 0 or step == 2 or step == 4 or step == 6
end

-- Which step above the root (at scale index `rootIdx`) a pitch class is, and
-- by how many semitones it is altered from the key's version of that step.
-- A pitch class outside the key sits between two scale notes; it is read as
-- whichever of the two is a chord tone (so C over A in D major is a minor
-- third, not a raised second), then as the nearer one, then as the lower one
-- raised.
function M.classify(scale, rootIdx, pc)
  local idx = scaleIndexOf(scale, pc)
  if idx then return (idx - rootIdx) % 7, 0 end

  local best
  for i = 0, 6 do
    local alt = pcDiff(pc, scale.pcs[i + 1])
    if alt >= -2 and alt <= 2 then
      local step = (i - rootIdx) % 7
      local cand = { step = step, alt = alt,
                     chord = isChordStep(step) and 1 or 0 }
      if not best
         or cand.chord > best.chord
         or (cand.chord == best.chord and math.abs(alt) < math.abs(best.alt))
         or (cand.chord == best.chord and math.abs(alt) == math.abs(best.alt)
             and alt > best.alt) then
        best = cand
      end
    end
  end
  return best.step, best.alt
end

-- Reads a chord (or a figure, which outlines one) against the key.  Returns
-- { rootPc, rootIdx, stepPc = { [step] = pc } } with the pitch class the chord
-- actually uses for each step it spells, and `pcs`, its distinct pitch
-- classes.  `weights` is passed on to detectRoot.
function M.analyzeChord(scale, pitches, weights)
  local rootPc = M.detectRoot(pitches, weights)
  if not rootPc then return nil end

  local pcs, seen = {}, {}
  for i = 1, #pitches do
    local pc = pcOf(pitches[i])
    if not seen[pc] then seen[pc] = true; pcs[#pcs + 1] = pc end
  end

  -- A root outside the key (a borrowed or chromatic chord) sits between two
  -- scale indices.  Use whichever makes the chord's other notes land on
  -- thirds and fifths.
  local rootIdx = scaleIndexOf(scale, rootPc)
  if not rootIdx then
    local bestFit = -1
    for i = 0, 6 do
      local alt = pcDiff(rootPc, scale.pcs[i + 1])
      if alt >= -2 and alt <= 2 then
        local fit = 0
        for j = 1, #pcs do
          if pcs[j] ~= rootPc then
            local step = M.classify(scale, i, pcs[j])
            if step == 2 or step == 4 then fit = fit + 1 end
          end
        end
        if fit > bestFit or (fit == bestFit and math.abs(alt) == 1
                             and alt < 0) then
          rootIdx, bestFit = i, fit
        end
      end
    end
  end

  local stepPc, stepAlt = { [0] = rootPc }, { [0] = 0 }
  for j = 1, #pcs do
    local pc = pcs[j]
    if pc ~= rootPc then
      local step, alt = M.classify(scale, rootIdx, pc)
      if step ~= 0 and (stepPc[step] == nil
                        or math.abs(alt) < math.abs(stepAlt[step])) then
        stepPc[step], stepAlt[step] = pc, alt
      end
    end
  end

  return { rootPc = rootPc, rootIdx = rootIdx, stepPc = stepPc, pcs = pcs }
end

-- The chord tones of a block chord: everything it plays, plus its root, third
-- and fifth as targetStepPcs resolves them, so a bare fifth or a single note
-- still implies a triad from the key.  Returns a set { [pc] = true }.
function M.chordTonePcs(scale, chord)
  local stepPcs = M.targetStepPcs(scale, chord)
  local set = {}
  for i = 1, #chord.pcs do set[chord.pcs[i]] = true end
  set[stepPcs[0]], set[stepPcs[2]], set[stepPcs[4]] = true, true, true
  return set
end

-- The pitch class to use for every step of the chord the figure is copied
-- onto: the chord's own note where it spells that step, otherwise the key's.
-- A chord with no third but a sus2 or sus4 uses that note as its third, so a
-- figure written on a triad follows a sus chord's spelling.
function M.targetStepPcs(scale, chord)
  local out = {}
  for step = 0, 6 do
    local pc = chord.stepPc[step]
    if pc == nil and step == 2 then
      pc = chord.stepPc[3] or chord.stepPc[1]
    end
    if pc == nil then pc = scalePc(scale, chord.rootIdx + step) end
    out[step] = pc
  end
  return out
end

-- The pitch class each step had in the figure's own chord.  Only the triad
-- (root, third, fifth) is taken from the figure itself; everything else is
-- measured against the key, so a chromatic passing note in the figure stays
-- chromatic in every copy.
function M.sourceStepPcs(scale, chord)
  local out = {}
  for step = 0, 6 do
    local pc
    if step == 0 or step == 2 or step == 4 then pc = chord.stepPc[step] end
    if pc == nil then pc = scalePc(scale, chord.rootIdx + step) end
    out[step] = pc
  end
  return out
end

-- Semitones from the root up to each step, for a resolved step table.  Kept
-- non-decreasing so diatonic order and pitch order agree.
local function stepOffsets(stepPcs, rootPc)
  local off, prev = {}, 0
  for step = 0, 6 do
    local o = (stepPcs[step] - rootPc) % 12
    if step > 0 and o < prev then o = prev end
    off[step], prev = o, o
  end
  return off
end

-- A figure's 7th (or any other non-triad note) counts as a chord tone only
-- when it is heard at least this much of the most heard note: a 7th that is
-- part of the arpeggio, not a 7th that passes once.
local EXTENSION_SHARE = 0.6

local function isStep(a, b)
  local d = math.abs(a - b)
  return d >= 1 and d <= 2
end

-- What kind of non-chord tone note i is, from the notes either side of it
-- in playing order: "passing" (a step in, a step on the same way), or
-- "neighbour" (a step away and back), else "other" (approached or left by
-- leap: an appoggiatura, escape note or plain leap).
local function nctKind(notes, i)
  local prev, nxt = notes[i - 1], notes[i + 1]
  local p = notes[i].pitch
  if prev and nxt and isStep(prev.pitch, p) and isStep(p, nxt.pitch) then
    if (p - prev.pitch) * (nxt.pitch - p) > 0 then return "passing" end
    return "neighbour"
  end
  return "other"
end

-- Reads the figure.  `notes` is a list of { startPos, endPos, pitch, ... }.
-- Returns the notes in playing order (by start, then low to high), each with
-- `deg` (diatonic position above the figure's root, octaves included: 7 is the
-- root an octave up), `alt` (chromatic alteration) and `kind` ("ct" for a
-- chord tone, else the non-chord tone kind), plus the anchor pitch and
-- `nctShare`, the fraction of the figure's duration that is non-chord tones.
function M.analyzePattern(scale, notes)
  local sorted = {}
  for i = 1, #notes do sorted[i] = notes[i] end
  table.sort(sorted, function(a, b)
    if a.startPos ~= b.startPos then return a.startPos < b.startPos end
    if a.pitch ~= b.pitch then return a.pitch < b.pitch end
    return (a.order or 0) < (b.order or 0)
  end)

  local pitches, lengths = {}, {}
  for i = 1, #sorted do
    pitches[i] = sorted[i].pitch
    lengths[i] = math.max(sorted[i].endPos - sorted[i].startPos, 1)
  end
  local chord = M.analyzeChord(scale, pitches, lengths)
  local share = M.weightShares(pitches, lengths)
  local stepPcs = M.sourceStepPcs(scale, chord)
  local off = stepOffsets(stepPcs, chord.rootPc)

  local anchor = sorted[1].pitch
  local rootRef = anchor - (anchor - chord.rootPc) % 12  -- root at/below anchor

  for i = 1, #sorted do
    local n = sorted[i]
    local step = M.classify(scale, chord.rootIdx, pcOf(n.pitch))
    local alt = pcDiff(n.pitch, stepPcs[step])
    local natural = n.pitch - alt
    local octave = math.floor((natural - rootRef - off[step]) / 12 + 0.5)
    n.deg = step + 7 * octave
    n.alt = alt
  end

  -- Chord tones: the triad the figure spells (a sus note standing in for a
  -- missing third), plus anything else it dwells on.
  local hasThird = chord.stepPc[2] ~= nil
  local nctTime, totalTime = 0, 0
  for i = 1, #sorted do
    local n = sorted[i]
    local step = n.deg % 7
    local ct = n.alt == 0 and (step == 0 or step == 2 or step == 4
      or (not hasThird and (step == 1 or step == 3)))
    if share[pcOf(n.pitch)] >= EXTENSION_SHARE then ct = true end
    n.kind = ct and "ct" or false
    totalTime = totalTime + lengths[i]
  end
  for i = 1, #sorted do
    if not sorted[i].kind then
      sorted[i].kind = nctKind(sorted, i)
      nctTime = nctTime + lengths[i]
    end
  end

  return { notes = sorted, anchor = anchor, chord = chord,
           nctShare = totalTime > 0 and nctTime / totalTime or 0 }
end

-- Inversions walk the figure up or down the chord's triad.  Each note is
-- measured from its nearest triad tone (a neighbour note stays a neighbour of
-- the same chord tone), and that triad tone moves `rot` places along the
-- ladder root, third, fifth, root, ...
local LADDER = { [0] = 0, 2, 4 }

function M.invertDegree(deg, rot)
  if rot == 0 then return deg end
  local octave = deg // 7
  local r = deg % 7
  local best, bestDist = nil, math.huge
  local refs = { 0, 2, 4, 7 }
  for i = 1, #refs do
    local d = math.abs(r - refs[i])
    if d < bestDist then best, bestDist = i - 1, d end  -- first wins ties
  end
  local e = r - refs[best + 1]
  local k = 3 * octave + best + rot
  return 7 * (k // 3) + LADDER[k % 3] + e
end

local function sign(x)
  if x > 0 then return 1 elseif x < 0 then return -1 end
  return 0
end

-- Each note's diatonic position in inversion `rot`.  Chord tones move along
-- the chord (invertDegree).  An inversion stretches some gaps between chord
-- tones and squeezes others, so a non-chord tone is not inverted on its own:
-- it keeps its step distance from the note before it, provided it still
-- falls on the right side of the next chord tone (a passing note still
-- passes); otherwise from the next chord tone.  A non-chord tone with no
-- room left between its neighbours is returned in `squeezed`, to become a
-- chord tone.
function M.invertFigure(notes, rot)
  local degs, squeezed = {}, {}
  if rot == 0 then
    for i = 1, #notes do degs[i] = notes[i].deg end
    return degs, squeezed
  end

  for i = 1, #notes do
    if notes[i].kind == "ct" then degs[i] = M.invertDegree(notes[i].deg, rot) end
  end
  for i = 1, #notes do
    local n = notes[i]
    if n.kind ~= "ct" then
      local j = i + 1
      while notes[j] and notes[j].kind ~= "ct" do j = j + 1 end
      local nxt = notes[j]

      local function fitsNext(d)
        return not nxt or sign(d - degs[j]) == sign(n.deg - nxt.deg)
      end
      local function fitsPrev(d)
        return i == 1 or sign(d - degs[i - 1]) == sign(n.deg - notes[i - 1].deg)
      end

      local fromPrev = i > 1 and degs[i - 1] + (n.deg - notes[i - 1].deg)
      local fromNext = nxt and degs[j] + (n.deg - nxt.deg)
      if fromPrev and fitsNext(fromPrev) then
        degs[i] = fromPrev
      elseif fromNext and fitsPrev(fromNext) then
        degs[i] = fromNext
      else
        degs[i] = fromPrev or fromNext or M.invertDegree(n.deg, rot)
        squeezed[i] = true
      end
    end
  end
  return degs, squeezed
end

-- Pitch of every figure note rebuilt on `chordPitches`, before any octave
-- shift, for inversion `rot`.  Returns the list of pitches, and the notes
-- that must become chord tones (see invertFigure).
local function buildPitches(pattern, stepPcs, rootPc, rot)
  local off = stepOffsets(stepPcs, rootPc)
  local degs, squeezed = M.invertFigure(pattern.notes, rot)
  local out = {}
  for i = 1, #pattern.notes do
    local deg = degs[i]
    local step, octave = deg % 7, deg // 7
    out[i] = rootPc + off[step] + 12 * octave + pattern.notes[i].alt
  end
  return out, squeezed
end

-- Shifts `pitches` by whole octaves so that the first lands as near `anchor`
-- as possible (the lower option on a tie).  Returns the distance too.
local function nearestOctave(pitches, anchor)
  local first = pitches[1]
  local shift = 12 * math.floor((anchor - first) / 12)  -- first+shift <= anchor
  if math.abs(first + shift + 12 - anchor) < math.abs(first + shift - anchor) then
    shift = shift + 12
  end
  local out = {}
  for i = 1, #pitches do out[i] = pitches[i] + shift end
  return out, math.abs(out[1] - anchor)
end

-- Moves note i of `pitches` onto a chord tone: the nearest one that keeps the
-- figure's direction from the note before, and does not simply repeat a
-- neighbouring note (a decoration turned into a repeated note sounds stuck).
-- Falls back to the nearest chord tone when nothing better fits.
local DIRECTION_COST = 10  -- a step into or out of the note turns around
local REPEAT_COST = 8      -- the note just repeats a neighbour

local function toChordTone(pattern, pitches, i, tones)
  local notes = pattern.notes
  local p = pitches[i]
  local prevOut, nextOut = pitches[i - 1], pitches[i + 1]

  local best, bestCost = nil, math.huge
  for c = p - 7, p + 7 do
    if c >= 0 and c <= 127 and tones[pcOf(c)] then
      local cost = math.abs(c - p)
      if prevOut and sign(c - prevOut) ~= sign(notes[i].pitch - notes[i - 1].pitch) then
        cost = cost + DIRECTION_COST
      end
      if nextOut and sign(nextOut - c) ~= sign(notes[i + 1].pitch - notes[i].pitch) then
        cost = cost + DIRECTION_COST
      end
      if c == prevOut or c == nextOut then cost = cost + REPEAT_COST end
      if cost < bestCost then best, bestCost = c, cost end
    end
  end
  return best or p, bestCost
end

-- How reluctant we are to turn each kind of non-chord tone into a chord
-- tone, on the same scale as toChordTone's costs.  Leaps are the most
-- exposed dissonances, so they go first; passing notes are what make a line
-- move rather than jump, so they go last.
local KIND_BIAS = { other = 0, neighbour = 2, passing = 4 }

-- Keeps a mapped figure anchored in its chord.
--
-- 1. Notes that were chord tones in the figure must be chord tones here too:
--    a 7th the figure arpeggiates, mapped onto a triad, moves to a chord
--    tone instead of sounding as a dissonance it never was.  So do the
--    `squeezed` non-chord tones an inversion left no room for.
-- 2. Non-chord tones may take up at most `maxShare` of the figure's
--    duration (and never more than the figure itself had).  Over that, they
--    become chord tones one at a time, cheapest first: the one that turns
--    into a chord tone with the least disturbance to the line (no repeated
--    note, no change of direction), leaning towards leaps before neighbours
--    before passing notes, and longer notes before shorter ones.
--
-- Non-chord tones that happen to land on one of this chord's tones (a
-- passing 9th over a chord that plays a 9th) simply count as chord tones.
function M.balance(pattern, pitches, tones, maxShare, squeezed)
  local out = {}
  for i = 1, #pitches do out[i] = pitches[i] end
  local notes = pattern.notes

  local total = 0
  local len = {}
  for i = 1, #notes do
    len[i] = math.max(notes[i].endPos - notes[i].startPos, 1)
    total = total + len[i]
  end

  for i = 1, #notes do
    if (notes[i].kind == "ct" and not tones[pcOf(out[i])])
       or (squeezed and squeezed[i]) then
      out[i] = toChordTone(pattern, out, i, tones)
    end
  end

  local allowance = math.min(pattern.nctShare, maxShare or 1) * total
  local outside, nct = 0, {}
  for i = 1, #notes do
    if not tones[pcOf(out[i])] then
      outside = outside + len[i]
      nct[#nct + 1] = i
    end
  end
  local longest = 0
  for i = 1, #len do if len[i] > longest then longest = len[i] end end

  local done = {}
  while outside > allowance + 1e-9 do
    local pick, pickPitch, pickCost = nil, nil, math.huge
    for k = 1, #nct do
      local i = nct[k]
      if not done[i] then
        local pitch, cost = toChordTone(pattern, out, i, tones)
        cost = cost + (KIND_BIAS[notes[i].kind] or 0) - len[i] / longest
        if cost < pickCost then pick, pickPitch, pickCost = i, pitch, cost end
      end
    end
    if not pick then break end
    done[pick] = true
    out[pick] = pickPitch
    if tones[pcOf(pickPitch)] then outside = outside - len[pick] end
  end
  return out
end

-- The heart of the script: the figure rebuilt on one chord.
--
-- opts: { maxAnchorJump, allowInversions, maxNctShare }
-- Returns the pitches in the figure's playing order, and the inversion used.
function M.realize(scale, pattern, chordPitches, opts)
  opts = opts or {}
  local maxJump = opts.maxAnchorJump or 2
  local chord = M.analyzeChord(scale, chordPitches)
  local stepPcs = M.targetStepPcs(scale, chord)

  local best, bestJump, bestRot = nil, math.huge, 0
  local rots = opts.allowInversions == false and { 0 } or { 0, -1, 1, -2, 2 }
  local bestSqueezed
  for i = 1, #rots do
    local rot = rots[i]
    local raw, squeezed = buildPitches(pattern, stepPcs, chord.rootPc, rot)
    local pitches, jump = nearestOctave(raw, pattern.anchor)
    if rot == 0 and jump <= maxJump then
      best, bestRot, bestSqueezed = pitches, 0, squeezed
      break
    end
    if jump < bestJump then
      best, bestJump, bestRot, bestSqueezed = pitches, jump, rot, squeezed
    end
  end

  best = M.balance(pattern, best, M.chordTonePcs(scale, chord),
                   opts.maxNctShare or 0.5, bestSqueezed)

  for i = 1, #best do
    if best[i] < 0 then best[i] = best[i] + 12 * math.ceil(-best[i] / 12) end
    if best[i] > 127 then best[i] = best[i] - 12 * math.ceil((best[i] - 127) / 12) end
  end
  return best, bestRot
end

-- The figure's length: its span rounded up to `unit` ticks.
function M.patternLength(notes, unit)
  local s, e = math.huge, -math.huge
  for i = 1, #notes do
    if notes[i].startPos < s then s = notes[i].startPos end
    if notes[i].endPos > e then e = notes[i].endPos end
  end
  local span = e - s
  if unit and unit > 0 then
    -- A hair of slack so float noise in PPQ values cannot add a whole unit.
    span = math.ceil(span / unit - 1e-6) * unit
  end
  return s, span
end

-- The notes that make up the chords to rewrite: unselected notes starting at
-- or after `after` and before `limit`, at least `minLen` long.  Shorter notes
-- (the rest of a melody, an earlier figure, 8ths and below) are not chords;
-- they are ignored and left as they are.
function M.blockChordNotes(notes, after, limit, minLen, tol)
  local out = {}
  for i = 1, #notes do
    local n = notes[i]
    if n.startPos >= after and n.startPos < limit - tol
       and n.endPos - n.startPos >= minLen then
      out[#out + 1] = n
    end
  end
  return out
end

-- Splits the notes after the figure into chords.  A chord starts at every
-- onset cluster and lasts until the next one, or until its notes end if a
-- rest follows.  Each chord holds every note sounding at its onset, so a note
-- sustained under a chord change belongs to both chords.
-- Returns { { startPos, endPos, notes = {...} }, ... } in time order.
function M.findChords(notes, tol)
  local sorted = {}
  for i = 1, #notes do sorted[i] = notes[i] end
  table.sort(sorted, function(a, b) return a.startPos < b.startPos end)

  local onsets = {}
  for i = 1, #sorted do
    local t = sorted[i].startPos
    if #onsets == 0 or t > onsets[#onsets] + tol then onsets[#onsets + 1] = t end
  end

  local chords = {}
  for i = 1, #onsets do
    local t = onsets[i]
    local members, lastEnd = {}, t
    for j = 1, #sorted do
      local n = sorted[j]
      if n.startPos <= t + tol and n.endPos > t + tol then
        members[#members + 1] = n
        if n.endPos > lastEnd then lastEnd = n.endPos end
      end
    end
    if #members > 0 then
      local stop = lastEnd
      if onsets[i + 1] and onsets[i + 1] < stop then stop = onsets[i + 1] end
      chords[#chords + 1] = { startPos = t, endPos = stop, notes = members }
    end
  end
  return chords
end

-- Lays the figure out over [regionStart, regionEnd): repeated every
-- `patternLen` ticks, with notes cut off at the region end.  `pitches` lines
-- up with `pattern.notes`.  Returns new notes { startPos, endPos, pitch, src }.
function M.layout(pattern, patternStart, patternLen, pitches,
                  regionStart, regionEnd)
  local out = {}
  if patternLen <= 0 then return out end
  local rep = 0
  while true do
    local base = regionStart + rep * patternLen
    if base >= regionEnd then break end
    for i = 1, #pattern.notes do
      local n = pattern.notes[i]
      local s = base + (n.startPos - patternStart)
      if s < regionEnd then
        local e = s + (n.endPos - n.startPos)
        if e > regionEnd then e = regionEnd end
        if e > s then
          out[#out + 1] = { startPos = s, endPos = e, pitch = pitches[i],
                            src = n }
        end
      end
    end
    rep = rep + 1
  end
  return out
end

--=============================================================================
-- REAPER GLUE
--=============================================================================

local function fail(msg)
  return nil, msg
end

local function ppqPerQN(take)
  local a = reaper.MIDI_GetPPQPosFromProjQN(take, 0)
  local b = reaper.MIDI_GetPPQPosFromProjQN(take, 1)
  local ppq = b - a
  if ppq <= 0 then ppq = 960 end
  return ppq
end

-- The key chosen in the MIDI editor's Key Snap settings.  Read from the editor
-- first, which is what the toolbar shows, then from the take.  The chosen key
-- is used even while snapping itself is switched off.
local function readKey(editor, take)
  local root = reaper.MIDIEditor_GetSetting_int(editor, "scale_root")
  local _, str = reaper.MIDIEditor_GetSetting_str(editor, "scale", "")
  local mask = M.maskFromScaleString(str)
  if root and root >= 0 and mask then return root % 12, mask end

  if reaper.MIDI_GetScale then
    local _, tRoot, tMask = reaper.MIDI_GetScale(take, 0, 0, "")
    if tMask and tMask ~= 0 then return (tRoot or 0) % 12, tMask end
  end
  return nil
end

local function readNotes(take)
  local figure, others = {}, {}
  local _, noteCount = reaper.MIDI_CountEvts(take)
  for i = 0, noteCount - 1 do
    local ok, selected, muted, startPos, endPos, chan, pitch, vel =
      reaper.MIDI_GetNote(take, i)
    if ok and pitch > CONFIG.KEYSWITCH_MAX_PITCH then
      local note = {
        index = i, order = i, startPos = startPos, endPos = endPos,
        muted = muted, chan = chan, pitch = pitch, vel = vel,
      }
      if selected then figure[#figure + 1] = note
      else others[#others + 1] = note end
    end
  end
  return figure, others
end

local function run()
  local editor = reaper.MIDIEditor_GetActive()
  if not editor then
    return fail("No MIDI editor is open.\n\nRun this from the MIDI editor, " ..
                "with the figure you want to copy selected.")
  end

  local take = reaper.MIDIEditor_GetTake(editor)
  if not take or not reaper.TakeIsMIDI(take) then
    return fail("The MIDI editor has no active MIDI take.")
  end

  local figure, others = readNotes(take)
  if #figure == 0 then
    return fail("No notes are selected.\n\nSelect the figure (arpeggio, " ..
                "broken chord, ...) to copy, then run this again.")
  end

  local keyRoot, keyMask = readKey(editor, take)
  if not keyRoot then
    return fail("Could not read the MIDI editor's Key Snap key.\n\n" ..
                "Pick a key and scale in the Key Snap dropdowns and run " ..
                "this again.")
  end
  local scale = M.makeScale(keyRoot, keyMask)

  local ppq = ppqPerQN(take)
  local tol = CONFIG.ONSET_TOLERANCE_QN * ppq
  local gridQN = reaper.MIDI_GetGrid(take)
  local unitQN = CONFIG.MAX_LENGTH_UNIT_QN
  if gridQN and gridQN > 0 and gridQN < unitQN then unitQN = gridQN end
  local patStart, patLen = M.patternLength(figure, unitQN * ppq)

  local patEnd = -math.huge
  for i = 1, #figure do
    if figure[i].endPos > patEnd then patEnd = figure[i].endPos end
  end
  local after = math.min(patEnd, patStart + patLen) - tol

  local limit = math.huge
  if CONFIG.RESPECT_TIME_SELECTION then
    local tsStart, tsEnd = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    if tsEnd > tsStart then
      local tsEndPPQ = reaper.MIDI_GetPPQPosFromProjTime(take, tsEnd)
      if tsEndPPQ > after then limit = tsEndPPQ end
    end
  end

  local candidates = M.blockChordNotes(others, after, limit,
                                       CONFIG.CHORD_MIN_LENGTH_QN * ppq - tol,
                                       tol)

  local chords = M.findChords(candidates, tol)
  if #chords == 0 then
    return fail("There are no chords after the selected figure to copy it " ..
                "onto.\n\nThe chords to rewrite are unselected notes a " ..
                "quarter note or longer, starting after the last selected note" ..
                (limit < math.huge and " and inside the time selection." or "."))
  end

  local pattern = M.analyzePattern(scale, figure)
  local opts = {
    maxAnchorJump = CONFIG.MAX_ANCHOR_JUMP,
    allowInversions = CONFIG.ALLOW_INVERSIONS,
    maxNctShare = CONFIG.MAX_NCT_SHARE,
  }

  local newNotes, doomed = {}, {}
  for c = 1, #chords do
    local chord = chords[c]
    local pitches = {}
    for i = 1, #chord.notes do
      pitches[i] = chord.notes[i].pitch
      doomed[chord.notes[i].index] = true
    end
    local stop = math.min(chord.endPos, limit)
    local realized = M.realize(scale, pattern, pitches, opts)
    local laid = M.layout(pattern, patStart, patLen, realized,
                          chord.startPos, stop)
    for i = 1, #laid do newNotes[#newNotes + 1] = laid[i] end
  end

  -- Delete from the top down so the remaining indices stay valid.
  local indices = {}
  for index in pairs(doomed) do indices[#indices + 1] = index end
  table.sort(indices, function(a, b) return a > b end)
  for i = 1, #indices do reaper.MIDI_DeleteNote(take, indices[i]) end

  for i = 1, #newNotes do
    local n = newNotes[i]
    local s = math.floor(n.startPos + 0.5)
    local e = math.floor(n.endPos + 0.5)
    if e <= s then e = s + 1 end
    reaper.MIDI_InsertNote(take, false, n.src.muted, s, e, n.src.chan,
                           n.pitch, n.src.vel, true)
  end
  reaper.MIDI_Sort(take)

  return string.format("%s (%d chord%s)", SCRIPT_TITLE, #chords,
                       #chords == 1 and "" or "s")
end

-- One undo block for the whole run, so a single Ctrl/Cmd+Z restores the
-- chords.  REAPER drops a block that changed nothing.
local function main()
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local ok, undoName, message = pcall(run)

  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock(ok and undoName or SCRIPT_TITLE, -1)
  reaper.UpdateArrange()

  if not ok then error(undoName, 0) end
  if message then reaper.ShowMessageBox(message, SCRIPT_TITLE, 0) end
end

if reaper and reaper.MIDIEditor_GetActive then
  main()
end

return M
