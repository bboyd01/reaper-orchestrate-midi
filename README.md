# REAPER orchestration ReaScripts

Two REAPER ReaScripts for turning a polyphonic sketch played into an *ensemble*
patch into a proper divisi string section. Both are MIDI Editor actions, both
need only stock REAPER (no SWS functions are called, though they run fine
alongside SWS), and both are single self-contained files.

| Folder | Script | What it does |
|---|---|---|
| [`orchestrate/`](orchestrate/) | `Orchestrate_selected_notes_to_next_tracks.lua` | Distributes the selected notes by pitch across the MIDI items on the next tracks below the source. |
| [`legato/`](legato/) | `Orchestrate_and_legato_selected_notes_to_next_tracks.lua` | The same distribution, plus a legato offset: every note that continues a phrase is pulled earlier so it overlaps its predecessor, and its velocity is pushed to 127 to trigger a sample library's legato transitions. |

Pick one. The legato script is a superset of the orchestrator, so running both
on the same material would apply the distribution twice.

Each folder has its own README with install instructions, the configuration
table and the design notes, plus an offline test suite that runs in a plain Lua
interpreter without REAPER:

```sh
cd orchestrate && lua5.4 tests/test_voicing.lua
cd legato      && lua5.4 tests/test_legato.lua
```
