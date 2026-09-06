--[[
  Offline tests for the pure voicing core of
  Orchestrate_selected_notes_to_next_tracks.lua.

  The script under test returns its core table and runs nothing else when the
  `reaper` global is absent, so it can be loaded straight into a plain Lua
  interpreter.

    lua5.4 tests/test_voicing.lua
]]

local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local M = dofile(here .. "/../Orchestrate_selected_notes_to_next_tracks.lua")

local PPQ = 960
local TOL = 0.03 * PPQ          -- the script's default onset tolerance
local DIVISI = { 3, 4, 2, 1, 5 } -- Vla, Vcl, Vln 2, Vln 1, Db

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

-- start and len in quarter notes, for readability
local function note(startQN, lenQN, pitch, order)
  return {
    order    = order or 0,
    startPos = startQN * PPQ,
    endPos   = (startQN + lenQN) * PPQ,
    pitch    = pitch,
  }
end

local function assign(notes, maxSlots)
  local sorted, slots = M.assignSlots(notes, {
    tol = TOL, maxSlots = maxSlots or 5, divisiOrder = DIVISI,
  })
  local bySlot = {}
  for i = 1, #sorted do
    bySlot[sorted[i].pitch] = sorted[i].slot
  end
  return bySlot, slots
end

--=============================================================================
print("-- capacities: fewer voices than parts (top down with bass anchor)")
--=============================================================================

check("2 of 5", M.capacities(2, 5, DIVISI), { 1, 0, 0, 0, 1 })
check("3 of 5", M.capacities(3, 5, DIVISI), { 1, 1, 0, 0, 1 })
check("4 of 5", M.capacities(4, 5, DIVISI), { 1, 1, 1, 0, 1 })
check("5 of 5", M.capacities(5, 5, DIVISI), { 1, 1, 1, 1, 1 })
check("2 of 2", M.capacities(2, 2, DIVISI), { 1, 1 })
check("2 of 3", M.capacities(2, 3, DIVISI), { 1, 0, 1 })
check("1 is degenerate", M.capacities(1, 5, DIVISI), nil)

--=============================================================================
print("-- capacities: more voices than parts (divisi Vla, Vcl, Vln2, Vln1, Db)")
--=============================================================================

check("6 of 5", M.capacities(6, 5, DIVISI),  { 1, 1, 2, 1, 1 })
check("7 of 5", M.capacities(7, 5, DIVISI),  { 1, 1, 2, 2, 1 })
check("8 of 5", M.capacities(8, 5, DIVISI),  { 1, 2, 2, 2, 1 })
check("9 of 5", M.capacities(9, 5, DIVISI),  { 2, 2, 2, 2, 1 })
check("10 of 5", M.capacities(10, 5, DIVISI), { 2, 2, 2, 2, 2 })
check("11 of 5 wraps", M.capacities(11, 5, DIVISI), { 2, 2, 3, 2, 2 })
-- Db (slot 5) stays monophonic until every other part has doubled.
check("Db last to divide", M.capacities(9, 5, DIVISI)[5], 1)

--=============================================================================
print("-- capacities: divisi order filtered to the parts that exist")
--=============================================================================

-- The bottom part carries the bass anchor, so it divides last whatever the
-- part count: with three parts the surplus goes to the middle one first.
check("4 of 3", M.capacities(4, 3, DIVISI), { 1, 2, 1 })
check("5 of 3", M.capacities(5, 3, DIVISI), { 2, 2, 1 })
check("6 of 3", M.capacities(6, 3, DIVISI), { 2, 2, 2 })
check("3 of 2", M.capacities(3, 2, DIVISI), { 2, 1 })
check("4 of 2", M.capacities(4, 2, DIVISI), { 2, 2 })

--=============================================================================
print("-- slotForRank")
--=============================================================================

check("5 voices rank 1", M.slotForRank(1, 5, 5, DIVISI), 1)
check("5 voices rank 5", M.slotForRank(5, 5, 5, DIVISI), 5)
-- 3 voices over 5 parts: Vln 1, Vln 2, then the bass anchors on Db.
check("3 voices rank 1", M.slotForRank(1, 3, 5, DIVISI), 1)
check("3 voices rank 2", M.slotForRank(2, 3, 5, DIVISI), 2)
check("3 voices rank 3", M.slotForRank(3, 3, 5, DIVISI), 5)
-- 6 voices: the two middle ones share the viola part.
check("6 voices rank 3", M.slotForRank(3, 6, 5, DIVISI), 3)
check("6 voices rank 4", M.slotForRank(4, 6, 5, DIVISI), 3)
check("6 voices rank 5", M.slotForRank(5, 6, 5, DIVISI), 4)
check("6 voices rank 6", M.slotForRank(6, 6, 5, DIVISI), 5)

--=============================================================================
print("-- soloSlot: a lone note is both the top and the bottom voice")
--=============================================================================

check("high lone note -> top part", M.soloSlot(76, 41, 76, 5), 1)
check("low lone note -> bottom part", M.soloSlot(45, 41, 76, 5), 5)
check("only one part available", M.soloSlot(45, 41, 76, 1), 1)

--=============================================================================
print("-- assignSlots: block chords")
--=============================================================================

do
  -- A5 F5 C5 A4 F3 -> Vln1 Vln2 Vla Vcl Db
  local bySlot, slots = assign({
    note(0, 4, 81, 1), note(0, 4, 77, 2), note(0, 4, 72, 3),
    note(0, 4, 69, 4), note(0, 4, 53, 5),
  })
  check("5 part chord uses 5 tracks", slots, 5)
  check("A5 -> Vln 1", bySlot[81], 1)
  check("F5 -> Vln 2", bySlot[77], 2)
  check("C5 -> Vla",   bySlot[72], 3)
  check("A4 -> Vcl",   bySlot[69], 4)
  check("F3 -> Db",    bySlot[53], 5)
end

do
  -- Three voices on their own only need three tracks.
  local bySlot, slots = assign({
    note(0, 4, 79, 1), note(0, 4, 74, 2), note(0, 4, 59, 3),
  })
  check("3 part chord uses 3 tracks", slots, 3)
  check("G5 -> Vln 1", bySlot[79], 1)
  check("D5 -> Vln 2", bySlot[74], 2)
  check("B3 -> Vla (bottom of 3)", bySlot[59], 3)
end

do
  -- Same three voices inside a passage that peaks at five: now the bass
  -- anchor holds B3 on Db rather than letting it climb to Vla.
  local bySlot, slots = assign({
    note(0, 1, 81, 1), note(0, 1, 77, 2), note(0, 1, 72, 3),
    note(0, 1, 69, 4), note(0, 1, 53, 5),
    note(1, 1, 79, 6), note(1, 1, 74, 7), note(1, 1, 59, 8),
  })
  check("passage uses 5 tracks", slots, 5)
  check("G5 -> Vln 1", bySlot[79], 1)
  check("D5 -> Vln 2", bySlot[74], 2)
  check("B3 anchors on Db", bySlot[59], 5)
end

--=============================================================================
print("-- assignSlots: adaptive track count")
--=============================================================================

do
  local _, slots = assign({ note(0, 4, 72, 1), note(0, 4, 60, 2) })
  check("2 voices -> 2 tracks", slots, 2)
end

do
  -- Eight voices are capped at five tracks, with the surplus in the middle.
  local pitches = { 84, 81, 79, 76, 72, 69, 64, 48 }
  local notes = {}
  for i, p in ipairs(pitches) do notes[i] = note(0, 4, p, i) end
  local bySlot, slots = assign(notes)
  check("8 voices -> 5 tracks", slots, 5)
  check("C6 -> Vln 1", bySlot[84], 1)
  check("A5 -> Vln 2", bySlot[81], 2)
  check("G5 -> Vln 2 (divisi)", bySlot[79], 2)
  check("E5 -> Vla", bySlot[76], 3)
  check("C5 -> Vla (divisi)", bySlot[72], 3)
  check("A4 -> Vcl", bySlot[69], 4)
  check("E4 -> Vcl (divisi)", bySlot[64], 4)
  check("C3 -> Db (monophonic)", bySlot[48], 5)
end

--=============================================================================
print("-- assignSlots: held notes rank against everything sounding")
--=============================================================================

do
  -- A pedal F2 under a moving upper line.  The bass keeps the bottom part and
  -- every upper note is the top voice of the two sounding.
  local bySlot, slots = assign({
    note(0, 4, 41, 1),
    note(0, 1, 72, 2), note(1, 1, 74, 3), note(2, 1, 76, 4), note(3, 1, 77, 5),
  })
  check("pedal texture uses 2 tracks", slots, 2)
  check("F2 pedal -> bottom part", bySlot[41], 2)
  check("C5 -> Vln 1", bySlot[72], 1)
  check("D5 -> Vln 1", bySlot[74], 1)
  check("E5 -> Vln 1", bySlot[76], 1)
  check("F5 -> Vln 1", bySlot[77], 1)
end

do
  -- An inner line moving inside a held outer frame stays in the middle
  -- instead of being read as a fresh top voice.
  local bySlot = assign({
    note(0, 4, 84, 1),                 -- held top
    note(0, 4, 48, 2),                 -- held bottom
    note(0, 2, 67, 3), note(2, 2, 65, 4), -- moving inner voice
  })
  check("held top -> Vln 1", bySlot[84], 1)
  check("inner G4 -> Vln 2", bySlot[67], 2)
  check("inner F4 -> Vln 2", bySlot[65], 2)
  check("held bottom -> Db", bySlot[48], 3)
end

--=============================================================================
print("-- assignSlots: onset tolerance")
--=============================================================================

do
  -- A strummed / humanized chord: onsets scattered by a few ticks still rank
  -- as one sonority rather than as three entries of a solo top voice.
  local notes = {
    { order = 1, startPos = 0,  endPos = 4 * PPQ, pitch = 79 },
    { order = 2, startPos = 7,  endPos = 4 * PPQ, pitch = 74 },
    { order = 3, startPos = 15, endPos = 4 * PPQ, pitch = 55 },
  }
  local bySlot, slots = assign(notes)
  check("strummed chord uses 3 tracks", slots, 3)
  check("strummed top -> Vln 1", bySlot[79], 1)
  check("strummed middle -> Vln 2", bySlot[74], 2)
  check("strummed bottom -> bottom part", bySlot[55], 3)
end

do
  -- Legato overlap: each note outlasts the next attack by a hair.  That tail
  -- must not read as a second voice.
  local notes = {}
  for i = 0, 3 do
    notes[i + 1] = {
      order = i + 1,
      startPos = i * PPQ,
      endPos   = (i + 1) * PPQ + 10,   -- 10 ticks of overlap, tolerance is ~29
      pitch    = 72 + i,
    }
  end
  local _, slots = assign(notes)
  check("legato line stays monophonic", slots, 1)
end

do
  -- A real overlap, well beyond the tolerance, is genuine two part writing.
  local notes = {
    { order = 1, startPos = 0,        endPos = 2 * PPQ, pitch = 72 },
    { order = 2, startPos = 1 * PPQ,  endPos = 3 * PPQ, pitch = 60 },
  }
  local _, slots = assign(notes)
  check("real overlap counts as 2 voices", slots, 2)
end

--=============================================================================
print("-- assignSlots: degenerate input")
--=============================================================================

do
  local sorted, slots = M.assignSlots({}, { tol = TOL, maxSlots = 5,
                                            divisiOrder = DIVISI })
  check("empty selection", #sorted, 0)
  check("empty selection uses no tracks", slots, 0)
end

do
  -- A lone melodic fragment belongs on the top part, not the bass.
  local bySlot, slots = assign({ note(0, 1, 76, 1), note(1, 1, 77, 2) })
  check("solo line uses 1 track", slots, 1)
  check("solo line -> first track", bySlot[76], 1)
end

do
  -- Where a passage does use several parts, an isolated low note left alone
  -- after the others rest stays on the bass part.
  local bySlot = assign({
    note(0, 1, 84, 1), note(0, 1, 76, 2), note(0, 1, 48, 3),
    note(2, 1, 50, 4),
  })
  check("isolated low note -> bottom part", bySlot[50], 3)
end

--=============================================================================
print(string.format("\n%d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
