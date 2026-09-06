--[[
  Offline tests for the pure core of
  Orchestrate_and_legato_selected_notes_to_next_tracks.lua.

  The script under test returns its core table and runs nothing else when the
  `reaper` global is absent, so it can be loaded straight into a plain Lua
  interpreter.

    lua5.4 tests/test_legato.lua

  The voicing half of that core is covered by the orchestrator's own suite;
  what is exercised here is the legato half, plus enough of the two working
  together to show that phrases are traced per part.
]]

local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local M = dofile(here ..
  "/../Orchestrate_and_legato_selected_notes_to_next_tracks.lua")

local PPQ    = 960
local OFFSET = PPQ / 6           -- a 24th note: the script's default offset
local TOL    = 0.03 * PPQ        -- the script's default onset tolerance

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

local function section(name) print("-- " .. name) end

--=============================================================================
-- Fixtures
--=============================================================================

local nextOrder = 0

-- A note, positioned in quarter notes for legibility.
local function note(startQN, lenQN, pitch, vel)
  nextOrder = nextOrder + 1
  return {
    order    = nextOrder,
    startPos = math.floor(startQN * PPQ + 0.5),
    endPos   = math.floor((startQN + lenQN) * PPQ + 0.5),
    pitch    = pitch,
    vel      = vel or 64,
  }
end

-- The whole legato pass over one part, with the script's defaults.
local function legato(notes, opts)
  opts = opts or {}
  M.buildChains(notes, {
    onsetTol = opts.onsetTol or 0,
    gapTol   = opts.gapTol or 0,
  })
  return M.applyLegato(notes, {
    offset            = opts.offset or OFFSET,
    velocity          = 127,
    maxOffsetFraction = opts.fraction or 0.5,
    minStart          = opts.minStart,
  })
end

local function starts(notes)
  local out = {}
  for i = 1, #notes do out[i] = notes[i].legStart end
  return out
end

local function ends(notes)
  local out = {}
  for i = 1, #notes do out[i] = notes[i].legEnd or notes[i].endPos end
  return out
end

local function vels(notes)
  local out = {}
  for i = 1, #notes do out[i] = notes[i].legVel end
  return out
end

local function firsts(notes)
  local out = {}
  for i = 1, #notes do out[i] = notes[i].phraseFirst end
  return out
end

local function prevPitches(notes)
  local out = {}
  for i = 1, #notes do
    out[i] = notes[i].prev and notes[i].prev.pitch or false
  end
  return out
end

--=============================================================================
-- canFollow
--=============================================================================

section("canFollow: what keeps a phrase going")

do
  local a = note(0, 1, 60)
  local b = note(1, 1, 62)
  check("touching notes are one phrase", M.canFollow(a, b, 0, 0), true)
end

do
  local a = note(0, 1.5, 60)
  local b = note(1, 1, 62)
  check("overlapping notes are one phrase", M.canFollow(a, b, 0, 0), true)
end

do
  local a = note(0, 0.9, 60)
  local b = note(1, 1, 62)
  check("a gap ends the phrase", M.canFollow(a, b, 0, 0), false)
  check("a gap inside gapTol does not", M.canFollow(a, b, 0, 0.1 * PPQ), true)
end

do
  local a = note(0, 1, 60)
  local b = note(1, 1, 60)
  check("a repeated pitch ends the phrase", M.canFollow(a, b, 0, 0), false)
end

do
  local a = note(0, 1, 60)
  local b = note(0, 1, 64)
  check("simultaneous notes are a chord, not a line",
        M.canFollow(a, b, 0, 0), false)
end

do
  local a = note(0, 1, 60)
  local b = note(0.02, 1, 64)
  check("near simultaneous notes are a chord too",
        M.canFollow(a, b, TOL, 0), false)
end

--=============================================================================
-- buildChains
--=============================================================================

section("buildChains: tracing phrases through one part")

do
  local ns = { note(0, 1, 60), note(1, 1, 62), note(2, 1, 64) }
  M.buildChains(ns, {})
  check("a touching run is one phrase", firsts(ns), { true, false, false })
  check("each note is slurred from the one before it",
        prevPitches(ns), { false, 60, 62 })
end

do
  local ns = { note(0, 0.9, 60), note(1, 1, 62), note(2, 1, 64) }
  M.buildChains(ns, {})
  check("a gap starts a new phrase", firsts(ns), { true, true, false })
end

do
  local ns = { note(0, 1, 60), note(1, 1, 60), note(2, 1, 64) }
  M.buildChains(ns, {})
  check("a repeat starts a new phrase", firsts(ns), { true, true, false })
  check("and the note after the repeat follows the repeat",
        prevPitches(ns), { false, false, 60 })
end

do
  -- C D C: the second C is slurred from the D, not left dangling by the
  -- first C being the same pitch.
  local ns = { note(0, 1, 60), note(1, 1, 62), note(2, 1, 60) }
  M.buildChains(ns, {})
  check("a pitch may return later in the phrase",
        firsts(ns), { true, false, false })
  check("and follows whatever actually preceded it",
        prevPitches(ns), { false, 60, 62 })
end

do
  -- A part that has gone divisi: two lines, a fifth apart, moving together.
  local a1 = note(0, 1, 67)
  local b1 = note(0, 1, 60)
  local a2 = note(1, 1, 69)
  local b2 = note(1, 1, 62)
  local ns = { a1, b1, a2, b2 }
  M.buildChains(ns, {})
  check("both lines of a divided part continue",
        firsts(ns), { true, true, false, false })
  check("the upper line follows the upper line", a2.prev.pitch, 67)
  check("the lower line follows the lower line", b2.prev.pitch, 60)
end

do
  -- Two attacks, one note to slur from: one of them has to start a phrase.
  local held = note(0, 1, 60)
  local x    = note(1, 1, 62)
  local y    = note(1, 1, 72)
  local ns = { held, x, y }
  M.buildChains(ns, {})
  check("a note can only be slurred from once",
        firsts(ns), { true, false, true })
  check("and the nearest in pitch is the one that claims it", x.prev.pitch, 60)
end

do
  local ns = {}
  M.buildChains(ns, {})
  check("no notes is not an error", #ns, 0)
end

do
  local ns = { note(0, 1, 60) }
  M.buildChains(ns, {})
  check("a lone note is a phrase of one", firsts(ns), { true })
end

--=============================================================================
-- applyLegato
--=============================================================================

section("applyLegato: pulling the continuations earlier")

do
  local ns = { note(0, 1, 60, 70), note(1, 1, 62, 80), note(2, 1, 64, 90) }
  local continuations, moved = legato(ns)

  check("the first note of the phrase does not move",
        starts(ns), { 0, 960 - OFFSET, 1920 - OFFSET })
  check("ends are left alone, so the notes just get longer",
        ends(ns), { 960, 1920, 2880 })
  check("the first note keeps its velocity, the rest are the trigger value",
        vels(ns), { 70, 127, 127 })
  check("continuation count", continuations, 2)
  check("moved count", moved, 2)
end

do
  local ns = { note(0, 0.9, 60, 70), note(1, 1, 62, 80) }
  legato(ns)
  check("a phrase start after a gap keeps its position",
        starts(ns), { 0, 960 })
  check("and its velocity", vels(ns), { 70, 80 })
end

do
  -- A run of 32nd notes: 120 ticks each, shorter than the 160 tick offset.
  local ns = {}
  for i = 0, 3 do ns[#ns + 1] = note(i * 0.125, 0.125, 60 + i) end
  local continuations, moved = legato(ns)
  local cap = math.floor(0.125 * PPQ * 0.5)   -- 60 ticks

  check("a fast run is offset by a fraction of the note, not the full amount",
        starts(ns), { 0, 120 - cap, 240 - cap, 360 - cap })
  check("every note of it still counts as legato", continuations, 3)
  check("and every one of them moved", moved, 3)
  check("the run stays evenly spaced",
        ns[3].legStart - ns[2].legStart, ns[4].legStart - ns[3].legStart)
end

do
  local ns = { note(0, 1, 60), note(1, 1, 62) }
  legato(ns, { minStart = 900 })
  check("nothing is pulled out of the front of its item",
        starts(ns), { 0, 900 })
end

do
  -- A C sustaining under a moving E, then a fresh C slurred from that E a
  -- moment after the first one let go: pulling the new C back the full offset
  -- would leave it overlapping the old one.
  local ns = { note(0, 1.5, 60), note(0.5, 1.1, 64), note(1.6, 1, 60) }
  legato(ns)
  check("an attack is never pulled back over the same pitch",
        ns[3].legStart, ns[1].endPos)
  check("it is held at the release of that note, not at its own start",
        ns[3].legStart < ns[3].startPos, true)
  check("and it is still a legato note", ns[3].legVel, 127)
end

do
  local ns = { note(0, 1, 60, 70), note(1, 1, 62, 80) }
  legato(ns)
  local firstPass = { starts(ns)[1], starts(ns)[2], vels(ns)[1], vels(ns)[2] }
  legato(ns)
  local secondPass = { starts(ns)[1], starts(ns)[2], vels(ns)[1], vels(ns)[2] }
  check("the pass reads the original geometry, so re-running is stable",
        firstPass, secondPass)
end

do
  local ns = { note(0, 1, 60), note(1, 1, 62) }
  ns[2].offsetTicks = 40
  legato(ns)
  check("a note may carry its own offset (this is the millisecond mode)",
        ns[2].legStart, 920)
end

do
  local ns = { note(0, 1, 60, 70) }
  local continuations, moved = legato(ns)
  check("a lone note is not legato", vels(ns), { 70 })
  check("and moves nowhere", starts(ns), { 0 })
  check("counts", { continuations, moved }, { 0, 0 })
end

--=============================================================================
-- The two halves together
--=============================================================================

section("distribution and legato together")

do
  -- Two voices, each a touching run, distributed over two parts.
  local ns = {
    note(0, 1, 72), note(0, 1, 48),
    note(1, 1, 74), note(1, 1, 50),
  }
  local assigned, slots = M.assignSlots(ns, {
    tol = TOL, maxSlots = 5, divisiOrder = { 3, 4, 2, 1, 5 },
  })
  check("two voices use two parts", slots, 2)

  local parts = { {}, {} }
  for i = 1, #assigned do
    local p = parts[assigned[i].slot]
    p[#p + 1] = assigned[i]
  end
  check("the top line went to the first part", parts[1][1].pitch, 72)
  check("the bass line went to the last", parts[2][1].pitch, 48)

  local total = 0
  for slot = 1, slots do total = total + legato(parts[slot], { onsetTol = TOL }) end
  check("one continuation in each part", total, 2)

  check("phrases are traced inside a part, not across the texture",
        { parts[1][2].prev.pitch, parts[2][2].prev.pitch }, { 72, 48 })
  check("voices that move together stay vertically aligned",
        parts[1][2].legStart, parts[2][2].legStart)
end

do
  -- A held bass under a moving top line: the held note is not re-attacked,
  -- and the line above it is legato throughout.
  local ns = {
    note(0, 4, 36),
    note(0, 1, 72), note(1, 1, 74), note(2, 1, 76), note(3, 1, 77),
  }
  local assigned, slots = M.assignSlots(ns, {
    tol = TOL, maxSlots = 5, divisiOrder = { 3, 4, 2, 1, 5 },
  })
  local parts = {}
  for slot = 1, slots do parts[slot] = {} end
  for i = 1, #assigned do
    local p = parts[assigned[i].slot]
    p[#p + 1] = assigned[i]
  end

  local top = parts[1]
  legato(top, { onsetTol = TOL })
  check("the melody is one phrase", firsts(top), { true, false, false, false })

  local bass = parts[slots]
  legato(bass, { onsetTol = TOL })
  check("a pedal note is left exactly where it was",
        { bass[1].legStart, bass[1].legVel }, { 0, 64 })
end

print(string.format("\n%d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
