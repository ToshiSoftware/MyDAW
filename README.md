# MyDAW — Professinal Audio Workstation for Mac (Apple Silicon)

**Version 1.9** · [日本語版 README](README_jp.md)

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
- **Input monitoring** (`I` button): hear the live input through the track's effects while it is armed (the recording stays dry).
- Metronome with BPM, bars-and-beats ruler and adjustable click timing/volume. It can be switched on/off while playing or recording.
- **Song start / end flags** on the ruler: Rewind goes to the start flag (again: to 00:00), playback and recording stop at the end flag, and the flags set the export range.
- Mono/stereo can be switched on recorded tracks too, without rewriting files (a mono track plays stereo clips as (L+R)/2).
- The playhead has a ball that bounces on every beat; green while playing, red while recording. Clicking the ruler snaps the playhead to the grid.

### Editing
- Move clips (also between tracks), trim both edges, clip gain, fade in/out, split, duplicate, delete, mute.
- **Multiple selection**: shift/cmd-click, marquee (shift to add), cmd+A. Selected clips move and delete together.
- **Right-click menu**: right-clicking an unselected clip selects it; right-clicking a selected clip applies the command to every selected clip (Normalize, Reverse, Mute, Duplicate, Split, Delete; with several clips the items show the count). Duplicate places the selection, as one block, at the playhead. Inside a selected range the range menu opens.
- **Range selection** (cmd-drag) across tracks: delete (leave silence), crop, split at both edges.
- **Cut / copy / paste** (cmd+X / C / V, pasted at the playhead) and option-drag to duplicate.
- **Fade curves**: drag the handle in the middle of a fade line to bend it continuously (snaps to linear and equal power; double-click for Auto).
- **Normalize** (clip gain to 0 dBFS) and **Reverse** (writes a reversed WAV and switches the clip to it).
- Tooltips show fade length, gain (dB) and curve while dragging. Waveforms are drawn at the level heard, including fades and crossfades.
- Undo / redo of clip edits, beat snap.
- **Overlap layering**: the most recently added clip plays on top of older ones, with automatic crossfades (equal power by default) at the boundaries. The fades of the upper clip drive the crossfades.
- **Track reordering**: drag a track header up or down by any free spot (the name, the meter, …). The track lifts with its waveforms while the others step aside to show where it will land. The mixer strips follow the same order.
- WAV import by drag and drop from Finder. Files at another sample rate or bit depth are converted to 24-bit WAV at the current rate.
- View: mouse wheel over the ruler or a pinch zooms horizontally, option+wheel sets track height, option+shift+wheel sets waveform height.
- **Auto-scroll**: the view follows the playhead while playing or recording; turn it on/off with the |→ button at the right end of the transport bar. The horizontal scroll bar moves only when its knob (●) is dragged.

### Mixing
- Studio One-style mixer with three resizable sections per strip: **INSERT**, **SEND**, **controls**. Drag the top edge to resize the mixer; at least 220 pt is kept between the SEND/fader divider and the bottom edge. Shrinking the window shrinks only the track area; the transport bar and the mixer are never cut off.
- dB-scaled faders up to **+6 dB**, stereo L/R meters with peak hold, horizontal pan, mute/solo, double-click to type exact values.
- Tracks, FX channels (renamable, with mute/solo) and a master channel. Sends are post-insert and post-pan. Soloing an FX channel plays only its return.
- Track colours selectable from a palette.

### Plug-ins
- Audio Unit and VST3 effects on tracks, FX channels and master; mixed in any order.
- VST3 runs in real time inside the audio graph; GUI parameter changes are heard immediately.
- VST3 discovery runs in a separate process with a cache; VST3s that also exist as an AU are hidden to avoid conflicts between the two builds.
- **Plug-in latency compensation** for track inserts and FX channels: dry and effect sounds stay in time, even with a high-latency plug-in (such as a mastering suite) on an FX channel. Bypassing a plug-in keeps its compensation, and a plug-in that changes its latency is followed.
- The sound right at the play position is heard from the first sample; the metronome's first click too.
- Plug-in state saved with the project.

### Project
- One folder per project (`MySong/MySong.mydaw` + `MySong/Recordings/`), fully portable.
- **Recent Projects** on the start screen: up to 50 projects with their last-saved date; click a name to open it.
- Master mix export to 24-bit WAV, cut to the sample at the start and end positions (plug-in latency included).
- **Move unused recordings**: WAV files in `Recordings/` that the project no longer uses (for example deleted punch takes) are moved to `Recordings/Unused/`.

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
./scripts/build.sh      # builds the VST3 bridge (CMake) and the app
open build/MyDAW.app    # launch

./scripts/run.sh        # build and launch in one step
```

> You can also build with Xcode: open `MyDAW.xcodeproj` and choose Product > Build (⌘B), or run `xcodebuild -project MyDAW.xcodeproj -target MyDAW -configuration Release build`. The output goes to `build/Release/MyDAW.app`. The first build step compiles the VST3 bridge with CMake, which must be installed in `/opt/homebrew/bin` or `/usr/local/bin`. `Package.swift` is **not** kept in sync with the sources.

When the project is inside a Google Drive folder, the script removes extended attributes before code signing.

---

## Quick start

1. Launch MyDAW and choose **New Project** (pick a folder) or **Open Project**, or click a project in **Recent Projects**.
2. Allow microphone access when macOS asks.
3. Click the gear button and choose your input/output device and buffer size.
4. Arm a track with **R**, choose its input channel, and check the meter moves.
5. Press the red **Record** button to record and **Space** to stop.
6. Press **Space** to play. Adjust levels in the mixer at the bottom.

See the [Operation Manual](OperationManual_en.pdf) for step-by-step instructions.

---

## Directory layout

```
MyDAW/
├── Sources/            Swift sources (Models / Audio / Views)
├── VST3Host/           C++ VST3 host bridge
├── ThirdParty/vst3sdk/ Steinberg VST3 SDK
├── Resources/          Translations (en.lproj, ja.lproj)
├── scripts/            build.sh, run.sh, extract-strings.sh (translation check)
├── docs/               Analysis, specification, manual sources (docs/manual)
├── OperationManual_*.pdf
└── snapshots/          Source snapshots taken around each change
```

---

## Known limitations

- Instruments are not supported, neither AU nor VST3 (effects only). AU effects driven by MIDI (music effects) are not listed either.
- A high-latency plug-in on an FX channel also delays input monitoring by that amount, and playback takes that much longer to start (the recording itself is not affected).
- A VST3 plug-in that changes its latency after it is loaded is not followed (AU plug-ins are).
- Device, sample-rate and language changes take effect after MyDAW restarts (it offers to restart when you change them).
- Switching input monitoring (I) during playback takes effect after you stop: when turned on, the input is heard once effect tails have faded; when turned off, the input stays audible until you stop (monitoring cannot be rewired while playing).
- While MyDAW runs, the chosen devices are the macOS defaults, so other apps use them too. If MyDAW crashes the defaults are not restored; reset them in System Settings → Sound.
- Plug-ins can be inserted, removed and reordered only while stopped.
- If a plug-in's own editor does not respond within 3 seconds, MyDAW shows a generic parameter view (Generic UI) instead.

---

## Version

The About dialog shows version **1.9**.
