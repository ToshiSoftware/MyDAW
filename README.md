# MyDAW — Professinal Audio Workstation for Mac (Apple Silicon)

**Version 3.0** · [日本語版 README](README_jp.md)

MyDAW is a multitrack audio recording, editing and mixing DAW (Digital Audio Workstation) for Apple Silicon Macs. It is built on Core Audio (AVAudioEngine / Core Audio HAL) and hosts both Audio Unit and VST3 effects.

[NOTE]
This project was automatically generated using AI (Copilot, Antigravity). Please refer to the article below for details.

* [Japanese, original] https://note.com/tokada375/n/n8582557559d5
* [English, translated] https://note.com/tokada375/n/n8582557559d5?hl=en

---

## Documentation

| Document | Contents |
| --- | --- |
| [OperationManual_en.pdf](OperationManual_en.pdf) / [OperationManual_jp.pdf](OperationManual_jp.pdf) | User manual for first-time users |
| [docs/PROJECT_ANALYSIS_en.md](docs/PROJECT_ANALYSIS_en.md) / [_jp](docs/PROJECT_ANALYSIS_jp.md) | System analysis: architecture, signal paths, threading, design decisions |
| [docs/SOURCE_SPECIFICATION_en.md](docs/SOURCE_SPECIFICATION_en.md) / [_jp](docs/SOURCE_SPECIFICATION_jp.md) | Source specification per file and type |

---

## Features

### Recording
- 24-bit Linear PCM WAV, 44.1 / 48 / 88.2 / 96 kHz, mono or stereo tracks, written directly to disk.
- Per-track input channel selection from any Core Audio interface.
- Sample-accurate placement of takes, with automatic and manual latency compensation.
- **Punch in/out**: records only inside the punch range; the whole pass is kept so the take can be extended later.
- **Rollback recording** (↺ button, right of P): a normal recording starts playing a set number of bars (1–16, in Settings) before the playhead and records from the playhead, so the take starts where the playhead was. The run-up is kept in the file; drag the clip's left edge to reveal it.
- **R key** starts recording on the armed tracks (same as the red Record button; stops when running).
- **Input monitoring** (`I` button): hear the live input through the track's effects while it is armed (the recording stays dry).
- Metronome with BPM, bars-and-beats ruler and adjustable click timing/volume. It can be switched on/off while playing or recording. Right-clicking the metronome button pops up a volume fader that works while playing.
- **Song start / end flags** on the ruler: Rewind goes to the start flag (again: to 00:00), playback and recording stop at the end flag, and the flags set the export range.
- Mono/stereo can be switched on recorded tracks too, without rewriting files (a mono track plays stereo clips as (L+R)/2).
- The playhead has a ball that bounces on every beat; green while playing, red while recording. Clicking the ruler snaps the playhead to the grid.

### Editing
- Move clips (also between tracks), trim both edges, clip gain, fade in/out, split, duplicate, delete, mute.
- **Multiple selection**: shift/cmd-click, marquee (shift to add), cmd+A. Selected clips move and delete together.
- **Right-click menu**: right-clicking an unselected clip selects it; right-clicking a selected clip applies the command to every selected clip (the top line shows the file name, format and size, e.g. `Guitar_001.wav, mono 24bit 7.8MB`; Normalize, Reverse, Mute, Duplicate, Split, Delete; with several clips the items show the count). Duplicate places the selection, as one block, at the playhead. Inside a selected range the range menu opens.
- **Range selection** (cmd-drag) across tracks: delete (leave silence), crop, split at both edges.
- **Cut / copy / paste** (cmd+X / C / V, pasted at the playhead) and option-drag to duplicate.
- **Handle pointers**: the pointer changes shape over a clip's edges (→ at the start, ← at the end), the fade dots and curve diamonds (pointing hand) and the gain bar (up-down arrow), so you can see what you are about to grab.
- **Fade curves**: drag the handle in the middle of a fade line to bend it continuously (snaps to linear and equal power; double-click for Auto).
- **Normalize** (clip gain to 0 dBFS) and **Reverse** (writes a reversed WAV and switches the clip to it).
- Tooltips show fade length, gain (dB) and curve while dragging. Waveforms are drawn at the level heard, including fades and crossfades.
- Undo / redo of clip edits, beat snap.
- **Overlap layering**: the most recently added clip plays on top of older ones, with automatic crossfades (equal power by default) at the boundaries. The fades of the upper clip drive the crossfades.
- **Track reordering**: drag a track header up or down by any free spot (the name, the meter, …). A white line shows where it will land. The mixer strips follow the same order.
- **Track folders**: **Add Folder** from the track list's + menu or a header's right-click menu, then drag tracks into it (tracks inside are indented; an indented drop line means the track goes into the folder). ▼ / ▶ opens and closes a folder; the tracks of a closed folder are not drawn (they still play and record). A folder's [M] / [S] mute or solo all its tracks (their own buttons light grey), and turning it off brings back each track's own state. Folders move with their tracks when dragged, take a colour, and are renamed by double-clicking. Folders do not nest.
- **Header right-click menu**: right-clicking a track makes it current and offers **Add Track** / **Add Folder** above it (only Add Track for a track inside a folder), **Duplicate Track** / **Duplicate Folder** (not during playback or recording), and **Show in Mixer** (scrolls the mixer so that track or folder is at its left edge). A duplicate gets the same clips (the recordings are shared, not copied), mixer settings, sends and plug-ins with their settings; its name gets the next free number ("Guitar" → "Guitar 2").
- WAV import by drag and drop from Finder. Files at another sample rate or bit depth are converted to 24-bit WAV at the current rate.
- Detailed waveforms: one min–max bar per point, from the samples themselves when zoomed in far, so single cycles are visible.
- The timeline is as long as the song (clips and end flag, at least 60 s); the part past it is darkened. Ruler clicks and playing on do not lengthen it.
- View: mouse wheel over the ruler or a pinch zooms horizontally (5–3200 px/s), option+wheel sets track height, option+shift+wheel sets waveform height.
- **Auto-scroll**: the view follows the playhead while playing or recording; turn it on/off with the |→ button at the right end of the transport bar. The horizontal scroll bar moves only when its knob (●) is dragged.

### Mixing
- Studio One-style mixer with three resizable sections per strip: **INSERT**, **SEND**, **controls**. Drag the top edge to resize the mixer; at least 220 pt is kept between the SEND/fader divider and the bottom edge. Shrinking the window shrinks only the track area; the transport bar and the mixer are never cut off. The ▼ button on the mixer bar folds the mixer down to its bar; ▲ brings it back.
- The current track's name is shown black on white in the mixer. A coloured vertical line marks where each folder and the FX channels start; click it to change the colour (the FX line's colour goes to every FX channel, and new FX channels take it).
- **Operate several channels together**: ⇧- or ⌘-click mixer channels to add them to the current track (click again to remove). Their faders move together keeping their dB differences, pan and sends keep their differences, and M / S follow the channel you click. Inserts are not included. Selecting another track clears the added channels.
- dB-scaled faders up to **+6 dB**, stereo L/R meters with peak hold, horizontal pan, mute/solo, double-click to type exact values.
- Tracks, FX channels (renamable, with mute/solo) and a master channel. Sends are post-insert and post-pan. Soloing an FX channel plays only its return. A new FX channel is numbered one past the highest existing "FX n".
- Track colours selectable from a palette.

### Plug-ins
- Audio Unit and VST3 effects on tracks, FX channels and master; mixed in any order.
- **Built-in effects** (listed as "MyDAW: …"): **MyReverb** (plate reverb), **MyDelay**, **MyChannelStrip** (4-band EQ + compressor) and **MyMaximizer** (loudness maximizer with 10 ms look-ahead). They come from the separate MyPlugIn project and are compiled into MyDAW as in-process Audio Units; each editor shows the name of the channel it is on.
- Drag a plug-in name onto another channel's INSERT list to insert a copy with the same settings (the original stays); dropping on an empty part of the list adds it at the bottom.
- Clicks in a plug-in window or the main window act on the first click, even when another window was in front, and Space / R / ← keep working while a plug-in window is in front.
- VST3 runs in real time inside the audio graph; GUI parameter changes are heard immediately.
- VST3 discovery runs in a separate process with a cache; VST3s that also exist as an AU are hidden to avoid conflicts between the two builds.
- **Plug-in latency compensation** for track inserts and FX channels: dry and effect sounds stay in time, even with a high-latency plug-in (such as a mastering suite) on an FX channel. Bypassing a plug-in keeps its compensation, and a plug-in that changes its latency is followed.
- The sound right at the play position is heard from the first sample; the metronome's first click too.
- Plug-in state saved with the project.
- A plug-in that cannot be used is shown in red in the insert list; its tooltip says whether it cannot be used on this Mac or was not found (not installed).
- Closing an AU plug-in's window only hides it; opening it again shows the same window.

### Project
- A project is a `.mydaw` file plus the `Recordings/` folder next to it (for example `MySong/Ballad.mydaw` + `MySong/Recordings/`). File and folder names are free, and the folder is fully portable. Several `.mydaw` files in one folder share its `Recordings/`. **Save Project As** (⇧⌘S) saves only into the same folder. Double-clicking a `.mydaw` file in the Finder opens it (the file shows a MyDAW document icon).
- **Recent Projects** on the start screen: up to 50 projects with their last-saved date; click a name to open it.
- Master mix export from a dialog (file name, folder, format) to WAV (16 / 24-bit) or MP3 (constant bitrate or VBR) at 44.1 / 48 / 96 kHz (MP3: up to 48 kHz), cut to the sample at the start and end positions (plug-in latency included). The master is rendered in real time, then converted.
- **Optimize recordings**: for sharing a project, rewrites the recordings so that each clip plays its own WAV holding only the part it plays (clips playing the same part share one file), named `Optimized_NNN.wav`. Mono-track clips become mono; mono files stay mono; higher sample rates are lowered to the current rate (never raised); 32-bit and float files become 24-bit, 16/24-bit keep their depth. Originals no longer used go to `Recordings/Unused/`. It cannot be undone, and it is not done while other `.mydaw` files share the folder.
- **Move unused recordings**: WAV files in `Recordings/` that the project no longer uses (for example deleted punch takes) are moved to `Recordings/Unused/`. Files used by other `.mydaw` files in the same folder are kept.

### Audio devices
- Separate input and output devices (for example, an audio interface for input and a monitor's speakers for output). While MyDAW runs, the chosen devices become the macOS default input and output; the previous defaults are restored on quit.
- Changing a device or the sample rate offers to save and restart, and reopens the project after the restart.
- **CPU meter** in the status bar: audio processing load as a bar that turns from green through yellow and orange to red, and a red **● Dropout** mark for 3 seconds whenever the sound breaks up.

### Languages
- **MyDAW Help** in the Help menu (⌘?) opens the operation manual (PDF on the web) in the GUI language.
- The GUI is available in English and Japanese. It follows the macOS language at first and can be switched under Language in Settings (after a restart).
- Translations live in `Localizable.strings` under `Resources/en.lproj` and `Resources/ja.lproj`; an English/Japanese table is in [docs/UI_Strings_en_ja.csv](docs/UI_Strings_en_ja.csv). After adding GUI strings, run `./scripts/extract-strings.sh` to find missing translations.

---

## Requirements

- Apple Silicon Mac, macOS 13 or later
- Xcode command line tools and CMake (for building)
- A microphone or Core Audio audio interface; headphones or monitors

---

## Build and run

The supported build is the shell script:

```bash
./scripts/build.sh      # builds the VST3 bridge (CMake), the MP3 encoder (LAME) and the app
open build/MyDAW.app    # launch

./scripts/run.sh        # build and launch in one step
```

> You can also build with Xcode: open `MyDAW.xcodeproj` and choose Product > Build (⌘B), or run `xcodebuild -project MyDAW.xcodeproj -target MyDAW -configuration Release build`. The output goes to `build/Release/MyDAW.app`. The first build step compiles the VST3 bridge with CMake, which must be installed in `/opt/homebrew/bin` or `/usr/local/bin`; a later step installs the MP3 encoder with `scripts/build-lame.sh`. `Package.swift` is **not** kept in sync with the sources.

When the project is inside a Google Drive folder, the script removes extended attributes before code signing.

---

## Quick start

1. Launch MyDAW and choose **New Project** (choose a folder and name in the save panel) or **Open Project** (choose a `.mydaw` file), or click a project in **Recent Projects**.
2. Allow microphone access when macOS asks.
3. Click the gear button and choose your input/output device and buffer size.
4. Arm a track with **R**, choose its input channel, and check the meter moves.
5. Press the red **Record** button (or **R**) to record and **Space** to stop.
6. Press **Space** to play. Adjust levels in the mixer at the bottom.

See the [Operation Manual](OperationManual_en.pdf) for step-by-step instructions.

---

## Directory layout

```
MyDAW/
├── Sources/            Swift sources (Models / Audio / Views; BuiltIn/MyPlugIn = built-in effects, synced from ../MyPlugIn)
├── VST3Host/           C++ VST3 host bridge
├── ThirdParty/vst3sdk/ Steinberg VST3 SDK
├── Resources/          Translations (en.lproj, ja.lproj)
├── scripts/            build.sh, run.sh, build-lame.sh (MP3 encoder), extract-strings.sh (translation check),
│                       make-document-icon.swift (draws the .mydaw icon), sync-myplugin.sh (copies MyPlugIn sources),
│                       make-zip.sh / pre-commit.sh (build/MyDAW.zip is made only when committing on main)
├── docs/               Analysis, specification, manual sources (docs/manual)
├── OperationManual_*.pdf
├── AppIcon.icns        App icon
├── DocumentIcon.icns   .mydaw file icon (a page with the app icon)
└── snapshots/          Source snapshots taken around each change
```

The MP3 encoder is [LAME](https://lame.sourceforge.io/) 3.100 (LGPL). `scripts/build-lame.sh` downloads its source (checked by SHA-256) and builds `libmp3lame.0.dylib`, which ships in `MyDAW.app/Contents/Frameworks` as a separate, replaceable library, with its license in `Contents/Resources/LAME-COPYING.txt`. The first build needs an internet connection for this.

---

## Known limitations

- Instruments are not supported, neither AU nor VST3 (effects only). AU effects driven by MIDI (music effects) are not listed either.
- A high-latency plug-in on an FX channel also delays input monitoring by that amount, and playback takes that much longer to start (the recording itself is not affected).
- A VST3 plug-in that changes its latency after it is loaded is not followed (AU plug-ins are).
- Device, sample-rate and language changes take effect after MyDAW restarts (it offers to restart when you change them).
- Switching input monitoring (I) during playback takes effect after you stop: when turned on, the input is heard once effect tails have faded; when turned off, the input stays audible until you stop (monitoring cannot be rewired while playing).
- While MyDAW runs, the chosen devices are the macOS defaults, so other apps use them too. If MyDAW crashes the defaults are not restored; reset them in System Settings → Sound.
- Plug-ins can be inserted, removed, reordered and copied only while stopped.
- Mono-only plug-ins (such as Waves "(m)" versions) cannot be used, because the insert chain is stereo even on mono tracks. Use the stereo version ("(s)").
- If a plug-in's own editor does not respond within 3 seconds, MyDAW shows a generic parameter view (Generic UI) instead.

---

## Version

The About dialog shows version **3.0**. Version 3.0 adds four built-in effects (MyReverb, MyDelay, MyChannelStrip, MyMaximizer), copying a plug-in to another channel by dragging it, first-click response in all windows, and transport shortcuts (Space / R / ←) while a plug-in window is in front. Version 2.3 adds **Optimize Recordings to Minimum Size** (File menu) for sharing a project, and shows the file's format and size next to its name in the clip right-click menu. Version 2.2 replaces the export save panel with an export dialog (file name, folder, format) and adds MP3 export (constant bitrate or VBR) and 16-bit WAV / 44.1–96 kHz export choices. Version 2.1 adds track folders, the track header right-click menu and the mixer's fold button, among others (a project with folders loses them when opened in v2.0). Version 2.0 opens and creates projects by their `.mydaw` file instead of a folder, so the file no longer has to be named after its folder.
