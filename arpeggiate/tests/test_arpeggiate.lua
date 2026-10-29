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
  -- G is not in the A chord, so chord tones win: the neighbour becomes E.
  check("over A: group 3's neighbour becomes a chord tone",
        { a[9], a[10], a[11], a[12] }, ps("A4 C#5 E5 A5"))
  a = M.realize(D_MAJOR, pattern, ps("A4 C#5 E5 A5"), { chordTones = false })
  check("chord tones off: group 3 takes the key's 7th",
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
  check("passing lowest note does not become the root",
        pattern.chord.rootPc, 11)
  local r = M.realize(D_MAJOR, pattern, ps("E4 G4 B4"),
                      { allowInversions = false, chordTones = false })
  check("leading tone stays a leading tone", r, ps("E5 D#5 E5 G5 B5"))

  -- Inverted onto the fifth, it becomes the fifth's leading tone.
  r = M.realize(D_MAJOR, pattern, ps("E4 G4 B4"), { chordTones = false })
  check("inverted: neighbour follows its chord tone", r, ps("B4 A#4 B4 E5 G5"))

  -- With chord tones winning, the neighbour drops to the chord tone below.
  r = M.realize(D_MAJOR, pattern, ps("E4 G4 B4"))
  check("chord tones: neighbour becomes the tone below", r, ps("B4 G4 B4 E5 G5"))
end

--=============================================================================
print("-- chord tones over shape")
--=============================================================================

do
  -- Two bars of 8ths over C with passing and neighbour notes.
  local pattern = M.analyzePattern(C_MAJOR, figure(
    "C4 D4 E4 G4  A4 G4 E4 D4  C4 E4 F4 G4  C5 B4 G4 E4", 0.5))
  check("long figure is read as C", pattern.chord.rootPc, 0)

  local function onlyTones(pitches, pcs)
    for i = 1, #pitches do
      if not pcs[pitches[i] % 12] then return false end
    end
    return true
  end
  local function sameContour(a, b)
    for i = 2, #a do
      local x, y = a[i] - a[i - 1], b[i] - b[i - 1]
      if (x > 0) ~= (y > 0) or (x < 0) ~= (y < 0) then return false end
    end
    return true
  end
  local src = {}
  for i = 1, #pattern.notes do src[i] = pattern.notes[i].pitch end

  local chords = {
    { "G",   ps("G3 B3 D4"),     { [7] = true, [11] = true, [2] = true } },
    { "Am",  ps("A3 C4 E4"),     { [9] = true, [0] = true, [4] = true } },
    { "F",   ps("F3 A3 C4"),     { [5] = true, [9] = true, [0] = true } },
    { "Dm7", ps("D3 A3 C4 F4"),  { [2] = true, [5] = true, [9] = true, [0] = true } },
  }
  for _, c in ipairs(chords) do
    local r = M.realize(C_MAJOR, pattern, c[2])
    check(c[1] .. ": every note is a chord tone", onlyTones(r, c[3]), true)
    check(c[1] .. ": contour kept", sameContour(r, src), true)
    check(c[1] .. ": starts near the anchor",
          math.abs(r[1] - pattern.anchor) <= 2, true)
  end
end

do
  -- A bare fifth still gets a third, from the key.
  local chord = M.analyzeChord(C_MAJOR, ps("A3 E4"))
  local tones = M.chordTonePcs(C_MAJOR, chord)
  check("power chord tones include the key's third",
        { tones[9], tones[0], tones[4], tones[2] }, { true, true, true, nil })
end

do
  -- The line is chosen as a whole: a neighbour snaps to the tone that keeps
  -- the next step cheap, not just to the nearest.
  local out = M.snapToChordTones(ps("A4 C#5 G5 A5"), ps("B4 D5 A5 B5"),
                                 { [9] = true, [1] = true, [4] = true })
  check("neighbour picks the tone that keeps the line", out, ps("A4 C#5 E5 A5"))
  out = M.snapToChordTones(ps("C4 C4 E4"), ps("C4 C4 E4"),
                           { [0] = true, [4] = true, [7] = true })
  check("repeats stay repeats", out, ps("C4 C4 E4"))
end

--=============================================================================
print("-- timing")
--=============================================================================

do
  local notes = figure("C4 E4 G4 C5", 0.25)
  notes[4].endPos = notes[4].startPos + 0.1 * PPQ    -- staccato last note
  local s, len = M.patternLength(notes, 0.25 * PPQ)
  check("staccato figure rounds up to the grid", { s, len }, { 0, PPQ })
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
