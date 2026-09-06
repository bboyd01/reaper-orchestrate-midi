--[[
  Orchestrate selected notes to the next tracks (string ensemble)

  A ReaScript for REAPER, intended to be run as a MIDI Editor action.

  With notes selected in the active MIDI editor take, distributes them by pitch
  across the MIDI items on the next tracks below the source track, so that a
  polyphonic ensemble-patch sketch becomes a Vln 1 / Vln 2 / Vla / Vcl / Db
  divisi setup.

  The highest sounding voice goes to the first track below the source, the next
  highest to the second, and so on.  The lowest sounding voice is always placed
  on the last active track so the bass line stays put when the texture thins.

  Requires only stock REAPER (no SWS functions are used, so it also runs fine
  in an installation that has SWS).

  Usage:
    Actions -> Show action list -> MIDI Editor section -> New action ->
    Load ReaScript, then bind this file to a key.

  Assumptions:
    - The next tracks below the source already exist and each already holds a
      MIDI item at the same position and length as the source item.
    - The source material is polyphonic.

  This file is also loadable as a plain Lua module (it returns its pure voicing
  core and does nothing else when the `reaper` global is absent), which is what
  tests/test_voicing.lua does.
]]

--=============================================================================
-- CONFIGURATION
--=============================================================================

local CONFIG = {
  -- Maximum number of tracks below the source to write to.
  -- 5 == Vln 1, Vln 2, Vla, Vcl, Db.
  MAX_TARGET_TRACKS = 5,

  -- Notes at or below this MIDI pitch are treated as articulation keyswitches
  -- rather than music: they take no part in the voice distribution and are
  -- copied verbatim to every target track.
  -- 11 == B-1 in REAPER's default C-1 = 0 naming, i.e. everything below C0.
  -- Raise to 23 (everything below C1) if your library keyswitches up to B0 and
  -- you never write below the double bass's low C.
  KEYSWITCH_MAX_PITCH = 11,

  -- Onset clustering tolerance, in quarter notes.  Notes starting within this
  -- window of one another are treated as one chord attack, so humanized or
  -- strummed input is still ranked as a single vertical sonority.
  -- It doubles as a release tolerance: a held note with less than this much
  -- duration remaining at an attack is treated as already released, so legato
  -- overlaps do not inflate the voice count.
  -- 0.03 QN is about 15 ms at 120 bpm.
  ONSET_TOLERANCE_QN = 0.03,

  -- Order in which slots take a second (and third, ...) note once there are
  -- more simultaneous voices than target tracks.  Slot 1 is the first track
  -- below the source.  Slots not listed here, and slots beyond the number of
  -- active tracks, are skipped.  Db (slot 5) is last, so the bass line stays
  -- monophonic longest.
  DIVISI_ORDER = { 3, 4, 2, 1, 5 },  -- Vla, Vcl, Vln 2, Vln 1, Db

  -- Copy MIDI CC, pitch bend, program change and channel/poly pressure to
  -- every track that receives notes.
  COPY_CC = true,

  -- Copy text and sysex events (this includes REAPER's notation events).
  -- Off by default: notation attached to the source voicing rarely makes sense
  -- on the distributed parts.
  COPY_TEXT_SYSEX = false,

  -- Clear each target item's existing notes and CC before writing, so that
  -- re-running the script replaces the previous result instead of stacking a
  -- second copy on top of it.
  CLEAR_TARGETS = true,

  -- How far apart (in seconds) a target item's start may be from the source
  -- item's start and still count as an exact positional match.
  ITEM_MATCH_TOLERANCE_SEC = 0.001,
}

local SCRIPT_TITLE = "Orchestrate selected notes to next tracks"

--=============================================================================
-- PURE CORE
--
-- Everything below this point up to the "REAPER GLUE" banner is free of any
-- reaper.* call, and is unit tested by tests/test_voicing.lua.
--
-- A "note" here is a table with at least: startPos, endPos, pitch, order.
-- Positions are in PPQ ticks of the source take; `order` is the note's index
-- in the source take and is only used to break ties deterministically.
--=============================================================================

local M = {}

-- True when `note` is sounding at time `t`, given a tolerance.
-- Half open: a note starting within `tol` of `t` counts as sounding, a note
-- whose remaining duration at `t` is `tol` or less counts as already released.
function M.isSounding(note, t, tol)
  return note.startPos <= t + tol and note.endPos > t + tol
end

-- Groups note onsets into chord attacks.  Returns the input notes sorted by
-- start position, each stamped with an `onsetKey` equal to the start position
-- of the first note in its cluster.  Also returns the ascending list of
-- distinct cluster times.
function M.clusterOnsets(notes, tol)
  local sorted = {}
  for i = 1, #notes do sorted[i] = notes[i] end
  table.sort(sorted, function(a, b)
    if a.startPos ~= b.startPos then return a.startPos < b.startPos end
    if a.pitch ~= b.pitch then return a.pitch > b.pitch end
    return a.order < b.order
  end)

  local clusterTimes = {}
  local current = nil
  for i = 1, #sorted do
    local n = sorted[i]
    if current == nil or n.startPos > current + tol then
      current = n.startPos
      clusterTimes[#clusterTimes + 1] = current
    end
    n.onsetKey = current
  end

  return sorted, clusterTimes
end

-- Every note sounding at `t`, ranked high to low.  Rank 1 is the highest
-- pitch; ties are broken by earlier onset, then by source order, so the
-- ranking is stable and reproducible.
function M.soundingRanked(notes, t, tol)
  local sounding = {}
  for i = 1, #notes do
    if M.isSounding(notes[i], t, tol) then
      sounding[#sounding + 1] = notes[i]
    end
  end
  table.sort(sounding, function(a, b)
    if a.pitch ~= b.pitch then return a.pitch > b.pitch end
    if a.startPos ~= b.startPos then return a.startPos < b.startPos end
    return a.order < b.order
  end)
  return sounding
end

-- The largest number of voices sounding simultaneously anywhere in `notes`.
-- Polyphony can only peak at an attack, so it is enough to sample the cluster
-- times.
function M.maxPolyphony(notes, tol)
  local sorted, clusterTimes = M.clusterOnsets(notes, tol)
  local best = 0
  for i = 1, #clusterTimes do
    local n = #M.soundingRanked(sorted, clusterTimes[i], tol)
    if n > best then best = n end
  end
  return best
end

-- How many notes each slot takes when `m` voices are spread over `n` slots.
-- Returns an array of length `n` summing to `m`.
--
--   m < n   top down with a bass anchor: slots 1..m-1 take the upper voices,
--           the lowest voice lands on slot n, the slots in between are tacet.
--   m == n  one voice per slot.
--   m > n   one voice per slot, then the surplus is handed out cyclically in
--           `divisiOrder` so the inner parts go divisi before the outer ones.
--
-- `m == 1` is degenerate (the note is both the top and the bottom voice) and
-- is resolved by the caller, not here; this returns nil for it.
function M.capacities(m, n, divisiOrder)
  if m < 1 or n < 1 then return nil end
  if m == 1 then return nil end

  local cap = {}
  for i = 1, n do cap[i] = 0 end

  if m <= n then
    for i = 1, m - 1 do cap[i] = 1 end
    cap[n] = 1
    return cap
  end

  for i = 1, n do cap[i] = 1 end

  -- Keep only the slots that exist for this part count, preserving priority,
  -- and always push the bottom part to the end of the queue: it carries the
  -- bass anchor, so it is the last one that should go divisi.
  local order = {}
  for i = 1, #divisiOrder do
    local slot = divisiOrder[i]
    if slot <= n and slot ~= n then order[#order + 1] = slot end
  end
  order[#order + 1] = n

  local surplus = m - n
  local k = 0
  while surplus > 0 do
    local slot = order[(k % #order) + 1]
    cap[slot] = cap[slot] + 1
    surplus = surplus - 1
    k = k + 1
  end

  return cap
end

-- Maps a voice's rank (1 = highest of `m` sounding voices) to a slot number
-- (1 = first track below the source).  `soloSlot` is used for the degenerate
-- single voice case.
function M.slotForRank(rank, m, n, divisiOrder, soloSlot)
  if n < 1 then return 1 end
  if m == 1 then
    local s = soloSlot or 1
    if s < 1 then s = 1 elseif s > n then s = n end
    return s
  end

  local cap = M.capacities(m, n, divisiOrder)
  local acc = 0
  for slot = 1, n do
    acc = acc + cap[slot]
    if rank <= acc then return slot end
  end
  return n
end

-- Which slot a lone note belongs on.  A single note is simultaneously the top
-- and the bottom voice, so neither the top-down rule nor the bass anchor
-- decides it.  Compare it against the midpoint of the selection's overall
-- pitch range instead: an isolated melodic fragment stays on the top part, an
-- isolated bass note stays on the bottom one.
function M.soloSlot(pitch, minPitch, maxPitch, n)
  if n < 2 then return 1 end
  local midpoint = (minPitch + maxPitch) / 2
  if pitch >= midpoint then return 1 end
  return n
end

-- The heart of the script.
--
-- Assigns every note in `notes` a `slot`, and returns the notes (sorted by
-- onset) together with the number of slots actually used.
--
-- A note's slot is decided once, at its own attack, from its pitch rank among
-- everything sounding at that moment.  Notes held over from an earlier attack
-- keep the slot they were already given, because a sustaining note cannot
-- change track partway through.
--
-- opts: { tol, maxSlots, divisiOrder }
function M.assignSlots(notes, opts)
  local tol = opts.tol or 0
  local maxSlots = opts.maxSlots or 5
  local divisiOrder = opts.divisiOrder or { 3, 4, 2, 1, 5 }

  if #notes == 0 then return {}, 0 end

  local sorted, clusterTimes = M.clusterOnsets(notes, tol)

  local minPitch, maxPitch = math.huge, -math.huge
  for i = 1, #sorted do
    if sorted[i].pitch < minPitch then minPitch = sorted[i].pitch end
    if sorted[i].pitch > maxPitch then maxPitch = sorted[i].pitch end
  end

  -- Number of parts to use: the thickest moment in the selection, capped.
  local maxPoly = 0
  local ranked = {}
  for i = 1, #clusterTimes do
    local t = clusterTimes[i]
    ranked[i] = M.soundingRanked(sorted, t, tol)
    if #ranked[i] > maxPoly then maxPoly = #ranked[i] end
  end

  local slots = maxPoly
  if slots > maxSlots then slots = maxSlots end
  if slots < 1 then slots = 1 end

  for i = 1, #clusterTimes do
    local t = clusterTimes[i]
    local sounding = ranked[i]
    local m = #sounding
    for rank = 1, m do
      local note = sounding[rank]
      -- Only notes attacking in this cluster are assigned here; anything held
      -- over already has a slot from the cluster it started in.
      if note.onsetKey == t and note.slot == nil then
        if m == 1 then
          note.slot = M.soloSlot(note.pitch, minPitch, maxPitch, slots)
        else
          note.slot = M.slotForRank(rank, m, slots, divisiOrder, nil)
        end
      end
    end
  end

  -- Belt and braces: a note that somehow never appeared in a sounding set
  -- (a zero or negative length note, say) still needs a home.
  for i = 1, #sorted do
    if sorted[i].slot == nil then
      sorted[i].slot = M.soloSlot(sorted[i].pitch, minPitch, maxPitch, slots)
    end
  end

  return sorted, slots
end

--=============================================================================
-- REAPER GLUE
--=============================================================================

-- Bail-outs hand their message back to main(), which shows it once the undo
-- block is closed, rather than popping a dialog mid-run.
local function fail(msg)
  return nil, msg
end

-- PPQ ticks per quarter note for a take, derived rather than assumed.
local function ppqPerQN(take)
  local a = reaper.MIDI_GetPPQPosFromProjQN(take, 0)
  local b = reaper.MIDI_GetPPQPosFromProjQN(take, 1)
  local ppq = b - a
  if ppq <= 0 then ppq = 960 end
  return ppq
end

-- Reads every selected note out of the source take, splitting keyswitches from
-- musical material.
local function readSelectedNotes(take)
  local music, keyswitches = {}, {}
  local _, noteCount = reaper.MIDI_CountEvts(take)
  for i = 0, noteCount - 1 do
    local ok, selected, muted, startPos, endPos, chan, pitch, vel =
      reaper.MIDI_GetNote(take, i)
    if ok and selected then
      local note = {
        order    = i,
        startPos = startPos,
        endPos   = endPos,
        muted    = muted,
        chan     = chan,
        pitch    = pitch,
        vel      = vel,
      }
      if pitch <= CONFIG.KEYSWITCH_MAX_PITCH then
        keyswitches[#keyswitches + 1] = note
      else
        music[#music + 1] = note
      end
    end
  end
  return music, keyswitches
end

-- Reads all CC style events: control change, program change, pitch bend and
-- channel/poly pressure, with their curve shapes.
local function readCCs(take)
  local ccs = {}
  if not CONFIG.COPY_CC then return ccs end
  local _, _, ccCount = reaper.MIDI_CountEvts(take)
  for i = 0, ccCount - 1 do
    local ok, _, muted, ppqpos, chanmsg, chan, msg2, msg3 =
      reaper.MIDI_GetCC(take, i)
    if ok then
      local _, shape, tension = reaper.MIDI_GetCCShape(take, i)
      ccs[#ccs + 1] = {
        muted   = muted,
        ppqpos  = ppqpos,
        chanmsg = chanmsg,
        chan    = chan,
        msg2    = msg2,
        msg3    = msg3,
        shape   = shape or 0,
        tension = tension or 0.0,
      }
    end
  end
  return ccs
end

local function readTextSysex(take)
  local evts = {}
  if not CONFIG.COPY_TEXT_SYSEX then return evts end
  local _, _, _, count = reaper.MIDI_CountEvts(take)
  for i = 0, count - 1 do
    local ok, _, muted, ppqpos, evtType, msg =
      reaper.MIDI_GetTextSysexEvt(take, i)
    if ok then
      evts[#evts + 1] = {
        muted = muted, ppqpos = ppqpos, evtType = evtType, msg = msg,
      }
    end
  end
  return evts
end

-- Finds the MIDI take on `track` that lines up with the source item.  Prefers
-- an exact positional match, and otherwise takes the item with the greatest
-- overlap.  Returns the take, or nil plus a reason.
local function findTargetTake(track, srcPos, srcLen)
  local srcEnd = srcPos + srcLen
  local best, bestOverlap = nil, 0

  for i = 0, reaper.CountTrackMediaItems(track) - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

    if math.abs(pos - srcPos) <= CONFIG.ITEM_MATCH_TOLERANCE_SEC then
      best, bestOverlap = item, math.huge
      break
    end

    local overlap = math.min(srcEnd, pos + len) - math.max(srcPos, pos)
    if overlap > bestOverlap then
      best, bestOverlap = item, overlap
    end
  end

  if not best or bestOverlap <= 0 then
    return nil, "no MIDI item overlapping the source item"
  end

  local take = reaper.GetActiveTake(best)
  if not take then
    return nil, "the item there has no active take"
  end
  if not reaper.TakeIsMIDI(take) then
    return nil, "the item there is not a MIDI item"
  end

  return take
end

local function clearTake(take)
  local _, notes, ccs, sysex = reaper.MIDI_CountEvts(take)
  for i = notes - 1, 0, -1 do reaper.MIDI_DeleteNote(take, i) end
  for i = ccs - 1, 0, -1 do reaper.MIDI_DeleteCC(take, i) end
  if CONFIG.COPY_TEXT_SYSEX then
    for i = sysex - 1, 0, -1 do reaper.MIDI_DeleteTextSysexEvt(take, i) end
  end
end

-- Source PPQ -> destination PPQ, routed through project time so that items
-- with a different PPQ resolution, start offset or play rate still line up.
local function makePPQMapper(srcTake, dstTake)
  return function(ppq)
    local t = reaper.MIDI_GetProjTimeFromPPQPos(srcTake, ppq)
    return math.floor(reaper.MIDI_GetPPQPosFromProjTime(dstTake, t) + 0.5)
  end
end

local function writeToTake(srcTake, dstTake, notes, ccs, sysex)
  local mapPPQ = makePPQMapper(srcTake, dstTake)

  if CONFIG.CLEAR_TARGETS then clearTake(dstTake) end

  for i = 1, #notes do
    local n = notes[i]
    local s = mapPPQ(n.startPos)
    local e = mapPPQ(n.endPos)
    if e <= s then e = s + 1 end
    reaper.MIDI_InsertNote(dstTake, false, n.muted, s, e, n.chan, n.pitch,
                           n.vel, true)
  end

  -- Inserted with sorting deferred, so each new CC lands at the end of the
  -- event list and its index is known: that is how the curve shape is
  -- reattached to the right event.  Counted from whatever the take already
  -- holds, so this stays correct with CLEAR_TARGETS off.
  local _, _, ccIndex = reaper.MIDI_CountEvts(dstTake)
  for i = 1, #ccs do
    local c = ccs[i]
    reaper.MIDI_InsertCC(dstTake, false, c.muted, mapPPQ(c.ppqpos), c.chanmsg,
                         c.chan, c.msg2, c.msg3, true)
    reaper.MIDI_SetCCShape(dstTake, ccIndex, c.shape, c.tension, true)
    ccIndex = ccIndex + 1
  end

  for i = 1, #sysex do
    local e = sysex[i]
    reaper.MIDI_InsertTextSysexEvt(dstTake, false, e.muted, mapPPQ(e.ppqpos),
                                   e.evtType, e.msg)
  end

  reaper.MIDI_Sort(dstTake)
end

-- The whole run, top to bottom.  Returns the name for the undo point, or nil
-- plus a message to show when it bailed out without changing anything.
local function run()
  local editor = reaper.MIDIEditor_GetActive()
  if not editor then
    return fail("No MIDI editor is open.\n\nRun this from the MIDI editor, " ..
                "with the notes you want to orchestrate selected.")
  end

  local srcTake = reaper.MIDIEditor_GetTake(editor)
  if not srcTake or not reaper.TakeIsMIDI(srcTake) then
    return fail("The MIDI editor has no active MIDI take.")
  end

  local srcItem = reaper.GetMediaItemTake_Item(srcTake)
  local srcTrack = reaper.GetMediaItemTake_Track(srcTake)
  local srcTrackNum = math.floor(
    reaper.GetMediaTrackInfo_Value(srcTrack, "IP_TRACKNUMBER"))
  local srcPos = reaper.GetMediaItemInfo_Value(srcItem, "D_POSITION")
  local srcLen = reaper.GetMediaItemInfo_Value(srcItem, "D_LENGTH")

  local music, keyswitches = readSelectedNotes(srcTake)
  if #music == 0 then
    return fail("No notes are selected.\n\nSelect the notes you want to " ..
                "orchestrate, then run this again.")
  end

  local tol = CONFIG.ONSET_TOLERANCE_QN * ppqPerQN(srcTake)
  local assigned, slotCount = M.assignSlots(music, {
    tol         = tol,
    maxSlots    = CONFIG.MAX_TARGET_TRACKS,
    divisiOrder = CONFIG.DIVISI_ORDER,
  })

  -- Validate every destination before touching any of them, so a missing item
  -- halfway down cannot leave the orchestration half written.
  local trackCount = reaper.CountTracks(0)
  if srcTrackNum + slotCount > trackCount then
    return fail(string.format(
      "This selection needs %d tracks below the source track, but only %d " ..
      "track(s) exist below track %d.\n\nAdd the missing tracks (each with a " ..
      "MIDI item lined up with the source item) and run this again.",
      slotCount, trackCount - srcTrackNum, srcTrackNum))
  end

  local targets = {}
  local problems = {}
  for slot = 1, slotCount do
    local track = reaper.GetTrack(0, srcTrackNum + slot - 1)
    local take, reason = findTargetTake(track, srcPos, srcLen)
    if take then
      targets[slot] = take
    else
      local _, name = reaper.GetTrackName(track)
      problems[#problems + 1] = string.format(
        "  Track %d (%s): %s", srcTrackNum + slot, name, reason)
    end
  end

  if #problems > 0 then
    return fail("Nothing was changed. These target tracks are not ready:\n\n" ..
                table.concat(problems, "\n") ..
                "\n\nEach target track needs a MIDI item at the same position " ..
                "as the source item.")
  end

  -- Bucket the notes by slot, adding the keyswitches to every part.
  local buckets = {}
  for slot = 1, slotCount do
    buckets[slot] = {}
    for i = 1, #keyswitches do
      buckets[slot][#buckets[slot] + 1] = keyswitches[i]
    end
  end
  for i = 1, #assigned do
    local n = assigned[i]
    local slot = n.slot
    if slot >= 1 and slot <= slotCount then
      buckets[slot][#buckets[slot] + 1] = n
    end
  end

  local ccs = readCCs(srcTake)
  local sysex = readTextSysex(srcTake)

  for slot = 1, slotCount do
    writeToTake(srcTake, targets[slot], buckets[slot], ccs, sysex)
  end

  return string.format("%s (%d part%s)", SCRIPT_TITLE, slotCount,
                       slotCount == 1 and "" or "s")
end

-- Everything the script does happens inside one undo block, so a single
-- Ctrl/Cmd+Z puts the project back exactly as it was before the run.  REAPER
-- drops a block that changed nothing, so the bail-outs cost no undo history.
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

-- Only run when hosted by REAPER; loading this file as a plain Lua module
-- yields the pure core for testing.
if reaper and reaper.MIDIEditor_GetActive then
  main()
end

return M
