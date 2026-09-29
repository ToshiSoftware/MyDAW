# MyDAW Source Code Specification (v1.6)

> Version covered: **1.6** / Japanese edition: [SOURCE_SPECIFICATION_jp.md](SOURCE_SPECIFICATION_jp.md)
> System structure, signal paths and design decisions: [PROJECT_ANALYSIS_en.md](PROJECT_ANALYSIS_en.md)

For every file under `Sources/` and `VST3Host/`, this document describes responsibilities, types, the contracts of the main properties and methods, threading assumptions and side effects. Private methods are listed only where they are needed to follow the processing flow.

---

## 0. Conventions

- **@MainActor**: `ProjectState`, `AudioEngineManager`, `AudioTrack`, `AudioClip`, `FXChannel` and all views run on the main thread.
- **Real-time (RT)**: code running on the audio render thread. It avoids memory allocation, blocking locks and Objective-C messaging.
- **Volume**: stored as linear gain (1.0 = 0 dB). The maximum is `MixerGain.maximum` (+6 dB ≈ 1.995).
- **Pan**: -1.0 (left) to +1.0 (right).
- **GUI strings**: the English text is the key; `Resources/{en,ja}.lproj/Localizable.strings` supply what is shown. SwiftUI literals are localised automatically; strings in variables or passed to AppKit are wrapped in `String(localized:)`.
- **Time**: timeline seconds (`Double`). Playback scheduling uses AVAudioTime (host time or sample time).

---

## 1. Application

### `Sources/MyDAWApp.swift`

#### `MyDAWApp: App` (`@main`)
- **`init()`**: first calls `PluginManager.runVST3ScanChildIfRequested()`. If launched with `--scan-vst3 <path>`, the process enumerates that VST3, writes JSON to stdout and exits (child-process mode). Otherwise it requests microphone permission.
- **`body`**: a `WindowGroup` with `MainDAWView`, plus menus:
  - About (shows the version; falls back to `1.6` without Info.plist)
  - File: New Project… (⌘N), Open Project… (⌘O), Save Project… (⌘S), Export Master Mix…
  - Edit: Undo Clip Edit (⌘Z), Redo Clip Edit (⇧⌘Z / ⌘Y)
- **`requestAudioPermissions()`**: calls the microphone permission API appropriate for the OS version.

#### `MyDAWApplicationDelegate: NSApplicationDelegate`
- Keeps the app running when the last window closes.
- **`applicationWillTerminate`**: calls `shutdownAudioEngine`, which runs `AudioEngineManager.shutdown()` (required to release VST3 modules correctly and to restore the macOS default input/output devices).

---

## 2. Models (`Sources/Models`)

### `AudioTrack.swift`

#### `MixerGain`
Gain constants shared by all faders and sends: `unity = 1.0`, `maximum = 10^(6/20)` (+6 dB).

#### `ChannelMode: String, Codable, CaseIterable`
`.mono` (1 ch) / `.stereo` (2 ch); exposes `channelCount`.

#### `AudioTrack: ObservableObject` (@MainActor)
| Property | Meaning |
| --- | --- |
| `id`, `name`, `color` | Identifier, display name, track colour |
| `channelMode`, `inputChannelIndex` | Recorded channel count and first input channel (0-based) |
| `isRecordArmed`, `isInputMonitoring` | Record arm (R), input monitoring (I) |
| `isMuted`, `isSoloed`, `volume`, `pan` | Mixer values |
| `trackHeight` | Lane height (at least 120 pt) |
| `clips` | Clip array. **Array order is layer order** (later = higher) |
| `selectedClipIDs` | Selected clips (a set). `selectedClipId` is a compatibility computed property: it returns the first selected clip, and setting it selects only that clip |
| `plugins`, `fxSends` | Inserts and FX sends |
| `currentInputPeak`, `currentOutputPeak`, `outputStereoPeak` | Meter values |

- When `clips` changes, each clip's `objectWillChange` is relayed to the track (so lower clips redraw their overlap shading).
- **`addClip(startTime:fileURL:)`**, **`moveClip(id:to:)`**, **`deleteClip(id:removeFile:)`** (deletes the file only if no other clip uses it), **`duplicateClip(id:)`** (placed right after), **`splitClip(id:at:)`** (rejects pieces shorter than 20 ms), **`removeClipForTransfer(id:)`**, **`restoreClip(_:)`**, **`insertClip(_:below:)`** (inserts directly below the given clip in layer order), **`replaceClips(_:)`** (keeps the selection only for clips that remain).
- **Range edits**: **`clipPieces(from:to:)`** (copies of the audio in a range), **`removeAudio(from:to:)`** (removes the range, cutting clips that straddle it), **`cropAudio(from:to:)`** (keeps only the range), **`splitAudio(at:)`** (splits at the given times). All rebuild the clip list in layer order and return true when something changed.
- **`insertPlugin(_:)` / `removePlugin(id:)` / `movePlugin(id:before:)`**: edit inserts.

### `AudioClip.swift`

#### `AudioClip: ObservableObject` (@MainActor)
A non-destructive clip holding the timeline placement (`startTime`, `duration`) and the playback range inside the WAV (`sourceStartTime`).
- Further attributes: `gainDB` (-24…+24), `isMuted`, `fadeInDuration` / `fadeOutDuration`, `fadeInCurve` / `fadeOutCurve` (`FadeCurve`, default `.auto`), `sampleRate`, `originalDuration` (file length), `waveformCache`.
- **`loadMetadata()`**: reads sample rate and length from the file and starts asynchronous peak loading; `duration` is clamped to what is available.
- **`setTrim(startTime:sourceStartTime:duration:)`**: minimum 0.02 s.
- **`setFadeInDuration` / `setFadeOutDuration`**: clamped to 0…`duration`.
- **`duplicate(at:)`**: a copy referencing the same file (fades and curves included).
- **`piece(from:to:)`**: returns the part of the clip within a timeline range as a new clip (nil if shorter than 20 ms). Fades and curves are kept only on edges shared with the original.

### `ClipLayering.swift`

Pure functions for clip overlaps and fade curves, shared by playback (`AudioEngineManager.scheduleClips`) and drawing (`WaveformLaneView`, `WaveformCanvas`).

#### `FadeCurve: Codable, Equatable` (new in v1.6)
| Case | Meaning |
| --- | --- |
| `.auto` | Equal power where the fade crosses lower-clip audio, linear against silence (made concrete by `resolved(crossfade:)`) |
| `.equalPower` | A quarter sine wave (steady perceived level across a crossfade) |
| `.bend(midpoint:)` | Power curve r^p through level m (0.05–0.95) at the midpoint (p = log m / log 0.5); `linear` is m = 0.5 |

`value(_:)` (progress r → gain), `midpointGain`, `withMidpoint(_:)` (snaps to equal power and linear near -3 dB and -6 dB), `title` (name for the tooltip).

#### `ClipLayerSpan`
`id`, `start`, `end`, `fadeIn`, `fadeOut`, `isMuted`, `fadeInCurve`, `fadeOutCurve` of one clip (listed in layer order).

#### `ClipLayering`
| API | Meaning |
| --- | --- |
| `spans(for: [AudioClip])` | Builds spans from clips (`end` uses the actually playable length) |
| `gain(_:clip:at:)` | Final envelope of the clip at time t = own fades × product of upper clips' pass-through |
| `segments(_:clip:)` | Splits a clip into `.plain` (untouched) / `.hidden` (fully covered) / `.shaped` (needs an envelope) pieces |
| `isEdgeCovered(_:clip:atStart:)` | Whether the clip's edge lies under an upper clip (locks that fade handle) |
| `resolvedCurve(_:clip:atStart:)` | The fade curve with `.auto` made concrete, for drawing |
| `envelope(_:clip:)` | Function from seconds after the clip start to final gain, or nil when there are no fades or overlaps (used for waveform amplitude) |

- Pass-through of an upper clip for fade progress r: the upper fade's curve mirrored in time, `curve(1 − r)` (`cos(πr/2)` for equal power, `1 − r` for linear).
- Fade shape: given by `FadeCurve`; `.auto` is equal power if lower-clip audio exists within that fade, linear otherwise.
- Muted clips do not cover others.

### `FXChannel.swift`

#### `FXChannel: ObservableObject`
`id`, `name` (default "FX n"), `volume`, `pan`, `plugins`, `color`, `currentOutputPeak`, `outputStereoPeak`; `insertPlugin` / `removePlugin` / `movePlugin`.

#### `FXSend: Codable`
`id`, `fxChannelID`, `level` (linear gain), `enabled`.

### `StereoPeak.swift`
L/R peak values. `init(buffer:)` computes each channel's maximum absolute sample (mono reports the same value on both sides). `merged(with:)`, `falling(to:by:)` (instant attack, exponential release; values below -100 dB become 0 so an idle meter stops changing), `maximum`.

### `WaveformCache.swift`
- Keeps `PeakPoint` (min/max) arrays, combined (`peaks`) and per channel (`channelPeaks`); 512 samples per peak by default.
- **`loadPeaks(from:)`**: reads the file in `Task.detached` and publishes on the main thread.
- **`appendLivePeaks` / `appendLiveChannelPeaks`**: live waveform while recording.

### `ProjectDocument.swift` (`.mydaw` JSON)
| Type | Main contents |
| --- | --- |
| `ProjectDocument` | `version` (currently 4), zoom, scroll, playhead, BPM, metronome, master volume, display scales, tracks, FX, master plug-ins, plug-in states, punch range |
| `TrackDocument` | Name, channels, input, R/M/S, **I (`isInputMonitoring`)**, volume, pan, height, colour, clips, plug-ins, sends |
| `ClipDocument` | ID, start, source offset, duration, original duration, gain, mute, fades, fade curves (`fadeInCurve` / `fadeOutCurve`, `.auto` if unreadable), file path (relative to the project) |
| `FXChannelDocument` | FX name, volume, pan, colour, plug-ins |
| `PluginStateDocument` | `pluginID`, `stateData`, `format` (plist for AU, `"vst3-state"` for VST3) |
| `PunchRangeDocument` | `startBeat`, `endBeat`, `enabled` |
| `ColorDocument` | RGBA |

Every decoder uses `decodeIfPresent` with defaults, so files from older versions load.

### `ProjectState.swift`

`ProjectState: ObservableObject` (@MainActor) is the facade between UI and engine.

- **Published state**: `tracks`, `fxChannels`, `masterPlugins`, `selectedTrackId`, `pixelsPerSecond` (20–400), `timelineScrollTime`, `punchRange`, `showsBeats`, `snapToGrid` (stored in UserDefaults), `waveformVerticalScale` (1–32), `trackHeightScale` (0.5–3), `timeSelection` (range selection), `marqueeRect` (marquee while dragging), `clipboard`, export dialog state, startup log, `pluginManager`, `audioEngine`, `deviceManager`.
- **Initialisation**: applies devices and buffer size to the engine, subscribes to peak notifications, creates two default tracks, starts plug-in discovery.
- **Tracks**: `addTrack`, `deleteTrack`, `toggleRecordArm`, `toggleInputMonitoring`, `toggleMute`, `toggleSolo`, `setInputRouting(for:channelMode:inputChannelIndex:)` (syncs the engine immediately).
- **Clips**: `selectClip` (selects only that clip and clears the range selection), `moveClip` (across tracks), `deleteSelectedClip` (deletes inside the range selection if there is one, otherwise every selected clip) / `deleteClip`, `toggleClipMute`, `duplicateClip`, `splitSelectedClip` / `splitClip`, drag preview (`beginClipDragPreview` etc.). Selection, ranges, clipboard and group moves live in `ProjectState+Editing.swift`.
- **Undo/redo**: `beginClipEdit()` takes a snapshot (clip position, range, gain, mute, fades and curves, file, and each track's selection); `endClipEdit()` pushes it unless the clips are unchanged (for example after just clicking a handle). `undo()` / `redo()` do nothing while playing or recording.
- **Punch**: `setPunchRange`, `setPunchStartBeat`, `setPunchEndBeat`, `setPunchEnabled`.
- **Plug-ins**: tracks `insertPlugin(_:into:)` / `removePlugin(_:from:)` / `movePlugin(_:before:on:)` / `togglePlugin(_:on:)`; FX `…intoFX:` / `…fromFX:` / `…onFX:`; master `insertMasterPlugin` / `removeMasterPlugin` / `moveMasterPlugin` / `toggleMasterPlugin`; `openPluginUI`.
- **FX**: `addFXChannel()`, `renameFXChannel(id:to:)` (ignores empty names), `removeFXChannel(id:)`, `setSend(trackID:fxChannelID:level:)`.
- **Files**: `createNewProject`, `loadProject`, `saveProject`, `saveProjectAndShowConfirmation`, `importAudioFile(_:intoTrackId:)` (copies 24-bit integer PCM at the current rate as is; otherwise converts it with `ClipAudioProcessing.writeConverted` into `Recordings/`), `locateClipFile` (matching sample rate only).
- **Restart**: `promptRestartForAudioSettings()` (after a device, sample-rate or language change, asks Save and Restart / Restart Without Saving / Cancel), `relaunch()` (a `/bin/sh` waits for this process to exit, then `open -n` relaunches with the project as an argument).
- **Export**: `beginMasterExportDialog`, `exportMasterMix(startTime:endTime:)`, `cancelMasterExport`.
- **View**: `zoomIn`, `zoomOut`, `setPixelsPerSecond(_:)` (keeps the playhead in place), `setPixelsPerSecond(_:anchorOffset:)` (keeps the pointer position in place; for wheel and pinch), `snappedTimelineTime` (one beat).

### `AppLanguage.swift` (new in v1.6)
The GUI language (`english = "en"` / `japanese = "ja"`). `displayName` is written in the language itself (English / 日本語). `current` is the language the running app loaded (`Bundle.main.preferredLocalizations`). `select(_:)` stores it as the app's `AppleLanguages` default, used from the next launch. Unset, the macOS preferred languages decide (English if neither matches).

### `ProjectState+Editing.swift` (new in v1.6)

An extension of `ProjectState` that gathers selection and editing operations.

| Type / API | Purpose |
| --- | --- |
| `TimeSelection` | Range selection (`start`, `end`, `trackIDs` top to bottom) |
| `ClipboardClip` | Values of a copied clip (file, source offset, duration, gain, mute, fades and curves, time/track offsets from the top-left of the copied block) |
| `hasSelection`, `canPaste` | Enable state for the delete button and menus |
| `toggleClipSelection`, `selectAllClips`, `clearSelection` | Clip selection |
| `trackTopY(for:)`, `trackID(atTimelineY:)` | Track geometry in the `timelineScroll` coordinate space |
| `beginMarquee(at:additive:)`, `updateMarquee(from:to:)`, `endMarquee()` | Marquee selection: selects every clip the rectangle touches (additive keeps the existing selection) |
| `beginTimeSelection`, `updateTimeSelection`, `endTimeSelection` | Range selection (times snap to beats; tracks form a contiguous block) |
| `deleteTimeSelection`, `cropToTimeSelection`, `splitAtTimeSelection` | Range edits (one undo step each) |
| `deleteSelectedClips` | Deletes all selected clips |
| `copySelection`, `cutSelection`, `paste()` | Clipboard. Paste is relative to the playhead and the selected track (tracks beyond the last fold onto it) |
| `normalizeClips`, `reverseClips` | Act on the right-clicked clip, or the whole selection if it is part of one. Normalize sets the gain that brings the whole file's peak to 0 dBFS; Reverse writes `Reverse_*.wav`, switches the clip to it and swaps the fades |
| `beginGroupDrag`, `updateGroupDrag(delta:)`, `endGroupDrag(trackDelta:)` | Moves the selected clips together (never before zero; across tracks only when every clip has a destination) |
| `duplicateSelectedClipsInPlace` | At the start of an option-drag, leaves copies at the original positions (directly below each original) |

---

## 3. Audio, devices and plug-ins (`Sources/Audio`)

### `AudioEngineManager.swift`

The central class (@MainActor, `NSWindowDelegate`) for the AVAudioEngine graph, playback, recording, metronome, meters, plug-in creation and GUIs, and export.

#### Published state (excerpt)
`engine`, `isPlaying`, `isRecording`, `isPunchRecording`, `currentTime`, `bpm`, metronome (enabled, timing offset, volume), `hardwareSampleRate`, `masterVolume`, `masterPeak`, `masterStereoPeak` (both updated only when they change), `recordingsDirectory`, `inputBufferFrameSize`, `manualRecordingCompensationMs`, selected input/output devices.

#### Node layout (per track)
| Dictionary | Role |
| --- | --- |
| `playerNodes` | Spare per-track player (normally unused) |
| `clipPlayerNodes` | One `AVAudioPlayerNode` per clip |
| `trackOutputNodes` | Track output mixer (fader volume, solo, mute) |
| `trackPluginNodes` | Inserts (AU / `VST3AudioUnit`) |
| `trackPanNodes` | Pan mixer (after the inserts) |
| `trackSplitterNodes` | Splitter mixer (one-to-many into mainMixer and sends; meter point) |
| `sendGainNodes` | Per-send gain mixer |
| `inputMonitorNodes` | `InputMonitorAudioUnit` (when I is on) |
| `fxInputNodes` / `fxPluginNodes` / `fxPanNodes` / `fxOutputNodes` | FX channel input, inserts, pan and output (meter) |
| `masterOutputNode` / `masterPluginNodes` / `masterMeterNode` | Master volume, POST plug-ins, final meter |

#### Main public methods
- **Graph sync**: `syncTracks(_:fxChannels:)` (incremental update of tracks, FX, master, sends and input monitoring), `syncTracks(_:fxChannels:masterPlugins:)`, `syncMasterPlugins`, `syncAfterClipEdit` (reschedules while playing), `updateMixerLevels` (volume, pan, sends, FX), `updateSendLevel`, `setClipMuted`, `setPluginEnabled`.
- **Transport**: `startPlayOrRecord(tracks:fxChannels:recordArmedTracks:)` (starts playback/recording, or stops if running), `stop(tracks:)`, `rewind`, `seek(to:)`, `setPunchRange`.
- **Devices**: `applyAudioDevices(inputDeviceID:outputDeviceID:sampleRate:)` (sets the device sample rate and calls `bindIODevice` when the devices change), `applyInputBufferFrameSize`, `applyAutomaticTimingCompensation`.
- **Plug-ins**: `openPluginUI(pluginID:)`, `isPluginUnavailable`, `capturePluginStates`, `setSavedPluginStates`, `prepareForPluginGraphRestore`.
- **Other**: `exportMasterMix(to:startTime:endTime:tracks:fxChannels:)` (renders the master path in real time to 24-bit WAV), `shutdown()` (stops the engine, releases VST3, restores the macOS default input/output devices), recordings folder helpers.

#### Main internals
| Method | Purpose |
| --- | --- |
| `setupEngine()` | Reads the input format, builds the master path and final meter, click, input tap, input monitors, raises slice limits, starts the engine |
| `bindIODevice(inputDeviceID:outputDeviceID:)` | Makes the chosen devices the macOS default input and output (AVAudioEngine with input runs on an aggregate of the defaults). Records the original defaults the first time; `restoreOriginalDefaultDevices()` puts them back in `shutdown()` |
| `startMeterTimer` | Collects peaks at 30 Hz and posts them. `masterPeak` / `masterStereoPeak` are assigned only on change (values below -100 dB become 0) |
| `wireSend` | Connects a send's gain mixer to an FX input. `wiredSendTargets` remembers the target so it is rewired only when it changes (rewiring every sync throws `mixingDest` while input monitoring is on) |
| `applyDeferredRewiresWhenQuiet` | On stop, performs the deferred fan-out rewiring and input monitor connection once the master output is below -60 dB (at most 8 s). While waiting, `isWaitingForQuietRewire` is set and `syncTracks` leaves the rewiring to it. Gives up if the transport starts, retrying on the next stop |
| Stop-time recording finalisation (task in `stop`) | Finalises writers and loads the clips; calls `syncTracks` only when files were recorded |
| `installAudioUnits` / `installFXAudioUnits` / `installMasterAudioUnits` | Creates plug-ins asynchronously and chains them in insert order; for VST3 creates a `VST3AudioUnit` and binds the instance |
| `connectTrackChainTail` | Wires chain end → pan → splitter → mainMixer + sends. One-to-many connections are made **only with the engine stopped** (deferred via `pendingSplitterRewires` while playing) |
| `connectReformatting` | If an AU at either end has allocated render resources and the format changes, releases them before connecting (avoids the -10865 exception) |
| `setMixerVolume` | `reset()`s the mixer after a volume change (a silent input does not advance the ramp) |
| `scheduleClips` | Following `ClipLayering.segments`: plain → `scheduleSegment`, shaped → `makeClipPlaybackBuffer` (envelope applied) → `scheduleBuffer`, hidden → not scheduled; sample-time scheduling and plug-in latency compensation |
| `startPlayback` | Schedules all tracks, then `play(at:)` only on nodes with audio |
| `processInputAudioBuffer` | Input tap: peaks, sample-accurate trim via host time, per-track channel extraction and writing |
| `startRecording` / `stop` | Writer creation, muting the recording tracks' clips, whole-pass punch recording → `trimToPunchRange` on stop (adds 10 ms fades) |
| `updatePunchRecordingState` | 30 Hz timer: detects entering/leaving the punch range and mutes existing clips only inside it |
| `applyInputMonitoringIfNeeded` / `connectInputMonitors` | Connects inputNode → `InputMonitorAudioUnit` → track output according to I buttons (engine stopped) |
| `raiseMaximumFramesPerSlice` | Raises the I/O units' slice limit to 4096 (propagates to every node) |
| `releaseVST3Instances` | On quit: closes editors, detaches wrappers, destroys VST3 instances |
| Plug-in GUI helpers | `requestOriginalPluginUI`, `presentPluginViewController` (window matches the view size and follows later resizes), `presentGenericPluginView`, `openVST3PluginUI` |

#### Threads and locks
`captureLock` (recording config, writers), `recordingTimingLock` (start time), `peakLock` (peaks). The tap and timers exchange values with the main thread through these.

### `ClipAudioProcessing.swift` (new in v1.6)
Offline processing of the file range a clip plays (runs synchronously on the main thread).
- **`peakAmplitude(of:sourceStartTime:duration:)`**: largest absolute sample over all channels (for Normalize).
- **`writeReversed(from:sourceStartTime:duration:to:)`**: reads the range from its end in 65,536-frame chunks, reverses each chunk and writes a 32-bit float WAV.
- **`is24BitPCM(_:sampleRate:)`**: whether a file is 24-bit integer PCM at the given rate (decides whether an import needs converting).
- **`writeConverted(from:to:sampleRate:)`**: converts the whole file with AVAudioConverter (maximum sample-rate converter quality) to a 24-bit integer WAV at the given rate, keeping the channel count.

### `VST3AudioUnit.swift`
In-app AUv3 (`aufx`/`vst3`/`MyDW`) that places a VST3 instance in the AVAudioEngine graph.
- **`registration`**: runs `AUAudioUnit.registerSubclass` once.
- **`attach(_:)` / `detachInstance()`**: bind/unbind the `VST3NativeInstance` (engine stopped only).
- **`shouldBypassEffect`**: mirrored into the kernel's bypass flag.
- **`latency`**: VST3 `latencySamples` in seconds (used for track latency compensation).
- **`internalRenderBlock`** (RT): pulls input into preallocated buffers, provides output buffers that never alias the input and calls `processStereo`. If called twice for the same sample time it replays the previous result (the plug-in state must not advance twice). Passes input through on failure or bypass.

### `InputMonitorAudioUnit.swift`
In-app AUv3 (`aufx`/`inmn`/`MyDW`) that extracts a track's input channel(s) from the multichannel input (mono is duplicated to L/R). `configure(channelOffset:isStereo:)` is set while stopped; the input bus is sized to the device's channel count.

### `VST3NativeInstance.swift`
Swift wrapper holding the C++ bridge handle (`@unchecked Sendable`).
- **`init?(descriptor:sampleRate:maxFrames:)`**: loads the module and initialises the component.
- **`processStereo(...)`** (RT): processes in blocks of at most `maxFrames`.
- **`captureState()` / `restoreState(_:)`**, **`attachEditor(to:)`** (registers the `resizeView` callback), **`currentEditorSize()`**, **`removeEditor()`**, `latencySamples`.
- **deinit**: detaches the editor and calls `MyDAWVST3Destroy`.

### `PluginManager.swift`
- **`TrackPluginDescriptor`**: ID, name, kind (AU/VST3), bundle path, VST3 UID, AU component description, enabled flag, UI compatibility.
- **`discoverAvailablePlugins(onLog:completion:)`**: discovers AUs (`AudioComponentFindNext`) and VST3s in the background. **VST3s with a same-named AU are excluded.**
- **VST3 discovery**: `scanVST3Bundle` → checks the cache (path + modification date) → otherwise `runScanChild` (`MyDAW --scan-vst3 <path>`, 60 s timeout; a crashed scan caches an empty result).
- **`runVST3ScanChildIfRequested()`**: the child side (enumerates and prints JSON prefixed with `MYDAW_VST3_SCAN_RESULT:`).

### `VST3HostBridge.swift` / `VST3Host.swift`
`VST3HostBridge.enumerate(bundleURL:)` calls C++ `MyDAWVST3EnumerateAudioEffects` and returns UID, name, vendor and version (used only in the child process). `VST3Host.swift` holds host-abstraction protocols and an unavailable implementation.

### `AudioDeviceManager.swift`
Reads and sets input/output devices, input channels (mono/stereo choices), sample rate and buffer size through the Core Audio HAL. Selected devices are stored by UID in UserDefaults. The engine is actually pointed at them by `AudioEngineManager.bindIODevice` (switching the macOS defaults).

### `AudioDiskWriter.swift`
Copies recording buffers and writes them to 24-bit WAV on a serial queue. File names: `Rec_<track>_<6-char ID>_<ch>ch_<rate>_24bit_<timestamp>.wav`. `finalize()` completes the file and returns its URL.

### `GenericAUParameterView.swift`
Generic UI that builds sliders from an AU's parameter tree (used when there is no usable custom GUI).

---

## 4. Views (`Sources/Views`)

### `MainDAWView.swift`
Stacks the transport, arranger, mixer and status bar. Contains the startup log (plug-in discovery progress; removed from the view hierarchy once done), the master export dialog, the close-window confirmation and key handling (`SpacebarHandler`: ⌘Z / ⇧⌘Z / ⌘Y, ← to rewind, ⌘X / ⌘C / ⌘V / ⌘A as `EditCommand`s, Esc clears the selection and is passed on; nothing is handled while typing in a text field).
- **`refreshToolTips()`**: when a project opens or the startup log goes away, widens the main window by 1 pt and back so tooltip areas are re-registered (SwiftUI does not do so when only an overlay disappears).

### `ProjectSelectionView.swift`
Launch screen: New Project (choose a folder) and Open Project (⌘O); shows the version.

### `TransportBarView.swift`
- Buttons: Undo, Redo, Rewind, Play/Pause (Space), Record (records armed tracks), P (enable punch), Delete, Save, Open, Metronome, Settings, Snap. Tooltips use the standard `.help`.
- Displays: TIME (time or bars/beats), TEMPO (BPM entry 20–400), FORMAT (24-bit WAV and sample rate); the panel is as wide as its contents.
- The bar is left-aligned; when the window is narrower, the right end is cut off (`frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)` plus `clipped()`).
- Right side: timeline zoom, track height scale, waveform vertical scale, ruler toggle, master volume.
- **`BufferSettingsView`** (gear, titled “Settings”): recordings folder, language (`AppLanguage`), input/output device, sample rate (44.1–96 kHz), recording delay compensation, click timing offset, click volume, buffer size. When a language, device or sample-rate change is applied it calls `onAudioDevicesChanged` to offer a restart.

### `ArrangerView.swift`
Track headers and lanes, the ruler (seconds or bars/beats; click to seek), playhead, punch range (drag the left/right handles on the ruler in beat steps), Add Track button, auto-scroll, Delete key, and drawing of the marquee rectangle and range-selection band.
- **`ArrangerWheelMonitor`**: a local event monitor for scroll-wheel and pinch events over the whole arranger (ruler included). A wheel over the ruler and a pinch zoom horizontally around the pointer; ⌥+wheel sets track height; ⌥⇧+wheel sets waveform height (also when shift turns the wheel into horizontal scrolling). Handled events are not passed to the scroll views.

### `TrackHeaderView.swift`
Colour bar on the left (click for `TrackColorPalette`: 16 presets + custom), name (double-click to edit), mono/stereo toggle (1/2), delete, R / M / S / I, input channel menu, meter (input while armed, output otherwise), drag the bottom edge to change height.

### `WaveformLaneView.swift`
One track lane.
- **Lane**: dragging over empty space draws a marquee (⌘ for a range selection); a click clears the selection; right-click opens the edit menu; WAV files can be dropped from Finder.
- **`AudioClipView`**: click (⇧/⌘ to add or remove), drag to move the selected clips together (⌥ to duplicate, ⌘ for a range selection), left/right trim, gain (top centre), fade in/out (top-left / top-right), fade curve (the diamond in the middle of a fade line; vertical drag via `FadeCurve.withMidpoint`, double-click for `.auto`). Gain, fade and curve handles start dragging on mouse-down and show their value in an `EditValueTooltip`.
- **Context menu**: Cut / Copy / Paste at Playhead, and with a range selected Delete Range / Crop to Range / Split at Range Edges (`EditMenuItems`); Normalize, Reverse, choose file, mute, duplicate, split, delete.
- **Display**: waveforms are drawn at the `ClipLayering.envelope` level; only parts fully hidden by upper clips are darkened. Fade handles at covered edges are hidden.

### `WaveformCanvas.swift`
Draws `WaveformCache` peaks with SwiftUI `Canvas` (per channel, gain scaling, amplitude from `envelope`).
- **`FadeLinesOverlay`**: draws the fade-in / fade-out lines across the clip's full height in the shape of their curves (one line even for stereo).

### `MixerView.swift`
Studio One-style mixer.
- **Overall**: drag the top edge to resize (320–1000 pt), horizontally scrolling track/FX strips, MASTER pinned on the right, right-click for Add FX.
- **`StripSections`**: INSERT / SEND / controls sections (headings via `SectionHeader`, localised through `LocalizedStringKey`) with draggable dividers (shared by all strips, stored in UserDefaults).
- **`TrackStripView`**: INSERT (+ menu, green dot on/off, click name for GUI, drag to reorder, × to remove), SEND (level bar and dB value per FX), pan, M/S, fader value, scale / fader / stereo meter, name (click to select).
- **`FXStripView`**: INSERT, (an empty SEND section kept only for alignment), pan, remove FX, fader, name (double-click to rename).
- **`MasterStripView`**: POST plug-ins, fader, stereo meter.
- **`MixerLevelMeter`**: horizontal meter used in track headers (Logic Pro-like scale).

### `MixerControls.swift`
| Type | Purpose |
| --- | --- |
| `MixerScale` | dB⇔gain conversion, the piecewise-linear taper shared by faders and meters (0 dB at 84%, +6 dB at the top), display strings (`-3.5`, `0dB`, `-∞`, `<C>`, `L56`) and input parsing |
| `EditableValueText` | Value that becomes a text field on double-click (Return commits, Esc cancels) |
| `VolumeFader` | Vertical fader: relative drag, ⌘ for fine control, ⌥-click resets to 0 dB |
| `FaderScale` | dB tick labels (+6 … -72) |
| `StereoMeter` | L/R meter (colour changes at -12 / -6 dB, 1.5 s peak hold) |
| `PanControl` | Horizontal pan bar (⌥-click centres) |
| `SendLevelBar` | Horizontal send level on the dB taper (⌥-click → 0 dB) |

### `WindowCloseHandler.swift`
Asks Save / Don't Save / Cancel when the window closes and quits after a successful save or discard.

---

## 5. C++ VST3 bridge (`VST3Host/`)

CMake (`VST3Host/CMakeLists.txt`) builds the static library `MyDAWVST3Bridge`, which is linked into the Swift binary with `sdk_hosting` and friends.

| Function | Purpose |
| --- | --- |
| `MyDAWVST3EnumerateAudioEffects` | Loads a bundle and enumerates `kVstAudioEffectClass` classes |
| `MyDAWVST3Create` | Loads the module, initialises `PlugProvider`, registers `IComponentHandler`, sets stereo buses, `setupProcessing` / `setActive` / `setProcessing` |
| `MyDAWVST3ProcessStereo` | RT path: calls `process()` with non-interleaved in/out pointers and passes `inputParameterChanges` / `outputParameterChanges` every block |
| `MyDAWVST3ProcessInterleaved` | Interleaved variant (kept for the probe tool) |
| `MyDAWVST3GetState` / `SetState` | Save/restore component state (restore also calls the controller's `setComponentState`) |
| `MyDAWVST3AttachEditor` / `GetEditorSize` / `SetResizeCallback` / `RemoveEditor` | NSView editor attachment and size tracking |
| `MyDAWVST3GetLatencySamples` | Processing latency |
| `MyDAWVST3Destroy` | Stops processing, clears the handler, releases editor, component and module (module release runs `bundleExit`) |

`MyDAWVST3ComponentHandler`: collects the GUI's `performEdit` calls per parameter ID; the audio thread takes them with `try_lock` and fills `ParameterChanges` (it never waits).

---

## 6. Representative sequences

### 6.1 Inserting a plug-in on a track
1. `ProjectState.insertPlugin(_:into:)` → `AudioEngineManager.syncTracks`.
2. For VST3, `syncVST3Instances` creates the instance (restoring saved state if present).
3. Tracks whose chain signature changed are rebuilt: provisional tail connection → `installAudioUnits` creates the AU / `VST3AudioUnit` asynchronously → engine stopped → `connectReformatting` connects → next plug-in → `connectTrackChainTail` at the end.

### 6.2 Save / load
1. `saveProject` → `ProjectDocument` (plug-in states via `capturePluginStates`) → JSON write.
2. `loadProject(from:)` → DTOs restored → `AudioClip.loadMetadata` → `setSavedPluginStates` → `syncTracks` rebuilds the graph (AU state restored asynchronously, VST3 state when the instance is created).

### 6.3 Quit
`applicationWillTerminate` → `shutdown()` → engine stop → `releaseVST3Instances` (close editors → detach wrappers → destroy instances → `bundleExit`) → `restoreOriginalDefaultDevices` (puts the macOS default input/output back).

### 6.4 Device change and restart
1. Apply in `BufferSettingsView` → `AppLanguage.select` if the language changed; `AudioEngineManager.applyAudioDevices` (sample rate, `bindIODevice`) if a device or the sample rate changed → on success `AudioDeviceManager.setSelectedDeviceIDs`.
2. After the sheet closes, `ProjectState.promptRestartForAudioSettings` offers to save and restart.
3. `relaunch()` starts a waiting shell and calls `NSApp.terminate` → the default devices are restored on quit → the shell runs `open -n`, and `MainDAWView` in the new process opens the `.mydaw` passed as an argument → the new process switches the defaults again and builds its engine.
