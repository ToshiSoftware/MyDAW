# MyDAW Project Analysis (v1.5)

> Version covered: **1.5** (source as of 2026-09-28)
> Japanese edition: [PROJECT_ANALYSIS_jp.md](PROJECT_ANALYSIS_jp.md)
> Type- and function-level details: [SOURCE_SPECIFICATION_en.md](SOURCE_SPECIFICATION_en.md)

This document explains the MyDAW system as a whole: structure, signal paths, threading, persistence, design decisions and known limitations. It is meant for a developer reading the source for the first time, so they can find where things live and why they are built the way they are.

---

## 1. Overview

MyDAW is a multitrack audio recording, editing and mixing DAW for Apple Silicon Macs. The UI is SwiftUI and audio processing is AVAudioEngine; only VST3 hosting is written in C++ (Steinberg VST3 SDK).

| Item | Details |
| --- | --- |
| Platform | macOS 13 or later / Apple Silicon |
| Languages | Swift (UI, engine), C++17 / Objective-C++ (VST3 bridge) |
| Audio stack | AVAudioEngine, Core Audio HAL, AUAudioUnit (v3 subclasses) |
| Recording format | 24-bit Linear PCM WAV, 44.1 / 48 kHz, mono / stereo |
| Plug-ins | Audio Unit effects, VST3 effects (VST3s that also exist as an AU are hidden) |
| Code size | ~11,000 lines of Swift / ~900 lines of C++ (`Sources/` and `VST3Host/`) |
| Build | `./scripts/build.sh` (builds the VST3 bridge with CMake and links it with `swiftc`) |

### 1.1 Main features

- **Recording**: per-track input channel assignment (mono/stereo), 24-bit WAV written directly to disk, sample-accurate placement.
- **Punch in/out**: records only inside the punch range on the ruler. The whole pass is kept on disk and the take is trimmed to the range on stop (leaving handles).
- **Input monitoring**: the track's `I` button routes live input through the track's inserts, fader and sends (the recording stays dry).
- **Clip editing**: move (also across tracks), left/right trim, gain, linear fades, split, duplicate, delete, mute, undo/redo, beat snap.
- **Overlap layering**: when clips overlap, the most recently added clip wins; boundaries get equal-power crossfades.
- **Mixer**: Studio One-style three-section strips (INSERT / SEND / controls), dB faders (up to +6 dB), stereo peak meters, pan, M/S, direct numeric entry.
- **Effects**: AU/VST3 on tracks, FX channels and master. Sends are post-insert and post-pan. Plug-in latency compensation.
- **Other**: BPM / bars-and-beats ruler, metronome, master export (24-bit WAV), project save/load, WAV import, track colours.

---

## 2. Directory and module layout

```
MyDAW/
├── Sources/                    Swift sources (the app)
│   ├── MyDAWApp.swift          @main, menus, termination, VST3 scan child mode
│   ├── Models/                 Domain model, state, persistence
│   │   ├── ProjectState.swift      Facade between UI and engine
│   │   ├── AudioTrack.swift        Track (+ MixerGain, ChannelMode)
│   │   ├── AudioClip.swift         Clip (timeline placement and file range)
│   │   ├── ClipLayering.swift      Overlap / crossfade maths (pure functions)
│   │   ├── FXChannel.swift         FX channel and FXSend
│   │   ├── ProjectDocument.swift   .mydaw JSON DTOs
│   │   ├── StereoPeak.swift        L/R peak value
│   │   └── WaveformCache.swift     Waveform peak cache
│   ├── Audio/                  Audio engine, devices, plug-ins
│   │   ├── AudioEngineManager.swift  AVAudioEngine graph, playback, recording, meters
│   │   ├── AudioDiskWriter.swift     Asynchronous WAV writer
│   │   ├── AudioDeviceManager.swift  Core Audio HAL (devices, channels, buffer size)
│   │   ├── PluginManager.swift       AU / VST3 discovery (VST3 via child process + cache)
│   │   ├── VST3AudioUnit.swift       In-app AUv3 wrapping a VST3
│   │   ├── InputMonitorAudioUnit.swift In-app AUv3 that picks input channels
│   │   ├── VST3NativeInstance.swift  Swift wrapper around the C++ VST3 instance
│   │   ├── VST3HostBridge.swift      Swift wrapper around the VST3 enumeration API
│   │   ├── VST3Host.swift            VST3 host abstraction (protocols)
│   │   └── GenericAUParameterView.swift  Generic AU parameter UI
│   └── Views/                  SwiftUI screens
│       ├── MainDAWView.swift         Root view, startup log, export dialog, key handling
│       ├── ProjectSelectionView.swift Project chooser at launch
│       ├── TransportBarView.swift    Transport, view scaling, audio settings
│       ├── ArrangerView.swift        Timeline, ruler, punch range
│       ├── TrackHeaderView.swift     Track header, colour palette
│       ├── WaveformLaneView.swift    Waveform lane, clip gestures, overlap shading
│       ├── WaveformCanvas.swift      Waveform drawing (SwiftUI Canvas)
│       ├── MixerView.swift           Mixer (three-section strips)
│       ├── MixerControls.swift       Fader, pan, meter, dB scale
│       └── WindowCloseHandler.swift  Save prompt when the window closes
├── VST3Host/                   C++ VST3 host bridge (static library via CMake)
├── ThirdParty/vst3sdk/         Steinberg VST3 SDK
├── scripts/build.sh, run.sh    Build / launch scripts (the supported build path)
├── docs/                       This document, source specification, manual sources
└── snapshots/                  Manual source snapshots taken around each change
```

> **Note**: `./scripts/build.sh` and `MyDAW.xcodeproj` both produce the same app. The Xcode target runs the "Build VST3 Bridge" script phase (CMake), links the bridge and SDK static libraries through `OTHER_LDFLAGS`, then runs "Strip Extended Attributes" (`xattr -cr`) before signing. Both use arm64 only, ad-hoc signing and no hardened runtime. `Package.swift` is not kept in sync.

---

## 3. Architecture

### 3.1 Layers

```mermaid
flowchart TD
    subgraph UI["SwiftUI Views"]
        Main["MainDAWView"] --> Transport["TransportBarView"]
        Main --> Arranger["ArrangerView"]
        Main --> Mixer["MixerView"]
        Arranger --> Header["TrackHeaderView"]
        Arranger --> Lane["WaveformLaneView"]
    end
    UI --> State["ProjectState<br/>@MainActor facade"]
    State --> Models["AudioTrack / AudioClip / FXChannel"]
    State --> Doc["ProjectDocument<br/>.mydaw JSON"]
    State --> Engine["AudioEngineManager"]
    State --> Device["AudioDeviceManager"]
    State --> PM["PluginManager"]
    Engine --> AVE["AVAudioEngine"]
    Engine --> Writer["AudioDiskWriter"]
    Engine --> VAU["VST3AudioUnit / InputMonitorAudioUnit"]
    VAU --> NI["VST3NativeInstance"]
    NI --> Bridge["C++ VST3 bridge<br/>VST3PluginInstance.cpp"]
    PM -. child process .-> Scan["MyDAW --scan-vst3"]
    Models --> Layer["ClipLayering"]
    Engine --> Layer
    Lane --> Layer
```

- **UI → ProjectState**: views call `ProjectState` methods; `ProjectState` updates the model and pushes changes to the engine (`AudioEngineManager.syncTracks` etc.).
- **ProjectState**: owns track/FX/master configuration, undo/redo, save/load, import and export.
- **AudioEngineManager**: the central class (~3,700 lines) for the AVAudioEngine node graph, playback scheduling, recording, meters and plug-in creation.
- **ClipLayering**: overlap maths extracted as pure functions so playback and drawing use exactly the same calculation.

### 3.2 Audio signal paths

#### Track

```
Per-clip AVAudioPlayerNode (one node per clip)
 + InputMonitorAudioUnit (only when R and I are on)
      │
      ▼
Track output mixer (fader volume)
      │
      ▼
Inserts (AU / VST3AudioUnit, in insert order)
      │
      ▼
Pan mixer (applies pan)
      │
      ▼
Splitter mixer (★ meter point: post-insert, post-fader, post-pan)
      ├──► mainMixer ──► MASTER
      └──► Send gain mixers ──► FX channel inputs
```

#### FX channel

```
FX input mixer (FX volume) → inserts → pan mixer → FX output mixer (★ meter) → mainMixer
```

#### Master

```
mainMixer → master volume mixer → master plug-ins (POST) → meter mixer (★ meter) → output device
```

#### Input (recording)

```
inputNode (all device input channels)
  ├──► input tap → channel extraction → AudioDiskWriter (WAV, dry)
  └──► InputMonitorAudioUnit (per track, when I is on) → track output mixer
```

### 3.3 VST3 hosting

VST3s are inserted into the AVAudioEngine graph as in-app AUv3 units.

1. **Discovery**: `PluginManager` runs `MyDAW --scan-vst3 <path>` as a child process per bundle and reads class info back as JSON. Results are cached with modification dates in `~/Library/Application Support/MyDAW/vst3-scan-cache.json`. The main process does not load VST3 binaries during discovery.
2. **Duplicate filtering**: VST3s whose name matches an installed AU are hidden (loading a vendor's AU and VST3 builds into one process makes them collide).
3. **Creation**: `VST3NativeInstance` (C++ `MyDAWVST3Create`) loads the module and initialises component and controller.
4. **Processing**: the `internalRenderBlock` of `VST3AudioUnit` (an `AUAudioUnit` subclass) calls `MyDAWVST3ProcessStereo` directly on the audio thread. It sits in the same chain as AUs, in insert order.
5. **Parameters**: an `IComponentHandler` receives the GUI's `performEdit` calls and delivers them to the processor as `inputParameterChanges` on the next block.
6. **State**: saved and restored with `getState` / `setState`; on restore the controller also gets `setComponentState`.
7. **Shutdown**: on quit, editors are detached and all instances destroyed so each module's `bundleExit` runs.

### 3.4 Threading model

| Thread | Work | Synchronisation |
| --- | --- | --- |
| Main (@MainActor) | UI, `ProjectState`, public `AudioEngineManager` API, graph changes | — |
| Audio render thread | AVAudioEngine rendering, `VST3AudioUnit` / `InputMonitorAudioUnit` render blocks | Lock-free (preallocated buffers); a `std::mutex` inside the VST3 bridge only (uncontended) |
| Input tap thread | `processInputAudioBuffer` (peaks, recording extraction) | `captureLock`, `recordingTimingLock`, `peakLock` |
| Writer queue | `AudioDiskWriter` WAV writes | Serial `DispatchQueue` |
| Meter timer (30 Hz) | Peak collection, notifications, punch state | `peakLock` |
| Child process | VST3 scan | stdout (JSON) |

### 3.5 Persistence

- A project is a **folder**: `MySong/MySong.mydaw` + `MySong/Recordings/*.wav`.
- `.mydaw` is JSON (`ProjectDocument` version 4). Audio is referenced by relative WAV paths, never embedded.
- AU state is stored as a binary plist of `fullStateForDocument`; VST3 state is the `getState` byte stream with `format: "vst3-state"`.
- New fields (e.g. `isInputMonitoring`) are decoded with `decodeIfPresent`, so older files still load.
- UI preferences such as mixer section heights live in `UserDefaults` (app-wide).

---

## 4. Key flows

### 4.1 Starting playback

1. `startPlayOrRecord` waits until the plug-in graph is ready (`isPluginGraphReady`).
2. A shared start time (now + 50 ms, as host time) is chosen.
3. For each track, `scheduleClips`:
   - splits every clip with `ClipLayering.segments` into plain / hidden / shaped pieces;
   - plain pieces are streamed with `scheduleSegment`, shaped pieces are rendered with gain, fades and crossfades and scheduled with `scheduleBuffer`, hidden pieces are not scheduled;
   - times are explicit sample times so adjacent pieces join seamlessly;
   - everything is scheduled early by the track's plug-in latency.
4. Only clip nodes that received audio are started with `play(at:)`, which keeps transport start fast.
5. The metronome and playhead timer start at the same shared time.

### 4.2 Recording

1. Record button → an `AudioDiskWriter` and a new clip per armed track.
2. For every input tap buffer (~100 ms), the timeline position of each sample is derived from the buffer's host time; audio captured before the transport started is trimmed sample-accurately before writing.
3. While recording, the armed track's existing clips are muted (only inside the range when punching).
4. Stop → writers are finalised and clip metadata loaded. Punch takes are trimmed to the range and get 10 ms fades.
5. Clip position = start position − recording compensation (I/O latency + buffer + manual offset + master plug-in latency).

### 4.3 Clip overlaps (ClipLayering)

- Later entries in a track's clip array are higher layers.
- Where an upper clip plays, lower clips are silent. Across the upper clip's fade-in/out, the lower clip gets the complementary curve, i.e. a crossfade.
- A fade that crosses lower-clip audio is equal-power (sin/cos); a fade against silence stays linear.
- Fade handles of a lower clip are hidden at edges covered by an upper clip.
- Everything is derived from positions each time, so moving or deleting the upper clip restores the lower one.

### 4.4 Mixer changes

- Fader, pan and send changes go through `updateMixerLevels` / `setSend` straight to the mixer nodes.
- After a volume change the mixer is `reset()` so its volume ramp completes immediately (a stopped input does not advance the ramp and would otherwise leak the old level on its next note).
- Solo and mute are implemented through the track output mixer volume.

---

## 5. Design decisions and lessons learned

AVAudioEngine and plug-in pitfalls found while building v1.4–1.5, and how they were solved. Keep these in mind when changing the engine.

| Symptom | Cause | Fix |
| --- | --- | --- |
| VST3 track ~400 ms late when starting mid-song | Buffers scheduled with `at: nil` that arrive after the start time stay late; lock contention with many `play(at:)` calls on the main thread | Schedule every chunk with explicit times; later VST3 moved to real-time in-app AUv3 processing |
| Rare crash at launch (-10865) | Reconnecting an AU whose render resources are allocated with a different format | `connectReformatting` deallocates render resources first |
| Crashes when AU and VST3 of the same vendor coexist | Shared ObjC classes / support libraries between the two builds | VST3 scanning in a child process; VST3s with an AU twin are hidden |
| VST3 GUI changes not heard | No `IComponentHandler`, so no `inputParameterChanges` | Implement the handler and pass changes every block |
| Input stops when input monitoring is on | A one-to-many connect made while running ignores the format and leaves a 44.1 kHz mixer; the input then refuses 513-frame cycles | Rewire fan-out only with the engine stopped (deferred to stop while playing) |
| Muted/soloed-out track leaks for an instant | A mixer volume ramp does not advance on silent inputs | `reset()` the mixer after volume changes |
| Recordings land ~100 ms late | The pre-start part of the first tap buffer was written as-is | Trim sample-accurately using the buffer's host time |
| Pan ignored by meters and on tracks with inserts | AVAudioMixing pan only applies on connections into a mixer | Dedicated pan mixer after the inserts |
| Guitar Rig 7 crashes on quit | `exit()` ran without the VST3 module's `bundleExit` | Destroy VST3 instances on shutdown |

---

## 6. Known limitations

- **Build**: `Package.swift` is out of date; use `./scripts/build.sh` or `MyDAW.xcodeproj`.
- **VST3 sample rate**: a VST3 instance runs at the rate it was created with. Changing the device sample rate with a project open needs the plug-in to be re-inserted.
- **Shaped pieces of mismatched-rate audio**: for audio at a rate different from the device (normally rejected on import), shaped and plain pieces are converted separately, which can leave a tiny step at the join.
- **Relab LX480**: multiple custom AU GUIs can hang; with several instances the Generic UI is used.
- **VST3 instruments**: not supported (effects only).
- **Input monitoring latency**: depends on buffer size (about 25–30 ms round trip at 48 kHz / 512 frames). Use 128–256 for guitar. Using the interface's direct monitoring at the same time makes the signal sound doubled.
- **Graph changes while playing**: inserting, removing and reordering plug-ins is only allowed while stopped.

---

## 7. Improvement candidates

### High priority
1. Update or remove `Package.swift` (the Xcode project was updated in v1.5).
2. Recreate VST3 instances when the device sample rate changes.
3. Automated tests, starting with pure logic (`ClipLayering`, dB conversion, recording trim).

### Medium priority
1. Split `AudioEngineManager` (~3,700 lines) into graph building, playback scheduling, recording and metering types.
2. More robust saving (atomic writes, autosave).
3. Multiple clip selection, track reordering.
4. Unify conversion of shaped pieces to remove joins in mismatched-rate audio.

### Low priority
1. MIDI and instruments.
2. Automation.
3. Out-of-process plug-in hosting (resilience against collisions and crashes).

---

## 8. Development and verification practice

- Sources are snapshotted to `snapshots/<name>-<timestamp>/` before and after changes (Git is not used).
- Build with `./scripts/build.sh`. When building inside Google Drive, the script strips extended attributes before code signing.
- Runtime logging: stdout is buffered, so file-based diagnostics are the most reliable; `NSLog` output may not be readable from the system log.
- For audio timing problems, do not fix by guesswork: measure with shared-clock timestamps or dump the graph first, then fix.
