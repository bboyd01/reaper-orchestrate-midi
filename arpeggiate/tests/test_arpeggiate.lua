--[[
  Offline tests for the pure core of
  Arpeggiate_selected_pattern_over_following_chords.lua.

  The script under test returns its core table and runs nothing else when the
  `reaper` global is absent, so it can be loaded straight into a plain Lua
  interpreter.

    lua5.4 tests/test_arpeggiate.lua
]]

local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local M = dofile(here .. "/../Arpeggiate_selected_pattern_over_following_chords.lua")

local PPQ = 960
local TOL = 0.03 * PPQ

local failures, checks = 0, 0

local function fmt(v)
  if type(v) ~= "table" then return tostring(v) end
  local parts = {}
  for i = 1, #v do parts[i] = tostring(v[i]) end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function same(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then return a == b end
  if #a ~= #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end

local function check(label, got, want)
  checks = checks + 1
  if not same(got, want) then
    failures = failures + 1
    print(string.format("FAIL  %s\n        got  %s\n        want %s",
                        label, fmt(got), fmt(want)))
  end
end

-- Note names to MIDI pitch, REAPER's default naming (C4 = 60).
local NAMES = { C = 0, D = 2, E = 4, F = 5, G = 7, A = 9, B = 11 }
local function p(name)
  local letter, acc, oct = name:match("^([A-G])([#b]?)(%-?%d)$")
  local pc = NAMES[letter] + (acc == "#" and 1 or acc == "b" and -1 or 0)
  return 12 * (tonumber(oct) + 1) + pc
end
local function ps(list)
  local out = {}
  for name in list:gmatch("%S+") do out[#out + 1] = p(name) end
  return out
end

-- start and len in quarter notes
local function note(startQN, lenQN, pitch, order)
  return { order = order or 0, startPos = startQN * PPQ,
           endPos = (startQN + lenQN) * PPQ, pitch = pitch }
end

-- A figure from a space separated list of names, one per `stepQN`.
local function figure(names, stepQN)
  local notes = {}
  local pitches = ps(names)
  for i = 1, #pitches do
    notes[i] = note((i - 1) * stepQN, stepQN, pitches[i], i)
  end
  return notes
end

local D_MAJOR = M.makeScale(2, 0xAB5)
local C_MAJOR = M.makeScale(0, 0xAB5)

--=============================================================================
print("-- key snap parsing")
--=============================================================================

check("major scale string", M.maskFromScaleString("102034050607"), 0xAB5)
check("minor scale string", M.maskFromScaleString("102304056070"), 0x5AD)
check("empty scale string", M.maskFromScaleString(""), nil)
check("D major pcs", D_MAJOR.pcs, { 2, 4, 6, 7, 9, 11, 1 })
check("pentatonic falls back to major",
      M.makeScale(0, 0x295).pcs, { 0, 2, 4, 5, 7, 9, 11 })
check("minor pentatonic falls back to minor",
      M.makeScale(9, 0x4A9).pcs, { 9, 11, 0, 2, 4, 5, 7 })

--=============================================================================
print("-- root detection")
--=============================================================================

check("root position triad", M.detectRoot(ps("A4 C#5 E5")), 9)
check("first inversion", M.detectRoot(ps("C#4 E4 A4")), 9)
check("second inversion", M.detectRoot(ps("E4 A4 C#5")), 9)
check("sus2 with 7th (A B E G)", M.detectRoot(ps("A4 B4 E5 G5")), 9)
check("sus4", M.detectRoot(ps("A4 D5 E5")), 9)
check("power chord", M.detectRoot(ps("A3 E4")), 9)
check("dominant 7th, 3rd inversion", M.detectRoot(ps("G3 A3 C#4 E4")), 9)
check("min7 figure", M.detectRoot(ps("B4 D5 F#5 A5 B5")), 11)
check("major 7th", M.detectRoot(ps("C4 E4 G4 B4")), 0)

--=============================================================================
print("-- scale degree reading")
--=============================================================================

do
  -- Over A in D major (A is scale index 4).
  local step, alt = M.classify(D_MAJOR, 4, 1)  -- C#
  check("C# over A is the third", { step, alt }, { 2, 0 })
  step, alt = M.classify(D_MAJOR, 4, 0)        -- C natural
  check("C over A is a minor third, not a raised second", { step, alt }, { 2, -1 })
  step, alt = M.classify(D_MAJOR, 5, 10)       -- A# over B
  check("A# over B is a raised 7th", { step, alt }, { 6, 1 })
end

do
  local chord = M.analyzeChord(D_MAJOR, ps("A4 B4 E5 G5"))
  local pcs = M.targetStepPcs(D_MAJOR, chord)
  check("sus2 chord: third resolves to the 2nd",
        { pcs[0], pcs[2], pcs[4], pcs[6] }, { 9, 11, 4, 7 })

  chord = M.analyzeChord(D_MAJOR, ps("A4 C#5 E5"))
  pcs = M.targetStepPcs(D_MAJOR, chord)
  check("triad: 7th filled in from the key", pcs[6], 7)

  -- C major chord borrowed into D major: root sits outside the key.
  chord = M.analyzeChord(D_MAJOR, ps("C4 E4 G4"))
  pcs = M.targetStepPcs(D_MAJOR, chord)
  check("chromatic chord keeps its own spelling",
        { pcs[0], pcs[2], pcs[4] }, { 0, 4, 7 })
end

--=============================================================================
print("-- the user's example")
--=============================================================================

do
  -- Measure 1: four groups of ascending 16ths, the third with A for F#.
  local notes = figure(
    "B4 D5 F#5 B5  B4 D5 F#5 B5  B4 D5 A5 B5  B4 D5 F#5 B5", 0.25)
  local pattern = M.analyzePattern(D_MAJOR, notes)
  check("anchor is the first note", pattern.anchor, p("B4"))
  check("figure root is B", pattern.chord.rootPc, 11)

  local degs = {}
  for i = 1, 4 do degs[i] = pattern.notes[i].deg end
  check("figure degrees", degs, { 0, 2, 4, 7 })
  check("neighbour A is the 7th", pattern.notes[11].deg, 6)

  local a = M.realize(D_MAJOR, pattern, ps("A4 C#5 E5 A5"))
  check("over A: groups 1, 2, 4", { a[1], a[2], a[3], a[4] }, ps("A4 C#5 E5 A5"))
  check("over A: group 3 takes the key's 7th",
        { a[9], a[10], a[11], a[12] }, ps("A4 C#5 G5 A5"))

  local s = M.realize(D_MAJOR, pattern, ps("A4 B4 E5 G5"))
  check("over Asus2(7): follows the chord's spelling",
        { s[1], s[2], s[3], s[4] }, ps("A4 B4 E5 A5"))
  check("over Asus2(7): 7th is the chord's G",
        { s[9], s[10], s[11], s[12] }, ps("A4 B4 G5 A5"))
end

--=============================================================================
print("-- anchoring and inversions")
--=============================================================================

do
  local pattern = M.analyzePattern(C_MAJOR, figure("C4 E4 G4 C5", 0.25))

  local g, rot = M.realize(C_MAJOR, pattern, ps("G3 B3 D4"))
  -- G3 is 5 below C4 and G4 is 7 above: too far.  B3 (3rd of G) is 1 away.
  check("G chord inverts to start on its third", g, ps("B3 D4 G4 B4"))
  check("G chord inversion", rot, 1)

  g = M.realize(C_MAJOR, pattern, ps("G3 B3 D4"), { allowInversions = false })
  check("inversions off: root position, nearest octave", g, ps("G3 B3 D4 G4"))

  local d = M.realize(C_MAJOR, pattern, ps("D4 F4 A4"))
  check("close root stays in root position", d, ps("D4 F4 A4 D5"))

  local a = M.realize(C_MAJOR, pattern, ps("A3 C4 E4"))
  -- A3 is 3 below C4; C4 (3rd of Am) is 0 away.
  check("Am starts on the common tone", a, ps("C4 E4 A4 C5"))

  local f = M.realize(C_MAJOR, pattern, ps("F3 A3 C4"), { maxAnchorJump = 5 })
  -- F4 is 5 above C4 (F3 would be 7 below): allowed, so no inversion.
  check("wider jump allowance keeps root position", f, ps("F4 A4 C5 F5"))
end

do
  -- A neighbour note stays a neighbour of the same chord tone when inverted.
  check("invert root up a place", M.invertDegree(0, 1), 2)
  check("invert octave root up a place", M.invertDegree(7, 1), 9)
  check("invert fifth up a place", M.invertDegree(4, 1), 7)
  check("invert 7th (neighbour of the octave)", M.invertDegree(6, 1), 8)
  check("invert down a place", M.invertDegree(0, -1), -3)
  check("invert 2nd (passing from root)", M.invertDegree(1, 1), 3)
end

--=============================================================================
print("-- chromatic notes in the figure")
--=============================================================================

do
  -- Leading-tone neighbour: B A# B over Bm in D major.
  local pattern = M.analyzePattern(D_MAJOR, figure("B4 A#4 B4 D5 F#5", 0.25))
  local r = M.realize(D_MAJOR, pattern, ps("E4 G4 B4"),
                      { allowInversions = false })
  check("leading tone stays a leading tone", r, ps("E5 D#5 E5 G5 B5"))

  -- Inverted onto the fifth, it becomes the fifth's leading tone.
  r = M.realize(D_MAJOR, pattern, ps("E4 G4 B4"))
  check("inverted: neighbour follows its chord tone", r, ps("B4 A#4 B4 E5 G5"))
end

--=============================================================================
print("-- chord tones and non-chord tones")
--=============================================================================

local function kinds(pattern)
  local out = {}
  for i = 1, #pattern.notes do out[i] = pattern.notes[i].kind end
  return out
end

-- How many of `pitches` fall outside the chord `chordPitches` implies.
local function outside(scale, pitches, chordPitches)
  local tones = M.chordTonePcs(scale, M.analyzeChord(scale, chordPitches))
  local count = 0
  for i = 1, #pitches do
    if not tones[pitches[i] % 12] then count = count + 1 end
  end
  return count
end

do
  -- A passing tone that is the figure's lowest note does not become its root.
  local pattern = M.analyzePattern(D_MAJOR, figure("B4 A#4 B4 D5 F#5", 0.25))
  check("passing lowest note is not the root", pattern.chord.rootPc, 11)
end

do
  -- Two bars of 8ths over C with passing and neighbour notes.
  local pattern = M.analyzePattern(C_MAJOR, figure(
    "C4 D4 E4 G4  A4 G4 E4 D4  C4 E4 F4 G4  C5 B4 G4 E4", 0.5))
  check("figure read as C", pattern.chord.rootPc, 0)
  check("chord and non-chord tones", kinds(pattern), {
    "ct", "passing", "ct", "ct",  "neighbour", "ct", "ct", "passing",
    "ct", "ct", "passing", "ct",  "ct", "other", "ct", "ct" })
  check("non-chord share", pattern.nctShare, 5 / 16)

  -- Within its budget, the figure keeps its decorations: passing notes still
  -- pass, the neighbour still neighbours.
  local r = M.realize(C_MAJOR, pattern, ps("F3 A3 C4"))
  -- (Inverted onto C: the falling third E-D-C became the falling fourth
  -- F-?-C; the passing D splits it as evenly as the figure's two steps.)
  check("over F: decorations kept", r, ps(
    "C4 D4 F4 A4  B4 A4 F4 D4  C4 F4 G4 A4  C5 B4 A4 F4"))
  check("over F: at most the figure's share outside", outside(C_MAJOR, r,
        ps("F3 A3 C4")) <= 5, true)

  -- A chord that plays an extension absorbs the decorations that land on it.
  r = M.realize(C_MAJOR, pattern, ps("D3 A3 C4 F4"))
  check("over Dm7: the passing C is the chord's own 7th",
        outside(C_MAJOR, r, ps("D3 A3 C4 F4")), 4)

  r = M.realize(C_MAJOR, pattern, ps("F3 A3 C4"), { maxNctShare = 0 })
  check("budget 0: every note a chord tone",
        outside(C_MAJOR, r, ps("F3 A3 C4")), 0)
  local repeats = 0
  for i = 2, #r do if r[i] == r[i - 1] then repeats = repeats + 1 end end
  check("budget 0: decorations do not become repeated notes", repeats, 0)
end

do
  -- A scale run is half non-chord tones: within the default budget.
  local pattern = M.analyzePattern(C_MAJOR, figure("C4 D4 E4 F4 G4 A4 B4 C5", 0.5))
  check("scale run share", pattern.nctShare, 0.5)
  local function climbs(r)
    for i = 2, #r do if r[i] <= r[i - 1] then return false end end
    return true
  end
  local function repeatsIn(r)
    local n = 0
    for i = 2, #r do if r[i] == r[i - 1] then n = n + 1 end end
    return n
  end
  local r = M.realize(C_MAJOR, pattern, ps("G3 B3 D4"),
                      { allowInversions = false })
  check("scale run over G: still a scale run", r, ps("G3 A3 B3 C4 D4 E4 F4 G4"))

  -- A tighter budget is kept, without repeated notes.
  r = M.realize(C_MAJOR, pattern, ps("G3 B3 D4"),
                { allowInversions = false, maxNctShare = 0.35 })
  check("budget 35%: at most 35% outside",
        outside(C_MAJOR, r, ps("G3 B3 D4")) <= 2, true)
  check("budget 35%: no repeated notes", repeatsIn(r), 0)

  -- Inverted, the chord's gaps no longer fit a note per step; a passing note
  -- with no room left becomes a chord tone, never a repeated note.
  r = M.realize(C_MAJOR, pattern, ps("G3 B3 D4"))
  check("inverted scale run: no repeated notes", repeatsIn(r), 0)
  check("inverted scale run: at most half outside",
        outside(C_MAJOR, r, ps("G3 B3 D4")) <= 4, true)
end

do
  -- A 7th the figure arpeggiates is a chord tone: over a triad it moves to
  -- one of the triad's tones rather than sounding as a dissonance.
  local pattern = M.analyzePattern(C_MAJOR, figure("C4 E4 G4 B4", 0.25))
  check("arpeggiated 7th is a chord tone", kinds(pattern), { "ct", "ct", "ct", "ct" })
  check("pure chord-tone figure has no budget", pattern.nctShare, 0)
  local r = M.realize(C_MAJOR, pattern, ps("D4 F4 A4"))
  check("maj7 figure over Dm: all chord tones",
        outside(C_MAJOR, r, ps("D4 F4 A4")), 0)
  check("maj7 figure over Dm: still climbs", r[4] > r[3], true)

  -- ... and over a 7th chord it takes that chord's own 7th.
  r = M.realize(C_MAJOR, pattern, ps("D4 F4 A4 C5"))
  check("maj7 figure over Dm7", r, ps("D4 F4 A4 C5"))
end

do
  local chord = M.analyzeChord(C_MAJOR, ps("A3 E4"))
  local tones = M.chordTonePcs(C_MAJOR, chord)
  check("power chord implies the key's third",
        { tones[9], tones[0], tones[4], tones[2] }, { true, true, true, nil })
end

--=============================================================================
print("-- the result follows the figure's shape")
--=============================================================================

local function directions(r)
  local out = {}
  for i = 2, #r do
    out[i - 1] = r[i] > r[i - 1] and "up" or r[i] < r[i - 1] and "down" or "same"
  end
  return out
end

do
  -- Over a sus4 chord the figure's 3rd and 4th both map to the 4th; the
  -- step between them must still be a step up, not a repeated note.
  local pattern = M.analyzePattern(C_MAJOR, figure("C4 E4 F4 G4 E4 C4", 0.25))
  local src = {}
  for i = 1, #pattern.notes do src[i] = pattern.notes[i].pitch end
  local r = M.realize(C_MAJOR, pattern, ps("D4 G4 A4"))
  check("sus4: same ups and downs", directions(r), directions(src))
end

do
  -- keepShape leaves a line that already has the right shape alone ...
  local pattern = M.analyzePattern(C_MAJOR, figure("C4 E4 G4 E4", 0.25))
  local tones = { [0] = true, [4] = true, [7] = true }
  check("keepShape: right shape untouched",
        M.keepShape(pattern, ps("C4 E4 G4 E4"), tones, {}, C_MAJOR),
        ps("C4 E4 G4 E4"))
  -- ... and turns a flattened or reversed step back the right way, staying
  -- on the chord where it must.
  local fixed = M.keepShape(pattern, ps("C4 E4 E4 G4"), tones,
                            { true, true, true, true }, C_MAJOR)
  check("keepShape: directions restored", directions(fixed),
        { "up", "up", "down" })
  local onChord = true
  for i = 1, #fixed do if not tones[fixed[i] % 12] then onChord = false end end
  check("keepShape: chord tones stay chord tones", onChord, true)
end

do
  -- A broad sweep: random figures of chord tones and scale steps over a
  -- spread of chords (triads, 7ths, sus, inversions, a bare fifth).  The
  -- result must take every step the same way as the figure.
  local seed = 12345
  local function rand(n)
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed % n + 1
  end
  local chordTone = { [0] = true, [4] = true, [7] = true }
  local inKey = { [0] = true, [2] = true, [4] = true, [5] = true,
                  [7] = true, [9] = true, [11] = true }
  local chords = {
    ps("C4 E4 G4"), ps("D4 F4 A4"), ps("E4 G4 B4"), ps("F3 A3 C4"),
    ps("G3 B3 D4"), ps("A3 C4 E4"), ps("B3 D4 F4"), ps("G3 B3 D4 F4"),
    ps("D4 F4 A4 C5"), ps("A3 B3 E4"), ps("D4 G4 A4"), ps("E3 A3 C4"),
    ps("C3 G3"),
  }
  local wrong, steps = 0, 0
  for _ = 1, 60 do
    local list, pitch = {}, ({ 60, 64, 67 })[rand(3)]
    for i = 1, 6 + rand(10) do
      list[i] = note((i - 1) * 0.25, 0.25, pitch, i)
      local dir = rand(2) == 1 and -1 or 1
      local ok = rand(10) <= 6 and chordTone or inKey
      repeat pitch = pitch + dir until ok[pitch % 12]
      if pitch < 52 then pitch = pitch + 12 elseif pitch > 84 then pitch = pitch - 12 end
    end
    local pattern = M.analyzePattern(C_MAJOR, list)
    local src = {}
    for i = 1, #pattern.notes do src[i] = pattern.notes[i].pitch end
    local want = directions(src)
    for c = 1, #chords do
      local got = directions(M.realize(C_MAJOR, pattern, chords[c]))
      for i = 1, #want do
        steps = steps + 1
        if got[i] ~= want[i] then wrong = wrong + 1 end
      end
    end
  end
  check(string.format("sweep: steps that change direction (of %d)", steps),
        wrong, 0)
end

--=============================================================================
print("-- which notes are chords")
--=============================================================================

do
  local notes = {
    note(4, 0.5, p("E5"), 1), note(4.5, 0.5, p("D5"), 2),   -- leftover 8ths
    note(5, 0.25, p("C5"), 3),                              -- a 16th
    note(8, 4, p("A4"), 4), note(8, 4, p("C#5"), 5),        -- whole notes
    note(12, 1, p("D4"), 6), note(13, 2, p("G4"), 7),       -- quarter, half
    note(15, 0.9, p("A4"), 8),                              -- short quarter
  }
  local got = M.blockChordNotes(notes, 4 * PPQ, math.huge, 0.75 * PPQ - TOL, TOL)
  local orders = {}
  for i = 1, #got do orders[i] = got[i].order end
  check("8ths and 16ths are ignored, quarters and longer are chords",
        orders, { 4, 5, 6, 7, 8 })
end

--=============================================================================
print("-- timing")
--=============================================================================

do
  local notes = figure("C4 E4 G4 C5", 0.25)
  notes[4].endPos = notes[4].startPos + 0.1 * PPQ    -- staccato last note
  local s, len = M.patternLength(notes, 0.25 * PPQ)
  check("staccato figure rounds up to the grid", { s, len }, { 0, PPQ })

  -- A figure that opens after a rest keeps the rest: its time starts on the
  -- beat, so every copy starts the same distance after the chord's attack.
  local late = figure("C4 E4 G4", 0.25)
  for i = 1, #late do
    late[i].startPos = late[i].startPos + 0.25 * PPQ
    late[i].endPos = late[i].endPos + 0.25 * PPQ
  end
  s, len = M.patternLength(late, 0.25 * PPQ, 0)
  check("figure after a rest starts on the beat", { s, len }, { 0, PPQ })
  local pattern = M.analyzePattern(C_MAJOR, late)
  local out = M.layout(pattern, s, len, ps("D4 F4 A4"), 4 * PPQ, 5 * PPQ)
  check("copy keeps the rest", out[1].startPos, 4.25 * PPQ)
end

do
  local chords = M.findChords({
    note(4, 4, p("A4"), 1), note(4.01, 4, p("C#5"), 2), note(4, 4, p("E5"), 3),
    note(8, 4, p("A4"), 4), note(8, 4, p("B4"), 5),
    note(14, 2, p("D4"), 6),
  }, TOL)
  check("three chords", #chords, 3)
  check("humanized onsets cluster", #chords[1].notes, 3)
  check("chord 1 runs to chord 2", { chords[1].startPos, chords[1].endPos },
        { 4 * PPQ, 8 * PPQ })
  check("chord 2 stops at its own end before a rest", chords[2].endPos, 12 * PPQ)
end

do
  -- A held bass note belongs to every chord it sounds under.
  local chords = M.findChords({
    note(0, 8, p("C3"), 1), note(0, 4, p("E4"), 2), note(0, 4, p("G4"), 3),
    note(4, 4, p("F4"), 4), note(4, 4, p("A4"), 5),
  }, TOL)
  check("held bass shared: chord 2 size", #chords[2].notes, 3)
end

do
  local pattern = M.analyzePattern(C_MAJOR, figure("C4 E4 G4 C5", 0.25))
  local pitches = ps("D4 F4 A4 D5")

  local out = M.layout(pattern, 0, PPQ, pitches, 4 * PPQ, 8 * PPQ)
  check("whole note gets the 1-beat figure 4 times", #out, 16)
  check("repeat 2 starts a beat in", out[5].startPos, 5 * PPQ)

  out = M.layout(pattern, 0, PPQ, pitches, 4 * PPQ, 4.6 * PPQ)
  check("short chord cuts the figure", #out, 3)
  check("last note is cut at the chord end", out[3].endPos, 4.6 * PPQ)
end

--=============================================================================
print(string.format("\n%d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
