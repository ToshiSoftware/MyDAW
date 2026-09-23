# MyDAW - Logic Pro-Style Audio Recording & Playback DAW Prototype (Mac / Apple Silicon)

A prototype of a Logic Pro-style multitrack audio recording and playback DAW (Digital Audio Workstation) with native support for Apple Silicon (Mac).

It uses Core Audio (AVAudioEngine / CoreAudio HAL) as its backend and provides 24-bit 44.1 kHz / 48 kHz Direct-to-Disk recording, unlimited multitrack playback and mixing, real-time waveform rendering, and timeline/playhead control.

[NOTE]
This project was automatically generated using AI (Copilot, Antigravity). Please refer to the article below for details.

* [Japanese, original] https://note.com/tokada375/n/n750bfe9ef3f7
* [English, translated] https://note.com/tokada375/n/n750bfe9ef3f7?hl=en


## Main Features & Specifications

1. **Audio Specifications**
   - **Sample Rate**: 44.1 kHz or 48.0 kHz (switchable instantly from the top of the screen)
   - **Bit Depth**: 24-bit Linear PCM WAV (industry-standard format)
   - **Track Format**: Mono (1ch) / Stereo (2ch)
2. **Direct-to-Disk Recording**
   - To prevent memory pressure and ensure stable operation during long recordings, audio is streamed immediately from the Core Audio input buffer to the SSD/HDD (the `Recordings/` folder) via a background I/O thread.
3. **Core Audio Input Channel Selection**
   - Detects the physical channels (Input 1, Input 2, Input 3...) of connected audio interfaces and built-in microphones.
   - The input channel to be recorded can be individually assigned to each track from a drop-down menu.
4. **Track Modes (Record Mode / Playback Mode)**
   - **Record Mode (`[R]` button ON / lit red)**:
     - Displays a real-time peak level meter for the input signal.
     - When Start (Play/Record) is pressed, audio from the specified channel is recorded to disk as a 24-bit WAV file while the waveform is drawn in real time toward the right.
   - **Playback Mode (`[R]` button OFF)**:
     - Plays recorded audio files from the specified position.
     - Audio from all playback tracks is mixed (summed) and played simultaneously through the master output.
5. **Transport Controls**
   - **Start (`▶` Play)**: Starts recording and playback.
   - **Stop (`■` Stop)**: Finalizes the recording file and stops playback.
   - **Rewind (`|<<` Rewind)**: Resets the playhead to `00:00.000`.
   - **Ruler Click**: Seeks to the clicked timeline position.
6. **Track Management (Unlimited Tracks)**
   - Add unlimited mono or stereo tracks using the `+ Add Track` button.
   - Each track includes track-name editing, mute (`[M]`), solo (`[S]`), a volume fader, and a pan pot.
7. **Waveform Display & Playhead**
   - Logic Pro-style dark-theme UI.
   - Fast peak caching enables smooth scrolling and zooming of long audio using SwiftUI Canvas rendering.
   - A vertical playhead bar (orange) fully synchronized with playback/recording.

8. **Audio Plug-ins**
   - Detects Audio Unit effects and VST3 audio effects in standard macOS plug-in locations.
   - VST3 instruments are excluded from the effect list.
   - AU and VST3 effects can be inserted on tracks, FX channels, and the master channel.
   - VST3 track audio is processed in short blocks, so parameter changes during playback are applied without restarting transport.
   - Plug-in state is saved in `.mydaw` project files and restored when the project is opened.
   - The mixer displays inserted plug-ins with `AU:` or `VST:` prefixes.
   - Relab LX480 AU uses Generic UI when multiple LX480 AU instances are present, because its custom editor has a known multi-instance limitation.

9. **Startup**
   - The main window appears while plug-ins are detected.
   - A black, bordered startup log shows Audio Unit and VST3 detection progress and disappears when detection completes.

---

## Directory Structure

```text
MyDAW/
├── MyDAW.xcodeproj/          # Xcode project (can be launched by double-clicking)
│   └── project.pbxproj
├── Package.swift             # Swift Package Manager definition
├── Info.plist                # App settings & microphone access permission definition (NSMicrophoneUsageDescription)
├── MyDAW.entitlements        # macOS audio input & file access permissions
├── Sources/
│   ├── MyDAWApp.swift        # Application entry point (@main)
│   ├── Models/
│   │   ├── AudioTrack.swift  # Track data model (ID, name, R/M/S, volume, pan, etc.)
│   │   ├── WaveformCache.swift # Fast peak calculation & real-time waveform cache
│   │   └── ProjectState.swift # Project management (add/delete tracks, zoom, selection)
│   ├── Audio/
│   │   ├── AudioEngineManager.swift # Core Audio engine (AVAudioEngine)
│   │   ├── AudioDiskWriter.swift    # 24-bit WAV Direct-to-Disk streamer
│   │   └── AudioDeviceManager.swift # Core Audio hardware channel enumeration
│   └── Views/
│       ├── MainDAWView.swift        # Overall layout & status bar
│       ├── TransportBarView.swift   # Transport controls & LCD display
│       ├── ArrangerView.swift       # Arranger view (track headers + timeline)
│       ├── TrackHeaderView.swift    # Track controls (R, M, S, input selection, meter, fader)
│       ├── WaveformLaneView.swift   # Track waveform lane
│       └── WaveformCanvas.swift     # SwiftUI Canvas waveform renderer
├── VST3Host/                        # C++ VST3 hosting bridge and probe
├── ThirdParty/vst3sdk/              # Steinberg VST3 SDK
├── scripts/
│   ├── build.sh              # One-click build script from the command line
│   └── run.sh                # Build & launch script
└── Recordings/               # Folder where recorded 24-bit WAV files are stored
```

---

## How to Build & Run

You can build and run the application from either **Xcode** or the **Terminal**, depending on your preference.

### Method 1: Using Xcode (Recommended)

1. Double-click `MyDAW.xcodeproj` in Finder to open it in Xcode.
2. Confirm that the target at the top of the window is `MyDAW` (My Mac).
3. Press `⌘R` (Product -> Run) to build and immediately launch the application.

### Method 2: Build & Run from the Terminal

Run the following script from the project's root directory.

```bash
# Build and launch
./scripts/run.sh
```


```bash
./scripts/build.sh
# Launch the generated application
open build/MyDAW.app
```

---

## Basic Usage

1. **Microphone Permission on First Launch**:
   - When macOS displays the dialog saying `"MyDAW" would like to access the microphone`, click **OK**.
2. **Arm a Track for Recording**:
   - Click the `[R]` button on the track you want to record so that it lights up red.
   - Select the interface input channel from the drop-down menu, such as `Input 1` or `Input 2`.
   - Make a sound into the microphone and confirm that the level meter in the track header moves from green to yellow.
3. **Start Recording**:
   - Press the `▶` (Play) button in the top transport bar, or press the `Space` key.
   - Recording starts, and the input waveform extends in real time along the timeline. At the same time, any previously recorded tracks are automatically played back (monitored).
4. **Stop Recording**:
   - Press the `■` (Stop) button or the `Space` key.
   - The recorded audio is finalized and saved as a 24-bit WAV file in the `Recordings/` folder and displayed as a static waveform.
5. **Rewind & Play All Tracks**:
   - Press the `|<<` (Rewind) button to return the playback cursor to `00:00.000`.
   - Turn the track's `[R]` button off to put that track into "Playback Mode."
   - Press the `▶` (Play) button to mix and play all recorded tracks through the speakers/headphones.
6. **Add & Delete Tracks**:
   - Press the `+ Add Track` button at the top to add as many stereo or mono tracks as needed.

7. **Insert Plug-ins**:
   - Open the plug-in menu in a track, FX channel, or master channel.
   - Click an inserted plug-in name in the mixer to open its editor.
   - Removing a plug-in also closes its open editor window.

## Version

The current About dialog version is **1.2**.
