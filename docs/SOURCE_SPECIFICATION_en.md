# MyDAW Source Code Specification (v3.0)

> Version covered: **3.0** / Japanese edition: [SOURCE_SPECIFICATION_jp.md](SOURCE_SPECIFICATION_jp.md)
> System structure, signal paths and design decisions: [PROJECT_ANALYSIS_en.md](PROJECT_ANALYSIS_en.md)

For every file under `Sources/` and `VST3Host/` (except the built-in effects in `Sources/BuiltIn`, which are copied from MyPlugIn and only summarised in section 3), this document describes responsibilities, types, the contracts of the main properties and methods, threading assumptions and side effects. Private methods are listed only where they are needed to follow the processing flow.

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
  - About (shows the version; falls back to `3.0` without Info.plist)
  - File: New Project… (⌘N), Open Project… (⌘O), Save Project… (⌘S), Save Project As… (⇧⌘S), separator, Export Master Mix…, separator, Optimize Recordings to Minimum Size, Move Unused Recordings to Unused Folder
  - Edit: Undo Clip Edit (⌘Z), Redo Clip Edit (⇧⌘Z / ⌘Y)
  - Help: MyDAW Help (⌘?). Opens `https://toshi.life.coocan.jp/note/OperationManual_{jp,en}.pdf` for `AppLanguage.current` with `NSWorkspace.open` (the system picks the app)
- **Built-in effects**: `init()` evaluates `BuiltInPlugins.registration` (after the VST3 scan child check, before any plug-in scan or project load), so the built-in effects are registered as AUs first.
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
| `isMuted`, `isSoloed`, `volume`, `pan` | Mixer values (`isMuted` / `isSoloed` are the track's own buttons) |
| `folderID` | The folder the track is in (v2.1; set by `ProjectState` only) |
| `isMutedByFolder`, `isSoloedByFolder` | True while the folder's M / S holds the track (v2.1; set by `applyFolderStates()`) |
| `effectiveMuted`, `effectiveSoloed` | Mute / solo as heard: the track's own OR its folder's (used by the engine's `audibility`) |
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
- Further attributes: `gainDB` (−∞…+36; `setGainDB` turns values at or below `silenceGainDB` (−72) into −∞ and caps at `maximumGainDB` (36). JSON cannot hold −∞, so `ClipDocument` saves −144 and loading turns it back into −∞), `isMuted`, `fadeInDuration` / `fadeOutDuration`, `fadeInCurve` / `fadeOutCurve` (`FadeCurve`, default `.auto`), `sampleRate`, `originalDuration` (file length), `waveformCache`.
- **`loadMetadata()`**: reads sample rate and length from the file and starts asynchronous peak loading; `duration` is clamped to what is available.
- **Caution about −∞ in `gainDB`**: silence is held as a real `-infinity` (so the factor `pow(10, gainDB / 20)` is exactly 0). Code that uses the value must (1) never write it straight to JSON or the like (`JSONEncoder` throws and saving fails; replace it with a finite value as `ClipDocument` does), (2) never convert it to an integer (a runtime trap), and (3) avoid calculations that give NaN, such as multiplying by 0 or adding an infinity (start from `silenceGainDB` when the starting point is −∞, as the drag does). Display it by checking `isFinite`, as "-∞ dB".
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
`id`, `name` (default "FX n", n being one past the highest existing "FX number"), `volume`, `pan`, `isMuted`, `isSoloed`, `plugins`, `color`, `currentOutputPeak`, `outputStereoPeak`; `insertPlugin` / `removePlugin` / `movePlugin`.

#### `FXSend: Codable`
`id`, `fxChannelID`, `level` (linear gain), `enabled`.

### `StereoPeak.swift`
L/R peak values. `init(buffer:)` computes each channel's maximum absolute sample (mono reports the same value on both sides). `merged(with:)`, `falling(to:by:)` (instant attack, exponential release; values below -100 dB become 0 so an idle meter stops changing), `maximum`.

### `WaveformCache.swift`
- Two levels of peaks, each the true lowest and highest sample of its block (not anchored at 0, so zoomed in a peak sits where its part of the wave is): the coarse `PeakPoint` arrays, combined (`peaks`) and per channel (`channelPeaks`), 512 samples per peak; and the fine `CompactPeak` arrays (`fineCombinedPeaks`, `fineChannelPeaks`; `finePeaks(for:)`), `fineSamplesPerPeak` = 64 samples per peak stored as Int16 min/max (4 bytes; a mono file's combined array shares its channel's storage). The fine level is about one peak per point at 800 px/s (48 kHz). A take being recorded has only the coarse level (live peaks).
- **Raw samples**: `requestSamples(_:)` makes `sampleWindow` (`SampleWindow`: start frame, per-channel and averaged samples) cover a frame range, reading it in the background with the same length again on each side; cheap to call on every draw (a window already there or on its way is not read again; at most 4 s at 48 kHz per request, so a waveform drawn whole never reads a whole file; a newer request or `loadPeaks` / `clear` supersedes an older read).
- **`loadPeaks(from:)`**: reads the file in `Task.detached` and publishes on the main thread; one pass makes both levels (each coarse peak gathers 8 fine ones). Peaks are shared per file (keyed by path, size, modification date and `samplesPerPeak`): a file already read is applied at once, and a cache asking while it is being read waits for that read, so split clips never read the same file again.
- **`appendLivePeaks` / `appendLiveChannelPeaks`**: live waveform while recording.

### `ProjectDocument.swift` (`.mydaw` JSON)
| Type | Main contents |
| --- | --- |
| `ProjectDocument` | `version` (currently 5), zoom, scroll, playhead, BPM, metronome, master volume, display scales, tracks, folders (`folders`, v2.1), FX, master plug-ins, plug-in states, punch range, song range, master export settings (file name, format, folder) |
| `TrackDocument` | Name, channels, input, R/M/S, **I (`isInputMonitoring`)**, volume, pan, height, colour, folder (`folderID`, v2.1), clips, plug-ins, sends |
| `TrackFolderDocument` | A folder's ID, name, colour, open state (`isOpen`), M / S and `position`, its index among all rows of tracks and folders. `makeFolder()` turns it back into a `TrackFolder`; loading inserts folders into the track list in increasing position |
| `ClipDocument` | ID, start, source offset, duration, original duration, gain, mute, fades, fade curves (`fadeInCurve` / `fadeOutCurve`, `.auto` if unreadable), file path (relative to the project) |
| `FXChannelDocument` | FX name, volume, pan, mute, solo, colour, plug-ins (mute / solo default to off in older projects) |
| `PluginStateDocument` | `pluginID`, `stateData`, `format` (plist for AU, `"vst3-state"` for VST3) |
| `PunchRangeDocument` | `startBeat`, `endBeat`, `enabled` |
| `SongRangeDocument` | Song start / end flags: optional `startBeat`, `endBeat` |
| `ProjectDocument.masterExportFileName` | File name (with extension) last used for the master export (optional). The dialog shows it without the extension; without it, `<project name>_Master_Mix` |
| `ProjectDocument.masterExportSettings` | (v2.2) `ExportSettings` last used for the master export (optional; absent until the first export, when the dialog starts from the hardware rate if it is 44.1 / 48 / 96 kHz) |
| `ProjectDocument.masterExportFolderPath` | (v2.2) Export folder (optional; nil: the project folder). Relative to the project folder when inside it, `.` for the folder itself, absolute otherwise. A folder that no longer exists falls back to the project folder |
| `ColorDocument` | RGBA |

Every decoder uses `decodeIfPresent` with defaults, so files from older versions load.

### `ProjectState.swift`

`ProjectState: ObservableObject` (@MainActor) is the facade between UI and engine.

- **Published state**: `rows` (the rows of tracks and folders, the single source of the order; v2.1), `tracks` (the rows' tracks, refreshed in `rows`' `didSet`), `mixerScrollRequests` (a `PassthroughSubject` carrying the row ID for "Show in Mixer"), `fxChannels`, `masterPlugins`, `selectedTrackId`, `pixelsPerSecond` and `trackHeightScale` (held by a separate `timelineGeometry`, a `TimelineGeometry`: publishing every step of a zoom or height control from ProjectState redrew every view, the mixer included; only the timeline's views — `ArrangerView`, the ruler parts, `WaveformLaneView`, `AudioClipView`, `TrackHeaderView`, `TransportBarView` — observe it, as an environment object). `pixelsPerSecond` (5–800, `minimumPixelsPerSecond`/`maximumPixelsPerSecond`; the slider is logarithmic), `timelineScrollTime` (held by a separate `timelineScroll` object, `TimelineScrollPosition`: publishing every scroll step from ProjectState would redraw every track header and lane. Only the ruler shift (`TimelineScrollOffset`) and the scroll knob (`TimelineScrollSlider`) observe it; the track view is scrolled synchronously right after the change by `TimelineScrollPosition.onChange` (`followScrollTime`, registered by ArrangerView), so it moves in the same frame as the ruler), `punchRange`, `showsBeats`, `snapToGrid` (stored in UserDefaults), `autoScrollEnabled` (UserDefaults `MyDAW.autoScroll`), `waveformVerticalScale` (1–256, `maximumWaveformVerticalScale`; logarithmic slider; `WaveformCanvas` clamps peaks to the lane), `trackHeightScale` (`TrackHeaderView.minimumRowHeight` 56 pt ÷ 170 ≈ 0.33 to 3; the slider and ⌥+wheel go through `setTrackHeightScale`, which first returns every track's `trackHeight` to the standard value), `timeSelection` (range selection), `marqueeRect` (marquee while dragging), `clipboard`, export dialog state, startup log, `pluginManager`, `audioEngine`, `deviceManager`.
- **Initialisation**: applies devices and buffer size to the engine, subscribes to peak notifications, creates two default tracks, starts plug-in discovery.
- **Tracks**: `addTrack` (below the current track; the place comes from `newTrackPlace()` and the insertion from `insertNewTrack(name:mode:isArmed:at:)`; inside a folder it takes the folder's colour and a closed folder opens), `deleteTrack` (the UI calls `confirmDeleteTrack`, which asks first), reordering and folders in `ProjectState+Folders.swift`, `toggleRecordArm`, `toggleInputMonitoring`, `toggleMute` / `toggleSolo` (do nothing while the folder holds them), `setInputRouting(for:channelMode:inputChannelIndex:)` (syncs the engine immediately).
- **Clips**: `selectClip` (selects only that clip and clears the range selection), `moveClip` (across tracks), `deleteSelectedClip` (deletes inside the range selection if there is one, otherwise every selected clip), `splitSelectedClip` / `splitClip`, drag preview (`ClipDragPreview`: the set of dragged clip IDs, the vertical travel and the track delta; `beginClipDragPreview()` / `updateClipDragPreview(verticalOffset:trackDelta:)` / `endClipDragPreview()`; the delta is 0 when some clip would have no destination). Selection, ranges, clipboard and group moves live in `ProjectState+Editing.swift`.
- **Undo/redo**: `beginClipEdit()` takes a snapshot (clip position, range, gain, mute, fades and curves, file, and each track's selection); `endClipEdit()` pushes it unless the clips are unchanged (for example after just clicking a handle). `undo()` / `redo()` do nothing while playing or recording and until the takes are finalized after a stop (`isRecordingLocked`). A recording (via `onRecordingWillAddTakes`, right before the engine adds its takes) and a WAV import are each pushed as one step. A track added after a snapshot is left as it is when restoring, not emptied.
- **Punch**: `setPunchRange`, `setPunchStartBeat`, `setPunchEndBeat`, `setPunchEnabled`.
- **Rollback recording**: `recordRollbackEnabled` (UserDefaults `MyDAW.recordRollback`) and `recordRollbackBars` (`MyDAW.recordRollbackBars`, default 2, `recordRollbackBarsRange` 1...16). `toggleTransport` passes `bars × 4 × beat duration` (0 when off) to the engine's `recordRollbackDuration`.
- **Unused recordings**: `moveUnusedRecordings()` (File menu; `canMoveUnusedRecordings` = project open, stopped, no recording being finalised) first asks to save (Save Project and Continue / Cancel) and saves, then moves WAV files directly in Recordings that no clip or clipboard entry refers to into `Recordings/Unused` (numbered on a name clash) and lists them in an NSAlert. Clips of the other `.mydaw` files in the same folder (`clipPathsOfOtherProjects()` decodes their `ProjectDocument`) also count as in use; if one cannot be read, nothing is moved and an error is shown. If a moved file appears in an Undo / Redo snapshot, both stacks are cleared.
- **Optimize recordings**: `optimizeRecordings()` (File menu; `canOptimizeRecordings` = `canMoveUnusedRecordings`). When other `.mydaw` files are in the same folder (`otherProjectFileNames()`), they share Recordings, so it only warns. After the confirmation (Optimize / Cancel) it saves, then for every clip `ClipAudioProcessing.extractDecision()` (`.nothing` / `.keep` / `.extract(ExtractPlan)`) works out the source frames it plays (`sourceStartTime` rounded down to the end rounded up), the channel count (1 on a mono track; the source's, at most 2, on a stereo track), the sample rate (lowered to `hardwareSampleRate` only when higher) and the bit depth (16 for integer files of 16 bits or less, otherwise 24). A clip that plays a whole file already in that format is left alone; the rest share one `RecordingExtract` per source / range / channel count, written by `ClipAudioProcessing.writeExtract()` as `Optimized_NNN.wav`. Mono is (L+R)/2 as in playback; sample-rate conversion uses `AVAudioConverter` at max quality. Writing runs in the background behind a cancellable progress panel (`RecordingOptimizeProgress`, `NSApp.runModal`). On failure or Cancel every written file is removed and nothing changes. On success each clip gets the new file with `sourceStartTime` set to the sub-sample remainder, Undo / Redo and the clipboard are cleared, the tracks are synced and the project is saved. Source files directly in Recordings that no clip uses any more then go to `Recordings/Unused` (`moveToUnusedFolder()`), and the number of files created and the total size before and after are shown.
- **Song flags**: `songRange` (pushes `songEndTime` to the engine), `songStartTime` / `songEndTime` (seconds), `setSongStart(time:)` / `setSongEnd(time:)` (nil removes; kept at least `minimumSongLengthBeats` apart), `canPlaceSongStart(at:)` / `canPlaceSongEnd(at:)`. `toggleTransport(recordArmedTracks:)` passes the punch range, rollback and song end to the engine and starts or pauses (used by the play / record buttons, Space and R). `rewindToSongStart()` goes to the start flag, or to 0 when on or before it. The engine's `onReachSongEnd` calls `stop(tracks:)`.
- **Plug-ins**: tracks `insertPlugin(_:into:)` / `removePlugin(_:from:)` / `togglePlugin(_:on:)`; FX `…intoFX:` / `…fromFX:` / `…onFX:`; master `insertMasterPlugin` / `removeMasterPlugin` / `toggleMasterPlugin`; `openPluginUI`.
- **Moving and copying plug-ins** (v3.0; replaces `movePlugin` / `moveMasterPlugin`): `dropPlugin(_:before:on:)` takes the dragged plug-in's ID, the plug-in to insert before (nil = at the end) and the target `PluginChain` (`.track(UUID)`, `.fx(UUID)`, `.master`). It finds the source chain with `pluginChain(containing:)`; on the same chain it moves the plug-in, on another chain it inserts `newInstance()` of it after `audioEngine.copyPluginStates([source: copy])`, leaving the original. Then `setPlugins(_:on:)` and `syncTracks`. Ignored while playing or recording.
- **FX**: `addFXChannel()` (named one past the highest "FX number", coloured like the first FX channel), `renameFXChannel(id:to:)` (ignores empty names), `removeFXChannel(id:)` (the UI calls `confirmRemoveFXChannel(id:)`; the NSAlert makes Return and Esc cancel), `setSend(trackID:fxChannelID:level:)`.
- **Files**: `createNewProject` (an NSSavePanel for folder and name: `canCreateDirectories`, opened expanded, `.mydaw` type; creates the `.mydaw` and `Recordings/` in the chosen folder), `loadProject` (an NSOpenPanel for a `.mydaw` file; its parent becomes the project folder). Both panels start one level above the last project's folder (`projectPanelStartDirectory`). `openRecentProject(_:)` (checks the file exists, then `loadProject(from:projectFolderURL:)` with the file's folder), `saveProject` (a successful write calls `RecentProjects.noteSaved`; a successful `loadProject(from:)` calls `noteOpened`), `saveProjectAndShowConfirmation`, `openProjectFile(_:)` (from the Finder: brings the app to the front, does nothing if that file is already open, shows an error while playing or recording, and asks Save / Don't Save / Cancel when a project is open before `loadProject(from:projectFolderURL:)`), `saveProjectAs()` (asks only for a name in an NSAlert text field, saves to `<name>.mydaw` in the same folder and switches `currentProjectURL`; rejects empty names, a leading “.”, “/” and “:”, confirms replacing an existing file, restores the old URL on failure), `importAudioFile(_:intoTrackId:)` (copies 24-bit integer PCM at the current rate as is; otherwise converts it with `ClipAudioProcessing.writeConverted` into `Recordings/`), `locateClipFile` (matching sample rate only).
- **Restart**: `promptRestartForAudioSettings()` (after a device, sample-rate or language change, asks Save and Restart / Restart Without Saving / Cancel), `relaunch()` (a `/bin/sh` waits for this process to exit, then `open -n` relaunches with the project as an argument).
- **Export**: `beginMasterExportDialog` (opens the dialog directly; no save panel), `masterExportSettings` / `masterExportBaseName` / `masterExportFolder` (the dialog's choices), `chooseMasterExportFolder` (NSOpenPanel, folders only), `exportMasterMix(startTime:endTime:)`, `cancelMasterExport`. `exportMasterMix` checks the name (same rules as Save As; a typed .wav / .mp3 is dropped), adds the format's extension, confirms replacing an existing file, then (1) has `AudioEngineManager.exportMasterMix` capture the master in real time into a temporary 32-bit float CAF (`NSTemporaryDirectory`) and (2) runs `ExportEncoder.encode` in a detached task. `masterExportStage` (`.capturing` / `.converting`) and `masterExportProgress` (0…1) drive the dialog's progress bar. Cancel or failure deletes the partial output; the temporary file is always deleted.
- **View**: `zoomIn`, `zoomOut`, `setPixelsPerSecond(_:)` (keeps the playhead in place), `setPixelsPerSecond(_:anchorOffset:)` (keeps the pointer position in place; for wheel and pinch; both scroll the tracks even when the scroll time stays the same, through `setScrollTimeAfterZoom`), `minimumPixelsPerSecond` / `maximumPixelsPerSecond` (5 / 3200), `snappedTimelineTime` (one beat).

### `ExportSettings.swift` (new in v2.2)
The master export format (Codable, saved in `ProjectDocument.masterExportSettings`): `format` (`.wav` / `.mp3`), `sampleRate` (44.1 / 48 / 96 kHz; MP3 44.1 / 48 kHz, the MPEG-1 Layer III limit), `wavBitDepth` (16 / 24), `mp3Mode` (`.constant` / `.variable`), `mp3Bitrate` (128 / 192 / 256 / 320 kbps), `mp3VBRQuality` (V0 / V2 / V4). Defaults: WAV, 48 kHz, 24-bit, MP3 constant 320 kbps, V0. `normalize()` pulls values outside the choices back (e.g. MP3 at 96 kHz → 48 kHz); the decoder calls it too.

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
| `rowTopY(for:)`, `trackTopY(for:)`, `trackID(atTimelineY:)` | Row geometry in the `timelineScroll` coordinate space, counted over `visibleRows` (no tracks of closed folders); `trackID` is nil over a folder's row |
| `beginMarquee(at:additive:)`, `updateMarquee(from:to:)`, `endMarquee()` | Marquee selection: selects every clip the rectangle touches (additive keeps the existing selection) |
| `beginTimeSelection`, `updateTimeSelection`, `endTimeSelection` | Range selection (times snap to beats; tracks form a contiguous block) |
| `deleteTimeSelection`, `cropToTimeSelection`, `splitAtTimeSelection` | Range edits (one undo step each) |
| `deleteSelectedClips` | Deletes all selected clips |
| `copySelection`, `cutSelection`, `paste()` | Clipboard. Paste is relative to the playhead and the selected track (tracks beyond the last fold onto it). Track offsets count `visibleTracks`; with the selected track hidden, it starts on the first visible track below it (`pasteBaseIndex(in:)`) |
| `menuTargets`, `selectForMenu`, `splittableMenuTargets` | Right-click targets: the whole selection when the right-clicked clip is part of it, otherwise that clip (selected by `selectForMenu`). `splittableMenuTargets` keeps those the playhead is inside |
| `toggleMuteMenuTargets`, `duplicateMenuTargets`, `splitMenuTargets`, `deleteMenuTargets` | Commands on the right-click targets. Mute mutes all if any is unmuted, otherwise unmutes all; Duplicate copies them as a block whose start lands on the playhead and selects the copies; Split cuts those the playhead is inside and keeps both halves selected. Each is one undo step (except mute) |
| `normalizeClips`, `reverseClips` | Act on the right-clicked clip, or the whole selection if it is part of one. Normalize sets the gain that brings the whole file's peak to 0 dBFS; Reverse writes `Reverse_<track name>_NNN.wav` (`RecordingFileName`), switches the clip to it and swaps the fades |
| `stripSilenceClips` | Finds runs of silence (every channel's sample at or below the silence level) at least the chosen length with `silenceRanges`, makes a `piece(from:to:)` for each part to keep and swaps them in with `AudioTrack.replaceClip(id:with:)` (the silent parts are dropped). Each part with sound is widened into the silence by the fade length on the edges that border a silence, and those edges get the fade (10 ms by default, limited to half the minimum silence length so neighbouring pieces never overlap); edges shared with the original clip keep its fades. Pieces under 20 ms are dropped. The pieces become the selection. The settings are asked by `askStripSilenceSettings` (NSAlert) and kept in UserDefaults as `MyDAW.stripSilenceThresholdDB` (default −72 dB, −144 to 0), `MyDAW.stripSilenceMinimumDuration` (default 1 s) and `MyDAW.stripSilenceFadeMilliseconds` (default 10). The audio files are not changed |
| `beginGroupDrag`, `updateGroupDrag(delta:)`, `endGroupDrag(trackDelta:)` | Moves the selected clips together (never before zero; across tracks only when every clip has a destination, `canMoveSelectedClips(trackDelta:)`; tracks are counted in `visibleTracks`) |
| `layeringClips(for:)` | The clips a lane layers. While clips are dragged to another track, they leave the source's list and go on top of the destination's |
| `duplicateSelectedClipsInPlace` | At the start of an option-drag, leaves copies at the original positions (directly below each original) |

### `TrackFolder.swift` (new in v2.1)
| Type | Contents |
| --- | --- |
| `TrackFolder: ObservableObject` (@MainActor) | `id`, `name`, `color`, `isOpen`, `isMuted`, `isSoloed` (the last three changed only by `ProjectState`). `rowHeight` (28 pt, not scaled by the track height zoom) |
| `ArrangerRow: Identifiable` | A row: `.track(AudioTrack)` / `.folder(TrackFolder)`; `id`, `track`, `folder` |
| `ArrangerLayout` | `headerWidth` (230), `folderIndent` (18, the width of a folder's open/close button), `headerColumnWidth` (248, always, so the timeline's width does not depend on folders) |

### `ProjectState+Folders.swift` (new in v2.1)

An extension of `ProjectState` for the order of tracks and folders.

| API | Contents |
| --- | --- |
| `folders`, `folder(withID:)`, `tracks(in:)` | The folders, lookup, a folder's tracks |
| `visibleRows`, `visibleTracks`, `isTrackVisible(_:)` | Rows and tracks without those of closed folders; the arranger draws only these |
| `rowHeight(_:)` | A row's drawn height (a track's `trackHeight × trackHeightScale`, a folder's `TrackFolder.rowHeight`) |
| `rowsDidChange()` | `rows`' `didSet`: takes any track outside its folder's block (the rows right after the header) out of the folder, and refreshes `tracks` |
| `applyFolderStates()` | Copies each folder's M / S to its tracks' `isMutedByFolder` / `isSoloedByFolder`; true when anything changed |
| `newTrackPlace()` | Where the + menu's track goes: below the current track (in its folder), at the end of a closed folder, or at the end without a current track |
| `addFolder()` | An empty folder above the current track (above its folder when it is in one), named "Folder n" (localized) |
| `addTrack(above:)`, `addFolder(above:)` | From a header's right-click menu: above the clicked row (a track goes first into a clicked folder). No folder above a track inside a folder |
| `duplicateTrack(id:)`, `duplicateFolder(id:)`, `duplicateName(of:taken:)` | From a header's right-click menu. A track is copied right below itself (same folder) and the copy becomes current; a folder is copied with its tracks after its last row. `makeCopy` copies the settings, mixer state, sends, clips (`AudioClip.duplicate`, same files) and plug-ins (new IDs from `newInstance()`; `audioEngine.copyPluginStates` puts the source's current state into `savedPluginStates`, restored when the copy is built). Names get their trailing “ number” raised by one (or “ 2” added), moving on to a number no existing name has |
| `confirmDeleteFolder(id:)`, `deleteFolder(id:)` | After a confirmation saying the tracks stay, removes only the header; its tracks stay in place, out of the folder |
| `toggleFolderOpen(_:)` | Opens / closes; closing clears clip selections inside and any range selection touching them |
| `toggleMute(for:)`, `toggleSolo(for:)` (`TrackFolder`) | A folder's M / S; nothing on an empty folder; the tracks' own values are left alone |
| `moveTrack(id:beforeRowID:folderID:)` | Moves a track before row `beforeRowID` (nil: the end) into folder `folderID` (outside its block `rowsDidChange` takes it out). Clears a range selection; updates levels when what is heard changes |
| `moveFolder(id:beforeRowID:)` | Moves a folder with its tracks; does nothing when the place is inside another folder's block |

---

## 3. Audio, devices and plug-ins (`Sources/Audio`)

### `AudioEngineManager.swift`

The central class (@MainActor, `NSWindowDelegate`) for the AVAudioEngine graph, playback, recording, metronome, meters, plug-in creation and GUIs, and export.

#### Published state (excerpt)
`engine`, `isPlaying`, `isRecording`, `isPunchRecording`, `currentTime` (held by a separate `transportClock` object, `TransportClock`: it changes 60 times a second while playing, and publishing it from the engine redrew every view observing the engine (arranger, mixer, transport). Only `PlayheadLine`, `PlayheadBall`, `TransportTimeText` and the take being recorded (`LiveRecordingClipView`) observe it; auto-scroll receives it with `onReceive`), `bpm`, metronome (enabled, timing offset, volume), `hardwareSampleRate`, `masterVolume` (held by a separate `masterVolumeState`, so a drag does not republish the whole engine; observed only by `MasterFaderColumn`), `masterPeak`, `masterStereoPeak` (both updated only when they change), `recordingsDirectory`, `inputBufferFrameSize`, `manualRecordingCompensationMs`, selected input/output devices. `loadMonitor` (`AudioLoadMonitor`, a separate `ObservableObject` so its updates do not republish the engine).

#### Node layout (per track)
| Dictionary | Role |
| --- | --- |
| `trackRenderers` | One `TrackRenderer` (`AVAudioSourceNode`) per track, feeding bus 0 of the track output mixer; rebuilt when the sample rate changes |
| `trackOutputNodes` | Track output mixer (fader volume, solo, mute). Mute and solo come from `audibility(tracks:fxChannels:)` (using the tracks' `effectiveMuted` / `effectiveSoloed`, which include folders): soloing a track keeps the FX channels it sends to; soloing an FX channel plays only its return (the sending tracks keep feeding their sends, but their splitter → mainMixer connection volume is set to 0 via `setTrackDryAudible`) |
| `trackDownmixNodes` | `MonoDownmixAudioUnit` at the head of every track chain (before the inserts) |
| `trackDryDelayNodes` / `fxReturnDelayNodes` | `DelayCompensationAudioUnit` on each track's dry path (splitter → mainMixer, delay D; mutes the dry sound for an FX solo) and on each FX return (pan → output, delay D − own latency). Set by `updateLatencyCompensation()` |
| `trackPluginNodes` | Inserts (AU / `VST3AudioUnit`) |
| `pluginSwitches` / `pluginEnabledStates` | For every chain plug-in (track, FX and master; keyed by the plug-in node's `ObjectIdentifier`), the capture and output units of `PluginSwitchAudioUnit` around it, and the plug-in's on/off |
| `trackPanNodes` | Pan mixer (after the inserts) |
| `trackSplitterNodes` | Splitter mixer (one-to-many into mainMixer and sends) |
| `trackMeters` | A `RenderPeakMeter` per track. The dry path's `DelayCompensationAudioUnit` records the peak of its input (= the splitter output: post-insert, post-fader, post-pan, before the dry mute) at every render, and the 30 Hz timer reads it with `take()`. Meters used to be taps on the splitters, but after a plug-in insert on an FX channel (UADx Pure Plate Reverb) every track tap could stop being called, and reinstalling it did not help, so taps are no longer used |
| `sendGainNodes` | Per-send gain mixer |
| `inputMonitorNodes` | `InputMonitorAudioUnit` (when I is on) |
| `fxInputNodes` / `fxPluginNodes` / `fxPanNodes` / `fxOutputNodes` | FX channel input (fader volume), inserts, pan and output (meter; volume 0 when muted or soloed out) |
| `masterOutputNode` / `masterPluginNodes` / `masterMeterNode` | Master volume, POST plug-ins, final meter |

#### Main public methods
- **Graph sync**: `syncTracks(_:fxChannels:)` (incremental update of tracks, FX, master, sends and input monitoring), `syncTracks(_:fxChannels:masterPlugins:)`, `syncMasterPlugins`, `syncAfterClipEdit` (during playback, `rescheduleEditedClips` restarts only the clips whose `ClipScheduleSignature` changed plus the clips overlapping them, from the transport position at the restart time; the players of clips that left a track are stopped on all tracks before anything is rescheduled, so a clip moved to a higher track is not stopped after its restart; other clips play on), `updateMixerLevels` (volume, pan, sends, FX), `updateSendLevel`, `setClipMuted`, `setPluginEnabled`.
- **Transport**: `startPlayOrRecord(tracks:fxChannels:recordArmedTracks:)` (starts playback/recording, or stops if running), `stop(tracks:)`, `rewind(tracks:to:)`, `seek(to:)`, `setPunchRange` (ignored during a rollback pass). `recordRollbackDuration` (seconds; set by `toggleTransport`): when recording with armed tracks and no punch range, `beginPlayOrRecord` makes the pass a punch-in at the playhead with punch-out +∞ (`isRollbackPass`) and moves the playhead back by it; `stop` clears that range. `recordingTakePunchIn` / `recordingTakePunchOut`: the punch range of the take being recorded (`recordingTakePunchTrim`), kept until its file is finalized; the lanes draw only the part inside it. `songEndTime`: the playhead timer calls `onReachSongEnd` when it crosses it (only if playback started before it); that stop cuts recorded clips at it and leaves the playhead there.
- **Devices**: `applyAudioDevices(inputDeviceID:outputDeviceID:sampleRate:)` (sets the device sample rate and calls `bindIODevice` when the devices change), `applyInputBufferFrameSize`, `applyAutomaticTimingCompensation`.
- **Plug-ins**: `openPluginUI(pluginID:)`, `isPluginUnavailable`, `capturePluginStates`, `setSavedPluginStates`, `prepareForPluginGraphRestore`, `copyPluginStates(_:)` (copies each source's current state — live instance first, else the saved one — to the copy's ID in `savedPluginStates`, which its instance picks up when built).
- **`pluginWindowIdentifier`** (static, v3.0): the `NSUserInterfaceItemIdentifier` given to every plug-in window, so `MainDAWView`'s monitors can recognise them.
- **Other**: `exportMasterMix(to:startTime:endTime:tracks:fxChannels:progress:)` (renders the master path in real time to a 32-bit float file at the hardware rate, reports the captured fraction, returns the rate), `shutdown()` (stops the engine, releases VST3, restores the macOS default input/output devices), recordings folder helpers.

#### Main internals
| Method | Purpose |
| --- | --- |
| `startMetronome(at:)` | Schedules 256 clicks and schedules the next run from the last one. When the transport starts it uses that start time and position; when switched on during playback, after a BPM change and for each next run it uses the earliest time a player can start without losing its opening (`earliestPlayerStartHostTime`) and the transport position at that time (`transportPosition(atHostTime:)`), aligned to the next beat |
| `setupEngine()` | Reads the input format, builds the master path and final meter (when called again, e.g. for a buffer size change, it keeps the master mixer and final meter and rewires the master plug-in chain with `reconnectPluginChain`), click, input tap, input monitors, raises slice limits, starts the engine |
| `bindIODevice(inputDeviceID:outputDeviceID:)` | Makes the chosen devices the macOS default input and output (AVAudioEngine with input runs on an aggregate of the defaults). Records the original defaults the first time; `restoreOriginalDefaultDevices()` puts them back in `shutdown()` |
| `startMeterTimer` | Collects peaks at 30 Hz and posts them. The master level lives in a separate `masterMeter` (`TrackMeter`) that publishes only on change (observed only by `MasterFaderColumn`); `masterPeak` is an unpublished internal value |
| `checkTrackMeters`, `noteGraphEvent`, `writeMeterRecoveryLog` | Track meter watchdog. On the 30 Hz timer, while playing or recording with the engine running and the master tap advanced within 0.5 s, a track whose `RenderPeakMeter` render count (silence counts too) has not moved for 1 s gets the state and the last 60 engine / graph events (engine stop/start, `AVAudioEngineConfigurationChange`, `setupEngine`, `syncTracks`, splitter rewires and deferrals, …) appended to `~/Library/Logs/MyDAW/MeterRecovery.log` (logging only, once per track per playback; past 1 MB the older part is dropped, keeping about 0.5 MB) |
| `wireSend` | Connects a send's gain mixer to an FX input. `wiredSendTargets` remembers the target so it is rewired only when it changes (rewiring every sync throws `mixingDest` while input monitoring is on) |
| `applyDeferredRewiresWhenQuiet` | On stop, performs the deferred fan-out rewiring and input monitor connection once the master output is below -60 dB (at most 8 s). While waiting, `isWaitingForQuietRewire` is set and `syncTracks` leaves the rewiring to it. Gives up if the transport starts, retrying on the next stop |
| Stop-time recording finalisation (task in `stop`) | Finalises writers and loads the clips; calls `syncTracks` only when files were recorded |
| `installAudioUnits` / `installFXAudioUnits` / `installMasterAudioUnits` | Creates plug-ins asynchronously and chains them in insert order; for VST3 creates a `VST3AudioUnit` and binds the instance |
| `connectTrackChainTail` | Wires chain end → pan → splitter → mainMixer + sends. One-to-many connections are made **only with the engine stopped** (deferred via `pendingSplitterRewires` while playing) |
| `connectChainPlugin` / `chainOutput` / `updatePluginSwitch` / `detachPluginSwitch` | Wire previous → capture → plug-in → output (returns the output unit, the next plug-in's source); the node that carries a plug-in's output; pass on/off and latency (`auAudioUnit.latency` × sample rate) to the switch (and clear the plug-in's own bypass); remove the pair with its plug-in (also from `safeDetach`). `setAUBypass` drives the switch once the pair exists, and the plug-in's own bypass until then |
| `connectReformatting` | If an AU at either end has allocated render resources and the format changes, releases them before connecting (avoids the -10865 exception). Before connecting, checks the AUs at both ends with `acceptsChainFormat` and does not connect if one refuses |
| `acceptsChainFormat` | Tries the chain format on the AU's input and output bus 0 with `AUAudioUnitBus.setFormat` (always when render resources are not allocated, otherwise only when the format differs). A refusal comes back as an error, so it returns false (left to `engine.connect`, it is an uncatchable ObjC exception that aborts the app — e.g. the mono-only Waves "AudioTrack(m)" on the stereo chain). `installAudioUnits` / `installFXAudioUnits` / `installMasterAudioUnits` check each new AU with it; a refused AU is marked with `markPluginUnavailable` and left out of the chain, as when instantiation fails. `nonisolated` (the FX path calls it on the instantiation callback's thread) |
| `setMixerVolume` | `reset()`s the mixer after a volume change (a silent input does not advance the ramp) |
| Playback plans in `syncTracks` | Builds `TrackPlaybackPlan.make(for:)` per track (unmuted clips whose files exist, their `ClipLayering.segments` minus hidden parts, and the `spans`) and hands it over with `setPlan`; nothing restarts, even while playing. `setClipMuted` rebuilds the plan too |
| `startPlayback` | Calls `prepare(renderFrom:)` on every renderer, waits until the blocks at the start position are read (a few ms for 24 tracks, at most 2 s), picks the start (`nextTransportStartTime`, plus room for the metronome's two `play(at:)` calls), runs `beforePlayersStart` (recording, metronome) and then `start(anchorHost:anchorFrame:)` on each renderer, with anchorFrame = start position + that track's pre-roll (own insert latency + D). No `play(at:)`, so nothing holds the engine lock for long and the main thread never waits on it. `stopRenderers` stops them and logs render cycles that found no audio read ahead |
| `processInputAudioBuffer` | Input tap: peaks, sample-accurate trim via host time, per-track channel extraction and writing |
| `startRecording` / `stop` | Writer creation, muting the recording tracks' clips, whole-pass punch recording → `trimToPunchRange` on stop (adds 10 ms fades) |
| `updatePunchRecordingState` | 30 Hz timer: detects entering/leaving the punch range and mutes existing clips only inside it |
| `applyInputMonitoringIfNeeded` / `connectInputMonitors` | Connects inputNode → `InputMonitorAudioUnit` → track output according to I buttons (engine stopped) |
| `raiseMaximumFramesPerSlice` | Raises the I/O units' slice limit to 4096 (propagates to every node) |
| `releaseVST3Instances` | On quit: closes editors, detaches wrappers, destroys VST3 instances |
| `observeChannelNames` / `setChannelName` (v3.0) | On each `syncTracks`, subscribes (Combine) to every track's and FX channel's `$name` and `$plugins` and sets `auAudioUnit.contextName` of their plug-ins to the channel name; `syncMasterPlugins` sets "MASTER". The names are kept in `pluginChannelNames` and applied again in `replacePluginAudioUnit` |
| `configurePluginWindow` | Every plug-in window: delegate, `pluginWindowIdentifier`, `.floating` level, `hidesOnDeactivate`, `.moveToActiveSpace` |
| Plug-in GUI helpers | `requestOriginalPluginUI`, `presentPluginViewController` (window matches the view size and follows later resizes), `presentGenericPluginView`, `openVST3PluginUI` |
| `windowShouldClose` | An AU plug-in window's close button (and ⌘W) only hides the window with `orderOut` and keeps it in `pluginWindows`; the next `openPluginUI` shows that window again (moving the cached view controller into a new window at every open left Waves WaveShell and similar views blank after a few times). VST3 windows still close, and `windowWillClose` detaches the editor. A `window.close()` from the host (plug-in removed, project closed) does not go through this. `replacePluginAudioUnit` reopens only a visible window with the new AU |

#### Threads and locks
`captureLock` (recording config, writers), `recordingTimingLock` (start time), `peakLock` (peaks). The tap and timers exchange values with the main thread through these.

### `ExportEncoder.swift` (new in v2.2)
Converts the real-time capture into the exported file, off the main thread (`encode(source:to:settings:progress:)`, checks `Task.isCancelled` per chunk).
- Reads the capture in 32,768-frame chunks. When the export rate differs from the capture rate, `AVAudioConverter` resamples (quality max, `AVSampleRateConverterAlgorithm_Mastering`).
- **WAV**: 24-bit is written from float by `AVAudioFile`. 16-bit is quantized here: TPDF dither of ±1 LSB (two xorshift32 uniforms), rounded and clipped to Int16.
- **MP3**: LAME (`libmp3lame.0.dylib` in `Contents/Frameworks`, loaded with `dlopen`/`dlsym` on first use, so the LGPL library stays replaceable and the app runs without it; `isMP3Available` then is false and the dialog disables MP3). Joint stereo, `lame_set_quality(2)`; constant: `lame_set_brate`; VBR: `vbr_mtrh` with `lame_set_VBR_q` 0 / 2 / 4. Encodes with `lame_encode_buffer_ieee_float`, flushes, then writes `lame_get_lametag_frame` (Xing/LAME header with length and encoder delay) over the first frame. No ID3 tag.

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
- **`TrackRenderer`**: owns one `AVAudioSourceNode` (its render closure holds the renderer weakly and plays silence once it is gone, since the engine may call it once more after a detach). The render thread only copies its frames out of blocks read ahead (4,096 frames × 48 slots, about 4 s). The timeline position comes from the pair "`anchorFrame` is heard at `anchorHost`", converted to a sample time on the first cycle. Each slot is guarded by a sequence number (odd while written): the render thread never waits and never plays a torn block (it plays silence and counts `underruns`). The recording mute ramps over about 5 ms.
- **`TrackStreamer`**: one background thread that serves every renderer in turn (up to 4 blocks each per round). It reads the blocks ahead of the playhead from the files per the plan, applies gain, fades and crossfades (`ClipLayering.Envelope`) and mixes them. A new plan re-reads the blocks from two past the playhead on (the next one is not rewritten). Only files used within the look-ahead stay open.
- **`ClipReader`**: reads a file as stereo at the output rate; files at another rate are converted continuously with `AVAudioConverter`.
- **Atomics**: Swift's Atomics need macOS 15, so `MyDAWAtomicLoad64` / `MyDAWAtomicStore64` / `MyDAWMemoryFence` in `VST3Host/RealtimeAtomics.cpp` are called through `@_silgen_name`.

### `DelayCompensationAudioUnit.swift` (new in v1.8)
`StereoDelayLine` (render-thread ring buffer; a delay it cannot hold passes through) and an in-app AUv3 (`aufx`/`dlcp`/`MyDW`) with `delayFrames`, `isMuted` (about 5 ms ramp) and `meter`. `RenderPeakMeter` records the input peak and render count on a track's dry path (the render thread hands them over only when `os_unfair_lock_trylock` succeeds and otherwise keeps them for the next cycle, so it never waits). Holds up to one second; reports no latency. `VST3AudioUnit` also uses `StereoDelayLine` so its bypass output is delayed by the plug-in's latency.

`AudioEngineManager.updateLatencyCompensation()` sums each chain's `auAudioUnit.latency` (plug-ins that are off included; while off, `PluginSwitchAudioUnit` delays their pass-through by the same amount), sets D = largest FX channel latency, sets the delay nodes, keeps a `kAudioUnitProperty_Latency` listener on every plug-in, and moves every renderer's `anchorFrame` if anything changed while playing (`updateRendererAnchors`). `transportPreRoll` P = D + the largest track insert latency. The transport starts P after the earliest safe time (two IO buffers after `lastRenderTime`, at least 50 ms), and each track's renderer plays its own pre-roll (its latency + D) early, so nothing after the start position is lost. Recording arms its take files and input capture in `beforePlayersStart`, once the start time is known and before the renderers start. `exportMasterMix` waits until the engine renders, starts the transport the same way and keeps, through `ExportWindow`, exactly the tap frames from the host time at which the start is heard (+ master plug-in latency) for `end − start` seconds; it throws if the range was not fully captured.

### `PluginSwitchAudioUnit.swift` (new in v3.0)
A pair of in-app AUv3s that turn each chain plug-in on and off without relying on the plug-in's own bypass (capture `aufx`/`pscc`/`MyDW`, output `aufx`/`pswo`/`MyDW`; one class, behaviour set by `role`). The two share a `PluginSwitchKernel`.
- **Capture** (before the plug-in): passes its input through and records it in a ring buffer (1 s plus one render).
- **Output** (after the plug-in): when `isEnabled`, passes its input (the plug-in's output); when off, plays the input recorded in the same render, delayed by `latencyFrames`. Switching crossfades over 10 ms. A plug-in pulls the same frame count from its source, so capture and output stay aligned.
- Only a flag changes, nothing is rewired, so it switches during playback. A plug-in that is off is not bypassed and keeps running (no CPU saving).
- Why: Relab LX480 Essentials, bypassed, plays its left input on both sides, which made the plug-ins before it in the chain (MyReverb) mono.

### `ObjCExceptionCatcher.swift` (new in v3.0)
AVAudioEngine raises an ObjC exception when given a node or format it cannot connect; Swift cannot catch it, so the app ended. `ObjCExceptionCatcher.run { … }` calls `MyDAWCatchObjCException` in the native library (`VST3Host/ObjCExceptionCatcher.mm`, `@try` / `@catch`) through `@_silgen_name` and returns "name: reason" when the body raised. `value(_:_:)` is the variant for a call with a result (a fallback when it raised). What the interrupted closure retained is leaked, so `withoutActuallyEscaping` is not used.

Every graph call in `AudioEngineManager` goes through it: `engineConnect` (three forms), `engineDisconnectOutput` / `engineDisconnectInput`, `engineAttach` / `engineDetach`, `engineOutputPoints` (empty when it raised) and `installTapGuarded`. `guardedEngineCall` logs a failure with `print` and `noteGraphEvent` and carries on.

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
- **`TrackPluginDescriptor`**: ID, name, kind (AU/VST3), bundle path, VST3 UID, AU component description, enabled flag, UI compatibility. `isInstalled` tells whether the plug-in is on this Mac (an AU is registered according to `AudioComponentFindNext`; a VST3 bundle exists at its saved path); the tooltip of an unavailable insert uses it to tell "not found" from "cannot be used".
- **`discoverAvailablePlugins(onLog:completion:)`**: discovers AUs (`AudioComponentFindNext`) and VST3s in the background. **VST3s with a same-named AU are excluded.** MyDAW's own internal AUs (manufacturer code `MyDW`: Mono Downmix, VST3 Host, Delay Compensation, Input Monitor) are left out of the list. The built-in effects (manufacturer `MyDA`) are listed like any AU.
- **VST3 discovery**: `scanVST3Bundle` → checks the cache (path + modification date) → otherwise `runScanChild` (`MyDAW --scan-vst3 <path>`, 60 s timeout; a crashed scan caches an empty result).
- **`runVST3ScanChildIfRequested()`**: the child side (enumerates and prints JSON prefixed with `MYDAW_VST3_SCAN_RESULT:`).

### `BuiltInPlugins.swift` (new in v3.0)
- **`BuiltInPlugins.manufacturer`**: `'MyDA'`, the manufacturer code of the built-in effects ("MyDAW: MyReverb" etc.). Saved in projects; must not change, and must not be `'MyDW'` (hidden by `PluginManager`).
- **`BuiltInPlugins.registration`**: a lazily run static that calls `MyPlugInCatalog.registerAll(manufacturer:vendorName: "MyDAW")` once, registering every effect of `MyPlugInCatalog.plugIns` in-process with `AUAudioUnit.registerSubclass`.

### `Sources/BuiltIn/MyPlugIn/` (new in v3.0)
A copy of `../MyPlugIn/Sources` made by `scripts/sync-myplugin.sh` (Swift files only; the folder is deleted and rewritten on every sync). Do not edit it here; its own specification is in MyPlugIn (`Docs/My*.md`).
- **`MyPlugInCore`**: `MyFXAudioUnit` (the shared `AUAudioUnit` base: parameters, state, latency, editor), `MyFXParameter`, `MyFXExtensionViewController` (principal class for MyPlugIn's AUv3 app extensions; not used in-process by MyDAW), the shared editor (`MyFXEditor`: `MyFXEditorViewController` hosts the SwiftUI editor in an `NSHostingView`; header with the channel name from `contextName`, IN / OUT meters, faders, knobs, `MyFXEditableValue`), rendering helpers.
- **Effects**: `MyReverb`, `MyDelay`, `MyChorusPan`, `MyChannelStrip`, `MyMaximizer` — each an `…AudioUnit`, its kernel (DSP), parameters and editor. MyReverb's parameters are HPF, LPF, RT, PD, MIX and WIDTH (addresses 0 to 5; WIDTH was added later, and saved states without it load at 100 %). MyChorusPan keeps each mode's parameters in its own block of ten (Chorus Pedal 10–, Dimension 20–, Flanger Pedal 30–, Auto Pan 40–; 0 is the mode); its kernel is `ChorusPanKernel`, the LFO `ChorusPanLFO`, and the editor has INIT, the button row and the SPEED lamp (`ChorusPanLampModel` reads the kernel's LFO phase at 60 Hz).
- **`MyPlugInCatalog`**: `plugIns` (the effects in menu order) and `registerAll(manufacturer:vendorName:)`. Effects are imported with `#if canImport(…)`, so the same file builds in MyPlugIn's package and in MyDAW's single module.

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
Stacks the transport, arranger, mixer and status bar (device, `AudioLoadIndicator`, recordings folder, shortcut hints). The open project's name (`ProjectState.openProjectName`) is overlaid in the middle of the title-bar strip (the standard title is hidden by `.hiddenTitleBar`), with the strip height taken as the content's distance from the window top (`frame(in: .global).minY`) and the text shifted up by it; clicks pass through (`safeAreaInsets.top` of a GeometryReader that ignores the safe area reads 0 here, so it cannot be used). The window title (`navigationTitle`) becomes “MyDAW - <name>” for the Window menu and Mission Control (plug-in windows are told apart by the “MyDAW” prefix). `currentProjectURL` is `@Published` so the name updates. Contains the startup log (plug-in discovery progress; removed from the view hierarchy once done), the master export dialog, the close-window confirmation and key handling (`SpacebarHandler`: ⌘Z / ⇧⌘Z / ⌘Y, ← to rewind, R to record (`toggleTransport(recordArmedTracks: true)`, like the record button; key repeats ignored), ⌘X / ⌘C / ⌘V / ⌘A as `EditCommand`s, Esc clears the selection and is passed on; nothing is handled while typing in a text field).
- **`MasterExportDialog`**: file name field (the extension follows the format), folder with **Change…**, format, sample rate (MP3: 44.1 / 48 only), then bit depth (WAV) or mode with bitrate / VBR quality (MP3), start / end seconds, and a progress bar for the two stages. Changing a setting normalizes it (`ExportSettings.normalize`) and clears the “completed” state. MP3 is disabled when `ExportEncoder.isMP3Available` is false.
- **Minimum size**: the outer frame is only `.frame(minWidth: 800)`, with no height floor (one would hide the content's minimum height, letting the window get shorter than its content and cut off the transport and mixer). The window's minimum height is the transport + the arranger's minimum (`minimumArrangerHeight` = 180 pt) + the mixer + the status bar.
- **Arranger height**: `arrangerHeight` is read and handed to `MixerView` as `growthLimit` (the room left before the arranger reaches its minimum).
- **`TitleBarZoomHandler`** sits in the background (`WindowCloseHandler.swift`).
- **`SpacebarHandler`** (background `NSViewRepresentable`) installs the app-wide local monitors. `keyDown`: ⌘Z / ⇧⌘Z / ⌘Y, ⌘X / ⌘C / ⌘V / ⌘A, R (record), ← (rewind), Esc (clear selection, passed on), and Space in plug-in windows (`pluginWindowIdentifier`; the main window uses the play button's `keyboardShortcut`). Keys pass through while an editable `NSTextView` / `NSTextField` is first responder (`isEditingText`). `leftMouseDown`: first `FirstMouse.enable(for:in:)` for the main window (the representable's own window) and plug-in windows, then clears the first responder when the click lands outside it.
- **`FirstMouse`** (v3.0): when the window is not key or the app is inactive, hit-tests the clicked view inside the content view and, if it declines `acceptsFirstMouse`, replaces that method on its class (`object_getClass`) with one returning true (`class_replaceMethod`, once per class), before AppKit dispatches the click.
- **`refreshToolTips()`**: when a project opens or the startup log goes away, widens the main window by 1 pt and back so tooltip areas are re-registered (SwiftUI does not do so when only an overlay disappears).

### `ProjectSelectionView.swift`
Launch screen: New Project (save panel) and Open Project (⌘O, choose a `.mydaw`); shows the version. Below the buttons, the Recent Projects list (`RecentProjects.shared`, scrollable, 520 × 240 pt): each `RecentProjectRow` shows the name as an orange link (underlined with a pointing-hand cursor on hover, path as tooltip; click → `onOpenRecent`) and the last-saved date and time. Missing files are struck through and not clickable. Context menu: Remove from List.

### `AudioLoadIndicator.swift` (new in v1.8)
Status bar item “CPU [bar] 34% ● Dropout” observing `AudioLoadMonitor` (only this view redraws, at most 10 Hz). The bar (64 × 7 pt capsule, 0.1 s linear animation) is coloured by interpolating green (0) → yellow (0.6) → orange (0.8) → red (1.0); the percentage can exceed 100. The dropout mark keeps its space while hidden (opacity), so the bar does not shift. The tooltip is an AppKit tooltip (`DynamicToolTip`, `NSViewToolTipOwner`) whose text is built when shown, so the frequent redraws do not keep it from appearing.

### `TransportBarView.swift`
- Buttons (left to right): Settings, Undo, Redo, Rewind, Play/Pause (Space), Record (records armed tracks; R key), P (enable punch), rollback (↺ with the bar count; toggles `recordRollbackEnabled`, dimmed while punch is on, disabled while playing; help text from `rollbackHelp`), Metronome (can be switched while playing or recording; a right-click (`RightClickCatcher`, a local event monitor) pops up `ClickVolumeFader`, a vertical fader that changes `metronomeVolume` at once, also while playing), Save, Open, Snap, Auto-scroll (`ProjectState.autoScrollEnabled`, kept in UserDefaults `MyDAW.autoScroll`). Tooltips use the standard `.help`.
- Displays: TIME (time or bars/beats), TEMPO (BPM entry 20–400), FORMAT (24-bit WAV and sample rate); the panel is as wide as its contents.
- The bar is left-aligned; when the window is narrower, the right end is cut off (`frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)` plus `clipped()`).
- Right side: timeline zoom, track height scale, waveform vertical scale, ruler toggle (the master volume slider was removed in v2.1; the master volume is the mixer's MASTER fader).
- **`BufferSettingsView`** (gear, titled “Settings”; takes `projectState` too): sections separated by `Divider`s, each with a `sectionHeader` and captions from `note` — Environment (language, `AppLanguage`), Audio (recordings folder, input/output device, sample rate 44.1–96 kHz, buffer size), Compensation (recording latency (optional), click timing), Other (click volume, rollback when recording in bars; `commitRollbackBars` clamps to 1–16 on Return or Apply). When a language, device or sample-rate change is applied it calls `onAudioDevicesChanged` to offer a restart.

### `ArrangerView.swift`
Track headers and lanes (`visibleRows`; a folder's row is a `FolderHeaderView` and an empty `FolderLaneView`; tracks in folders are shifted right by `folderIndent` with a folder-coloured `FolderIndentGuide` on their left), the ruler (seconds or bars/beats; click to seek), playhead, punch range (drag the left/right handles on the ruler in beat steps), the + menu (Add Track / Add Folder), auto-scroll (only when `autoScrollEnabled` is on; moves on when the playhead enters the right 10%), Delete key, and drawing of the marquee rectangle and range-selection band.
- **Header tooltips (`TrackRowsPointer`, `trackRowHelp`)**: SwiftUI shows the `.help` of a header scrolled out under the mixer while the pointer is over the mixer. The track rows' scroll view sets `TrackRowsPointer.isInside` from `onHover` and passes it in the `trackRowsPointer` environment value; `TrackHeaderView` / `FolderHeaderView` attach their tooltips with `.trackRowHelp`, which gives them only while the pointer is inside the rows (an empty string otherwise). `TrackRowsPointer` is an `ObservableObject` held in `@State`, so entering and leaving updates only the tooltips, not the whole arranger.
- **Coordinate space `timelineScroll`**: set on the lanes' ZStack. `trackTopY`, `trackID(atTimelineY:)`, the marquee, range selection and clip drags are measured in it.
- **Clip drag display**: `clipDragPreviews` draws every clip in `clipDragPreview` from its own track, moved by the vertical travel (waveform and fades as layered in the destination).
- **Reordering tracks and folders**: the lane area reaches down to the bottom of the view, so a lane dragged below the last track is not clipped. A `DragGesture` on each header (`reorderGesture`, 4 pt minimum, in the header column's coordinate space `trackHeaderColumn`). A dragged folder takes its tracks along (`reorderMovingIDs`). `reorderDropTarget()` finds the drop place (`RowDropTarget`: row to go before, folder to go into, line height, indent, closed folder): the gap between the other rows nearest the pointer. A track goes into a folder when the row below is one of its tracks; right below an open folder's header or last track it goes inside while the pointer is still over that row and outside once it is over the row below; over the middle half of a closed folder's header it goes to that folder's end. A folder lands only where the row below is a folder, a track outside folders, or the end. `dropIndicator` draws the white line (indented for inside a folder) or the closed folder's outline. `ReorderLift` frames the dragged rows, adds a shadow and brings them to the front. On release `moveTrack` / `moveFolder` runs inside an animation.
- **Header right-click menu** (`headerMenu(for:)`): an `NSMenu` opened through `LaneMenuMonitor`. A track becomes current. Add Track (`addTrack(above:)`), Add Folder (not for a track inside a folder), a separator, Duplicate Track / Duplicate Folder (`canDuplicateRows`: disabled while playing or recording), a separator, Show in Mixer (sends the row ID to `mixerScrollRequests`).
- **Horizontal scrolling**: a `timelineScrollTime` change scrolls the tracks' `NSClipView` directly through `setTrackScrollOffset` (`followScrollTime`; skipped when the clip view is already at the offset, compared in points since after a zoom the same time is a different offset), and again on the next main-queue turn after the new layout (`scrollTo` can take the position from an outdated layout). After a zoom the content widens only some layout passes later and clamps the scroll short of its target, so `ScrollOffsetObserver` also watches the document view's frame and the pending offset is applied again whenever it resizes; if it is still not reached after 0.5 s, `timelineScrollTime` takes the tracks' real position. `ScrollOffsetObserver` feeds the user's own scrolling back into `timelineScrollTime` and reports every offset to `TimelineScrollPosition.trackOffset`.
- **Ruler position**: the ruler is offset by the tracks' real scroll offset (`TimelineScrollOffset` uses `trackOffset`, falling back to `time × pixelsPerSecond`), so the ball and the playhead line agree even while a zoom has the tracks clamped for a moment.
- **Timeline length and width**: `songLength()` = the largest of 60 s, the last clip's end + 5 s and the end flag + 5 s; ruler clicks and playing on do not lengthen it. `timelineWidth(viewportWidth:)` = the larger of the visible width and (the largest of the song length, `parkedPlayheadTime` and `playheadExtentTime`) × pixels per second. `playheadExtentTime` is raised only while playing or recording, to a screen + 30 s past the playhead (auto-scroll needs a screen of content ahead), and cleared on stop; `parkedPlayheadTime` keeps a stopped playhead left past the song's end (0 otherwise; updated from the clock, so a rewind narrows the timeline again). `pastSongShade` darkens the ruler and lanes past the song's end (black at 28%, no hit testing).
- **`KnobOnlySlider`**: the horizontal scroll bar at the bottom. It moves only when its knob (●) is dragged; clicks elsewhere are ignored.
- **`ArrangerWheelMonitor`**: a local event monitor for scroll-wheel and pinch events over the whole arranger (ruler included). A wheel over the ruler and a pinch zoom horizontally around the pointer; ⌥+wheel sets track height (around the pointer); ⌥⇧+wheel sets waveform height (also when shift turns the wheel into horizontal scrolling). Handled events are not passed to the scroll views.

### `TrackHeaderView.swift`
Width `ArrangerLayout.headerWidth`. Colour bar on the left (click for `TrackColorPalette`: 16 presets + custom; also used by folders and the mixer's lines), name (double-click to edit; the current track's is reversed, black on white, except while editing), mono/stereo toggle (1/2), delete, R / M / S / I (M / S faces are `HeaderToggleLabel`: lit grey and disabled while the folder holds them), input channel menu, meter (input while armed, output otherwise), drag the bottom edge to change height (`VerticalResizeHandle`: measured in screen space and divided by the scale into `trackHeight`; the drawn height stays at least `minimumRowHeight`, 56 pt). The content is top-aligned; in a short row the meter and below hide behind the opaque bottom strip. Dragging anywhere else reorders the track (the gesture is attached by `ArrangerView`).

### `FolderHeaderView.swift` (new in v2.1)
A folder's row (230 pt wide, fixed height `TrackFolder.rowHeight`): colour bar on the left (`TrackColorPalette`), ▼ / ▶ (`toggleFolderOpen`, `folderIndent` wide), folder icon, name (double-click to edit), M / S (`HeaderToggleLabel`, disabled on an empty folder), ✕ (`confirmDeleteFolder`). The background is tinted with the folder's colour. Clicking it does not make it current; `ArrangerView` attaches dragging and the right-click menu.

### `WaveformLaneView.swift`
One track lane.
- **Lane**: dragging over empty space draws a marquee (⌘ for a range selection); a click clears the selection; WAV files can be dropped from Finder.
- **`AudioClipView`**: click (⇧/⌘ to add or remove), drag to move the selected clips together (⌥ to duplicate, ⌘ for a range selection), left/right trim (the left edge stops at the file's first sample: the clip start is the initial start plus the clamped delta, so the clip never moves), gain (top centre), fade in/out (top-left / top-right), fade curve (the diamond in the middle of a fade line; vertical drag via `FadeCurve.withMidpoint`, double-click for `.auto`). Gain, fade and curve handles start dragging on mouse-down and show their value in an `EditValueTooltip`. Trim handles are not drawn: a clear 10 pt strip at each clip edge takes the drag and sets the pointer to a one-way arrow (right at the start, left at the end). A fade dot takes clicks only in a 16 pt square centred on it and sets the pointer to a pointing hand, as does the curve diamond; the gain bar takes clicks in 24×13 pt and shows an up-down arrow (`hoverCursor` at the end of the file, `pointerStyle` (`.columnResize(directions: .trailing / .leading)` / `.link` / `.rowResize`) on macOS 15 and later, `NSCursor.set()` (`resizeRight` / `resizeLeft` / `pointingHand` / `resizeUpDown`) on every `onContinuousHover` move before that; a cursor pushed from `onHover` is reset to the arrow at once by the hosting view).
- **Context menu**: `LaneMenuMonitor` (a local monitor for right-clicks and Control-clicks; it and `ClosureMenuItem` also serve the track header menu) builds an AppKit `NSMenu` at the click (a SwiftUI menu is built beforehand and cannot reflect a selection made by the click). Inside the selected range it shows the range menu; on a clip it selects the clip with `selectForMenu` and shows the clip menu; elsewhere Cut / Copy / Paste (`LaneMenu`). Clip menu: file name with format and size (`fileDescription()`, e.g. `Guitar_001.wav, mono 24bit 7.8MB`; just the name when the file is missing or unreadable) or the count, Cut / Copy / Paste, Normalize, Reverse, Strip Silence, choose file (single clip only), mute, duplicate, split, delete; with several clips the items show the count.
- **Display**: waveforms are drawn at the `ClipLayering.envelope` level; only parts fully hidden by upper clips are darkened. Fade handles at covered edges are hidden.

### `PreviewStretch.swift` (new in v2.0)
**Zoom and track height**: the ruler, headers and clip boxes follow the new value at once, but each waveform stays drawn at `ProjectState.waveformRenderPixelsPerSecond` / `waveformRenderTrackHeightScale` (the scale waveforms are drawn at) and is stretched to its box with `scaleEffect`. `WaveformCanvas` is `Equatable` (`.equatable()`, with the value-type `ClipLayering.Envelope`), so it is not redrawn while its inputs stay the same. A tenth of a second after the change stops, `syncWaveformRender` brings the drawing scale up to date and the waveforms are drawn properly (the `drawWindow` is re-centred then too); an opened project syncs at once. While the two scales differ (during a change), `AudioClipView` leaves out the trim, gain, fade and curve handles, so the several views each one adds are not moved on every step for every clip; the lane grid lines are drawn only inside the `drawWindow` too. What `ArrangerView` keeps to follow the scroll position (the last scroll time read, the offset being scrolled to) lives in a plain `ScrollFollow` object, not `@State`: it is written on every zoom step, and as state each write rebuilt the whole arranger once more. **Waveform scale** (slider, ⌥⇧ + wheel) calls `previewWaveformVerticalScale`: while the control moves the value stays, only `waveformScalePreview.scale` changes and the drawn waveforms are stretched by `VerticalStretch` (from their centre); a tenth of a second after it stops, `commitPreviews` sets the real value.

**Track height anchor**: `ArrangerView.zoomTrackHeight` records an anchor as a row and a fraction of that row's height before the scale changes, then scrolls the vertical `NSScrollView` so that point stays at the same height on screen. The slider goes through `ProjectState.zoomTrackHeightAroundCurrentTrack` (a closure the arranger registers) and anchors on the middle of the current track; ⌥ + wheel anchors on the pointer. While the taller content is not laid out yet and the offset is clamped, `VerticalScrollObserver` applies it again when the content resizes. With no visible current track, the top stays in place as before.

### `WaveformCanvas.swift`
Draws the waveform with SwiftUI `Canvas` (per channel, gain scaling, amplitude from `envelope`) as one filled bar per point-wide column, from the lowest to the highest sample in it (at least 1 pt thick, around the value). The source depends on how many samples a column covers: the coarse peaks while a coarse peak fits in a column; the fine peaks when zoomed in past that (about 94 px/s at 48 kHz); and, past the fine level (about 750 px/s), the raw samples of the visible part (`WaveformCache.requestSamples`; the previous sample is included so neighbouring columns join; the fine peaks are drawn until the samples arrive). It draws only inside `drawWindow` (`ProjectState.waveformDrawWindow`, a `DrawWindowState`: the visible range and two screens either side, moved by `ProjectState.refreshDrawWindow` only when the view comes within half a screen of its edge or the waveforms' drawing zoom or the viewport width changes), so a zoom or height change redraws a few screens rather than the whole song, and scrolling rarely redraws at all. `WaveformLaneView` does not build the views of clips outside it (selected clips and the take being recorded excepted).
- **`FadeLinesOverlay`**: draws the fade-in / fade-out lines across the clip's full height in the shape of their curves (one line even for stereo).

### `MixerView.swift`
Studio One-style mixer.
- **Overall**: ▼ / ▲ on the title bar folds and unfolds the mixer (`isCollapsed`, UserDefaults `mixer.collapsed`; folded it is only the 23 pt title bar). "Show in Mixer" (`mixerScrollRequests`) scrolls that row's ID to the left edge with a `ScrollViewReader` (unfolding first, then via `pendingScrollID` once shown). The strips come from `mixerItems` (from `rows`; closed folders hide nothing), with a `FolderEdgeLine` where each folder starts and an `FXEdgeLine` before the first FX channel (both `MixerEdgeLine`: a 6 pt coloured line; clicking opens `TrackColorPalette`; the FX line's colour is set on every FX channel). Drag the top edge to resize (from the height that keeps 220 pt between the SEND/fader divider and the bottom edge, up to 1000 pt, and never more than the `growthLimit` at the start of the drag, so the arranger keeps 180 pt; the edge is an AppKit `VerticalResizeHandle`, so cursor and drag area always match), horizontally scrolling track/FX strips, MASTER pinned on the right, right-click for Add FX.
- **`StripSections`**: INSERT / SEND / controls sections (headings via `SectionHeader`, localised through `LocalizedStringKey`) with draggable dividers (shared by all strips, stored in UserDefaults).
- **`PluginRow` / `PluginNameButton`**: one insert row. A plug-in for which `isPluginUnavailable` is true has a red name and the tooltip "(`menuDisplayName`)-This plug-in cannot be used" (when `isInstalled`) or "…-This plug-in was not found". A red row opens no GUI on a click and takes no drop (its handlers refuse them; `allowsHitTesting` stays on so the tooltip shows). A name is dragged as its plug-in ID (text); a drop on a name calls `onDropPlugin` (→ `dropPlugin(_:before:on:)`), and the INSERT list area of every strip is also a `pluginDropTarget` that appends (`before: nil`). Drops are refused while playing or recording.
- **`TrackStripView`**: also observes `audioEngine`, so an insert turns red as soon as it is marked unavailable. INSERT (+ menu, green dot on/off, click name for GUI, drag to reorder or onto another strip to copy, × to remove), SEND (level bar and dB value per FX), pan, M/S (lit grey and disabled while the folder holds them), fader value, scale / fader / stereo meter, name (click to select; the current track's is black on white through `StripFooter`'s `isCurrent`).
- **Grouped operation (`ProjectState+MixerGroup.swift`)**: a click on a channel outside its controls goes to `clickMixerChannel` (plain: makes it current and empties `mixerGroupTrackIDs`; ⇧/⌘: adds or removes it). Changing `selectedTrackId` empties `mixerGroupTrackIDs`. Targets (`isMixerTarget`: the current track plus the added ones) get the lighter background; only the current name is reversed. Fader, pan and sends go through `setMixerVolume` / `setMixerPan` / `setMixerSend`: the first change records every target's starting value in a `MixerGroupEdit`, and the operated channel's change from its start (in dB with -∞ as -96 dB; pan as a plain difference) is added to the others' starting values, so a channel stopped at a limit gets its offset back on the way back. Another target at -∞ moves only when the operated one also started at -∞. `endMixerGroupEdit` follows a drag, a ⌥-click or a typed value. M/S (`toggleMixerMute` / `toggleMixerSolo`) give the others the same state (except ones held by their folder). Inserts are never grouped. The fader, pan and send bars use `DragGesture(minimumDistance: 0)` and the value labels an empty single tap, so their clicks never reach the channel's selection.
- **`FXStripView`**: INSERT, (an empty SEND section kept only for alignment), pan, "FX" label, fader, name (double-click to rename). Its context menu has Add FX and Remove (channel name) (removal goes through the `confirmRemoveFXChannel` confirmation dialog) (it overrides the mixer-wide menu on the strip, so Add FX is repeated there).
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
