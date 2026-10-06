# MyDAW ソースコード仕様書（v2.1）

> 対象バージョン: **2.2** ／ 英語版: [SOURCE_SPECIFICATION_en.md](SOURCE_SPECIFICATION_en.md)
> システム全体の構成・信号経路・設計判断: [PROJECT_ANALYSIS_jp.md](PROJECT_ANALYSIS_jp.md)

本書は `Sources/` と `VST3Host/` の各ファイルについて、責務、型、主要なプロパティとメソッドの契約、スレッド上の前提、副作用を記載します。private なメソッドは、処理の流れを理解するのに必要なものだけを掲載します。

---

## 0. 表記と共通の前提

- **@MainActor**: `ProjectState`、`AudioEngineManager`、`AudioTrack`、`AudioClip`、`FXChannel` と全 View はメインスレッドで動作します。
- **リアルタイム（RT）**: オーディオ描画スレッドで実行されるコード。メモリ確保・ロック待ち・Objective-C メッセージ送信を避けます。
- **音量**: 内部値は線形ゲイン（1.0 = 0 dB）。上限は `MixerGain.maximum`（+6 dB ≒ 1.995）。
- **PAN**: -1.0（左）〜 +1.0（右）。
- **GUI 文字列**: 英語の文言をキーとし、`Resources/{en,ja}.lproj/Localizable.strings` で表示する。SwiftUI のリテラルは自動で翻訳対象、変数や AppKit に渡す文字列は `String(localized:)` で包む。
- **時刻**: タイムライン上の秒（`Double`）。再生スケジュールは AVAudioTime（hostTime またはサンプル時刻）。

---

## 1. アプリケーション

### `Sources/MyDAWApp.swift`

#### `MyDAWApp: App`（`@main`）
- **`init()`**: 最初に `raiseOpenFileLimit()` で同時に開けるファイル数の上限（RLIMIT_NOFILE の soft 値、既定 256）を `kern.maxfilesperproc` と hard 値の範囲で最大 65,536 まで上げる（再生用にクリップごとに WAV を開いたままにするため、クリップが数百になると上限を超え、AppKit がメニューの部品を読めずにクラッシュした）。次に `PluginManager.runVST3ScanChildIfRequested()` を呼ぶ。起動引数に `--scan-vst3 <path>` があれば VST3 を列挙して JSON を標準出力へ書き、`exit(0)` する（子プロセスモード）。通常起動時はマイク権限を要求する。
- **`body`**: `WindowGroup` に `MainDAWView` を置き、メニューを構成する。ウィンドウは `.hiddenTitleBar`（タイトルバーは透明で、内容がその下に広がる）と `.windowResizability(.contentMinSize)`（内容の最小サイズより小さくできない）。`.handlesExternalEvents(matching: [])` で、Finder から開いたファイルごとに SwiftUI が新しいウィンドウを作るのを防ぐ。
- **Finder から開く**: Info.plist の `CFBundleDocumentTypes`／`UTExportedTypeDeclarations` で `.mydaw`（`com.tokada.mydaw.project`、`public.data`／`public.content` に準拠。`public.json` にすると Finder が中身のテキストをサムネイルにしてアイコンが出ない）を宣言し、`MyDAWApplicationDelegate.application(_:open:)` が受け取る（複数なら最後の 1 つ）。ウィンドウの `onAppear` で `openProjectFile` が設定されるまでは `pendingProjectURL` に保持し、設定後に `ProjectState.openProjectFile(_:)` を呼ぶ。`build.sh` は署名後に `lsregister -f` でビルドを LaunchServices に登録する。書類のアイコンは `DocumentIcon.icns`（`scripts/make-document-icon.swift` が `AppIcon.iconset` から、折り返し付きの白い書類の中央にアプリアイコンを角丸で描いて作る。アプリアイコンを変えたら再実行する）。
  - About（バージョン表示。Info.plist が無い場合の既定値は `2.2`）
  - File: New Project…（⌘N）、Open Project…（⌘O）、Save Project…（⌘S）、Save Project As…（⇧⌘S）、区切り線、Export Master Mix…、区切り線、Move Unused Recordings to Unused Folder
  - Edit: Undo Clip Edit（⌘Z）、Redo Clip Edit（⇧⌘Z／⌘Y）
  - Help: MyDAW Help（⌘?）。`AppLanguage.current` に応じて `https://toshi.life.coocan.jp/note/OperationManual_{jp,en}.pdf` を `NSWorkspace.open` で開く（開くアプリはシステム任せ）
- **`requestAudioPermissions()`**: OS バージョンに応じてマイク権限 API を呼ぶ。

#### `MyDAWApplicationDelegate: NSApplicationDelegate`
- 最後のウィンドウを閉じてもアプリを終了しない。
- **`applicationShouldTerminate`**: `confirmQuit`（`ProjectState.confirmQuit()`）を呼び、キャンセルまたは保存失敗なら `.terminateCancel` を返す。終了メニュー・⌘Q・ウィンドウを閉じる操作のすべてがここを通る（`relaunch()` は確認済みのためスキップ）。
- **`applicationWillTerminate`**: `shutdownAudioEngine` を呼び、`AudioEngineManager.shutdown()` を実行する（VST3 モジュールの正しい解放と、macOS 既定入出力デバイスの復元に必須）。

---

## 2. モデル（`Sources/Models`）

### `AudioTrack.swift`

#### `MixerGain`
全フェーダー・Send 共通のゲイン定数。`unity = 1.0`、`maximum = 10^(6/20)`（+6 dB）。

#### `ChannelMode: String, Codable, CaseIterable`
`.mono`（1ch）／`.stereo`（2ch）。`channelCount` を返す。

#### `AudioTrack: ObservableObject`（@MainActor）
| プロパティ | 内容 |
| --- | --- |
| `id`, `name`, `color` | 識別子、表示名、トラック色 |
| `channelMode`, `inputChannelIndex` | 録音チャンネル数と入力の先頭チャンネル（0 起点）。`channelMode` は再生にも使われ、モノラルのトラックではステレオのクリップをモノラル化します（`MonoDownmixAudioUnit`）。ファイルは書き換えません |
| `isRecordArmed`, `isInputMonitoring` | 録音待機（R）、インプットモニター（I） |
| `isMuted`, `isSoloed`, `volume`, `pan` | ミキサー値（`isMuted`／`isSoloed` はトラック自身のボタンの状態） |
| `folderID` | 所属するフォルダ（v2.1。`ProjectState` だけが設定する） |
| `isMutedByFolder`, `isSoloedByFolder` | フォルダの M／S で有効になっている間 true（v2.1。`applyFolderStates()` が設定） |
| `effectiveMuted`, `effectiveSoloed` | 音に効くミュート／ソロ＝トラック自身 OR フォルダ（エンジンの `audibility` が使う） |
| `trackHeight` | レーンの高さ（標準 170pt = `AudioTrack.defaultTrackHeight`。表示は × `trackHeightScale`） |
| `clips` | クリップ配列。**配列順がレイヤー順**（後ろほど上） |
| `selectedClipIDs` | 選択中のクリップ（集合）。`selectedClipId` は先頭の選択クリップを返し、設定するとそのクリップだけを選ぶ互換用の計算プロパティ |
| `plugins`, `fxSends` | インサートと FX 送り |
| `meter`（`TrackMeter`）、`currentInputPeak`, `currentOutputPeak`, `outputStereoPeak` | メーター値。値は別オブジェクト `TrackMeter` が持ち（`update(inputPeak:outputPeak:)` は変化したときだけ通知）、30 Hz の更新でトラックを監視する全ビュー（ヘッダ・波形レーン・ミキサー）が再描画されないようにしている。表示はメーター専用のサブビュー（`TrackHeaderMeter`、`TrackFaderColumn`）だけが `meter` を監視する。3 つのプロパティは読み取り専用 |

- `clips` の変更時、各クリップの `objectWillChange` をトラックへ中継する（下のクリップの重なり表示を更新するため）。
- **`addClip(startTime:fileURL:)`**、**`moveClip(id:to:)`**、**`deleteClip(id:removeFile:)`**（他から参照されないファイルのみ削除）、**`duplicateClip(id:)`**（直後に複製）、**`splitClip(id:at:)`**（左右 20 ms 未満の分割は拒否）、**`removeClipForTransfer(id:)`**、**`restoreClip(_:)`**、**`insertClip(_:below:)`**（指定クリップの直下のレイヤーへ挿入）、**`replaceClips(_:)`**（選択は残ったクリップに絞る）。
- **範囲編集**: **`clipPieces(from:to:)`**（範囲部分の複製列）、**`removeAudio(from:to:)`**（範囲内を削除し、跨ぐクリップは前後に分割）、**`cropAudio(from:to:)`**（範囲内だけ残す）、**`splitAudio(at:)`**（指定時刻で分割）。いずれもレイヤー順を保って組み替え、変更があれば true を返す。
- **`insertPlugin(_:)`／`removePlugin(id:)`／`movePlugin(id:before:)`**: インサートの編集。

### `AudioClip.swift`

#### `AudioClip: ObservableObject`（@MainActor）
タイムライン上の配置（`startTime`、`duration`）と WAV 内の再生範囲（`sourceStartTime`）を保持する非破壊クリップ。
- 追加の属性: `gainDB`（−∞〜+36。`setGainDB` は `silenceGainDB`（−72）以下を −∞ に、`maximumGainDB`（36）で上限。JSON には −∞ を書けないため `ClipDocument` は −144 で保存し、読み込みで −∞ に戻る）、`isMuted`、`fadeInDuration`／`fadeOutDuration`、`fadeInCurve`／`fadeOutCurve`（`FadeCurve`、既定 `.auto`）、`sampleRate`、`originalDuration`（ファイル全長）、`waveformCache`。
- **`loadMetadata()`**: ファイルのサンプルレートと長さを読み、波形ピークの非同期読込を開始する。`duration` は利用可能な範囲に制限。
- **`gainDB` の −∞ についての注意**: 無音は本当の `-infinity` で持つ（倍率 `pow(10, gainDB / 20)` がちょうど 0 になる）。この値を使うコードを足すときは次を守る：(1) JSON などへ直接書かない（`JSONEncoder` が例外を投げて保存に失敗する。`ClipDocument` のように有限値に置き換える）、(2) 整数へ変換しない（実行時エラーで停止する）、(3) 0 を掛ける・無限大と足し引きするなど NaN になる計算をしない（ドラッグのように、計算の起点が −∞ のときは `silenceGainDB` から始める）。表示は `isFinite` で分けて「-∞ dB」とする。
- **`setTrim(startTime:sourceStartTime:duration:)`**: 最短 0.02 秒。
- **`setFadeInDuration`／`setFadeOutDuration`**: 0〜`duration` に制限。
- **`duplicate(at:)`**: 同じファイルを参照する複製（フェードとカーブも複製）。
- **`piece(from:to:)`**: タイムライン上の区間に当たる部分を新しいクリップとして返す（20 ms 未満は nil）。フェードとカーブは元のクリップと共有する端だけ引き継ぐ。

### `ClipLayering.swift`

クリップの重なりとフェードカーブを扱う純粋関数群。再生（`TrackRenderer`）と表示（`WaveformLaneView`、`WaveformCanvas`）が共有します。波形の点ごと・サンプルごとに評価するゲインは `ClipLayering.Envelope`（カーブの解決、重なる上のクリップの抽出、区間分けを一度だけ行い、plain／hidden の区間は計算せずに 1／0 を返す。`gain(_:clip:at:)` と同じ値）を使う。毎回すべてを調べていた頃は、フェード付きクリップの多いトラックの描画 1 回に 100 ms 以上かかった。

#### `FadeCurve: Codable, Equatable`（v1.6 新規）
| ケース | 内容 |
| --- | --- |
| `.auto` | 下のクリップの音と重なるときは等パワー、無音に対しては直線（`resolved(crossfade:)` で具体化） |
| `.equalPower` | sin の 1/4 周期（クロスフェードで音量感が一定） |
| `.bend(midpoint:)` | 中間点の音量 m（0.05〜0.95）を通るべき乗曲線 r^p（p = log m / log 0.5）。`linear` は m = 0.5 |

`value(_:)`（進行度 r → ゲイン）、`midpointGain`、`withMidpoint(_:)`（-3 dB と -6 dB 付近で等パワー・直線に吸着）、`title`（ツールチップ用の名前）。

#### `ClipLayerSpan`
1 クリップ分の `id`、`start`、`end`、`fadeIn`、`fadeOut`、`isMuted`、`fadeInCurve`、`fadeOutCurve`（レイヤー順に並べる）。

#### `ClipLayering`
| API | 内容 |
| --- | --- |
| `spans(for: [AudioClip])` | クリップ配列からスパン列を作る（実際に再生可能な長さで `end` を計算） |
| `gain(_:clip:at:)` | 時刻 t におけるクリップの最終エンベロープ = 自身のフェード × 上位クリップの透過率の積 |
| `segments(_:clip:)` | クリップを `.plain`（無加工）／`.hidden`（上位に完全に隠れる）／`.shaped`（エンベロープ必要）の区間へ分割 |
| `isEdgeCovered(_:clip:atStart:)` | クリップの端が上位クリップに覆われているか（フェードハンドルのロック判定） |
| `resolvedCurve(_:clip:atStart:)` | 描画用に `.auto` を具体化したフェードカーブ |
| `envelope(_:clip:)` | クリップ先頭からの秒数 → 最終ゲインの関数。フェードも重なりもなければ nil（波形の振幅表示に使用） |

- 上位クリップの透過率: フェード区間の進行度 r に対し、上位のフェードカーブを時間反転した `curve(1 − r)`（等パワーなら `cos(πr/2)`、直線なら `1 − r`）。
- フェードの形状: `FadeCurve` による。`.auto` はそのフェード区間に下位クリップの音があれば等パワー、なければ直線。
- ミュートされたクリップは他を覆わない。

### `FXChannel.swift`

#### `FXChannel: ObservableObject`
`id`、`name`（既定 "FX n"。n は既存の "FX 数字" の最大値 + 1）、`volume`、`pan`、`isMuted`、`isSoloed`、`plugins`、`color`、`currentOutputPeak`、`outputStereoPeak`。`insertPlugin`／`removePlugin`／`movePlugin`。

#### `FXSend: Codable`
`id`、`fxChannelID`、`level`（線形ゲイン）、`enabled`。

### `StereoPeak.swift`
L/R のピーク値。`init(buffer:)` は PCM バッファから各チャンネルの最大絶対値を計算（モノラルは両側に同じ値）。`merged(with:)`、`falling(to:by:)`（アタック即時・指数減衰。-100 dB 未満は 0 にして、無音時に値が変わり続けないようにする）、`maximum`。

### `WaveformCache.swift`
- 2 段階のピークを持つ。どちらも区間の本当の最小・最大（0 を含めない。拡大時に波のその部分の位置に描かれる）。粗い段階は `PeakPoint` の列を合成（`peaks`）とチャンネル別（`channelPeaks`）で、512 サンプル／ピーク。細かい段階は `CompactPeak` の列（`fineCombinedPeaks`、`fineChannelPeaks`、`finePeaks(for:)`）で、`fineSamplesPerPeak` = 64 サンプル／ピークを Int16 の最小・最大（4 バイト）で持つ（モノラルのファイルでは合成の列がチャンネルの列と記憶域を共有）。細かい段階は 48 kHz・800 px/秒でほぼ 1pt に 1 点。録音中のテイクは粗い段階（ライブピーク）だけ。
- **サンプルそのもの**: `requestSamples(_:)` が `sampleWindow`（`SampleWindow`：開始フレーム、チャンネル別と平均のサンプル）を指定のフレーム範囲を覆うようにし、前後に同じ長さを足して裏で読む。描画のたびに呼んでよい（すでにある範囲・読み込み中の範囲は読み直さない。1 回は 48 kHz で最大 4 秒分なので、全体を描く波形がファイルを丸ごと読むことはない。新しい要求や `loadPeaks`／`clear` は古い読み込みを無効にする）。
- **`loadPeaks(from:)`**: `Task.detached` でファイルを読み、結果をメインスレッドで公開。1 回の走査で 2 段階とも作る（粗いピーク 1 点は細かいピーク 8 点から）。ピークはファイル単位で共有する（キーはパス・サイズ・更新日時・`samplesPerPeak`）。読み込み済みならすぐ反映し、読み込み中なら完了を待つキャッシュの一覧に加わるので、分割したクリップが同じファイルを何度も読むことはない。
- **`appendLivePeaks`／`appendLiveChannelPeaks`**: 録音中のライブ波形追加。

### `ProjectDocument.swift`（`.mydaw` JSON）
| 型 | 主な内容 |
| --- | --- |
| `ProjectDocument` | `version`（現行 5）、ズーム、スクロール、プレイヘッド、BPM、メトロノーム、マスター音量、表示倍率、トラック、フォルダ（`folders`、v2.1）、FX、マスタープラグイン、プラグイン状態、パンチ範囲、曲の範囲、マスター書き出しの設定（ファイル名・形式・保存先） |
| `TrackDocument` | 名前、チャンネル、入力、R/M/S、**I（`isInputMonitoring`）**、音量、パン、高さ、色、所属フォルダ（`folderID`、v2.1）、クリップ、プラグイン、Send |
| `TrackFolderDocument` | フォルダの ID・名前・色・開閉（`isOpen`）・M／S と、トラックとフォルダを合わせた行の中の位置 `position`。`makeFolder()` で `TrackFolder` に戻す。読み込みでは位置の小さい順にトラック列へ差し込む |
| `ClipDocument` | ID、開始位置、ソース位置、長さ、元の長さ、ゲイン、ミュート、フェード、フェードカーブ（`fadeInCurve`／`fadeOutCurve`、読めない場合は `.auto`）、ファイルパス（プロジェクトからの相対） |
| `FXChannelDocument` | FX の名前・音量・パン・ミュート・ソロ・色・プラグイン（古いプロジェクトではミュート・ソロは OFF） |
| `PluginStateDocument` | `pluginID`、`stateData`、`format`（AU は plist、VST3 は `"vst3-state"`） |
| `PunchRangeDocument` | `startBeat`、`endBeat`、`enabled` |
| `SongRangeDocument` | 曲の開始・終了フラグ。`startBeat`、`endBeat`（どちらも省略可） |
| `ProjectDocument.masterExportFileName` | マスター書き出しで最後に使ったファイル名（拡張子付き、省略可）。ダイアログには拡張子を除いて表示。無ければ `<プロジェクト名>_Master_Mix` |
| `ProjectDocument.masterExportSettings` | （v2.2）マスター書き出しで最後に使った `ExportSettings`（省略可。最初の書き出しまでは無く、そのときダイアログはハードウェアのレートが 44.1／48／96 kHz ならそれで始まる） |
| `ProjectDocument.masterExportFolderPath` | （v2.2）書き出し先フォルダ（省略可。nil はプロジェクトのフォルダ）。プロジェクトのフォルダ内なら相対パス、フォルダ自体は `.`、外なら絶対パス。存在しないフォルダはプロジェクトのフォルダに戻す |
| `ColorDocument` | RGBA |

全デコーダは `decodeIfPresent` で欠落項目に既定値を補い、旧バージョンのファイルを読み込めます。

### `ProjectState.swift`

`ProjectState: ObservableObject`（@MainActor）は UI とエンジンの間の Facade です。

- **公開状態**: `rows`（トラックとフォルダの行。並びの唯一の正。v2.1）、`tracks`（`rows` のトラックだけ。`rows` の `didSet` で更新）、`mixerScrollRequests`（「ミキサーに表示」の行 ID を送る `PassthroughSubject`）、`fxChannels`、`masterPlugins`、`selectedTrackId`、`pixelsPerSecond` と `trackHeightScale`（値は別オブジェクト `timelineGeometry`（`TimelineGeometry`）が持つ。操作のたびに ProjectState 全体を通知するとミキサーを含む全画面が再描画されるため。タイムラインの部品（`ArrangerView`、ルーラーの各部品、`WaveformLaneView`、`AudioClipView`、`TrackHeaderView`、`TransportBarView`）だけが環境オブジェクトとして監視する）。`pixelsPerSecond`（5〜800、`minimumPixelsPerSecond`／`maximumPixelsPerSecond`。スライダーは対数）、`timelineScrollTime`（値は別オブジェクト `timelineScroll`（`TimelineScrollPosition`）が持つ。スクロールのたびに ProjectState 全体を通知すると全トラックのヘッダとレーンが再描画されるため。ルーラーのずらし（`TimelineScrollOffset`）とスクロールつまみ（`TimelineScrollSlider`）だけが監視し、トラック側は、値が変わった直後に `TimelineScrollPosition.onChange`（ArrangerView が登録する `followScrollTime`）が同期的にスクロールするので、ルーラーと同じフレームで動く）、`punchRange`、`showsBeats`、`snapToGrid`（UserDefaults 保存）、`autoScrollEnabled`（UserDefaults `MyDAW.autoScroll`）、`waveformVerticalScale`（1〜256、`maximumWaveformVerticalScale`。スライダーは対数。はみ出す波形は `WaveformCanvas` がレーン内に収める）、`trackHeightScale`（`TrackHeaderView.minimumRowHeight` 56pt ÷ 170 ≒ 0.33 〜 3。スライダーと ⌥＋ホイールは `setTrackHeightScale` 経由で、全トラックの `trackHeight` を標準値に戻してから倍率を設定）、`timeSelection`（範囲選択）、`marqueeRect`（枠選択中の矩形）、`clipboard`、書き出しダイアログ状態、起動ログ、`pluginManager`、`audioEngine`、`deviceManager`。
- **初期化**: デバイスとバッファサイズをエンジンへ適用、ピーク通知を購読、既定トラック 2 本を作成、プラグイン検出を開始。
- **トラック**: `addTrack`（カレントの下。位置は `newTrackPlace()`、追加は `insertNewTrack(name:mode:isArmed:at:)`。フォルダ内ならフォルダの色、閉じたフォルダなら開く）、`deleteTrack`（UI からは確認ダイアログ付きの `confirmDeleteTrack` 経由）、並べ替えとフォルダは `ProjectState+Folders.swift`、`toggleRecordArm`、`toggleInputMonitoring`、`toggleMute`／`toggleSolo`（フォルダで有効になっている間は何もしない）、`setInputRouting(for:channelMode:inputChannelIndex:)`（変更後に即エンジン同期）。
- **クリップ**: `selectClip`（そのクリップだけを選択し、範囲選択を解除）、`moveClip`（トラック間移動）、`deleteSelectedClip`（範囲選択があれば範囲内を削除、なければ選択クリップすべてを削除）、`splitSelectedClip`／`splitClip`、ドラッグプレビュー（`ClipDragPreview`：移動中のクリップ ID の集合、縦の移動量、移動先までのトラック数。`beginClipDragPreview()`／`updateClipDragPreview(verticalOffset:trackDelta:)`／`endClipDragPreview()`。移動先がないクリップがあるときトラック数は 0）。選択・範囲・クリップボード・まとめて移動は `ProjectState+Editing.swift`。
- **UNDO/REDO**: `beginClipEdit()` で編集前スナップショット（クリップの位置・範囲・ゲイン・ミュート・フェードとカーブ・ファイル、各トラックの選択）を取り、`endClipEdit()` で履歴に積む。クリップが変わっていなければ積まない（ハンドルをクリックしただけの場合など）。`undo()`／`redo()` は再生・録音中と、録音停止後にテイクが確定するまで（`isRecordingLocked`）は無効。録音（エンジンがテイクを加える直前の `onRecordingWillAddTakes`）と WAV の取り込みも、それぞれ 1 手順として積む。スナップショットの後に追加したトラックは、復元で空にせずそのまま残す。
- **パンチ**: `setPunchRange`、`setPunchStartBeat`、`setPunchEndBeat`、`setPunchEnabled`。
- **録音時のロールバック**: `recordRollbackEnabled`（UserDefaults `MyDAW.recordRollback`）と `recordRollbackBars`（`MyDAW.recordRollbackBars`、初期値 2、`recordRollbackBarsRange` 1...16）。`toggleTransport` が「小節数 × 4 × 1 拍の秒数」（OFF なら 0）をエンジンの `recordRollbackDuration` に渡す。
- **未使用の録音ファイル**: `moveUnusedRecordings()`（ファイルメニュー。`canMoveUnusedRecordings` はプロジェクトが開いていて、停止中で、録音の確定処理中でないこと）。まず保存の確認（プロジェクトを保存して実行／キャンセル）を出して保存し、そのあと Recordings 直下の WAV のうち、クリップとクリップボードのどちらからも参照されていないものを `Recordings/Unused` へ移動し（同名は番号付き）、NSAlert で一覧を表示します。同じフォルダーのほかの `.mydaw`（`clipPathsOfOtherProjects()` で `ProjectDocument` をデコード）のクリップも使用中として扱い、読めないファイルがあれば何も移動せずにエラーを表示します。移動したファイルが Undo／Redo のスナップショットに含まれていた場合は、両方の履歴を消去します。
- **開始・終了フラグ**: `songRange`（変更時にエンジンの `songEndTime` を更新）、`songStartTime`／`songEndTime`（秒）、`setSongStart(time:)`／`setSongEnd(time:)`（nil で削除。`minimumSongLengthBeats` 以上離す）、`canPlaceSongStart(at:)`／`canPlaceSongEnd(at:)`。`toggleTransport(recordArmedTracks:)` はパンチ範囲・ロールバック・終了位置をエンジンに渡して再生／録音を開始・一時停止します（再生・録音ボタン、Space、R から）。`rewindToSongStart()` は開始フラグへ、フラグ上かそれより前なら 0 へ戻ります。エンジンの `onReachSongEnd` から `stop(tracks:)` を呼びます。
- **プラグイン**: トラック用 `insertPlugin(_:into:)`／`removePlugin(_:from:)`／`movePlugin(_:before:on:)`／`togglePlugin(_:on:)`、FX 用 `…intoFX:`／`…fromFX:`／`…onFX:`、マスター用 `insertMasterPlugin`／`removeMasterPlugin`／`moveMasterPlugin`／`toggleMasterPlugin`、`openPluginUI`。
- **FX**: `addFXChannel()`（名前は既存の "FX 数字" の最大値 + 1、色は最初の FX と同じ）、`renameFXChannel(id:to:)`（空欄は無視）、`removeFXChannel(id:)`（UI からは `confirmRemoveFXChannel(id:)` 経由。確認は NSAlert で、Return／Esc はキャンセル側）、`setSend(trackID:fxChannelID:level:)`。
- **ファイル**: `createNewProject`（NSSavePanel で保存先と名前を指定。`canCreateDirectories`、展開表示、拡張子 `.mydaw`。選んだフォルダーに `.mydaw` と `Recordings/` を作成）、`loadProject`（NSOpenPanel で `.mydaw` ファイルを選び、その親フォルダーをプロジェクトフォルダーとする）。両パネルの初期位置は直前のプロジェクトのフォルダーの 1 つ上（`projectPanelStartDirectory`）。`openRecentProject(_:)`（ファイルの存在を確認し、そのフォルダーで `loadProject(from:projectFolderURL:)`）、`saveProject`（書き込みに成功すると `RecentProjects.noteSaved`。`loadProject(from:)` は成功時に `noteOpened`）、`saveProjectAndShowConfirmation`、`openProjectFile(_:)`（Finder から開く。アプリを前面に出し、同じファイルが開いていれば何もしない。再生・録音中はエラー。プロジェクトが開いていれば保存／保存しない／キャンセルを確認してから `loadProject(from:projectFolderURL:)`）、`saveProjectAs()`（NSAlert のテキスト欄で名前だけを入力し、同じフォルダーの `<名前>.mydaw` へ保存して `currentProjectURL` を切り替える。空・「.」始まり・「/」「:」を含む名前は拒否、既存ファイルは置き換えを確認、失敗時は元の URL に戻す）、`importAudioFile(_:intoTrackId:)`（今のサンプルレートの 24-bit 整数 PCM ならそのままコピー、それ以外は `ClipAudioProcessing.writeConverted` で変換して `Recordings/` へ保存）、`locateClipFile`（サンプルレートが一致するファイルのみ）。
- **再起動**: `promptRestartForAudioSettings()`（デバイス・サンプルレート・言語の変更後に Save and Restart／Restart Without Saving／Cancel を確認）、`relaunch()`（`/bin/sh` で現プロセスの終了を待ち、`open -n` でプロジェクトを引数に再起動）。
- **書き出し**: `beginMasterExportDialog`（保存パネルを出さず、ダイアログを直接開く）、`masterExportSettings`／`masterExportBaseName`／`masterExportFolder`（ダイアログの選択内容）、`chooseMasterExportFolder`（NSOpenPanel、フォルダのみ）、`exportMasterMix(startTime:endTime:)`、`cancelMasterExport`。`exportMasterMix` は名前を確認し（「別名で保存」と同じ規則。入力された .wav／.mp3 は除く）、形式の拡張子を付け、同名ファイルがあれば置き換えを確認してから、(1) `AudioEngineManager.exportMasterMix` でマスターを一時ファイル（`NSTemporaryDirectory` の 32-bit float CAF）へリアルタイムで取り込み、(2) 切り離したタスクで `ExportEncoder.encode` を実行する。`masterExportStage`（`.capturing`／`.converting`）と `masterExportProgress`（0〜1）がダイアログの進捗バーに使われる。キャンセル・失敗時は書きかけの出力を削除し、一時ファイルは常に削除する。
- **表示**: `zoomIn`、`zoomOut`、`setPixelsPerSecond(_:)`（再生位置を基準）、`setPixelsPerSecond(_:anchorOffset:)`（ポインター位置を基準、ホイール・ピンチ用。どちらもスクロール時刻が変わらなくても `setScrollTimeAfterZoom` でトラックをスクロールする）、`minimumPixelsPerSecond`／`maximumPixelsPerSecond`（5／3200）、`snappedTimelineTime`（1 拍単位）。

### `ExportSettings.swift`（v2.2 新規）
マスター書き出しの形式（Codable。`ProjectDocument.masterExportSettings` に保存）: `format`（`.wav`／`.mp3`）、`sampleRate`（44.1／48／96 kHz。MP3 は MPEG-1 Layer III の上限により 44.1／48 kHz）、`wavBitDepth`（16／24）、`mp3Mode`（`.constant`／`.variable`）、`mp3Bitrate`（128／192／256／320 kbps）、`mp3VBRQuality`（V0／V2／V4）。初期値は WAV、48 kHz、24-bit、MP3 は固定 320 kbps、V0。`normalize()` は選択肢にない値を戻す（例: MP3 で 96 kHz → 48 kHz）。デコード時にも呼ぶ。

### `RecentProjects.swift`（v1.8 新規）
- **`RecentProject: Codable, Identifiable`**: `path`（`.mydaw` ファイルのパス。正規化済みで `id` を兼ねる）、`lastSavedAt`。派生値 `url`、`name`（拡張子を除いたファイル名）、`exists`。
- **`RecentProjects: ObservableObject`**（`shared`）: `entries` は新しい順で最大 `maxCount`（50）件。UserDefaults のキー `MyDAW.recentProjects` に JSON で保存。`noteSaved(_:)` は現在時刻で先頭へ、`noteOpened(_:)` はファイルの更新日時（＝最終保存）で先頭へ移動。`remove(_:)` で 1 件削除。ファイルが見つからない項目も残す（Google Drive がオフラインの場合があるため）。表示は灰色。

### `AppLanguage.swift`（v1.6 新規）
GUI 言語（`english = "en"`／`japanese = "ja"`）。`displayName` は各言語自身の表記（English／日本語）。`current` は起動中のアプリが読み込んだ言語（`Bundle.main.preferredLocalizations`）。`select(_:)` はアプリの `AppleLanguages` 既定値に保存し、次回起動から反映。未選択時は macOS の優先言語（どちらでもなければ英語）。

### `ProjectState+Editing.swift`（v1.6 新規）

`ProjectState` の拡張。選択と編集操作をまとめます。

| 型／API | 内容 |
| --- | --- |
| `TimeSelection` | 範囲選択（`start`、`end`、上から順の `trackIDs`） |
| `ClipboardClip` | コピーしたクリップの値（ファイル、ソース位置、長さ、ゲイン、ミュート、フェードとカーブ、ブロック先頭からの時間とトラックのオフセット） |
| `hasSelection`、`canPaste` | 削除ボタンやメニューの有効判定 |
| `toggleClipSelection`、`selectAllClips`、`clearSelection` | クリップ選択の操作 |
| `rowTopY(for:)`、`trackTopY(for:)`、`trackID(atTimelineY:)` | `timelineScroll` 座標系での行の位置。`visibleRows`（閉じたフォルダのトラックを除く）で数え、フォルダの行の上では `trackID` は nil |
| `beginMarquee(at:additive:)`、`updateMarquee(from:to:)`、`endMarquee()` | 枠選択。矩形に触れるクリップを選択（additive なら既存選択に追加） |
| `beginTimeSelection`、`updateTimeSelection`、`endTimeSelection` | 範囲選択（時刻は拍にスナップ、トラックは隣接範囲） |
| `deleteTimeSelection`、`cropToTimeSelection`、`splitAtTimeSelection` | 範囲編集（1 回の UNDO 手順） |
| `deleteSelectedClips` | 選択クリップをまとめて削除 |
| `copySelection`、`cutSelection`、`paste()` | クリップボード。ペーストは再生位置と選択トラック基準（足りないトラックは最終トラックへ）。トラックのオフセットは `visibleTracks` で数え、選択トラックが隠れているときはその下で最初に見えるトラックから（`pasteBaseIndex(in:)`） |
| `menuTargets`、`selectForMenu`、`splittableMenuTargets` | 右クリックの対象: 右クリックしたクリップが選択に含まれていれば選択全体、そうでなければそのクリップ（`selectForMenu` で選択）。`splittableMenuTargets` はそのうち再生位置が内側にあるもの |
| `toggleMuteMenuTargets`、`duplicateMenuTargets`、`splitMenuTargets`、`deleteMenuTargets` | 右クリックの対象への処理。ミュートは 1 つでも未ミュートがあれば全ミュート、なければ全解除。複製は対象をかたまりのまま先頭を再生位置へ置き、複製を選択。分割は再生位置にかかる対象を分割し両側を選択。いずれも 1 回の UNDO 手順（ミュートを除く） |
| `normalizeClips`、`reverseClips` | 右クリックの対象（選択に含まれていれば選択全体）に対する処理。ノーマライズはファイル全体のピークで 0 dBFS になるゲインを設定、逆再生は `Reverse_<トラック名>_NNN.wav`（`RecordingFileName`）を作って差し替え、フェードの前後を入れ替える |
| `stripSilenceClips` | 対象クリップの無音（全チャンネルのサンプルの絶対値が無音レベル以下）が指定秒数以上続く区間を `silenceRanges` で求め、残す区間ごとに `piece(from:to:)` を作って `AudioTrack.replaceClip(id:with:)` で差し替える（無音区間は捨てる）。音のある区間を、無音と接する端だけフェードの長さぶん無音側へ広げてピースにし、その端にフェード（既定 10 ms。無音の最短の長さの半分までに制限するので、隣のピースとは重ならない）を付ける。元のクリップと共有する端は元のフェードを保つ。20 ms 未満のピースは捨てられる。できたピースは選択される。設定値は `askStripSilenceSettings`（NSAlert）で尋ね、UserDefaults の `MyDAW.stripSilenceThresholdDB`（既定 −72 dB、−144〜0）、`MyDAW.stripSilenceMinimumDuration`（既定 1 秒）と `MyDAW.stripSilenceFadeMilliseconds`（既定 10）に保存する。音声ファイルは変更しない |
| `beginGroupDrag`、`updateGroupDrag(delta:)`、`endGroupDrag(trackDelta:)` | 選択クリップのまとめて移動（0 秒より前に出さない。トラック間は全クリップの移動先がある場合のみ＝`canMoveSelectedClips(trackDelta:)`。トラック数は `visibleTracks` で数える） |
| `layeringClips(for:)` | レーンの重なり計算に使うクリップ列。別トラックへのドラッグ中は、移動中のクリップを移動元から外し、移動先の最上位に加える |
| `duplicateSelectedClipsInPlace` | option ドラッグ開始時に、元の位置へ複製を残す（元の直下のレイヤー） |

### `TrackFolder.swift`（v2.1 新規）
| 型 | 内容 |
| --- | --- |
| `TrackFolder: ObservableObject`（@MainActor） | `id`、`name`、`color`、`isOpen`、`isMuted`、`isSoloed`（後の 3 つは `ProjectState` からだけ変更）。`rowHeight`（28pt、縦の拡大に追従しない） |
| `ArrangerRow: Identifiable` | 行。`.track(AudioTrack)`／`.folder(TrackFolder)`。`id`、`track`、`folder` |
| `ArrangerLayout` | `headerWidth`（230）、`folderIndent`（18、フォルダの開閉ボタンの幅）、`headerColumnWidth`（248。フォルダの有無で波形エリアの幅が変わらないよう常にこの幅） |

### `ProjectState+Folders.swift`（v2.1 新規）

`ProjectState` の拡張。トラックとフォルダの並びを扱います。

| API | 内容 |
| --- | --- |
| `folders`、`folder(withID:)`、`tracks(in:)` | フォルダの一覧と検索、フォルダ内のトラック |
| `visibleRows`、`visibleTracks`、`isTrackVisible(_:)` | 閉じたフォルダのトラックを除いた行・トラック。アレンジャーはこれだけを描く |
| `rowHeight(_:)` | 行の表示の高さ（トラックは `trackHeight × trackHeightScale`、フォルダは `TrackFolder.rowHeight`） |
| `rowsDidChange()` | `rows` の `didSet`。フォルダのブロック（ヘッダ直後の連続した行）の外にあるトラックの `folderID` を外し、`tracks` を更新する |
| `applyFolderStates()` | フォルダの M／S を各トラックの `isMutedByFolder`／`isSoloedByFolder` に反映。変化があれば true |
| `newTrackPlace()` | 「＋」のトラックの位置：カレントの下（そのフォルダ内）。閉じたフォルダならその末尾。カレントがなければ末尾 |
| `addFolder()` | カレントの上（カレントがフォルダ内ならそのフォルダの上）に空のフォルダ。名前 "Folder n"（翻訳あり） |
| `addTrack(above:)`、`addFolder(above:)` | ヘッダの右クリックメニューから。クリックした行の上（フォルダの行ではトラックをフォルダの先頭へ）。フォルダ内のトラックの上にはフォルダを作らない |
| `confirmDeleteFolder(id:)`、`deleteFolder(id:)` | 確認ダイアログ（中のトラックは削除されない旨）の後、ヘッダだけを消す。中のトラックはその位置に残り、フォルダから出る |
| `toggleFolderOpen(_:)` | 開閉。閉じるときは中のクリップ選択と、中を含む範囲選択を解除 |
| `toggleMute(for:)`、`toggleSolo(for:)`（`TrackFolder`） | フォルダの M／S。空のフォルダでは何もしない。トラック自身の値は変えない |
| `moveTrack(id:beforeRowID:folderID:)` | トラックを行 `beforeRowID` の前（nil は末尾）へ移し、`folderID` のフォルダに入れる（ブロック外なら `rowsDidChange` が外す）。範囲選択を解除し、M／S の効き方が変われば音量を更新 |
| `moveFolder(id:beforeRowID:)` | フォルダを中のトラックごと移す。移動先が別のフォルダのブロックの中なら何もしない |

---

## 3. 音声・デバイス・プラグイン（`Sources/Audio`）

### `AudioEngineManager.swift`

AVAudioEngine のグラフ、再生、録音、メトロノーム、メーター、プラグイン生成と GUI、書き出しを管理する中心クラス（@MainActor、`NSWindowDelegate`）。

#### 公開状態（抜粋）
`engine`、`isPlaying`、`isRecording`、`isPunchRecording`、`currentTime`（値は別オブジェクト `transportClock`（`TransportClock`）が持つ。再生中は毎秒 60 回変わり、エンジンから通知するとエンジンを監視する全ビュー（アレンジ・ミキサー・トランスポート）が再描画されるため。監視するのは `PlayheadLine`、`PlayheadBall`、`TransportTimeText`、録音中のテイク（`LiveRecordingClipView`）だけで、自動スクロールは `onReceive` で受け取る）、`bpm`、メトロノーム（有効・発音タイミング補正・音量）、`hardwareSampleRate`、`masterVolume`（値は別オブジェクト `masterVolumeState`。ドラッグのたびにエンジン全体を通知しないため。`MasterFaderColumn` だけが監視）、`masterPeak`、`masterStereoPeak`（どちらも値が変わったときだけ更新）、`recordingsDirectory`、`inputBufferFrameSize`、`manualRecordingCompensationMs`、選択中の入出力デバイス。`loadMonitor`（`AudioLoadMonitor`。更新がエンジン全体の再通知にならないよう別の `ObservableObject`）。

#### ノード構成（トラックごと）
| 辞書 | 役割 |
| --- | --- |
| `trackRenderers` | トラック 1 つにつき 1 つの `TrackRenderer`（`AVAudioSourceNode`）。トラック出力ミキサーのバス 0 につなぐ。サンプルレートが変わると作り直す |
| `trackOutputNodes` | トラック出力ミキサー（フェーダー音量・ソロ・ミュート）。ミュート・ソロは `audibility(tracks:fxChannels:)` で決まります（トラックの `effectiveMuted`／`effectiveSoloed`＝フォルダの M／S を含む）。トラックをソロにすると送り先の FX も聞こえます。FX をソロにするとその FX のリターンだけが聞こえます（送り元トラックはセンドへは送り続け、splitter → mainMixer の接続音量だけを `setTrackDryAudible` で 0 にします） |
| `trackDownmixNodes` | 各トラックのチェーン先頭（インサートの前）にある `MonoDownmixAudioUnit` |
| `trackDryDelayNodes`／`fxReturnDelayNodes` | 各トラックのドライ経路（分岐 → mainMixer。遅延 D。FX ソロ時のドライ消音も担当）と各 FX のリターン（PAN → 出力。遅延 D − 自分の遅延）にある `DelayCompensationAudioUnit`。`updateLatencyCompensation()` が設定 |
| `trackPluginNodes` | インサート（AU／`VST3AudioUnit`） |
| `trackPanNodes` | PAN ミキサー（インサートの後） |
| `trackSplitterNodes` | 分岐ミキサー（mainMixer と Send へ 1 対多接続、メーター計測点） |
| `sendGainNodes` | Send ごとのゲインミキサー |
| `inputMonitorNodes` | `InputMonitorAudioUnit`（I 有効時） |
| `fxInputNodes`／`fxPluginNodes`／`fxPanNodes`／`fxOutputNodes` | FX チャンネルの入力（フェーダー音量）・インサート・PAN・出力（メーター。ミュート時とソロで外れたときは音量 0） |
| `masterOutputNode`／`masterPluginNodes`／`masterMeterNode` | マスターボリューム・POST プラグイン・最終メーター |

#### 主な公開メソッド
- **グラフ同期**: `syncTracks(_:fxChannels:)`（トラック・FX・マスター・Send・インプットモニターを差分更新）、`syncTracks(_:fxChannels:masterPlugins:)`、`syncMasterPlugins`、`syncAfterClipEdit`（再生中は `rescheduleEditedClips` で、`ClipScheduleSignature` が変わったクリップと、それに重なるクリップだけを、再開時刻の再生位置から予約し直します。先に全トラックで「なくなったクリップ」のプレイヤーを止めてから予約するため、上のトラックへ移したクリップも止められません。ほかのクリップは鳴り続けます）、`updateMixerLevels`（音量・PAN・Send・FX）、`updateSendLevel`、`setClipMuted`、`setPluginEnabled`。
- **トランスポート**: `startPlayOrRecord(tracks:fxChannels:recordArmedTracks:)`（再生／録音開始。再生中なら停止）、`stop(tracks:)`、`rewind(tracks:to:)`、`seek(to:)`、`setPunchRange`（ロールバックの回の間は無視）。`recordRollbackDuration`（秒。`toggleTransport` が設定）: armed トラックがありパンチ範囲がない録音のとき、`beginPlayOrRecord` がその回を「再生位置でパンチイン、パンチアウト +∞」の録音にし（`isRollbackPass`）、再生位置をその分戻す。`stop` で一時的な範囲を消す。`recordingTakePunchIn`／`recordingTakePunchOut`: 録音中のテイクのパンチ範囲（`recordingTakePunchTrim`）。ファイル確定まで保持し、波形レーンはその範囲内だけを描く。`songEndTime`: 再生位置タイマーがこれをまたぐと `onReachSongEnd` を呼びます（それより前から再生を始めた場合のみ）。この停止では、録音したクリップを終了位置で切り揃え、再生位置を終了位置に置きます。
- **デバイス**: `applyAudioDevices(inputDeviceID:outputDeviceID:sampleRate:)`（デバイスのサンプルレートを設定し、デバイスが変わった場合は `bindIODevice`）、`applyInputBufferFrameSize`、`applyAutomaticTimingCompensation`。
- **プラグイン**: `openPluginUI(pluginID:)`、`isPluginUnavailable`、`capturePluginStates`、`setSavedPluginStates`、`prepareForPluginGraphRestore`。
- **その他**: `exportMasterMix(to:startTime:endTime:tracks:fxChannels:progress:)`（マスター経路を実時間でハードウェアのレートの 32-bit float ファイルへ。取り込んだ割合を通知し、レートを返す）、`shutdown()`（エンジン停止、VST3 解放、macOS 既定入出力デバイスの復元）、録音フォルダ関連。

#### 主な内部処理
| メソッド | 内容 |
| --- | --- |
| `startMetronome(at:)` | クリックを 256 拍分予約し、最後のクリックで続きを予約。トランスポート開始時はその開始時刻と位置から、再生中の ON・BPM 変更・続きの予約では、頭が欠けずに鳴らせる最も早い時刻（`earliestPlayerStartHostTime`）とその時刻のトランスポート位置（`transportPosition(atHostTime:)`）から、次の拍に合わせる |
| `setupEngine()` | 入力フォーマット取得、マスター経路と最終メーターの構築、クリック、入力タップ、インプットモニター接続、スライス上限引上げ、エンジン開始 |
| `bindIODevice(inputDeviceID:outputDeviceID:)` | 選択デバイスを macOS の既定入力・既定出力に設定する（入力を使う AVAudioEngine は既定入出力の集約デバイスで動作するため）。初回に元の既定を記録し、`restoreOriginalDefaultDevices()` が `shutdown()` で戻す |
| `startMeterTimer` | 30 Hz でピークを集計し通知。マスターのレベルは別オブジェクト `masterMeter`（`TrackMeter`）が持ち、変わったときだけ通知する（`MasterFaderColumn` だけが監視）。`masterPeak` は通知しない内部値 |
| `wireSend` | Send のゲインミキサーを FX 入力へ接続。`wiredSendTargets` で接続先を覚え、変わったときだけつなぎ直す（毎回の再接続はインプットモニター有効時に `mixingDest` 例外になるため） |
| `applyDeferredRewiresWhenQuiet` | 停止時に、保留した分岐の組み替えとインプットモニターの接続を、マスター出力が -60 dB 未満になるまで（最大 8 秒）待ってから行う。待機中は `isWaitingForQuietRewire` が立ち、`syncTracks` も組み替えをこちらに任せる。再生が始まれば中止し、次の停止で再試行 |
| 停止時の録音確定（`stop` 内のタスク） | writer を確定してクリップを読み込む。録音したファイルがあるときだけ `syncTracks` を呼ぶ |
| `installAudioUnits`／`installFXAudioUnits`／`installMasterAudioUnits` | プラグインを非同期生成し、挿入順に直列接続。VST3 は `VST3AudioUnit` を生成してインスタンスを結び付ける |
| `connectTrackChainTail` | チェーン末尾 → PAN → 分岐 → mainMixer＋Send の配線。1 対多接続は**エンジン停止中のみ**（再生中は `pendingSplitterRewires` で停止時まで保留） |
| `connectReformatting` | 接続先／元の AU が描画リソース確保済みでフォーマットが変わる場合、先に解放してから接続（-10865 例外の回避） |
| `setMixerVolume` | 音量変更後にミキサーを `reset()`（無音入力で音量ランプが止まる問題の回避） |
| `syncTracks` の再生計画 | トラックごとに `TrackPlaybackPlan.make(for:)`（ファイルのあるミュートでないクリップ、`ClipLayering.segments` の hidden を除いた区間、`spans`）を作り、`setPlan` で渡す。再生中でも再起動はしない。`setClipMuted` も計画を作り直す |
| `startPlayback` | 全レンダラーを `prepare(renderFrom:)` し、開始位置のブロックが読み終わるのを待ってから（24 トラックで数 ms、最大 2 秒）、開始時刻（`nextTransportStartTime`。メトロノームの `play(at:)` 2 回分だけ余裕を足す）を決め、`beforePlayersStart`（録音・メトロノーム）の後に各レンダラーを `start(anchorHost:anchorFrame:)`。anchorFrame は「開始位置 ＋ そのトラックの先読み（自分のインサートの遅延 ＋ D）」。`play(at:)` を使わないので、エンジンのロックを長く握ることも、メインスレッドが待たされることもない。停止は `stopRenderers`（先読みが間に合わなかったサイクル数をログに出す） |
| `processInputAudioBuffer` | 入力タップ。ピーク計算、hostTime によるサンプル単位のトリミング、armed トラックのチャンネル抽出と書き込み |
| `startRecording`／`stop` | writer 作成、録音中クリップのミュート、パンチ時は通し録音 → 停止時 `trimToPunchRange`（10 ms フェード付与） |
| `updatePunchRecordingState` | 30 Hz タイマーでパンチ範囲の入退出を判定し、範囲内のみ既存クリップをミュート |
| `applyInputMonitoringIfNeeded`／`connectInputMonitors` | I ボタン状態に合わせて inputNode → `InputMonitorAudioUnit` → トラック出力を接続（エンジン停止中に実施） |
| `raiseMaximumFramesPerSlice` | 入出力ユニットのスライス上限を 4096 に上げる（全ノードに反映される） |
| `releaseVST3Instances` | 終了時にエディタを閉じ、ラッパーから参照を外し、VST3 インスタンスを破棄 |
| プラグイン GUI 群 | `requestOriginalPluginUI`、`presentPluginViewController`（ウィンドウをビューの実寸に合わせ、以後のサイズ変更に追従）、`presentGenericPluginView`、`openVST3PluginUI` |

#### スレッド・ロック
`captureLock`（録音設定・writer）、`recordingTimingLock`（開始時刻）、`peakLock`（ピーク）。タップと Timer はこれらを介してメインスレッドと値を交換します。

### `ExportEncoder.swift`（v2.2 新規）
リアルタイムで取り込んだファイルを、書き出す形式に変換する（`encode(source:to:settings:progress:)`。メインスレッド外で実行し、チャンクごとに `Task.isCancelled` を確認）。
- 取り込みファイルを 32,768 フレームずつ読む。書き出しのレートが取り込みのレートと違えば `AVAudioConverter`（品質 max、`AVSampleRateConverterAlgorithm_Mastering`）で変換する。
- **WAV**: 24-bit は float のまま `AVAudioFile` に変換させる。16-bit はここで量子化する：±1 LSB の TPDF ディザ（xorshift32 の一様乱数 2 つの差）を加え、丸めて Int16 にクリップ。
- **MP3**: LAME（`Contents/Frameworks` の `libmp3lame.0.dylib`。初回使用時に `dlopen`／`dlsym` で読み込むので、LGPL のライブラリを差し替えられ、無くてもアプリは動く。その場合 `isMP3Available` が false になり、ダイアログで MP3 を無効にする）。ジョイントステレオ、`lame_set_quality(2)`。固定は `lame_set_brate`、VBR は `vbr_mtrh` と `lame_set_VBR_q` 0／2／4。`lame_encode_buffer_ieee_float` でエンコードしてフラッシュし、最後に `lame_get_lametag_frame`（長さとエンコーダ遅延を持つ Xing／LAME ヘッダ）を先頭フレームに上書きする。ID3 タグは付けない。

### `ClipAudioProcessing.swift`（v1.6 新規）
クリップが参照するファイル範囲に対するオフライン処理（メインスレッドで同期実行）。
- **`peakAmplitude(of:sourceStartTime:duration:)`**: 全チャンネルの最大絶対値（ノーマライズ用）。
- **`silenceRanges(of:sourceStartTime:duration:thresholdDB:minimumDuration:)`**: 範囲を 65,536 フレーム単位で読み、全チャンネルのサンプルの絶対値が `thresholdDB`（dBFS を線形に換算）以下のフレームが `minimumDuration` 以上続く区間を、範囲の先頭からの秒で返す（無音部分をトリム用）。判定はサンプル単位で、RMS などの時間平均は取らない。
- **`writeReversed(from:sourceStartTime:duration:to:)`**: 範囲を末尾から 65,536 フレーム単位で読み、各チャンクを反転して 32-bit float WAV へ書く。
- **`is24BitPCM(_:sampleRate:)`**: 指定レートの 24-bit 整数 PCM かどうか（取り込み時に変換が必要かの判定）。
- **`writeConverted(from:to:sampleRate:)`**: AVAudioConverter（最高品質のサンプルレート変換）でファイル全体を指定レートの 24-bit 整数 WAV に変換（チャンネル数は維持）。

### `VST3AudioUnit.swift`
VST3 インスタンスを AVAudioEngine グラフへ組み込むアプリ内 AUv3（`aufx`/`vst3`/`MyDW`）。
- **`registration`**: `AUAudioUnit.registerSubclass` を 1 回実行。
- **`attach(_:)`／`detachInstance()`**: 処理対象の `VST3NativeInstance` を結び付け／外す（停止中のみ）。
- **`shouldBypassEffect`**: 変更をカーネルのバイパスフラグへ反映。
- **`latency`**: VST3 の `latencySamples` を秒で返す（トラックの遅延補正に使用）。
- **`internalRenderBlock`**（RT）: 入力を事前確保バッファへ pull、出力が入力と重ならないバッファを用意して `processStereo` を呼ぶ。同一サンプル時刻で 2 回呼ばれた場合は前回結果を再生（状態の二重進行を防ぐ）。処理失敗・バイパス時は入力を素通し。

### `InputMonitorAudioUnit.swift`
多チャンネル入力から、トラックの入力チャンネル（モノは L/R 両方へ複製）を抽出するアプリ内 AUv3（`aufx`/`inmn`/`MyDW`）。`configure(channelOffset:isStereo:)` は停止中に設定。入力バス数はデバイスのチャンネル数に合わせて確保します。

### `TrackRenderer.swift`（v2.0 新規）
トラックのクリップを再生する仕組み。以前はクリップ 1 つにつき 1 つの `AVAudioPlayerNode` を使っていたが、`play(at:)` は 1 回ごとにレンダー 1 回分待たされ、その間エンジンのロックを握るため、クリップが多いと再生開始時に UI 全体（カーソル・メーター）が止まった。

- **`TrackPlaybackPlan`**: メインスレッドでクリップから作る値（ファイル、位置、ゲイン、区間、`spans`）。読み込みスレッドは `AudioClip` に触れない。
- **`TrackRenderer`**: `AVAudioSourceNode` を 1 つ持つ。描画スレッドは、先読み済みのブロック（4,096 フレーム × 48 スロット、約 4 秒）から自分の位置の分をコピーするだけ。タイムラインのフレーム位置は「`anchorFrame` が `anchorHost` に聞こえる」対応を、最初のサイクルでサンプル時刻に換算して求める。スロットは連番（書き込み中は奇数）で守り、描画スレッドは待たず、書きかけのブロックは鳴らさない（無音にして `underruns` を数える）。録音中のミュートは約 5 ms のランプ。
- **`TrackStreamer`**: 全レンダラーを順番に回るバックグラウンドスレッド（1 回に各トラック最大 4 ブロック）。再生位置の先のブロックを、計画に従ってファイルから読み、ゲインとフェード・クロスフェード（`ClipLayering.Envelope`）を掛けてミックスする。計画が変わると、再生位置の 2 ブロック先以降を読み直す（直前のブロックは書き換えない）。ファイルは先読みの範囲で使うものだけを開く。
- **`ClipReader`**: ファイルを出力レートのステレオとして読む。レートが違うファイルは `AVAudioConverter` で連続的に変換する。
- **アトミック操作**: Swift の Atomics は macOS 15 以降のため、`VST3Host/RealtimeAtomics.cpp` の `MyDAWAtomicLoad64`／`MyDAWAtomicStore64`／`MyDAWMemoryFence` を `@_silgen_name` で呼ぶ。

### `DelayCompensationAudioUnit.swift`（v1.8 新規）
`StereoDelayLine`（レンダースレッド用のリングバッファ。保持できない遅延は素通し）と、`delayFrames`・`isMuted`（約 5 ms のランプ）を持つアプリ内 AUv3（`aufx`/`dlcp`/`MyDW`）。最大 1 秒まで。自身のレイテンシーは 0 と報告します。`VST3AudioUnit` も `StereoDelayLine` を使い、バイパス時の出力をプラグインのレイテンシー分だけ遅らせます。

`AudioEngineManager.updateLatencyCompensation()` は各チェーンの `auAudioUnit.latency` を合計し（バイパス中も含む）、D = FX チャンネルの遅延の最大値を求めて遅延ノードに設定し、全プラグインに `kAudioUnitProperty_Latency` のリスナーを付け、再生中に値が変わったら各レンダラーの `anchorFrame` を合わせ直します（`updateRendererAnchors`）。`transportPreRoll` P = D ＋ トラックのインサートの遅延の最大値。トランスポートの開始時刻はエンジンの計算済み区間の先（`lastRenderTime` から IO バッファ 2 つ分・最低 50 ms）に P を足した時刻で、各トラックのレンダラーは自分の先読み（自分の遅延 ＋ D）だけ早く音を出すので、開始位置以降の音は欠けません。録音は、開始時刻が決まった後・レンダラーの開始前に呼ばれる `beforePlayersStart` で、テイクのファイル作成と入力の取り込みを始めます。`exportMasterMix` はエンジンの処理開始を待ってから、同じ方法でトランスポートを始め、`ExportWindow` で「開始位置の音が聞こえるホストタイム（＋マスタープラグインの遅延）」から `end − start` 秒分のフレームだけをタップから切り出します。範囲を取り込みきれなかったときはエラーにします。

### `MonoDownmixAudioUnit.swift`
各トラックの出力ミキサーの直後に置くアプリ内 AUv3（`aufx`/`mndx`/`MyDW`）。`isMono`（トラックがモノラル）のときは `(L + R) / 2` を L/R 両方に書き、それ以外はそのまま通します。モノラルのクリップは `TrackRenderer` が L = R に展開して届けるので、どちらの場合も変化しません。

### `VST3NativeInstance.swift`
C++ ブリッジのハンドルを保持する Swift ラッパー（`@unchecked Sendable`）。
- **`init?(descriptor:sampleRate:maxFrames:)`**: モジュール読込とコンポーネント初期化。
- **`processStereo(...)`**（RT）: `maxFrames` 単位に分割して処理。
- **`captureState()`／`restoreState(_:)`**、**`attachEditor(to:)`**（`resizeView` コールバック登録）、**`currentEditorSize()`**、**`removeEditor()`**、`latencySamples`。
- **deinit**: エディタを外して `MyDAWVST3Destroy`。

### `AudioLoadMonitor.swift`（v1.8 新規）
ステータスバー用のオーディオ処理負荷と音飛びの検出（`@MainActor`。`AudioEngineManager.loadMonitor` が保持し、`init` で `start(engine:)`、`shutdown` で `stop()`）。
- **負荷**: `engine.outputNode.audioUnit` に `AudioUnitAddRenderNotify`（バス 0 のみ）を付け、pre／post render の間を `mach_absolute_time` で計測。負荷＝描画時間 ÷ 1 サイクルの長さ（`frames / sampleRate`）。描画スレッドは事前確保した `RenderStats` に累計とピークを書くだけ（ロック・メモリ確保なし）。
- **音飛び**（0.3 秒以内の重複は 1 回）: 負荷 > 1 のサイクル、デバイスのサンプル時刻が先へ飛んだとき（サイクルの抜け）、出力ユニットの現在のデバイス（`kAudioOutputUnitProperty_CurrentDevice`）からの `kAudioDeviceProcessorOverload`。入力使用時はこれが入出力の集約デバイスなので `inputNode` には触れない（入力のないエンジンで触れると構成が変わるため）。
- **再起動の扱い**: 0.25 秒を超える空白、またはサンプル時刻の巻き戻りを再起動とみなし、続く 16 サイクルは計測も判定もしない。デバイスのオーバーロード通知は 1 秒間無視。
- **メイン側**（10 Hz Timer）: 公開するのは `load`（区間のピーク。上昇は即時、下降は 0.75 の平滑化、0.5% 単位）と `isShowingDropout`（最後の音飛びから 3 秒、`dropoutDisplaySeconds`）だけ。`averageLoad`・`peakLoad`（直近 1 秒）、`processCPU`（`getrusage`、全コア比）、`dropoutCount`、`lastDropoutDate` はツールチップ用の通常プロパティ。1 秒ごとに出力ユニットやデバイスの変化を確認し、付け直す。
- **テスト用**: UserDefaults の `MyDAW.loadTestOffset`（%）を描画スレッドで各サイクルの負荷に加算し、色や音飛び表示の経路を確認できる（`open MyDAW.app --args -MyDAW.loadTestOffset 70`、または `defaults write com.tokada.MyDAW MyDAW.loadTestOffset -int 70`。`defaults delete …` で解除）。有効な間は黄色の「TEST +n%」を表示。

### `PluginManager.swift`
- **`TrackPluginDescriptor`**: ID、名前、種類（AU／VST3）、bundle パス、VST3 UID、AU コンポーネント記述、有効状態、UI 互換性。
- **`discoverAvailablePlugins(onLog:completion:)`**: バックグラウンドで AU（`AudioComponentFindNext`）と VST3 を検出。**同名の AU がある VST3 は除外**。MyDAW 自身が登録する内部 AU（メーカーコード `MyDW`：Mono Downmix、VST3 Host、Delay Compensation、Input Monitor）は一覧に出さない。
- **VST3 検出**: `scanVST3Bundle` → キャッシュ（パスと更新日時）を確認 → なければ `runScanChild`（`MyDAW --scan-vst3 <path>`、60 秒でタイムアウト、クラッシュ時は空結果をキャッシュ）。
- **`runVST3ScanChildIfRequested()`**: 子プロセス側の処理（列挙して `MYDAW_VST3_SCAN_RESULT:` 付き JSON を出力）。

### `VST3HostBridge.swift` / `VST3Host.swift`
`VST3HostBridge.enumerate(bundleURL:)` は C++ の `MyDAWVST3EnumerateAudioEffects` を呼び、UID・名前・ベンダー・バージョンを返す（子プロセスでのみ使用）。`VST3Host.swift` はホスト抽象のプロトコルと未対応実装。

### `AudioDeviceManager.swift`
Core Audio HAL から入出力デバイス、入力チャンネル（モノ／ステレオ候補）、サンプルレート、バッファサイズを取得・設定。選択デバイスは UID で UserDefaults に保存。エンジンへの実際の割り当ては `AudioEngineManager.bindIODevice`（macOS 既定デバイスの切り替え）が行う。

### `AudioDiskWriter.swift`
録音バッファをコピーしてシリアルキューで 24-bit WAV へ書き込む。ファイル名（`RecordingFileName`）は `<トラック名>_<テイク番号>.wav`（例 `Bass_001.wav`）。トラック名は、どの言語の文字も残し（NFC に正規化）、空白と `_` の連続は `_` 1つにまとめ、その他の記号は取り除き、40 文字で切ります（何も残らなければ `Track`）。テイク番号は、Recordings と Recordings/Unused で使われている最大の番号 ＋ 1。ファイルは `init` で作られるので、同じ名前のトラックを同時に録音しても番号は重なりません。逆再生は `Reverse_<トラック名>`、取り込みは `Import` を元にした名前（`Import_001.wav`）。（v1.8 より前は `Rec_<トラック名>_<ID6桁>_<ch>ch_<rate>_24bit_<日時>.wav`、`Import_<名前>_<16進8桁>.wav`、`Reverse_<ファイル名>_<16進8桁>.wav`）`finalize()` で確定して URL を返す。

### `GenericAUParameterView.swift`
AU のパラメータツリーからスライダー一覧を生成する汎用 UI（カスタム GUI が無い／使えない場合）。

---

## 4. ビュー（`Sources/Views`）

### `MainDAWView.swift`
上からトランスポート、アレンジャー、ミキサー、ステータスバー（デバイス、`AudioLoadIndicator`、録音フォルダー、ショートカットの案内）を配置。タイトルバーの帯（`.hiddenTitleBar` で標準のタイトルは非表示）の中央に `ProjectState.openProjectName` をオーバーレイで表示する（帯の高さは GeometryReader の `frame(in: .global).minY`＝内容の上端までの距離。その分だけ上にずらして表示し、クリックは通す。`ignoresSafeArea` した GeometryReader の `safeAreaInsets.top` はこの環境では 0 になり使えなかった）。ウィンドウのタイトル（`navigationTitle`）も「MyDAW - <名前>」にする（Window メニュー・Mission Control 用。プラグインのウィンドウとは「MyDAW」で始まるかで区別している）。`currentProjectURL` は表示を更新するため `@Published`。起動ログ（プラグイン検出の進捗。表示を終えたらビュー階層から外す）、マスター書き出しダイアログ、ウィンドウを閉じる時の確認、キー処理（`SpacebarHandler`: ⌘Z／⇧⌘Z／⌘Y、← で先頭へ、R で録音（`toggleTransport(recordArmedTracks: true)`。録音ボタンと同じ。キーリピートは無視）、⌘X／⌘C／⌘V／⌘A を `EditCommand` として処理、Esc で選択解除（イベントは通過させる）。テキスト入力中は処理しない）を含む。
- **`MasterExportDialog`**: ファイル名欄（拡張子は形式に合わせて表示）、保存先と**変更…**、形式、サンプルレート（MP3 は 44.1／48 のみ）、続いて WAV ならビット深度、MP3 ならモードとビットレート／VBR 品質、開始・終了（秒）、2 段階の進捗バー。設定を変えると `ExportSettings.normalize` で正し、「完了」表示を消す。`ExportEncoder.isMP3Available` が false なら MP3 を無効にする。
- **最小サイズ**: 外枠は `.frame(minWidth: 800)` だけで、高さの下限は付けない（付けると内容の最小の高さが隠れ、ウィンドウが内容より小さくなってトランスポートとミキサーが切れる）。ウィンドウの最小の高さ＝トランスポート＋アレンジャーの最小（`minimumArrangerHeight` = 180pt）＋ミキサー＋ステータスバー。
- **アレンジャーの高さ**: `arrangerHeight` を読み取り、`MixerView` へ `growthLimit`（アレンジャーが最小になるまでの余り）として渡す。
- **`TitleBarZoomHandler`** を背景に置く（`WindowCloseHandler.swift`）。
- **`refreshToolTips()`**: プロジェクトを開いたとき・起動ログが消えたときに、メインウィンドウの幅を 1pt 変えて戻し、ツールチップ領域を再登録させる（オーバーレイが消えただけでは SwiftUI が再登録しないため）。

### `ProjectSelectionView.swift`
起動画面。New Project（保存パネルで指定）と Open Project（⌘O、`.mydaw` を選択）。バージョン表示。ボタンの下に「最近使ったプロジェクト」一覧（`RecentProjects.shared`、スクロール可、520 × 240 pt）。各行 `RecentProjectRow` は名前をオレンジのリンクで表示（ホバーで下線と指カーソル、ツールチップにパス、クリックで `onOpenRecent`）し、右に最終保存日時。ファイルがない項目は取り消し線付きでクリック不可。右クリックメニューに Remove from List。

### `AudioLoadIndicator.swift`（v1.8 新規）
ステータスバーの「CPU [バー] 34% ●音飛び」。`AudioLoadMonitor` を監視（再描画はこのビューだけで最大 10 Hz）。バー（64 × 7 pt のカプセル、0.1 秒のリニアアニメーション）の色は緑（0）→黄（0.6）→オレンジ（0.8）→赤（1.0）を補間。数値は 100% を超えることもある。音飛びマークは非表示でも場所を確保（opacity）し、表示がずれない。ツールチップは表示時に文字列を作る AppKit のツールチップ（`DynamicToolTip`、`NSViewToolTipOwner`）で、頻繁な再描画でも表示される。

### `TransportBarView.swift`
- ボタン（左から）: 設定、Undo、Redo、Rewind、Play／Pause（Space）、Record（armed トラックを録音。R キー）、P（パンチ有効化）、ロールバック（↺ と小節数。`recordRollbackEnabled` を切り替え。パンチ ON の間は薄く表示、再生中は無効。ツールチップは `rollbackHelp`）、メトロノーム（再生・録音中も切り替え可。右クリック（`RightClickCatcher`：ローカルイベントモニター）でクリックの音量の縦フェーダー `ClickVolumeFader` をポップオーバーで開き、`metronomeVolume` を再生中も即時変更）、保存、開く、スナップ、自動スクロール（`ProjectState.autoScrollEnabled`。UserDefaults `MyDAW.autoScroll` に保存）。ツールチップは標準 `.help`。
- 表示: TIME（時間／小節・拍）、TEMPO（BPM 入力 20〜400）、FORMAT（24-bit WAV とサンプルレート）。幅は中身に合わせる。
- バー全体は左寄せで、ウィンドウより幅が広いときは右端から切れる（`frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)` と `clipped()`）。
- 右側: 時間軸ズーム、トラック高さ倍率、波形縦倍率、ルーラー切替（v2.1 でマスター音量のスライダーは削除。マスター音量はミキサーの MASTER フェーダーで操作）。
- **`BufferSettingsView`**（歯車、見出し「Settings」。`projectState` も受け取る）: `Divider` で区切った大項目ごとに `sectionHeader` と説明文（`note`）— 環境（言語、`AppLanguage`）、オーディオ（録音フォルダ、入力／出力デバイス、サンプルレート 44.1〜96 kHz、バッファサイズ）、補正（録音遅延（オプション）、クリックタイミング）、その他（クリックの音量、録音時のロールバックの小節数。`commitRollbackBars` が Return か適用で 1〜16 に収める）。言語・デバイス・サンプルレートの変更が適用されると `onAudioDevicesChanged` で再起動の確認を呼ぶ。

### `ArrangerView.swift`
トラックヘッダーと波形レーンの並び（`visibleRows`。フォルダの行は `FolderHeaderView` と空のレーン `FolderLaneView`。フォルダ内のトラックは `folderIndent` だけ右へずらし、左にフォルダ色の線 `FolderIndentGuide`）、ルーラー（秒または小節・拍、クリックでシーク）、プレイヘッド、パンチ範囲（ルーラー上の左右ハンドルを拍単位でドラッグ）、＋メニュー（トラックを追加／フォルダを追加）、自動スクロール（`autoScrollEnabled` が ON のときだけ、再生位置が右端 10% に入ると先へ送る）、Delete キー、枠選択の矩形と範囲選択の帯の表示。
- **座標空間 `timelineScroll`**: 波形レーン全体の ZStack に付ける。`trackTopY`、`trackID(atTimelineY:)`、枠選択、範囲選択、クリップのドラッグはこの座標で測る。
- **クリップのドラッグ表示**: `clipDragPreviews` が `clipDragPreview` の全クリップを、自分のトラックの位置から縦の移動量だけずらして描く（波形・フェードは移動先の重なりで表示）。
- **トラックとフォルダの並べ替え**: 波形レーンの領域は表示域の下端まで広げてあり、最後のトラックより下へドラッグしたレーンも切れない。ヘッダの `DragGesture`（`reorderGesture`、4pt 以上、ヘッダ列の座標空間 `trackHeaderColumn`）。フォルダをドラッグすると中のトラックも一緒に動く（`reorderMovingIDs`）。`reorderDropTarget()` が落とし先（`RowDropTarget`：前に入る行、入るフォルダ、線の高さ、インデントの有無、閉じたフォルダ）を決める：動かす行を除いた行の間のうちポインタに最も近い所。トラックは、下の行がフォルダ内のトラックならそのフォルダ内。開いたフォルダのヘッダ・最後のトラックの直下は、ポインタがまだその行の上ならフォルダ内、下の行にかかればフォルダ外。閉じたフォルダのヘッダの中央半分の上ではそのフォルダの末尾。フォルダは、下の行がフォルダ・フォルダ外のトラック・末尾の所にだけ落とせる。`dropIndicator` が白い線（フォルダ内はインデント）か閉じたフォルダの枠を描く。`ReorderLift` はドラッグ中の行に枠・影を付けて手前に出す。離すと `moveTrack`／`moveFolder` をアニメーション付きで実行。
- **ヘッダの右クリックメニュー**（`headerMenu(for:)`）: `LaneMenuMonitor` で開く `NSMenu`。トラックならカレントにする。トラックを追加（`addTrack(above:)`）、フォルダを追加（フォルダ内のトラックでは出さない）、区切り線、ミキサーに表示（`mixerScrollRequests` へ行 ID を送る）。
- **横スクロール**: `timelineScrollTime` の変更は `setTrackScrollOffset` でトラックの `NSClipView` を直接スクロールし（`followScrollTime`。クリップビューがすでにその位置なら何もしない。ズーム後は同じ時刻でもスクロール量が変わるので、時刻でなく pt で比べる）、次のメインキューで新しいレイアウトの後にもう一度合わせ直す（`scrollTo` は古いレイアウトで位置を決めることがあるため）。ズーム後は内容の幅が数回のレイアウトの後に広がり、それまでスクロールが手前で止められるので、`ScrollOffsetObserver` は内容（documentView）の大きさの変化も監視し、届いていない位置へ広がるたびにスクロールし直す。0.5 秒たっても届かなければ、`timelineScrollTime` をトラックの実際の位置に合わせる。`ScrollOffsetObserver` はユーザーのスクロールを `timelineScrollTime` へ戻し、毎回の位置を `TimelineScrollPosition.trackOffset` に知らせる。
- **ルーラーの位置**: ルーラーはトラックの実際のスクロール量でずらす（`TimelineScrollOffset` が `trackOffset` を使う。なければ `time × pixelsPerSecond`）。ズームでトラックが一瞬止められても、ボールと再生位置の線は一致する。
- **タイムラインの長さと幅**: `songLength()` ＝ 60 秒、最後のクリップの終わり＋5 秒、終了フラグ＋5 秒のうち最大。ルーラーのクリックや再生しっぱなしでは延びない。`timelineWidth(viewportWidth:)` ＝ 表示幅と、（曲の長さ・`parkedPlayheadTime`・`playheadExtentTime` の最大）× 拡大率の大きいほう。`playheadExtentTime` は再生・録音中だけ再生位置の 1 画面＋30 秒先まで上げ（自動スクロールに 1 画面先の内容が要る）、停止で 0 に戻す。`parkedPlayheadTime` は、停止中に曲の終わりより先にある再生位置を残す（それ以外は 0。クロックから更新するので、先頭へ戻すと幅も戻る）。`pastSongShade` が曲の終わりより先のルーラーとレーンを暗くする（黒 28%、操作は受けない）。
- **`KnobOnlySlider`**: 下部の横スクロールバー。つまみ（●）のドラッグでだけ動き、つまみ以外のクリックは無視。
- **`ArrangerWheelMonitor`**: アレンジャー全体（ルーラー含む）でのスクロールホイールとピンチをローカルイベントモニターで受ける。ルーラー上のホイールとピンチはポインター位置を基準に時間方向ズーム、⌥＋ホイールはトラック高さ（ポインター位置を中心）、⌥⇧＋ホイールは波形縦倍率（shift による横スクロール変換にも対応）。処理したイベントはスクロールビューへ渡さない。

### `TrackHeaderView.swift`
幅は `ArrangerLayout.headerWidth`。左端のカラーバー（クリックで `TrackColorPalette`：16 色プリセット＋カスタム。フォルダとミキサーの線でも使う）、名前（ダブルクリックで編集）、モノ／ステレオ切替（1／2）、削除、R／M／S／I（M／S の表示は `HeaderToggleLabel`：フォルダで有効な間はグレーで点灯し、ボタンは無効）、入力チャンネル選択、メーター（録音待機時は入力、それ以外は出力）、下端ドラッグで高さ変更（`VerticalResizeHandle`。画面座標で測り、倍率で割って `trackHeight` に反映。表示の高さは `minimumRowHeight` 56pt 以上）。中身は上詰めで、低いときはメーターから下が不透明な下端の帯の裏に隠れる。それ以外の所のドラッグはトラックの並べ替え（ジェスチャーは `ArrangerView` が付ける）。

### `FolderHeaderView.swift`（v2.1 新規）
フォルダの行（幅 230pt、高さ `TrackFolder.rowHeight` 固定）。左端のカラーバー（`TrackColorPalette`）、▼／▶（`toggleFolderOpen`、幅は `folderIndent`）、フォルダアイコン、名前（ダブルクリックで編集）、M／S（`HeaderToggleLabel`、空のフォルダでは無効）、✕（`confirmDeleteFolder`）。背景にフォルダの色を薄く重ねる。クリックしてもカレントにならない。ドラッグと右クリックは `ArrangerView` が付ける。

### `WaveformLaneView.swift`
1 トラック分のレーン。
- **レーン**: 空き領域のドラッグで枠選択（⌘ で範囲選択）、クリックで選択解除、Finder からの WAV ドロップで取り込み。
- **`AudioClipView`**: クリック（⇧／⌘ で追加・解除）、ドラッグで選択クリップをまとめて移動（⌥ で複製、⌘ で範囲選択）、左右トリム（左端はファイルの先頭で止まる。開始位置は「元の開始位置＋制限後の移動量」なので、クリップ自体は動かない）、ゲイン（上辺中央）、フェードイン／アウト（左上・右上）、フェードカーブ（フェード線中央のひし形。上下ドラッグで `FadeCurve.withMidpoint`、ダブルクリックで `.auto`）。ゲイン・フェード・カーブのハンドルは押した時点からドラッグとして扱い、値を `EditValueTooltip` で表示。トリムのハンドルは描かず、クリップ左右の幅 10 pt の透明な帯で受け、ポインタを矢印にする（開始側は右向き、終了側は左向きのみ）。フェードの点はその点を中心とした 16 pt 四方だけで受け、ポインタを指の形にする（カーブのひし形も同じ。ゲインの線は 24×13 pt で受け、上下矢印。ファイル末尾の `hoverCursor`。macOS 15 以降は `pointerStyle`（`.columnResize(directions: .trailing／.leading)`／`.link`／`.rowResize`）、それより前は `onContinuousHover` で移動のたびに `NSCursor.set()`（`resizeRight`／`resizeLeft`／`pointingHand`／`resizeUpDown`）。`onHover` で push した形はホストビューにすぐ矢印へ戻される）。
- **右クリックメニュー**: `LaneMenuMonitor`（右クリック／Control クリックのローカルモニター。`ClosureMenuItem` とともにトラックヘッダーのメニューでも使う）がクリック位置で AppKit の `NSMenu` を組み立てる（SwiftUI のメニューは開く前に作られ、直前の選択変更を反映できないため）。範囲選択の内側なら範囲メニュー、クリップ上なら `selectForMenu` で選択してからクリップメニュー、それ以外は Cut／Copy／Paste のメニュー（`LaneMenu`）。クリップメニュー: ファイル名（複数なら個数）、Cut／Copy／Paste、Normalize、Reverse、Strip Silence、ファイル選択（1 つのときのみ）、ミュート、複製、分割、削除。複数のときは項目名に個数を付ける。
- **表示**: 波形は `ClipLayering.envelope` の音量で描画し、上位クリップに完全に隠れた区間だけを暗くする。覆われた端のフェードハンドルは非表示。

### `PreviewStretch.swift`（v2.0 新規）
**横の拡大・縮小とトラックの縦幅**: ルーラー・ヘッダ・クリップの箱はすぐに新しい値で描くが、波形だけは `ProjectState.waveformRenderPixelsPerSecond`／`waveformRenderTrackHeightScale`（波形を描く倍率）で描いたまま、`scaleEffect` で今の箱の大きさに伸縮する。`WaveformCanvas` は `Equatable`（`.equatable()`。エンベロープは値型の `ClipLayering.Envelope`）なので、入力が変わらなければ描き直さない。倍率の変更が 0.1 秒止まると `syncWaveformRender` が描く倍率を合わせ、波形を正しく描き直す（描画範囲 `drawWindow` もこのときに合わせ直す）。プロジェクトを開いたときはすぐに合わせる。この 2 つの倍率がずれている間（変更中）は、`AudioClipView` がトリム・ゲイン・フェード・カーブのハンドルを作らない（クリップごとに何個もの部品を毎ステップ動かさずに済む）。レーンのグリッド線も `drawWindow` の中だけ描く。`ArrangerView` がスクロール追従のために持つ値（最後に読んだスクロール時刻、向かっている位置）は `@State` でなく参照型の `ScrollFollow` に置く：ズームの 1 ステップごとに書くので、`@State` だとそのたびにアレンジャー全体がもう一度作り直されていた。**波形の縦倍率**（スライダー、⌥⇧＋ホイール）は `previewWaveformVerticalScale` を呼び、操作中は値を変えずに `waveformScalePreview` の `scale` だけを変えて、描画済みの波形を `VerticalStretch`（中心基準）で伸縮する。0.1 秒止まると `commitPreviews` が本当の値を設定する。

**トラック高さの中心点**: `ArrangerView.zoomTrackHeight` が、倍率を変える前に基準点を「行と、その行の高さに対する割合」として覚え、変更後にその点が画面上の同じ高さに来るよう縦の `NSScrollView` をスクロールする。スライダーは `ProjectState.zoomTrackHeightAroundCurrentTrack`（アレンジャーが登録するクロージャ）経由でカレントトラックの中央を、⌥＋ホイールはポインター位置を基準にする。内容の高さの反映が遅れて目標位置まで届かない間は、`VerticalScrollObserver` が内容のリサイズ時に再適用する。カレントトラックが表示されていない場合は従来どおり上端基準。

### `WaveformCanvas.swift`
波形を SwiftUI `Canvas` で描画（チャンネル別、ゲイン倍率、`envelope` による振幅）。1pt 幅の列ごとに、その列に入るサンプルの最小〜最大の縦の棒を塗る（最低 1pt。値の位置を中心に）。元にするデータは 1 列に入るサンプル数で変わる：粗いピークが 1 列に収まる間は粗いピーク、それより拡大（48 kHz で約 94 px/秒）すると細かいピーク、細かいピークより細かく（約 750 px/秒）なると見えている範囲のサンプルそのもの（`WaveformCache.requestSamples`。隣の列とつながるよう 1 つ前のサンプルも含める。届くまでは細かいピークで描く）。描くのは `drawWindow`（`ProjectState.waveformDrawWindow`（`DrawWindowState`）：見えている範囲と左右 2 画面分。`ProjectState.refreshDrawWindow` が、見えている範囲が端から半画面以内に近づいたときと、波形を描く倍率・表示幅が変わったときだけ動かす）の中だけなので、拡大・高さ変更の描き直しは曲全体でなく数画面分で済み、スクロール中もほとんど描き直さない。`WaveformLaneView` はこの範囲（と選択中・録音中のクリップ）以外のクリップの部品を作らない。
- **`FadeLinesOverlay`**: フェードイン／アウトの線をクリップの高さ全体にカーブの形で描く（ステレオでも 1 本）。

### `MixerView.swift`
Studio One 風ミキサー。
- **全体**: タイトルバーの ▼／▲ でたたむ・開く（`isCollapsed`、UserDefaults `mixer.collapsed`。たたむとタイトルバーだけの 23pt）。「ミキサーに表示」（`mixerScrollRequests`）は `ScrollViewReader` でその行の ID を左端へスクロールする（たたんでいれば開いてから、`pendingScrollID` で表示後に）。ストリップの並びは `mixerItems`（`rows` から。閉じたフォルダも隠さない）で、フォルダの始まりに `FolderEdgeLine`、最初の FX の前に `FXEdgeLine`（どちらも `MixerEdgeLine`：幅 6pt の色の線。クリックで `TrackColorPalette`。FX の線の色は全 FX チャンネルに設定）。上端ドラッグで高さ変更（SEND とフェーダー部の境目からミキサー下端までが 220pt 以上残る高さ〜1000pt。さらに、ドラッグ開始時の `growthLimit` を超えては広げない＝アレンジャーを 180pt 未満にしない。境界は AppKit の `VerticalResizeHandle` でカーソル形状とドラッグ範囲が一致）、横スクロールするトラック／FX ストリップ、右端固定の MASTER、右クリックで Add FX。
- **`StripSections`**: INSERT／SEND／コントロールの 3 区画（見出しは `SectionHeader`。`LocalizedStringKey` で翻訳される）と、区画の高さを変える境界（全ストリップ共通・UserDefaults 保存）。
- **`TrackStripView`**: INSERT（＋メニュー、緑丸で ON/OFF、名前クリックで GUI、ドラッグで並べ替え、× で削除）、SEND（FX ごとのレベルバーと dB 値）、PAN、M／S（フォルダで有効な間はグレーで点灯し無効）、フェーダー値、目盛り・フェーダー・ステレオメーター、名前（クリックで選択。カレントトラックは `StripFooter` の `isCurrent` で白地に黒文字）。
- **`FXStripView`**: INSERT、（SEND 区画は空欄。位置合わせのためだけに残す）、PAN、「FX」表示、フェーダー、名前（ダブルクリックで改名）。右クリックメニューは「FX を追加」「（FX 名）を削除」（削除は `confirmRemoveFXChannel` で確認ダイアログを経由）（ストリップ上ではミキサー全体のメニューより優先されるため、FX を追加も併記）。
- **`MasterStripView`**: POST プラグイン、フェーダー、ステレオメーター。
- **`MixerLevelMeter`**: トラックヘッダー用の横型メーター（Logic Pro 相当のスケール）。

### `MixerControls.swift`
| 型 | 内容 |
| --- | --- |
| `MixerScale` | dB⇔ゲイン変換、フェーダー／メーター共通の区分線形テーパー（0 dB = 84%、+6 dB = 上端）、表示文字列（`-3.5`、`0dB`、`-∞`、`<C>`、`L56`）と入力の解析 |
| `EditableValueText` | ダブルクリックで入力欄になる数値表示（Return 確定、Esc 取消） |
| `VolumeFader` | 縦フェーダー。相対ドラッグ、⌘で微調整、⌥クリックで 0 dB |
| `FaderScale` | dB 目盛り（+6〜-72） |
| `StereoMeter` | L/R メーター（-12 dB／-6 dB で色分け、1.5 秒ピークホールド） |
| `PanControl` | 横 PAN バー（⌥クリックでセンター） |
| `SendLevelBar` | 横 Send レベル（dB テーパー、⌥クリックで 0 dB） |

### `WindowCloseHandler.swift`
ウィンドウを閉じると `NSApp.terminate` を呼ぶ。保存確認は `applicationShouldTerminate`（`ProjectState.confirmQuit()`）で行うため、終了メニューや ⌘Q と同じ確認になる。

**`TitleBarZoomHandler`**: タイトルバーの帯（`contentLayoutRect` より上。赤黄緑のボタンの上を除く）でのダブルクリックをローカルモニターで受け、`window.zoom(nil)` でメニューバーと Dock を残した画面全体表示と元の大きさを切り替える（タイトルバーが隠れているため、そのままでは内容のビューにクリックが届き、標準の動作にならない）。フルスクリーン中は何もしない。

---

## 5. C++ VST3 ブリッジ（`VST3Host/`）

CMake（`VST3Host/CMakeLists.txt`）で `MyDAWVST3Bridge` 静的ライブラリを作り、`sdk_hosting` などと共に Swift へリンクします。

| 関数 | 内容 |
| --- | --- |
| `MyDAWVST3EnumerateAudioEffects` | バンドルを読み込み、`kVstAudioEffectClass` のクラスを列挙 |
| `MyDAWVST3Create` | モジュール読込、`PlugProvider` 初期化、`IComponentHandler` 登録、ステレオバス設定、`setupProcessing`／`setActive`／`setProcessing` |
| `MyDAWVST3ProcessStereo` | RT 用。非インターリーブの入出力ポインタで `process()` を呼ぶ。`inputParameterChanges`／`outputParameterChanges` を毎ブロック渡す |
| `MyDAWVST3ProcessInterleaved` | インターリーブ版（プローブ用に残存） |
| `MyDAWVST3GetState`／`SetState` | コンポーネント状態の保存・復元（復元時はコントローラにも `setComponentState`） |
| `MyDAWVST3AttachEditor`／`GetEditorSize`／`SetResizeCallback`／`RemoveEditor` | NSView エディタの接続とサイズ追従 |
| `MyDAWVST3GetLatencySamples` | 処理遅延 |
| `MyDAWVST3Destroy` | 処理停止、ハンドラ解除、エディタ・コンポーネント・モジュールの解放（モジュール解放時に `bundleExit`） |

`MyDAWVST3ComponentHandler`: GUI の `performEdit` をパラメータ ID ごとに集約して保持し、オーディオスレッドが `try_lock` で取り出して `ParameterChanges` へ詰めます（待ちは発生しません）。

---

## 6. 代表的なシーケンス

### 6.1 プラグイン挿入（トラック）
1. `ProjectState.insertPlugin(_:into:)` → `AudioEngineManager.syncTracks`。
2. VST3 なら `syncVST3Instances` がインスタンスを生成（状態があれば復元）。
3. チェーン署名が変わったトラックは再構築: 末尾を仮接続 → `installAudioUnits` が非同期に AU／`VST3AudioUnit` を生成 → エンジン停止 → `connectReformatting` で接続 → 次のプラグインへ → 末尾で `connectTrackChainTail`。

### 6.2 保存／読込
1. `saveProject` → `ProjectDocument`（プラグイン状態は `capturePluginStates`）→ JSON 書き込み。
2. `loadProject(from:)` → DTO 復元 → `AudioClip.loadMetadata` → `setSavedPluginStates` → `syncTracks` でグラフ再構築（AU は非同期で状態復元、VST3 はインスタンス生成時に復元）。

### 6.3 終了
`applicationShouldTerminate` → `ProjectState.confirmQuit()`（プロジェクトを開いていれば Save／Don't Save／Cancel を確認。確認済みの `relaunch()` からはスキップ）→ `applicationWillTerminate` → `shutdown()` → エンジン停止 → `releaseVST3Instances`（エディタを閉じる → ラッパーから参照を外す → インスタンス破棄 → `bundleExit`）→ `restoreOriginalDefaultDevices`（macOS 既定入出力を起動前に戻す）。

### 6.4 デバイス変更と再起動
1. `BufferSettingsView` の Apply → 言語が変わっていれば `AppLanguage.select`、デバイスかサンプルレートが変わっていれば `AudioEngineManager.applyAudioDevices`（サンプルレート設定、`bindIODevice`）→ 成功時 `AudioDeviceManager.setSelectedDeviceIDs`。
2. シートを閉じた後、`ProjectState.promptRestartForAudioSettings` が保存と再起動を確認。
3. `relaunch()` が待機用のシェルを起動して `NSApp.terminate` → 終了時に既定デバイスを復元 → シェルが `open -n` で新しいプロセスを起動し、`MainDAWView` が引数の `.mydaw` を開く → 新しいプロセスが再び既定デバイスを切り替えてエンジンを構築。
