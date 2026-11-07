# MyDAW V4.0 MIDI Development Plan

Created: 2026-11-03　Target version: **V4.0**　UI model: a conventional DAW piano roll

## 1. Features

### 1.1 In the first release (V4.0)

| Area | Features |
|---|---|
| Tracks | Instrument track (a new track kind). Mixer, inserts, sends, folders and M/S work as on audio tracks |
| Instruments | Finding, choosing and replacing AU instruments (`aumu`), the plug-in's own GUI (Generic UI when it has none), instrument state saved in the project |
| MIDI clips | Shown in the arranger (miniature notes); move, copy, split, trim, delete, mute, undo |
| Piano roll | Keyboard, note grid, ruler, tools (arrow, pencil, eraser, mute, listen), audition notes, range and multiple selection, copy/paste, transpose with the up/down keys, zoom |
| Note editing | Add, delete, move, resize; default velocity; input length (1/16 etc., straight/triplet); snap |
| Adjustments | Quantize (grid, strength, start/end), length (fixed, legato), velocity (fixed, scale, offset), transpose |
| Velocity editing | Velocity lane at the bottom (drag bars, draw a line across many), note colour by velocity |
| Real-time input | Monitoring a MIDI keyboard on the armed track, recording (with count-in/rollback and punch), overdub/replace |
| SMF import | Format 0/1. One instrument track per SMF track. Option to adopt the file's first tempo |

### 1.2 Deferred

- VST3 instruments (no VST-only instrument to test with; to be discussed when we get there)
- Multi-output instruments (a drum instrument's separate outputs, for example). The first release uses the main stereo output only
- Editing lanes for CC, pitch bend and aftertouch (these events are still saved and played) → pitch bend, modulation (CC1) and aftertouch added 2026-11-04 (progress log)
- Tempo changes, SMF export, freeze/bounce, step input, drum editor, MIDI effects (`aumf`)

## 2. Design points

1. **Note times are kept in beats (ticks, 960 PPQ).** Unlike audio clips (seconds), they stay on the bar grid when the tempo changes.
2. **Where the instrument sits**: the instrument AU takes the place of the audio track's TrackRenderer at the head of the track; the rest of the chain (fader → inserts → pan → split) is reused.
3. **Scheduling**: just before the instrument renders, the events in that buffer are sent with `scheduleMIDIEventBlock` at sample offsets. The render side reads only a playback plan built on the main thread.
4. **Latency compensation**: events are sent early by "the track's insert latency + D", as clips are, plus the instrument's own latency.
5. **Stop and locate**: send All Notes Off and sustain off. On play start, send the sustain, pitch bend and program in effect at that position first (chase).
6. **MIDI input**: CoreMIDI receives all sources together (one keyboard). Recording converts host times to timeline beats and corrects for the monitoring latency.
7. **File format v6**: adds the track kind, MIDI clips and instrument state. Opening a v6 project in v3.1 drops instrument tracks (documented as a known limit).
8. **Other meters (3/4, 5/4, ...)**: done (2026-11-07). One per project, 1–16 over 4 or 8, BPM stays in quarter notes. Set in the transport bar's METER field and saved in the project. Notes are kept in beats (ticks), so changing the meter does not move them. Everything bar-related goes through `MusicalMeter`. No meter changes during a song.
9. **Known pitfalls**: AU v2 default bus rate (set formats before allocating), connections while running may be deferred (replace instruments only while stopped), heavy instruments (large drum libraries) load with a progress display without blocking the UI, and the plug-in window stacking order also applies to instrument GUIs.

## 3. Test instruments

| Use | Instrument | Format | Notes |
|---|---|---|---|
| Drums | multi-output drum AU | AU | Slow to load. Has multiple outputs (main output only at first) |
| Bass | bass AU | AU | |
| Piano | piano AU | AU | The AU name ends in "(0->2)" (probably 0 inputs / 2 outputs, the stereo version) |

One MIDI keyboard.

## 4. Stages

| Stage | Contents | How to check | Estimate | Status |
|---|---|---|---|---|
| 1. Foundation | Track kind, MIDI clip and note model, file format v6, finding AU instruments | Save/load round trip | 2 days | Done |
| 2. Instrument + keyboard monitoring | Creating the track, choosing the instrument, GUI, saving state, MIDI thru | Play the bass AU from the keyboard; sound restored after reopening | 3 days | Done |
| 3. SMF import + playback | SMF reading, scheduling, latency compensation, stop/locate, chase | Play a drum SMF on the drum AU; offset against the metronome; export | 3–4 days | Done |
| 4. Arranger | Showing and editing MIDI clips, undo | Sound after move/split/copy | 2–3 days | Done |
| 5. MIDI recording | Record, overdub, replace, count-in/punch | Record the piano AU and measure timing | 3 days | Done |
| 6. Piano roll | Editor, tools, note editing, audition, inspector | Edit recorded data | 5–6 days | Done |
| 7. Adjustments + velocity | Quantize, length, velocity, transpose; velocity lane | All three instruments | 3 days | Done |
| 8. Finishing | UI strings (en/ja), manual, analysis and specification docs, PDFs, snapshots | — | 2 days | Documented (version not yet raised to 4.0) |

Each stage is checked with `build/MyDAW.app` built by `scripts/build.sh`. After stages 3, 5 and 6, the work is squashed into one "UpdateN for V4.0" commit and pushed.

## 5. Progress log

- 2026-11-07: Time signatures (item 8). Confirmed by the user.
- 2026-11-05: piano roll for drum instruments: rows grouped by drum, ↑↓ changes the way of striking.
- 2026-11-05: Added buses and an output destination menu to the mixer. Para-out channels go to their parent's fader.
- 2026-11-05: Instrument outputs (para-out) implemented. A button on the mixer's instrument row gives each output its own channel. Project format v7.
- 2026-11-04: At the user's request the piano roll's velocity lane became tabs (Velocity / Pitch Bend / Modulation [CC1] / Aftertouch [channel pressure]). Events are dots joined by lines, with a fainter line holding the last value to the clip's end. Pencil: click or drag to draw (replaces the lane's events over the dragged span, one every 3 pt), Option-drag for a straight line. Eraser: removes the dots clicked or dragged over. Arrow: drag a dot to change its value. Pitch bend snaps to the centre (0) near it. New events take the channel of the lane's existing events, else the notes'. Undo and playback follow as for note edits. Build 3.1.20261104.1545.
- 2026-11-04: Arranger-style horizontal scroll bars added to the mixer and the piano roll (the standard scroller hides until scrolled, and a mouse's vertical wheel does not scroll sideways). Fixed MIDI clip boxes lagging behind a horizontal zoom of the tracks (they did not observe the zoom directly).

- 2026-11-03: Documentation updated and committed as "Update5 for V4.0" (not pushed): chapter 12 "MIDI and instruments" added to both manuals with later chapters and figures renumbered, chapter 1, the main window, shortcuts, troubleshooting and glossary updated, PDFs regenerated; MIDI added to PROJECT_ANALYSIS, SOURCE_SPECIFICATION and the READMEs (both languages). The version label (3.1) changes when the version is raised to 4.0.
- 2026-11-03: Quantize button reads "Qtz" at twice the width. Inspector rearranged as the user laid out (Default Values [velocity, note length = grid] / Note Length Adjustment [fixed length, remove overlaps] / Velocity Adjustment / Transpose / Octave Shift / Swing Adjustment, with dividers and bold headings; buttons as large as the pull-downs). Build 3.1.20261103.1538.
- 2026-11-03: [-12][+12] back in place under an "Octave Shift" caption. Swing added (user's spec: velocity -a to +b and start -a to +b (a bar = 128) changed at random per note, length kept, then overlaps removed; notes stay within the clip's current range; one undo step). Cmd-A and Select All Notes take only notes inside the clip (trimmed-off ones are left out). Build 3.1.20261103.1504.
- 2026-11-03: Remove Overlaps checked. Velocity, transpose and default velocity values are typed in (Return confirms; out-of-range values go to the nearest end, non-numbers revert; steppers removed). [-12][+12] line up under [Apply] (build 3.1.20261103.1450).
- 2026-11-03: At the user's decision legato was dropped for "Remove Overlaps" (build 3.1.20261103.1439): among the selected notes, a note overlapping the next one of the same pitch and channel ends where that one starts; of notes of one pitch starting together (any number) the longest is kept and the others deleted.
- 2026-11-03: Legato changed to the behaviour agreed with the user (build 3.1.20261103.1428): each selected note ends where the next later note of the clip starts, lengthened when that is after its end and shortened when before it (overlap). Notes starting within a 32nd of the note count as its chord and are skipped. A note with none after it stays.
- 2026-11-03: Stage 7 adjustments implemented (build 3.1.20261103.1359). At the user's request quantize and the adjustments act on the selected notes only (nothing without a selection). Inspector section "Adjust Selected Notes": fixed length (1/1 to 1/32, straight/triplet), legato (to the next note to start, any pitch; notes starting together count as one step; the last stays; no gap setting), velocity fixed / scale (1–400 %) / offset (±127), transpose (±48 and ±12). Results are kept within 1–127; transpose moves only as far as all notes can go. The inspector scrolls.
- 2026-11-03: Quantize checked. Added: the note name and velocity shown beside the pointer over a note (drawn by the piano roll), 1/1 and 1/2 in Length (build 3.1.20261103.1355).
- 2026-11-03: Stage 7 quantize implemented (build 3.1.20261103.1345): [Q] (also the Q key) and [|<-][->|][|<-|] in the toolbar; acts on the selected notes (all when none is selected) with the inspector's Length as the grid, moving to the nearest line; with start and end both on, both ends move; a note whose end would reach its start keeps one grid step.
- 2026-11-03: Stage 6 checked and committed as "Update4 for V4.0" (not pushed). The user specified stage 7's quantize: [Q] runs it; modes [|<-] start, [->|] end, [|<-|] start keeping the length; start and end toggle separately and exclude [|<-|].
- 2026-11-03: Right-clicking an empty spot in the piano roll showed the mixer's Add FX (the bottom panel's SwiftUI menu) → that menu now only on the mixer, and the piano roll has its own (Mute Notes / Unmute Notes / Cut / Copy / Paste at Playhead / Delete Notes / Select All Notes). The mute tool was removed at the user's request.
- 2026-11-03: At the user's request the listen tool is gone; the toolbar's speaker button turns note audition on/off (only when on do notes sound as they are clicked, moved up/down, added or transposed). The inspector's Audition Notes checkbox was removed. The keyboard always sounds (build 3.1.20261103.1316).
- 2026-11-03: Fixed: clicking a note of a trimmed clip in the piano roll undid the trim. Widening the clip at the end of an edit counted the notes the trim hides; it now counts only notes the edit added or changed (build 3.1.20261103.1302).
- 2026-11-03: Fixes from the stage 6 check (build 3.1.20261103.1259): the pencil adds a note even on a note (overlap allowed); Option-drag in the velocity lane sets a straight line (drawn while dragging); edits while playing no longer stop every sounding note, only those the new content does not release (keyboard notes are not counted); the wheel on the ruler zooms in time; opening a clip fits it in view; "Follow the Track View" button (shows the arranger's span and follows its auto-scroll; a manual horizontal scroll or zoom turns it off).
- 2026-11-03: At the user's request, "Merge Clips" for MIDI clips (the selected clips of a track become one, holding what they play; a muted clip's notes become muted notes). Stage 6 implemented: "Mixer | Piano Roll" tabs in the bottom panel (the user's choice), opened by double-clicking a MIDI clip. `PianoRollController` (target clip, tool, grid, default velocity, selection, clipboard, audition; undo through the clip edit snapshots) and `PianoRollCanvas` (AppKit; keyboard, ruler, notes and velocity lane in one view; wheel scrolls, Cmd-wheel zooms time, Option-wheel zooms rows). Tools: arrow (select, Shift adds, rubber band, move, Option copies, edges resize, double-click adds), pencil (adds and drags the length; click on a note deletes it), eraser, mute, listen. Up/down transpose (Shift: octave), Delete, Cmd-A/C/X/V (paste at the playhead). Velocity set by dragging a line across the bars; notes coloured by velocity. Build 3.1.20261103.1234.
- 2026-11-03: Stage 5 checked (recording, timing against the metronome, overdub/replace, punch, rollback, recording with audio, undo). Committed as "Update3 for V4.0" (not pushed).
- 2026-11-03: Stage 5 implemented. The keyboard is recorded on armed instrument tracks (also together with audio). CoreMIDI arrival times are turned into positions by the transport clock and moved earlier by the output latency (outputNode.presentationLatency) and the master plug-in latency. Clips run from the bar of the start (punch in) to the bar after the last note, and notes are drawn growing while recording. Punch range and rollback are followed (keys outside the range are dropped; a note pressed inside keeps its release). Overdub/replace switch in the transport (replace removes older notes in the recorded range). Build 3.1.20261103.1128.
- 2026-11-03: Stage 4 checked (move, Option-copy, moving between tracks, trim, split, mute, duplicate, delete, copy/paste, undo/redo).
- 2026-11-03: Two fixes from the second stage 4 check: a clip dragged over an audio track jumped back → it now follows the pointer (landing on instrument tracks only); Duplicate placed copies right after the clip → at the playhead, as for audio clips.
- 2026-11-03: Three fixes from the stage 4 check (build 3.1.20261103.1108): a clip dragged to a lower track was cut off → drawn above all lanes, as audio clips are; no resize pointer at the edges → the same HoverCursor as audio clips; no right-click menu → the lane's right-click handler (LaneMenuMonitor) takes the click first, so the MIDI clip commands were added to the lane menu.
- 2026-11-03: Stage 4 implemented (`ProjectState+MIDIClips.swift`: click to select MIDI clips, Shift adds; drag to move on the beat grid, Option copies, up/down moves to other instrument tracks; trim both edges; right-click Mute, Duplicate, Split at Cursor, Delete; Delete key, Select All, copy/cut/paste at the playhead; undo snapshots now include MIDI clips with their notes). Build 3.1.20261103.1011. Not covered: editing MIDI clips through a time range (Cmd-drag), undoing an SMF import.
- 2026-11-03: Stage 3 checked; stages 1-3 committed as "Update1 for V4.0" (not pushed).
- 2026-11-03: The export's default end now includes MIDI clips. At the user's request, the export dialog starts with the punch range while P is on (manual and analysis updated, PDFs regenerated). Build 3.1.20261103.1003.
- 2026-11-03: Stage 3 implemented (`StandardMIDIFile.swift`: SMF 0/1 reading, File > Import MIDI File… and dropping on a lane, asking whether to adopt the tempo; `MIDIPlaybackPlan`: clips laid out in timeline frames and sent at sample offsets just before the instrument renders, started/re-anchored/stopped with the same anchor as TrackRenderer, sounding notes and sustain released on stop, program/CC/pitch bend chased at the start; instrument latency added to the track latency; instrument row in the mixer; read-only MIDI clip display). Build 3.1.20261103.0944. An offline test showed notes starting at their scheduled frame (within a few samples, apart from the instrument attack).
- 2026-11-03: Stage 2 checked (adding and switching the bass, piano and drum AUs, keyboard playing, loading display, sound restored).
- 2026-11-03: Switching to a third-party piano AU crashed: its plug-in shell crashes when given a nil contextName. MyDAW no longer sets nil and names instruments after their track (build 3.1.20261103.0910).
- 2026-11-03: Stage 2 implemented (`InstrumentHost.swift`: CoreMIDI input from all sources, a queue that hands MIDI to the instrument just before it renders; adding instrument tracks, choosing the instrument, GUI, saved state, keyboard thru to armed instrument tracks; audio recording, WAV import and clip move/paste stay on audio tracks). Build 3.1.20261103.0856. Instrument slot in the mixer and instrument latency compensation come with stage 3.
- 2026-11-03: Stage 1 checked (existing project saves and reopens unchanged; 16 AU instruments found, including the three test instruments).
- 2026-11-03: Stage 1 implemented (`MIDIClip.swift`: ticks, notes, events, `MusicalMeter`; track kind; file format v6; AU instrument scan). Build 3.1.20261103.0841.
- 2026-11-03: Added the plan to prepare for other meters (implementation in the next step).
- 2026-11-03: Plan settled (V4.0, one keyboard, the piano as AU). Stage 1 started.
