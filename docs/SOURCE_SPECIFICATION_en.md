# MyDAW Source Code Specification (v2.0)

> Version covered: **2.0** / Japanese edition: [SOURCE_SPECIFICATION_jp.md](SOURCE_SPECIFICATION_jp.md)
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
- **`init()`**: first raises the open-file limit with `raiseOpenFileLimit()` (RLIMIT_NOFILE soft value, 256 by default, up to 65,536 within `kern.maxfilesperproc` and the hard value): every clip keeps its WAV open for playback, and with hundreds of clips the limit was reached and AppKit crashed when it could not load menu resources. Then calls `PluginManager.runVST3ScanChildIfRequested()`. If launched with `--scan-vst3 <path>`, the process enumerates that VST3, writes JSON to stdout and exits (child-process mode). Otherwise it requests microphone permission.
- **`body`**: a `WindowGroup` with `MainDAWView`, plus menus. The window uses `.hiddenTitleBar` (a transparent title bar with the content running under it) and `.windowResizability(.contentMinSize)` (it cannot get smaller than its content's minimum). `.handlesExternalEvents(matching: [])` stops SwiftUI from opening another window for each file opened from the Finder.
- **Opening from the Finder**: Info.plist declares `.mydaw` (`com.tokada.mydaw.project`, conforming to `public.data` / `public.content`; with `public.json` the Finder shows the text as a thumbnail instead of the icon) in `CFBundleDocumentTypes` / `UTExportedTypeDeclarations`; `MyDAWApplicationDelegate.application(_:open:)` receives it (the last one when several). Until the window's `onAppear` sets `openProjectFile`, the file waits in `pendingProjectURL`; then `ProjectState.openProjectFile(_:)` is called. `build.sh` registers the build with LaunchServices (`lsregister -f`) after signing. The document icon is `DocumentIcon.icns`, drawn by `scripts/make-document-icon.swift` from `AppIcon.iconset`: a white page with a folded corner and the app icon, rounded, in the middle. Run it again whenever the app icon changes. Menus:
  - About (shows the version; falls back to `2.0` without Info.plist)
  - File: New Project… (⌘N), Open Project… (⌘O), Save Project… (⌘S), Save Project As… (⇧⌘S), separator, Export Master Mix…, separator, Move Unused Recordings to Unused Folder
  - Edit: Undo Clip Edit (⌘Z), Redo Clip Edit (⇧⌘Z / ⌘Y)
  - Help: MyDAW Help (⌘?). Opens `https://toshi.life.coocan.jp/note/OperationManual_{jp,en}.pdf` for `AppLanguage.current` with `NSWorkspace.open` (the system picks the app)
- **`requestAudioPermissions()`**: calls the microphone permission API appropriate for the OS version.

#### `MyDAWApplicationDelegate: NSApplicationDelegate`
- Keeps the app running when the last window closes.
- **`applicationShouldTerminate`**: calls `confirmQuit` (`ProjectState.confirmQuit()`); returns `.terminateCancel` when the user cancels or saving fails. Every quit path goes through it (the Quit menu, ⌘Q, closing the window); `relaunch()` has already asked, so it skips the question.
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
| `channelMode`, `inputChannelIndex` | Recorded channel count and first input channel (0-based). `channelMode` also sets playback: a mono track downmixes stereo clips (`MonoDownmixAudioUnit`); files are never rewritten |
| `isRecordArmed`, `isInputMonitoring` | Record arm (R), input monitoring (I) |
| `isMuted`, `isSoloed`, `volume`, `pan` | Mixer values |
| `trackHeight` | Lane height (standard 170 pt = `AudioTrack.defaultTrackHeight`; drawn × `trackHeightScale`) |
| `clips` | Clip array. **Array order is layer order** (later = higher) |
| `selectedClipIDs` | Selected clips (a set). `selectedClipId` is a compatibility computed property: it returns the first selected clip, and setting it selects only that clip |
| `plugins`, `fxSends` | Inserts and FX sends |
| `meter` (`TrackMeter`), `currentInputPeak`, `currentOutputPeak`, `outputStereoPeak` | Meter values. They live in a separate `TrackMeter` object (`update(inputPeak:outputPeak:)` publishes only on change) so the 30 Hz updates do not redraw every view observing the track (header, waveform lane, mixer). Only the meter subviews (`TrackHeaderMeter`, `TrackFaderColumn`) observe `meter`. The three properties are read-only |

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

Pure functions for clip overlaps and fade curves, shared by playback (`TrackRenderer`) and drawing (`WaveformLaneView`, `WaveformCanvas`). Gains evaluated per peak or per sample use `ClipLayering.Envelope`, which resolves the curves, picks the overlapping upper clips and splits the clip into pieces once, and answers 1 / 0 for plain / hidden stretches without work (same values as `gain(_:clip:at:)`). Looking everything up on each call made one redraw of a track with many faded clips cost over 100 ms.

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
`id`, `name` (default "FX n"), `volume`, `pan`, `isMuted`, `isSoloed`, `plugins`, `color`, `currentOutputPeak`, `outputStereoPeak`; `insertPlugin` / `removePlugin` / `movePlugin`.

#### `FXSend: Codable`
`id`, `fxChannelID`, `level` (linear gain), `enabled`.

### `StereoPeak.swift`
L/R peak values. `init(buffer:)` computes each channel's maximum absolute sample (mono reports the same value on both sides). `merged(with:)`, `falling(to:by:)` (instant attack, exponential release; values below -100 dB become 0 so an idle meter stops changing), `maximum`.

### `WaveformCache.swift`
- Keeps `PeakPoint` (min/max) arrays, combined (`peaks`) and per channel (`channelPeaks`); 512 samples per peak by default.
- **`loadPeaks(from:)`**: reads the file in `Task.detached` and publishes on the main thread. Peaks are shared per file (keyed by path, size, modification date and `samplesPerPeak`): a file already read is applied at once, and a cache asking while it is being read waits for that read, so split clips never read the same file again.
- **`appendLivePeaks` / `appendLiveChannelPeaks`**: live waveform while recording.

### `ProjectDocument.swift` (`.mydaw` JSON)
| Type | Main contents |
| --- | --- |
| `ProjectDocument` | `version` (currently 4), zoom, scroll, playhead, BPM, metronome, master volume, display scales, tracks, FX, master plug-ins, plug-in states, punch range |
| `TrackDocument` | Name, channels, input, R/M/S, **I (`isInputMonitoring`)**, volume, pan, height, colour, clips, plug-ins, sends |
| `ClipDocument` | ID, start, source offset, duration, original duration, gain, mute, fades, fade curves (`fadeInCurve` / `fadeOutCurve`, `.auto` if unreadable), file path (relative to the project) |
| `FXChannelDocument` | FX name, volume, pan, mute, solo, colour, plug-ins (mute / solo default to off in older projects) |
| `PluginStateDocument` | `pluginID`, `stateData`, `format` (plist for AU, `"vst3-state"` for VST3) |
| `PunchRangeDocument` | `startBeat`, `endBeat`, `enabled` |
| `SongRangeDocument` | Song start / end flags: optional `startBeat`, `endBeat` |
| `ProjectDocument.masterExportFileName` | File name last chosen for the master export (optional). The export panel opens in the project folder with this name, or `<project name>_Master_Mix.wav` |
| `ColorDocument` | RGBA |

Every decoder uses `decodeIfPresent` with defaults, so files from older versions load.

### `ProjectState.swift`

`ProjectState: ObservableObject` (@MainActor) is the facade between UI and engine.

- **Published state**: `tracks`, `fxChannels`, `masterPlugins`, `selectedTrackId`, `pixelsPerSecond` and `trackHeightScale` (held by a separate `timelineGeometry`, a `TimelineGeometry`: publishing every step of a zoom or height control from ProjectState redrew every view, the mixer included; only the timeline's views — `ArrangerView`, the ruler parts, `WaveformLaneView`, `AudioClipView`, `TrackHeaderView`, `TransportBarView` — observe it, as an environment object). `pixelsPerSecond` (5–800, `minimumPixelsPerSecond`/`maximumPixelsPerSecond`; the slider is logarithmic), `timelineScrollTime` (held by a separate `timelineScroll` object, `TimelineScrollPosition`: publishing every scroll step from ProjectState would redraw every track header and lane. Only the ruler shift (`TimelineScrollOffset`) and the scroll knob (`TimelineScrollSlider`) observe it; the track view is scrolled synchronously right after the change by `TimelineScrollPosition.onChange` (`followScrollTime`, registered by ArrangerView), so it moves in the same frame as the ruler), `punchRange`, `showsBeats`, `snapToGrid` (stored in UserDefaults), `autoScrollEnabled` (UserDefaults `MyDAW.autoScroll`), `waveformVerticalScale` (1–256, `maximumWaveformVerticalScale`; logarithmic slider; `WaveformCanvas` clamps peaks to the lane), `trackHeightScale` (`TrackHeaderView.minimumRowHeight` 56 pt ÷ 170 ≈ 0.33 to 3; the slider and ⌥+wheel go through `setTrackHeightScale`, which first returns every track's `trackHeight` to the standard value), `timeSelection` (range selection), `marqueeRect` (marquee while dragging), `clipboard`, export dialog state, startup log, `pluginManager`, `audioEngine`, `deviceManager`.
- **Initialisation**: applies devices and buffer size to the engine, subscribes to peak notifications, creates two default tracks, starts plug-in discovery.
- **Tracks**: `addTrack`, `deleteTrack` (the UI calls `confirmDeleteTrack`, which asks first), `moveTrack(id:to:)` (reordering; the arranger and the mixer follow the order of `tracks`; the graph is not rewired; a time selection is cleared), `toggleRecordArm`, `toggleInputMonitoring`, `toggleMute`, `toggleSolo`, `setInputRouting(for:channelMode:inputChannelIndex:)` (syncs the engine immediately).
- **Clips**: `selectClip` (selects only that clip and clears the range selection), `moveClip` (across tracks), `deleteSelectedClip` (deletes inside the range selection if there is one, otherwise every selected clip), `splitSelectedClip` / `splitClip`, drag preview (`ClipDragPreview`: the set of dragged clip IDs, the vertical travel and the track delta; `beginClipDragPreview()` / `updateClipDragPreview(verticalOffset:trackDelta:)` / `endClipDragPreview()`; the delta is 0 when some clip would have no destination). Selection, ranges, clipboard and group moves live in `ProjectState+Editing.swift`.
- **Undo/redo**: `beginClipEdit()` takes a snapshot (clip position, range, gain, mute, fades and curves, file, and each track's selection); `endClipEdit()` pushes it unless the clips are unchanged (for example after just clicking a handle). `undo()` / `redo()` do nothing while playing or recording.
- **Punch**: `setPunchRange`, `setPunchStartBeat`, `setPunchEndBeat`, `setPunchEnabled`.
- **Unused recordings**: `moveUnusedRecordings()` (File menu; `canMoveUnusedRecordings` = project open, stopped, no recording being finalised) first asks to save (Save Project and Continue / Cancel) and saves, then moves WAV files directly in Recordings that no clip or clipboard entry refers to into `Recordings/Unused` (numbered on a name clash) and lists them in an NSAlert. Clips of the other `.mydaw` files in the same folder (`clipPathsOfOtherProjects()` decodes their `ProjectDocument`) also count as in use; if one cannot be read, nothing is moved and an error is shown. If a moved file appears in an Undo / Redo snapshot, both stacks are cleared.
- **Song flags**: `songRange` (pushes `songEndTime` to the engine), `songStartTime` / `songEndTime` (seconds), `setSongStart(time:)` / `setSongEnd(time:)` (nil removes; kept at least `minimumSongLengthBeats` apart), `canPlaceSongStart(at:)` / `canPlaceSongEnd(at:)`. `toggleTransport(recordArmedTracks:)` passes the punch range and song end to the engine and starts or pauses (used by the play / record buttons and Space). `rewindToSongStart()` goes to the start flag, or to 0 when on or before it. The engine's `onReachSongEnd` calls `stop(tracks:)`.
- **Plug-ins**: tracks `insertPlugin(_:into:)` / `removePlugin(_:from:)` / `movePlugin(_:before:on:)` / `togglePlugin(_:on:)`; FX `…intoFX:` / `…fromFX:` / `…onFX:`; master `insertMasterPlugin` / `removeMasterPlugin` / `moveMasterPlugin` / `toggleMasterPlugin`; `openPluginUI`.
- **FX**: `addFXChannel()`, `renameFXChannel(id:to:)` (ignores empty names), `removeFXChannel(id:)` (the UI calls `confirmRemoveFXChannel(id:)`; the NSAlert makes Return and Esc cancel), `setSend(trackID:fxChannelID:level:)`.
- **Files**: `createNewProject` (an NSSavePanel for folder and name: `canCreateDirectories`, opened expanded, `.mydaw` type; creates the `.mydaw` and `Recordings/` in the chosen folder), `loadProject` (an NSOpenPanel for a `.mydaw` file; its parent becomes the project folder). Both panels start one level above the last project's folder (`projectPanelStartDirectory`). `openRecentProject(_:)` (checks the file exists, then `loadProject(from:projectFolderURL:)` with the file's folder), `saveProject` (a successful write calls `RecentProjects.noteSaved`; a successful `loadProject(from:)` calls `noteOpened`), `saveProjectAndShowConfirmation`, `openProjectFile(_:)` (from the Finder: brings the app to the front, does nothing if that file is already open, shows an error while playing or recording, and asks Save / Don't Save / Cancel when a project is open before `loadProject(from:projectFolderURL:)`), `saveProjectAs()` (asks only for a name in an NSAlert text field, saves to `<name>.mydaw` in the same folder and switches `currentProjectURL`; rejects empty names, a leading “.”, “/” and “:”, confirms replacing an existing file, restores the old URL on failure), `importAudioFile(_:intoTrackId:)` (copies 24-bit integer PCM at the current rate as is; otherwise converts it with `ClipAudioProcessing.writeConverted` into `Recordings/`), `locateClipFile` (matching sample rate only).
- **Restart**: `promptRestartForAudioSettings()` (after a device, sample-rate or language change, asks Save and Restart / Restart Without Saving / Cancel), `relaunch()` (a `/bin/sh` waits for this process to exit, then `open -n` relaunches with the project as an argument).
- **Export**: `beginMasterExportDialog`, `exportMasterMix(startTime:endTime:)`, `cancelMasterExport`.
- **View**: `zoomIn`, `zoomOut`, `setPixelsPerSecond(_:)` (keeps the playhead in place), `setPixelsPerSecond(_:anchorOffset:)` (keeps the pointer position in place; for wheel and pinch), `snappedTimelineTime` (one beat).

### `RecentProjects.swift` (new in v1.8)
- **`RecentProject: Codable, Identifiable`**: `path` (the `.mydaw` file, standardised; also the `id`), `lastSavedAt`; derived `url`, `name` (file name without extension), `exists`.
- **`RecentProjects: ObservableObject`** (`shared`): `entries`, most recent first, at most `maxCount` (50), stored as JSON in UserDefaults under `MyDAW.recentProjects`. `noteSaved(_:)` moves the project to the top with the current time; `noteOpened(_:)` moves it to the top with the file's modification date (the last save); `remove(_:)` drops one entry. Entries whose file is missing are kept (a Google Drive folder may be offline) and shown greyed out.

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
| `menuTargets`, `selectForMenu`, `splittableMenuTargets` | Right-click targets: the whole selection when the right-clicked clip is part of it, otherwise that clip (selected by `selectForMenu`). `splittableMenuTargets` keeps those the playhead is inside |
| `toggleMuteMenuTargets`, `duplicateMenuTargets`, `splitMenuTargets`, `deleteMenuTargets` | Commands on the right-click targets. Mute mutes all if any is unmuted, otherwise unmutes all; Duplicate copies them as a block whose start lands on the playhead and selects the copies; Split cuts those the playhead is inside and keeps both halves selected. Each is one undo step (except mute) |
| `normalizeClips`, `reverseClips` | Act on the right-clicked clip, or the whole selection if it is part of one. Normalize sets the gain that brings the whole file's peak to 0 dBFS; Reverse writes `Reverse_<track name>_NNN.wav` (`RecordingFileName`), switches the clip to it and swaps the fades |
| `stripSilenceClips` | Finds runs of silence (every channel's sample at or below the silence level) at least the chosen length with `silenceRanges`, makes a `piece(from:to:)` for each part to keep and swaps them in with `AudioTrack.replaceClip(id:with:)` (the silent parts are dropped). Each part with sound is widened into the silence by the fade length on the edges that border a silence, and those edges get the fade (10 ms by default, limited to half the minimum silence length so neighbouring pieces never overlap); edges shared with the original clip keep its fades. Pieces under 20 ms are dropped. The pieces become the selection. The settings are asked by `askStripSilenceSettings` (NSAlert) and kept in UserDefaults as `MyDAW.stripSilenceThresholdDB` (default −72 dB, −144 to 0), `MyDAW.stripSilenceMinimumDuration` (default 1 s) and `MyDAW.stripSilenceFadeMilliseconds` (default 10). The audio files are not changed |
| `beginGroupDrag`, `updateGroupDrag(delta:)`, `endGroupDrag(trackDelta:)` | Moves the selected clips together (never before zero; across tracks only when every clip has a destination, `canMoveSelectedClips(trackDelta:)`) |
| `layeringClips(for:)` | The clips a lane layers. While clips are dragged to another track, they leave the source's list and go on top of the destination's |
| `duplicateSelectedClipsInPlace` | At the start of an option-drag, leaves copies at the original positions (directly below each original) |

---

## 3. Audio, devices and plug-ins (`Sources/Audio`)

### `AudioEngineManager.swift`

The central class (@MainActor, `NSWindowDelegate`) for the AVAudioEngine graph, playback, recording, metronome, meters, plug-in creation and GUIs, and export.

#### Published state (excerpt)
`engine`, `isPlaying`, `isRecording`, `isPunchRecording`, `currentTime` (held by a separate `transportClock` object, `TransportClock`: it changes 60 times a second while playing, and publishing it from the engine redrew every view observing the engine (arranger, mixer, transport). Only `PlayheadLine`, `PlayheadBall`, `TransportTimeText` and the take being recorded (`LiveRecordingClipView`) observe it; auto-scroll receives it with `onReceive`), `bpm`, metronome (enabled, timing offset, volume), `hardwareSampleRate`, `masterVolume` (held by a separate `masterVolumeState`, so a drag does not republish the whole engine; observed only by `MasterFaderColumn` and the transport bar's `MasterVolumeSlider`), `masterPeak`, `masterStereoPeak` (both updated only when they change), `recordingsDirectory`, `inputBufferFrameSize`, `manualRecordingCompensationMs`, selected input/output devices. `loadMonitor` (`AudioLoadMonitor`, a separate `ObservableObject` so its updates do not republish the engine).

#### Node layout (per track)
| Dictionary | Role |
| --- | --- |
| `trackRenderers` | One `TrackRenderer` (`AVAudioSourceNode`) per track, feeding bus 0 of the track output mixer; rebuilt when the sample rate changes |
| `trackOutputNodes` | Track output mixer (fader volume, solo, mute). Mute and solo come from `audibility(tracks:fxChannels:)`: soloing a track keeps the FX channels it sends to; soloing an FX channel plays only its return (the sending tracks keep feeding their sends, but their splitter → mainMixer connection volume is set to 0 via `setTrackDryAudible`) |
| `trackDownmixNodes` | `MonoDownmixAudioUnit` at the head of every track chain (before the inserts) |
| `trackDryDelayNodes` / `fxReturnDelayNodes` | `DelayCompensationAudioUnit` on each track's dry path (splitter → mainMixer, delay D; mutes the dry sound for an FX solo) and on each FX return (pan → output, delay D − own latency). Set by `updateLatencyCompensation()` |
| `trackPluginNodes` | Inserts (AU / `VST3AudioUnit`) |
| `trackPanNodes` | Pan mixer (after the inserts) |
| `trackSplitterNodes` | Splitter mixer (one-to-many into mainMixer and sends; meter point) |
| `sendGainNodes` | Per-send gain mixer |
| `inputMonitorNodes` | `InputMonitorAudioUnit` (when I is on) |
| `fxInputNodes` / `fxPluginNodes` / `fxPanNodes` / `fxOutputNodes` | FX channel input (fader volume), inserts, pan and output (meter; volume 0 when muted or soloed out) |
| `masterOutputNode` / `masterPluginNodes` / `masterMeterNode` | Master volume, POST plug-ins, final meter |

#### Main public methods
- **Graph sync**: `syncTracks(_:fxChannels:)` (incremental update of tracks, FX, master, sends and input monitoring), `syncTracks(_:fxChannels:masterPlugins:)`, `syncMasterPlugins`, `syncAfterClipEdit` (during playback, `rescheduleEditedClips` restarts only the clips whose `ClipScheduleSignature` changed plus the clips overlapping them, from the transport position at the restart time; the players of clips that left a track are stopped on all tracks before anything is rescheduled, so a clip moved to a higher track is not stopped after its restart; other clips play on), `updateMixerLevels` (volume, pan, sends, FX), `updateSendLevel`, `setClipMuted`, `setPluginEnabled`.
- **Transport**: `startPlayOrRecord(tracks:fxChannels:recordArmedTracks:)` (starts playback/recording, or stops if running), `stop(tracks:)`, `rewind(tracks:to:)`, `seek(to:)`, `setPunchRange`. `songEndTime`: the playhead timer calls `onReachSongEnd` when it crosses it (only if playback started before it); that stop cuts recorded clips at it and leaves the playhead there.
- **Devices**: `applyAudioDevices(inputDeviceID:outputDeviceID:sampleRate:)` (sets the device sample rate and calls `bindIODevice` when the devices change), `applyInputBufferFrameSize`, `applyAutomaticTimingCompensation`.
- **Plug-ins**: `openPluginUI(pluginID:)`, `isPluginUnavailable`, `capturePluginStates`, `setSavedPluginStates`, `prepareForPluginGraphRestore`.
- **Other**: `exportMasterMix(to:startTime:endTime:tracks:fxChannels:)` (renders the master path in real time to 24-bit WAV), `shutdown()` (stops the engine, releases VST3, restores the macOS default input/output devices), recordings folder helpers.

#### Main internals
| Method | Purpose |
| --- | --- |
| `startMetronome(at:)` | Schedules 256 clicks and schedules the next run from the last one. When the transport starts it uses that start time and position; when switched on during playback, after a BPM change and for each next run it uses the earliest time a player can start without losing its opening (`earliestPlayerStartHostTime`) and the transport position at that time (`transportPosition(atHostTime:)`), aligned to the next beat |
| `setupEngine()` | Reads the input format, builds the master path and final meter, click, input tap, input monitors, raises slice limits, starts the engine |
| `bindIODevice(inputDeviceID:outputDeviceID:)` | Makes the chosen devices the macOS default input and output (AVAudioEngine with input runs on an aggregate of the defaults). Records the original defaults the first time; `restoreOriginalDefaultDevices()` puts them back in `shutdown()` |
| `startMeterTimer` | Collects peaks at 30 Hz and posts them. The master level lives in a separate `masterMeter` (`TrackMeter`) that publishes only on change (observed only by `MasterFaderColumn`); `masterPeak` is an unpublished internal value |
| `wireSend` | Connects a send's gain mixer to an FX input. `wiredSendTargets` remembers the target so it is rewired only when it changes (rewiring every sync throws `mixingDest` while input monitoring is on) |
| `applyDeferredRewiresWhenQuiet` | On stop, performs the deferred fan-out rewiring and input monitor connection once the master output is below -60 dB (at most 8 s). While waiting, `isWaitingForQuietRewire` is set and `syncTracks` leaves the rewiring to it. Gives up if the transport starts, retrying on the next stop |
| Stop-time recording finalisation (task in `stop`) | Finalises writers and loads the clips; calls `syncTracks` only when files were recorded |
| `installAudioUnits` / `installFXAudioUnits` / `installMasterAudioUnits` | Creates plug-ins asynchronously and chains them in insert order; for VST3 creates a `VST3AudioUnit` and binds the instance |
| `connectTrackChainTail` | Wires chain end → pan → splitter → mainMixer + sends. One-to-many connections are made **only with the engine stopped** (deferred via `pendingSplitterRewires` while playing) |
| `connectReformatting` | If an AU at either end has allocated render resources and the format changes, releases them before connecting (avoids the -10865 exception) |
| `setMixerVolume` | `reset()`s the mixer after a volume change (a silent input does not advance the ramp) |
| Playback plans in `syncTracks` | Builds `TrackPlaybackPlan.make(for:)` per track (unmuted clips whose files exist, their `ClipLayering.segments` minus hidden parts, and the `spans`) and hands it over with `setPlan`; nothing restarts, even while playing. `setClipMuted` rebuilds the plan too |
| `startPlayback` | Calls `prepare(renderFrom:)` on every renderer, waits until the blocks at the start position are read (a few ms for 24 tracks, at most 2 s), picks the start (`nextTransportStartTime`, plus room for the metronome's two `play(at:)` calls), runs `beforePlayersStart` (recording, metronome) and then `start(anchorHost:anchorFrame:)` on each renderer, with anchorFrame = start position + that track's pre-roll (own insert latency + D). No `play(at:)`, so nothing holds the engine lock for long and the main thread never waits on it. `stopRenderers` stops them and logs render cycles that found no audio read ahead |
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
- **`silenceRanges(of:sourceStartTime:duration:thresholdDB:minimumDuration:)`**: reads the range in 65,536-frame chunks and returns the runs where every channel's absolute sample value is at or below `thresholdDB` (dBFS converted to linear) for at least `minimumDuration`, in seconds from the range start (for Strip Silence). Judged per sample, with no RMS or other time averaging.
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

### `TrackRenderer.swift` (new in v2.0)
Plays a track's clips. It replaces one `AVAudioPlayerNode` per clip: each `play(at:)` waited a render cycle while holding the engine lock, so with many clips the whole UI (playhead, meters) froze at the start of playback.

- **`TrackPlaybackPlan`**: a value built from the clips on the main thread (files, positions, gains, pieces, `spans`); the reading thread never touches `AudioClip`.
- **`TrackRenderer`**: owns one `AVAudioSourceNode`. The render thread only copies its frames out of blocks read ahead (4,096 frames × 48 slots, about 4 s). The timeline position comes from the pair "`anchorFrame` is heard at `anchorHost`", converted to a sample time on the first cycle. Each slot is guarded by a sequence number (odd while written): the render thread never waits and never plays a torn block (it plays silence and counts `underruns`). The recording mute ramps over about 5 ms.
- **`TrackStreamer`**: one background thread that serves every renderer in turn (up to 4 blocks each per round). It reads the blocks ahead of the playhead from the files per the plan, applies gain, fades and crossfades (`ClipLayering.Envelope`) and mixes them. A new plan re-reads the blocks from two past the playhead on (the next one is not rewritten). Only files used within the look-ahead stay open.
- **`ClipReader`**: reads a file as stereo at the output rate; files at another rate are converted continuously with `AVAudioConverter`.
- **Atomics**: Swift's Atomics need macOS 15, so `MyDAWAtomicLoad64` / `MyDAWAtomicStore64` / `MyDAWMemoryFence` in `VST3Host/RealtimeAtomics.cpp` are called through `@_silgen_name`.

### `DelayCompensationAudioUnit.swift` (new in v1.8)
`StereoDelayLine` (render-thread ring buffer; a delay it cannot hold passes through) and an in-app AUv3 (`aufx`/`dlcp`/`MyDW`) with `delayFrames` and `isMuted` (about 5 ms ramp). Holds up to one second; reports no latency. `VST3AudioUnit` also uses `StereoDelayLine` so its bypass output is delayed by the plug-in's latency.

`AudioEngineManager.updateLatencyCompensation()` sums each chain's `auAudioUnit.latency` (bypassed plug-ins included), sets D = largest FX channel latency, sets the delay nodes, keeps a `kAudioUnitProperty_Latency` listener on every plug-in, and moves every renderer's `anchorFrame` if anything changed while playing (`updateRendererAnchors`). `transportPreRoll` P = D + the largest track insert latency. The transport starts P after the earliest safe time (two IO buffers after `lastRenderTime`, at least 50 ms), and each track's renderer plays its own pre-roll (its latency + D) early, so nothing after the start position is lost. Recording arms its take files and input capture in `beforePlayersStart`, once the start time is known and before the renderers start. `exportMasterMix` waits until the engine renders, starts the transport the same way and keeps, through `ExportWindow`, exactly the tap frames from the host time at which the start is heard (+ master plug-in latency) for `end − start` seconds; it throws if the range was not fully captured.

### `MonoDownmixAudioUnit.swift`
In-app AUv3 (`aufx`/`mndx`/`MyDW`) placed after every track's output mixer. With `isMono` set (the track is mono) it writes `(L + R) / 2` to both sides; otherwise it passes through. Mono clips already arrive as L = R (`TrackRenderer` duplicates them), so they are unchanged either way.

### `VST3NativeInstance.swift`
Swift wrapper holding the C++ bridge handle (`@unchecked Sendable`).
- **`init?(descriptor:sampleRate:maxFrames:)`**: loads the module and initialises the component.
- **`processStereo(...)`** (RT): processes in blocks of at most `maxFrames`.
- **`captureState()` / `restoreState(_:)`**, **`attachEditor(to:)`** (registers the `resizeView` callback), **`currentEditorSize()`**, **`removeEditor()`**, `latencySamples`.
- **deinit**: detaches the editor and calls `MyDAWVST3Destroy`.

### `AudioLoadMonitor.swift` (new in v1.8)
Audio processing load and dropouts for the status bar (`@MainActor`, owned by `AudioEngineManager.loadMonitor`; `start(engine:)` in `init`, `stop()` in `shutdown`).
- **Load**: an `AudioUnitAddRenderNotify` on `engine.outputNode.audioUnit` (bus 0 only) times each I/O cycle between pre- and post-render with `mach_absolute_time`; load = render time ÷ cycle length (`frames / sampleRate`). The render thread writes running totals and the peak into a preallocated `RenderStats` (no locks, no allocation).
- **Dropouts** (events within 0.3 s count once): a cycle with load > 1; a forward jump of the device sample time (skipped cycles); `kAudioDeviceProcessorOverload` from the output unit's current device (`kAudioOutputUnitProperty_CurrentDevice`; with input in use this is the engine's aggregate of input and output, so `inputNode` is never touched — doing so would reconfigure an engine without input).
- **Restarts**: an idle gap > 0.25 s or the sample time going back marks a restart; the next 16 cycles are not measured or counted, and device overload reports are ignored for 1 s.
- **Main side** (10 Hz timer): publishes only `load` (window peak; rises at once, falls with 0.75 smoothing, rounded to 0.5%) and `isShowingDropout` (3 s after the last dropout, `dropoutDisplaySeconds`). `averageLoad`, `peakLoad` (last second), `processCPU` (`getrusage` over all cores), `dropoutCount`, `lastDropoutDate` are plain properties for the tooltip. Every second it re-attaches if the output unit or device changed.
- **Test aid**: `MyDAW.loadTestOffset` (UserDefaults, percent) is added to every cycle's load on the render thread, so the colours and the dropout path can be checked (`open MyDAW.app --args -MyDAW.loadTestOffset 70`, or `defaults write com.tokada.MyDAW MyDAW.loadTestOffset -int 70`; `defaults delete …` to turn off). A yellow “TEST +n%” badge is shown while it is on.

### `PluginManager.swift`
- **`TrackPluginDescriptor`**: ID, name, kind (AU/VST3), bundle path, VST3 UID, AU component description, enabled flag, UI compatibility.
- **`discoverAvailablePlugins(onLog:completion:)`**: discovers AUs (`AudioComponentFindNext`) and VST3s in the background. **VST3s with a same-named AU are excluded.** MyDAW's own internal AUs (manufacturer code `MyDW`: Mono Downmix, VST3 Host, Delay Compensation, Input Monitor) are left out of the list.
- **VST3 discovery**: `scanVST3Bundle` → checks the cache (path + modification date) → otherwise `runScanChild` (`MyDAW --scan-vst3 <path>`, 60 s timeout; a crashed scan caches an empty result).
- **`runVST3ScanChildIfRequested()`**: the child side (enumerates and prints JSON prefixed with `MYDAW_VST3_SCAN_RESULT:`).

### `VST3HostBridge.swift` / `VST3Host.swift`
`VST3HostBridge.enumerate(bundleURL:)` calls C++ `MyDAWVST3EnumerateAudioEffects` and returns UID, name, vendor and version (used only in the child process). `VST3Host.swift` holds host-abstraction protocols and an unavailable implementation.

### `AudioDeviceManager.swift`
Reads and sets input/output devices, input channels (mono/stereo choices), sample rate and buffer size through the Core Audio HAL. Selected devices are stored by UID in UserDefaults. The engine is actually pointed at them by `AudioEngineManager.bindIODevice` (switching the macOS defaults).

### `AudioDiskWriter.swift`
Copies recording buffers and writes them to 24-bit WAV on a serial queue. File names (`RecordingFileName`): `<track name>_<take number>.wav`, e.g. `Bass_001.wav`. The name keeps letters of any script (NFC), turns whitespace and `_` runs into one `_`, drops other symbols, and is cut at 40 characters (`Track` if empty). The take number is one past the highest used in Recordings and Recordings/Unused. The file is created in `init`, so same-named tracks recording together get consecutive numbers. Reversed clips use the stem `Reverse_<track name>` and imports `Import` (`Import_001.wav`). (Before v1.8: `Rec_<track>_<6-char ID>_<ch>ch_<rate>_24bit_<timestamp>.wav`, `Import_<name>_<8 hex>.wav`, `Reverse_<file>_<8 hex>.wav`.) `finalize()` completes the file and returns its URL.

### `GenericAUParameterView.swift`
Generic UI that builds sliders from an AU's parameter tree (used when there is no usable custom GUI).

---

## 4. Views (`Sources/Views`)

### `MainDAWView.swift`
Stacks the transport, arranger, mixer and status bar (device, `AudioLoadIndicator`, recordings folder, shortcut hints). The open project's name (`ProjectState.openProjectName`) is overlaid in the middle of the title-bar strip (the standard title is hidden by `.hiddenTitleBar`), with the strip height taken as the content's distance from the window top (`frame(in: .global).minY`) and the text shifted up by it; clicks pass through (`safeAreaInsets.top` of a GeometryReader that ignores the safe area reads 0 here, so it cannot be used). The window title (`navigationTitle`) becomes “MyDAW - <name>” for the Window menu and Mission Control (plug-in windows are told apart by the “MyDAW” prefix). `currentProjectURL` is `@Published` so the name updates. Contains the startup log (plug-in discovery progress; removed from the view hierarchy once done), the master export dialog, the close-window confirmation and key handling (`SpacebarHandler`: ⌘Z / ⇧⌘Z / ⌘Y, ← to rewind, ⌘X / ⌘C / ⌘V / ⌘A as `EditCommand`s, Esc clears the selection and is passed on; nothing is handled while typing in a text field).
- **Minimum size**: the outer frame is only `.frame(minWidth: 800)`, with no height floor (one would hide the content's minimum height, letting the window get shorter than its content and cut off the transport and mixer). The window's minimum height is the transport + the arranger's minimum (`minimumArrangerHeight` = 180 pt) + the mixer + the status bar.
- **Arranger height**: `arrangerHeight` is read and handed to `MixerView` as `growthLimit` (the room left before the arranger reaches its minimum).
- **`TitleBarZoomHandler`** sits in the background (`WindowCloseHandler.swift`).
- **`refreshToolTips()`**: when a project opens or the startup log goes away, widens the main window by 1 pt and back so tooltip areas are re-registered (SwiftUI does not do so when only an overlay disappears).

### `ProjectSelectionView.swift`
Launch screen: New Project (save panel) and Open Project (⌘O, choose a `.mydaw`); shows the version. Below the buttons, the Recent Projects list (`RecentProjects.shared`, scrollable, 520 × 240 pt): each `RecentProjectRow` shows the name as an orange link (underlined with a pointing-hand cursor on hover, path as tooltip; click → `onOpenRecent`) and the last-saved date and time. Missing files are struck through and not clickable. Context menu: Remove from List.

### `AudioLoadIndicator.swift` (new in v1.8)
Status bar item “CPU [bar] 34% ● Dropout” observing `AudioLoadMonitor` (only this view redraws, at most 10 Hz). The bar (64 × 7 pt capsule, 0.1 s linear animation) is coloured by interpolating green (0) → yellow (0.6) → orange (0.8) → red (1.0); the percentage can exceed 100. The dropout mark keeps its space while hidden (opacity), so the bar does not shift. The tooltip is an AppKit tooltip (`DynamicToolTip`, `NSViewToolTipOwner`) whose text is built when shown, so the frequent redraws do not keep it from appearing.

### `TransportBarView.swift`
- Buttons (left to right): Settings, Undo, Redo, Rewind, Play/Pause (Space), Record (records armed tracks), P (enable punch), Metronome (can be switched while playing or recording), Save, Open, Snap, Auto-scroll (`ProjectState.autoScrollEnabled`, kept in UserDefaults `MyDAW.autoScroll`). Tooltips use the standard `.help`.
- Displays: TIME (time or bars/beats), TEMPO (BPM entry 20–400), FORMAT (24-bit WAV and sample rate); the panel is as wide as its contents.
- The bar is left-aligned; when the window is narrower, the right end is cut off (`frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)` plus `clipped()`).
- Right side: timeline zoom, track height scale, waveform vertical scale, ruler toggle, master volume.
- **`BufferSettingsView`** (gear, titled “Settings”): recordings folder, language (`AppLanguage`), input/output device, sample rate (44.1–96 kHz), recording delay compensation, click timing offset, click volume, buffer size. When a language, device or sample-rate change is applied it calls `onAudioDevicesChanged` to offer a restart.

### `ArrangerView.swift`
Track headers and lanes, the ruler (seconds or bars/beats; click to seek), playhead, punch range (drag the left/right handles on the ruler in beat steps), Add Track button, auto-scroll (only when `autoScrollEnabled` is on; moves on when the playhead enters the right 10%), Delete key, and drawing of the marquee rectangle and range-selection band.
- **Coordinate space `timelineScroll`**: set on the lanes' ZStack. `trackTopY`, `trackID(atTimelineY:)`, the marquee, range selection and clip drags are measured in it.
- **Clip drag display**: `clipDragPreviews` draws every clip in `clipDragPreview` from its own track, moved by the vertical travel (waveform and fades as layered in the destination).
- **Track reordering**: the lane area reaches down to the bottom of the view, so a lane dragged below the last track is not clipped. A `DragGesture` on each header (`reorderGesture`, 4 pt minimum, global coordinates). `reorderTargetIndex` counts the tracks whose middle lies above the dragged row's middle. With `reorderOffset` the dragged row follows the pointer and the rows it passes step aside by its height. `ReorderLift` is applied to both the header and the lane, framing the dragged row, adding a shadow and bringing it to the front. On release `moveTrack` runs inside an animation.
- **Horizontal scrolling**: a `timelineScrollTime` change scrolls the tracks' `NSClipView` directly through `setTrackScrollOffset`, and again on the next main-queue turn after the new layout (`scrollTo` can take the position from an outdated layout). `ScrollOffsetObserver` feeds the user's own scrolling back into `timelineScrollTime`.
- **`KnobOnlySlider`**: the horizontal scroll bar at the bottom. It moves only when its knob (●) is dragged; clicks elsewhere are ignored.
- **`ArrangerWheelMonitor`**: a local event monitor for scroll-wheel and pinch events over the whole arranger (ruler included). A wheel over the ruler and a pinch zoom horizontally around the pointer; ⌥+wheel sets track height; ⌥⇧+wheel sets waveform height (also when shift turns the wheel into horizontal scrolling). Handled events are not passed to the scroll views.

### `TrackHeaderView.swift`
Colour bar on the left (click for `TrackColorPalette`: 16 presets + custom), name (double-click to edit), mono/stereo toggle (1/2), delete, R / M / S / I, input channel menu, meter (input while armed, output otherwise), drag the bottom edge to change height (`VerticalResizeHandle`: measured in screen space and divided by the scale into `trackHeight`; the drawn height stays at least `minimumRowHeight`, 56 pt). The content is top-aligned; in a short row the meter and below hide behind the opaque bottom strip. Dragging anywhere else reorders the track (the gesture is attached by `ArrangerView`).

### `WaveformLaneView.swift`
One track lane.
- **Lane**: dragging over empty space draws a marquee (⌘ for a range selection); a click clears the selection; WAV files can be dropped from Finder.
- **`AudioClipView`**: click (⇧/⌘ to add or remove), drag to move the selected clips together (⌥ to duplicate, ⌘ for a range selection), left/right trim, gain (top centre), fade in/out (top-left / top-right), fade curve (the diamond in the middle of a fade line; vertical drag via `FadeCurve.withMidpoint`, double-click for `.auto`). Gain, fade and curve handles start dragging on mouse-down and show their value in an `EditValueTooltip`. Trim handles are not drawn: a clear 10 pt strip at each clip edge takes the drag and sets the pointer to a one-way arrow (right at the start, left at the end). A fade dot takes clicks only in a 16 pt square centred on it and sets the pointer to a pointing hand, as does the curve diamond; the gain bar takes clicks in 24×13 pt and shows an up-down arrow (`hoverCursor` at the end of the file, `pointerStyle` (`.columnResize(directions: .trailing / .leading)` / `.link` / `.rowResize`) on macOS 15 and later, `NSCursor.set()` (`resizeRight` / `resizeLeft` / `pointingHand` / `resizeUpDown`) on every `onContinuousHover` move before that; a cursor pushed from `onHover` is reset to the arrow at once by the hosting view).
- **Context menu**: `LaneMenuMonitor` (a local monitor for right-clicks and Control-clicks) builds an AppKit `NSMenu` at the click (a SwiftUI menu is built beforehand and cannot reflect a selection made by the click). Inside the selected range it shows the range menu; on a clip it selects the clip with `selectForMenu` and shows the clip menu; elsewhere Cut / Copy / Paste (`LaneMenu`). Clip menu: file name (or the count), Cut / Copy / Paste, Normalize, Reverse, Strip Silence, choose file (single clip only), mute, duplicate, split, delete; with several clips the items show the count.
- **Display**: waveforms are drawn at the `ClipLayering.envelope` level; only parts fully hidden by upper clips are darkened. Fade handles at covered edges are hidden.

### `PreviewStretch.swift` (new in v2.0)
**Zoom and track height**: the ruler, headers and clip boxes follow the new value at once, but each waveform stays drawn at `ProjectState.waveformRenderPixelsPerSecond` / `waveformRenderTrackHeightScale` (the scale waveforms are drawn at) and is stretched to its box with `scaleEffect`. `WaveformCanvas` is `Equatable` (`.equatable()`, with the value-type `ClipLayering.Envelope`), so it is not redrawn while its inputs stay the same. A tenth of a second after the change stops, `syncWaveformRender` brings the drawing scale up to date and the waveforms are drawn properly (the `drawWindow` is re-centred then too); an opened project syncs at once. While the two scales differ (during a change), `AudioClipView` leaves out the trim, gain, fade and curve handles, so the several views each one adds are not moved on every step for every clip; the lane grid lines are drawn only inside the `drawWindow` too. What `ArrangerView` keeps to follow the scroll position (the last scroll time read, the offset being scrolled to) lives in a plain `ScrollFollow` object, not `@State`: it is written on every zoom step, and as state each write rebuilt the whole arranger once more. **Waveform scale** (slider, ⌥⇧ + wheel) calls `previewWaveformVerticalScale`: while the control moves the value stays, only `waveformScalePreview.scale` changes and the drawn waveforms are stretched by `VerticalStretch` (from their centre); a tenth of a second after it stops, `commitPreviews` sets the real value.

### `WaveformCanvas.swift`
Draws `WaveformCache` peaks with SwiftUI `Canvas` (per channel, gain scaling, amplitude from `envelope`). Zoomed out so far that several peaks share a pixel, it draws each group's extremes once. It draws only inside `drawWindow` (`ProjectState.waveformDrawWindow`, a `DrawWindowState`: the visible range and two screens either side, moved by `ProjectState.refreshDrawWindow` only when the view comes within half a screen of its edge or the waveforms' drawing zoom or the viewport width changes), so a zoom or height change redraws a few screens rather than the whole song, and scrolling rarely redraws at all. `WaveformLaneView` does not build the views of clips outside it (selected clips and the take being recorded excepted).
- **`FadeLinesOverlay`**: draws the fade-in / fade-out lines across the clip's full height in the shape of their curves (one line even for stereo).

### `MixerView.swift`
Studio One-style mixer.
- **Overall**: drag the top edge to resize (from the height that keeps 220 pt between the SEND/fader divider and the bottom edge, up to 1000 pt, and never more than the `growthLimit` at the start of the drag, so the arranger keeps 180 pt; the edge is an AppKit `VerticalResizeHandle`, so cursor and drag area always match), horizontally scrolling track/FX strips, MASTER pinned on the right, right-click for Add FX.
- **`StripSections`**: INSERT / SEND / controls sections (headings via `SectionHeader`, localised through `LocalizedStringKey`) with draggable dividers (shared by all strips, stored in UserDefaults).
- **`TrackStripView`**: INSERT (+ menu, green dot on/off, click name for GUI, drag to reorder, × to remove), SEND (level bar and dB value per FX), pan, M/S, fader value, scale / fader / stereo meter, name (click to select).
- **`FXStripView`**: INSERT, (an empty SEND section kept only for alignment), pan, "FX" label, fader, name (double-click to rename). Its context menu has Add FX and Remove FX channel (removal goes through the `confirmRemoveFXChannel` confirmation dialog) (it overrides the mixer-wide menu on the strip, so Add FX is repeated there).
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
Closing the window calls `NSApp.terminate`, so the save prompt comes from `applicationShouldTerminate` (`ProjectState.confirmQuit()`), the same as the Quit menu and ⌘Q.

**`TitleBarZoomHandler`**: a local monitor catches double-clicks on the title bar strip (above `contentLayoutRect`, except on the close / minimise / zoom buttons) and calls `window.zoom(nil)`, switching between filling the screen beside the menu bar and Dock and the previous size (with the title bar hidden, the click would otherwise reach the content views and the standard behaviour would not happen). Nothing happens in full screen.

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
`applicationShouldTerminate` → `ProjectState.confirmQuit()` (Save / Don't Save / Cancel while a project is open; skipped during `relaunch()`, which has already asked) → `applicationWillTerminate` → `shutdown()` → engine stop → `releaseVST3Instances` (close editors → detach wrappers → destroy instances → `bundleExit`) → `restoreOriginalDefaultDevices` (puts the macOS default input/output back).

### 6.4 Device change and restart
1. Apply in `BufferSettingsView` → `AppLanguage.select` if the language changed; `AudioEngineManager.applyAudioDevices` (sample rate, `bindIODevice`) if a device or the sample rate changed → on success `AudioDeviceManager.setSelectedDeviceIDs`.
2. After the sheet closes, `ProjectState.promptRestartForAudioSettings` offers to save and restart.
3. `relaunch()` starts a waiting shell and calls `NSApp.terminate` → the default devices are restored on quit → the shell runs `open -n`, and `MainDAWView` in the new process opens the `.mydaw` passed as an argument → the new process switches the defaults again and builds its engine.
