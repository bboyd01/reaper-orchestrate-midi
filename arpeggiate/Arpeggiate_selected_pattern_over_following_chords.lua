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
    result   A4 C#5 E5 A5 | A4 C#5 E5 A5       over the A chord
             A4 B4  E5 A5 | A4 B4  G5 A5       over the Asus2(add7) chord

  - The key comes from the MIDI editor's Key Snap setting.  Scale degrees the
    target chord does not spell are filled in from that key, so the figure
    stays in the key signature.
  - The target chord's own notes win over the key: a chromatic chord, or a
    sus chord with no third, is followed as written.
  - Chord tones win over the figure's exact shape: a passing or neighbour
    note lands on the nearest note of the new chord that keeps the figure's
    direction (PRIORITIZE_CHORD_TONES).
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

  -- Chord tones over shape.  After the figure is mapped onto a chord, every
  -- note is moved to the nearest note of that chord (its own notes, plus a
  -- third and fifth from the key if it does not spell them), choosing the
  -- whole line at once so the figure keeps its ups and downs.  Passing and
  -- neighbour notes therefore become chord tones.  Set to false to keep the
  -- figure's exact scale degrees, non-chord tones included.
  PRIORITIZE_CHORD_TONES = true,

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
-- against the heaviest one, so in a long figure the notes it keeps returning
-- to decide the chord, not a passing note heard once.
function M.detectRoot(pitches, weights)
  if #pitches == 0 then return nil end
  local order = {}
  for i = 1, #pitches do order[i] = i end
  table.sort(order, function(a, b) return pitches[a] < pitches[b] end)

  local pcs, total = {}, {}
  for k = 1, #order do
    local i = order[k]
    local pc = pcOf(pitches[i])
    if not total[pc] then pcs[#pcs + 1] = pc; total[pc] = 0 end
    total[pc] = total[pc] + (weights and weights[i] or 1)
  end
  local bass = pcs[1]

  local heaviest = 0
  for j = 1, #pcs do
    if total[pcs[j]] > heaviest then heaviest = total[pcs[j]] end
  end

  local function share(pc)
    return heaviest > 0 and total[pc] / heaviest or 1
  end

  -- A candidate also scores for being heard itself, and the bass bonus only
  -- counts as much as the bass note is heard: a passing note that happens to
  -- be a figure's lowest must not outvote the note the figure keeps
  -- returning to.  With equal weights (a block chord) both are the same for
  -- every candidate, so only the intervals and the bass decide.
  local best, bestScore = nil, -math.huge
  for i = 1, #pcs do
    local cand = pcs[i]
    local score = SELF_WEIGHT * share(cand)
    if cand == bass then score = score + BASS_BONUS * share(bass) end
    for j = 1, #pcs do
      score = score + ROOT_WEIGHTS[(pcs[j] - cand) % 12] * share(pcs[j])
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

-- The pitch classes a figure may land on when chord tones win: everything the
-- chord plays, plus its root, third and fifth as resolved above, so a bare
-- fifth or a single note still gets a full triad from the key.  Returns a set
-- { [pc] = true }.
function M.chordTonePcs(scale, chord)
  local stepPcs = M.targetStepPcs(scale, chord)
  local set = {}
  for i = 1, #chord.pcs do set[chord.pcs[i]] = true end
  set[stepPcs[0]], set[stepPcs[2]], set[stepPcs[4]] = true, true, true
  return set
end

-- Moves every note of a mapped figure onto a chord tone.
--
-- `ideal` is the figure mapped degree by degree, `source` the figure's own
-- pitches (both in playing order) and `tones` a pitch class set.  Each note
-- may take any chord tone within an octave of its ideal pitch.  The line is
-- chosen as a whole (dynamic programming over the notes) to keep it as close
-- to `ideal` as possible while every step goes the same way the figure's
-- step did: up stays up, down stays down, a repeat stays a repeat.  Breaking
-- that is allowed only at a cost, so a cramped chord still gets an answer.
local REVERSAL_COST = 24  -- an up step becoming a down step, or vice versa
local FLATTEN_COST = 8    -- a step becoming a repeat, or a repeat a step

local function sign(x)
  if x > 0 then return 1 elseif x < 0 then return -1 end
  return 0
end

function M.snapToChordTones(ideal, source, tones)
  local n = #ideal
  if n == 0 then return {} end

  local cands = {}
  for i = 1, n do
    local list = {}
    for p = ideal[i] - 12, ideal[i] + 12 do
      if p >= 0 and p <= 127 and tones[pcOf(p)] then list[#list + 1] = p end
    end
    if #list == 0 then list[1] = ideal[i] end
    cands[i] = list
  end

  -- cost[i][k]: cheapest line through note i ending on candidate k.
  local cost, from = { {} }, { {} }
  for k = 1, #cands[1] do cost[1][k] = math.abs(cands[1][k] - ideal[1]) end

  for i = 2, n do
    cost[i], from[i] = {}, {}
    local want = sign(source[i] - source[i - 1])
    for k = 1, #cands[i] do
      local p = cands[i][k]
      local best, bestJ = math.huge, 1
      for j = 1, #cands[i - 1] do
        local got = sign(p - cands[i - 1][j])
        local c = cost[i - 1][j]
        if got ~= want then
          if got == 0 or want == 0 then c = c + FLATTEN_COST
          else c = c + REVERSAL_COST end
        end
        if c < best then best, bestJ = c, j end
      end
      cost[i][k] = best + math.abs(p - ideal[i])
      from[i][k] = bestJ
    end
  end

  local k, best = 1, math.huge
  for j = 1, #cands[n] do
    if cost[n][j] < best then k, best = j, cost[n][j] end
  end
  local out = {}
  for i = n, 1, -1 do
    out[i] = cands[i][k]
    if i > 1 then k = from[i][k] end
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

-- Reads the figure.  `notes` is a list of { startPos, endPos, pitch, ... }.
-- Returns the notes in playing order (by start, then low to high), each with
-- `deg` (diatonic position above the figure's root, octaves included: 7 is the
-- root an octave up) and `alt` (chromatic alteration), plus the anchor pitch.
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

  return { notes = sorted, anchor = anchor, chord = chord }
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

-- Pitch of every figure note rebuilt on `chordPitches`, before any octave
-- shift, for inversion `rot`.  Returns the list of pitches.
local function buildPitches(pattern, stepPcs, rootPc, rot)
  local off = stepOffsets(stepPcs, rootPc)
  local out = {}
  for i = 1, #pattern.notes do
    local n = pattern.notes[i]
    local deg = M.invertDegree(n.deg, rot)
    local step, octave = deg % 7, deg // 7
    out[i] = rootPc + off[step] + 12 * octave + n.alt
  end
  return out
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

-- The heart of the script: the figure rebuilt on one chord.
--
-- opts: { maxAnchorJump, allowInversions, chordTones }
-- `chordTones` (default true) snaps the result onto the chord's tones.
-- Returns the pitches in the figure's playing order, and the inversion used.
function M.realize(scale, pattern, chordPitches, opts)
  opts = opts or {}
  local maxJump = opts.maxAnchorJump or 2
  local chord = M.analyzeChord(scale, chordPitches)
  local stepPcs = M.targetStepPcs(scale, chord)

  local tones, source
  if opts.chordTones ~= false then
    tones = M.chordTonePcs(scale, chord)
    source = {}
    for i = 1, #pattern.notes do source[i] = pattern.notes[i].pitch end
  end

  local best, bestJump, bestRot = nil, math.huge, 0
  local rots = opts.allowInversions == false and { 0 } or { 0, -1, 1, -2, 2 }
  for i = 1, #rots do
    local rot = rots[i]
    local pitches, jump = nearestOctave(
      buildPitches(pattern, stepPcs, chord.rootPc, rot), pattern.anchor)
    if tones then
      pitches = M.snapToChordTones(pitches, source, tones)
      jump = math.abs(pitches[1] - pattern.anchor)
    end
    if rot == 0 and jump <= maxJump then
      best, bestRot = pitches, 0
      break
    end
    if jump < bestJump then best, bestJump, bestRot = pitches, jump, rot end
  end

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

  local candidates = {}
  for i = 1, #others do
    local n = others[i]
    if n.startPos >= after and n.startPos < limit - tol then
      candidates[#candidates + 1] = n
    end
  end

  local chords = M.findChords(candidates, tol)
  if #chords == 0 then
    return fail("There are no chords after the selected figure to copy it " ..
                "onto.\n\nThe chords to rewrite must start after the last " ..
                "selected note" ..
                (limit < math.huge and " and inside the time selection." or "."))
  end

  local pattern = M.analyzePattern(scale, figure)
  local opts = {
    maxAnchorJump = CONFIG.MAX_ANCHOR_JUMP,
    allowInversions = CONFIG.ALLOW_INVERSIONS,
    chordTones = CONFIG.PRIORITIZE_CHORD_TONES,
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
