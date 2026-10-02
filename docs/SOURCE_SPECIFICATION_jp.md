# MyDAW ソースコード仕様書（v2.0）

> 対象バージョン: **2.0** ／ 英語版: [SOURCE_SPECIFICATION_en.md](SOURCE_SPECIFICATION_en.md)
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
- **`init()`**: 最初に `PluginManager.runVST3ScanChildIfRequested()` を呼ぶ。起動引数に `--scan-vst3 <path>` があれば VST3 を列挙して JSON を標準出力へ書き、`exit(0)` する（子プロセスモード）。通常起動時はマイク権限を要求する。
- **`body`**: `WindowGroup` に `MainDAWView` を置き、メニューを構成する。ウィンドウは `.hiddenTitleBar`（タイトルバーは透明で、内容がその下に広がる）と `.windowResizability(.contentMinSize)`（内容の最小サイズより小さくできない）。`.handlesExternalEvents(matching: [])` で、Finder から開いたファイルごとに SwiftUI が新しいウィンドウを作るのを防ぐ。
- **Finder から開く**: Info.plist の `CFBundleDocumentTypes`／`UTExportedTypeDeclarations` で `.mydaw`（`com.tokada.mydaw.project`、`public.data`／`public.content` に準拠。`public.json` にすると Finder が中身のテキストをサムネイルにしてアイコンが出ない）を宣言し、`MyDAWApplicationDelegate.application(_:open:)` が受け取る（複数なら最後の 1 つ）。ウィンドウの `onAppear` で `openProjectFile` が設定されるまでは `pendingProjectURL` に保持し、設定後に `ProjectState.openProjectFile(_:)` を呼ぶ。`build.sh` は署名後に `lsregister -f` でビルドを LaunchServices に登録する。書類のアイコンは `DocumentIcon.icns`（`scripts/make-document-icon.swift` が `AppIcon.iconset` から、折り返し付きの白い書類の中央にアプリアイコンを角丸で描いて作る。アプリアイコンを変えたら再実行する）。
  - About（バージョン表示。Info.plist が無い場合の既定値は `2.0`）
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
| `isMuted`, `isSoloed`, `volume`, `pan` | ミキサー値 |
| `trackHeight` | レーンの高さ（標準 170pt = `AudioTrack.defaultTrackHeight`。表示は × `trackHeightScale`） |
| `clips` | クリップ配列。**配列順がレイヤー順**（後ろほど上） |
| `selectedClipIDs` | 選択中のクリップ（集合）。`selectedClipId` は先頭の選択クリップを返し、設定するとそのクリップだけを選ぶ互換用の計算プロパティ |
| `plugins`, `fxSends` | インサートと FX 送り |
| `currentInputPeak`, `currentOutputPeak`, `outputStereoPeak` | メーター値 |

- `clips` の変更時、各クリップの `objectWillChange` をトラックへ中継する（下のクリップの重なり表示を更新するため）。
- **`addClip(startTime:fileURL:)`**、**`moveClip(id:to:)`**、**`deleteClip(id:removeFile:)`**（他から参照されないファイルのみ削除）、**`duplicateClip(id:)`**（直後に複製）、**`splitClip(id:at:)`**（左右 20 ms 未満の分割は拒否）、**`removeClipForTransfer(id:)`**、**`restoreClip(_:)`**、**`insertClip(_:below:)`**（指定クリップの直下のレイヤーへ挿入）、**`replaceClips(_:)`**（選択は残ったクリップに絞る）。
- **範囲編集**: **`clipPieces(from:to:)`**（範囲部分の複製列）、**`removeAudio(from:to:)`**（範囲内を削除し、跨ぐクリップは前後に分割）、**`cropAudio(from:to:)`**（範囲内だけ残す）、**`splitAudio(at:)`**（指定時刻で分割）。いずれもレイヤー順を保って組み替え、変更があれば true を返す。
- **`insertPlugin(_:)`／`removePlugin(id:)`／`movePlugin(id:before:)`**: インサートの編集。

### `AudioClip.swift`

#### `AudioClip: ObservableObject`（@MainActor）
タイムライン上の配置（`startTime`、`duration`）と WAV 内の再生範囲（`sourceStartTime`）を保持する非破壊クリップ。
- 追加の属性: `gainDB`（-24〜+24）、`isMuted`、`fadeInDuration`／`fadeOutDuration`、`fadeInCurve`／`fadeOutCurve`（`FadeCurve`、既定 `.auto`）、`sampleRate`、`originalDuration`（ファイル全長）、`waveformCache`。
- **`loadMetadata()`**: ファイルのサンプルレートと長さを読み、波形ピークの非同期読込を開始する。`duration` は利用可能な範囲に制限。
- **`setTrim(startTime:sourceStartTime:duration:)`**: 最短 0.02 秒。
- **`setFadeInDuration`／`setFadeOutDuration`**: 0〜`duration` に制限。
- **`duplicate(at:)`**: 同じファイルを参照する複製（フェードとカーブも複製）。
- **`piece(from:to:)`**: タイムライン上の区間に当たる部分を新しいクリップとして返す（20 ms 未満は nil）。フェードとカーブは元のクリップと共有する端だけ引き継ぐ。

### `ClipLayering.swift`

クリップの重なりとフェードカーブを扱う純粋関数群。再生（`AudioEngineManager.scheduleClips`）と表示（`WaveformLaneView`、`WaveformCanvas`）が共有します。

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
`id`、`name`（既定 "FX n"）、`volume`、`pan`、`isMuted`、`isSoloed`、`plugins`、`color`、`currentOutputPeak`、`outputStereoPeak`。`insertPlugin`／`removePlugin`／`movePlugin`。

#### `FXSend: Codable`
`id`、`fxChannelID`、`level`（線形ゲイン）、`enabled`。

### `StereoPeak.swift`
L/R のピーク値。`init(buffer:)` は PCM バッファから各チャンネルの最大絶対値を計算（モノラルは両側に同じ値）。`merged(with:)`、`falling(to:by:)`（アタック即時・指数減衰。-100 dB 未満は 0 にして、無音時に値が変わり続けないようにする）、`maximum`。

### `WaveformCache.swift`
- `PeakPoint`（min/max）の列を合成（`peaks`）とチャンネル別（`channelPeaks`）で保持。既定 512 サンプル／ピーク。
- **`loadPeaks(from:)`**: `Task.detached` でファイルを読み、結果をメインスレッドで公開。
- **`appendLivePeaks`／`appendLiveChannelPeaks`**: 録音中のライブ波形追加。

### `ProjectDocument.swift`（`.mydaw` JSON）
| 型 | 主な内容 |
| --- | --- |
| `ProjectDocument` | `version`（現行 4）、ズーム、スクロール、プレイヘッド、BPM、メトロノーム、マスター音量、表示倍率、トラック、FX、マスタープラグイン、プラグイン状態、パンチ範囲 |
| `TrackDocument` | 名前、チャンネル、入力、R/M/S、**I（`isInputMonitoring`）**、音量、パン、高さ、色、クリップ、プラグイン、Send |
| `ClipDocument` | ID、開始位置、ソース位置、長さ、元の長さ、ゲイン、ミュート、フェード、フェードカーブ（`fadeInCurve`／`fadeOutCurve`、読めない場合は `.auto`）、ファイルパス（プロジェクトからの相対） |
| `FXChannelDocument` | FX の名前・音量・パン・ミュート・ソロ・色・プラグイン（古いプロジェクトではミュート・ソロは OFF） |
| `PluginStateDocument` | `pluginID`、`stateData`、`format`（AU は plist、VST3 は `"vst3-state"`） |
| `PunchRangeDocument` | `startBeat`、`endBeat`、`enabled` |
| `SongRangeDocument` | 曲の開始・終了フラグ。`startBeat`、`endBeat`（どちらも省略可） |
| `ProjectDocument.masterExportFileName` | マスター書き出しで最後に選んだファイル名（省略可）。書き出しパネルはプロジェクトのフォルダで、この名前か `<プロジェクト名>_Master_Mix.wav` で開く |
| `ColorDocument` | RGBA |

全デコーダは `decodeIfPresent` で欠落項目に既定値を補い、旧バージョンのファイルを読み込めます。

### `ProjectState.swift`

`ProjectState: ObservableObject`（@MainActor）は UI とエンジンの間の Facade です。

- **公開状態**: `tracks`、`fxChannels`、`masterPlugins`、`selectedTrackId`、`pixelsPerSecond`（20〜400）、`timelineScrollTime`、`punchRange`、`showsBeats`、`snapToGrid`（UserDefaults 保存）、`autoScrollEnabled`（UserDefaults `MyDAW.autoScroll`）、`waveformVerticalScale`（1〜32）、`trackHeightScale`（`TrackHeaderView.minimumRowHeight` 56pt ÷ 170 ≒ 0.33 〜 3。スライダーと ⌥＋ホイールは `setTrackHeightScale` 経由で、全トラックの `trackHeight` を標準値に戻してから倍率を設定）、`timeSelection`（範囲選択）、`marqueeRect`（枠選択中の矩形）、`clipboard`、書き出しダイアログ状態、起動ログ、`pluginManager`、`audioEngine`、`deviceManager`。
- **初期化**: デバイスとバッファサイズをエンジンへ適用、ピーク通知を購読、既定トラック 2 本を作成、プラグイン検出を開始。
- **トラック**: `addTrack`、`deleteTrack`（UI からは確認ダイアログ付きの `confirmDeleteTrack` 経由）、`moveTrack(id:to:)`（並べ替え。アレンジャーとミキサーは `tracks` の順で並ぶ。グラフはつなぎ直さない。範囲選択は解除）、`toggleRecordArm`、`toggleInputMonitoring`、`toggleMute`、`toggleSolo`、`setInputRouting(for:channelMode:inputChannelIndex:)`（変更後に即エンジン同期）。
- **クリップ**: `selectClip`（そのクリップだけを選択し、範囲選択を解除）、`moveClip`（トラック間移動）、`deleteSelectedClip`（範囲選択があれば範囲内を削除、なければ選択クリップすべてを削除）、`splitSelectedClip`／`splitClip`、ドラッグプレビュー（`ClipDragPreview`：移動中のクリップ ID の集合、縦の移動量、移動先までのトラック数。`beginClipDragPreview()`／`updateClipDragPreview(verticalOffset:trackDelta:)`／`endClipDragPreview()`。移動先がないクリップがあるときトラック数は 0）。選択・範囲・クリップボード・まとめて移動は `ProjectState+Editing.swift`。
- **UNDO/REDO**: `beginClipEdit()` で編集前スナップショット（クリップの位置・範囲・ゲイン・ミュート・フェードとカーブ・ファイル、各トラックの選択）を取り、`endClipEdit()` で履歴に積む。クリップが変わっていなければ積まない（ハンドルをクリックしただけの場合など）。`undo()`／`redo()` は再生・録音中は無効。
- **パンチ**: `setPunchRange`、`setPunchStartBeat`、`setPunchEndBeat`、`setPunchEnabled`。
- **未使用の録音ファイル**: `moveUnusedRecordings()`（ファイルメニュー。`canMoveUnusedRecordings` はプロジェクトが開いていて、停止中で、録音の確定処理中でないこと）。まず保存の確認（プロジェクトを保存して実行／キャンセル）を出して保存し、そのあと Recordings 直下の WAV のうち、クリップとクリップボードのどちらからも参照されていないものを `Recordings/Unused` へ移動し（同名は番号付き）、NSAlert で一覧を表示します。同じフォルダーのほかの `.mydaw`（`clipPathsOfOtherProjects()` で `ProjectDocument` をデコード）のクリップも使用中として扱い、読めないファイルがあれば何も移動せずにエラーを表示します。移動したファイルが Undo／Redo のスナップショットに含まれていた場合は、両方の履歴を消去します。
- **開始・終了フラグ**: `songRange`（変更時にエンジンの `songEndTime` を更新）、`songStartTime`／`songEndTime`（秒）、`setSongStart(time:)`／`setSongEnd(time:)`（nil で削除。`minimumSongLengthBeats` 以上離す）、`canPlaceSongStart(at:)`／`canPlaceSongEnd(at:)`。`toggleTransport(recordArmedTracks:)` はパンチ範囲と終了位置をエンジンに渡して再生／録音を開始・一時停止します（再生・録音ボタンと Space から）。`rewindToSongStart()` は開始フラグへ、フラグ上かそれより前なら 0 へ戻ります。エンジンの `onReachSongEnd` から `stop(tracks:)` を呼びます。
- **プラグイン**: トラック用 `insertPlugin(_:into:)`／`removePlugin(_:from:)`／`movePlugin(_:before:on:)`／`togglePlugin(_:on:)`、FX 用 `…intoFX:`／`…fromFX:`／`…onFX:`、マスター用 `insertMasterPlugin`／`removeMasterPlugin`／`moveMasterPlugin`／`toggleMasterPlugin`、`openPluginUI`。
- **FX**: `addFXChannel()`、`renameFXChannel(id:to:)`（空欄は無視）、`removeFXChannel(id:)`（UI からは `confirmRemoveFXChannel(id:)` 経由。確認は NSAlert で、Return／Esc はキャンセル側）、`setSend(trackID:fxChannelID:level:)`。
- **ファイル**: `createNewProject`（NSSavePanel で保存先と名前を指定。`canCreateDirectories`、展開表示、拡張子 `.mydaw`。選んだフォルダーに `.mydaw` と `Recordings/` を作成）、`loadProject`（NSOpenPanel で `.mydaw` ファイルを選び、その親フォルダーをプロジェクトフォルダーとする）。両パネルの初期位置は直前のプロジェクトのフォルダーの 1 つ上（`projectPanelStartDirectory`）。`openRecentProject(_:)`（ファイルの存在を確認し、そのフォルダーで `loadProject(from:projectFolderURL:)`）、`saveProject`（書き込みに成功すると `RecentProjects.noteSaved`。`loadProject(from:)` は成功時に `noteOpened`）、`saveProjectAndShowConfirmation`、`openProjectFile(_:)`（Finder から開く。アプリを前面に出し、同じファイルが開いていれば何もしない。再生・録音中はエラー。プロジェクトが開いていれば保存／保存しない／キャンセルを確認してから `loadProject(from:projectFolderURL:)`）、`saveProjectAs()`（NSAlert のテキスト欄で名前だけを入力し、同じフォルダーの `<名前>.mydaw` へ保存して `currentProjectURL` を切り替える。空・「.」始まり・「/」「:」を含む名前は拒否、既存ファイルは置き換えを確認、失敗時は元の URL に戻す）、`importAudioFile(_:intoTrackId:)`（今のサンプルレートの 24-bit 整数 PCM ならそのままコピー、それ以外は `ClipAudioProcessing.writeConverted` で変換して `Recordings/` へ保存）、`locateClipFile`（サンプルレートが一致するファイルのみ）。
- **再起動**: `promptRestartForAudioSettings()`（デバイス・サンプルレート・言語の変更後に Save and Restart／Restart Without Saving／Cancel を確認）、`relaunch()`（`/bin/sh` で現プロセスの終了を待ち、`open -n` でプロジェクトを引数に再起動）。
- **書き出し**: `beginMasterExportDialog`、`exportMasterMix(startTime:endTime:)`、`cancelMasterExport`。
- **表示**: `zoomIn`、`zoomOut`、`setPixelsPerSecond(_:)`（再生位置を基準）、`setPixelsPerSecond(_:anchorOffset:)`（ポインター位置を基準、ホイール・ピンチ用）、`snappedTimelineTime`（1 拍単位）。

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
| `trackTopY(for:)`、`trackID(atTimelineY:)` | `timelineScroll` 座標系でのトラック位置 |
| `beginMarquee(at:additive:)`、`updateMarquee(from:to:)`、`endMarquee()` | 枠選択。矩形に触れるクリップを選択（additive なら既存選択に追加） |
| `beginTimeSelection`、`updateTimeSelection`、`endTimeSelection` | 範囲選択（時刻は拍にスナップ、トラックは隣接範囲） |
| `deleteTimeSelection`、`cropToTimeSelection`、`splitAtTimeSelection` | 範囲編集（1 回の UNDO 手順） |
| `deleteSelectedClips` | 選択クリップをまとめて削除 |
| `copySelection`、`cutSelection`、`paste()` | クリップボード。ペーストは再生位置と選択トラック基準（足りないトラックは最終トラックへ） |
| `menuTargets`、`selectForMenu`、`splittableMenuTargets` | 右クリックの対象: 右クリックしたクリップが選択に含まれていれば選択全体、そうでなければそのクリップ（`selectForMenu` で選択）。`splittableMenuTargets` はそのうち再生位置が内側にあるもの |
| `toggleMuteMenuTargets`、`duplicateMenuTargets`、`splitMenuTargets`、`deleteMenuTargets` | 右クリックの対象への処理。ミュートは 1 つでも未ミュートがあれば全ミュート、なければ全解除。複製は対象をかたまりのまま先頭を再生位置へ置き、複製を選択。分割は再生位置にかかる対象を分割し両側を選択。いずれも 1 回の UNDO 手順（ミュートを除く） |
| `normalizeClips`、`reverseClips` | 右クリックの対象（選択に含まれていれば選択全体）に対する処理。ノーマライズはファイル全体のピークで 0 dBFS になるゲインを設定、逆再生は `Reverse_<トラック名>_NNN.wav`（`RecordingFileName`）を作って差し替え、フェードの前後を入れ替える |
| `beginGroupDrag`、`updateGroupDrag(delta:)`、`endGroupDrag(trackDelta:)` | 選択クリップのまとめて移動（0 秒より前に出さない。トラック間は全クリップの移動先がある場合のみ＝`canMoveSelectedClips(trackDelta:)`） |
| `layeringClips(for:)` | レーンの重なり計算に使うクリップ列。別トラックへのドラッグ中は、移動中のクリップを移動元から外し、移動先の最上位に加える |
| `duplicateSelectedClipsInPlace` | option ドラッグ開始時に、元の位置へ複製を残す（元の直下のレイヤー） |

---

## 3. 音声・デバイス・プラグイン（`Sources/Audio`）

### `AudioEngineManager.swift`

AVAudioEngine のグラフ、再生、録音、メトロノーム、メーター、プラグイン生成と GUI、書き出しを管理する中心クラス（@MainActor、`NSWindowDelegate`）。

#### 公開状態（抜粋）
`engine`、`isPlaying`、`isRecording`、`isPunchRecording`、`currentTime`、`bpm`、メトロノーム（有効・発音タイミング補正・音量）、`hardwareSampleRate`、`masterVolume`、`masterPeak`、`masterStereoPeak`（どちらも値が変わったときだけ更新）、`recordingsDirectory`、`inputBufferFrameSize`、`manualRecordingCompensationMs`、選択中の入出力デバイス。`loadMonitor`（`AudioLoadMonitor`。更新がエンジン全体の再通知にならないよう別の `ObservableObject`）。

#### ノード構成（トラックごと）
| 辞書 | 役割 |
| --- | --- |
| `playerNodes` | トラック用予備プレイヤー（通常未使用） |
| `clipPlayerNodes` | クリップ 1 つにつき 1 つの `AVAudioPlayerNode`（クリップがトラック間を移っても使い回す） |
| `clipPlayerOutputs` | 各クリップのプレイヤーの接続先（トラック出力ミキサー）。今のトラックと違えば `syncTracks` がつなぎ直す |
| `trackOutputNodes` | トラック出力ミキサー（フェーダー音量・ソロ・ミュート）。ミュート・ソロは `audibility(tracks:fxChannels:)` で決まります。トラックをソロにすると送り先の FX も聞こえます。FX をソロにするとその FX のリターンだけが聞こえます（送り元トラックはセンドへは送り続け、splitter → mainMixer の接続音量だけを `setTrackDryAudible` で 0 にします） |
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
- **トランスポート**: `startPlayOrRecord(tracks:fxChannels:recordArmedTracks:)`（再生／録音開始。再生中なら停止）、`stop(tracks:)`、`rewind(tracks:to:)`、`seek(to:)`、`setPunchRange`。`songEndTime`: 再生位置タイマーがこれをまたぐと `onReachSongEnd` を呼びます（それより前から再生を始めた場合のみ）。この停止では、録音したクリップを終了位置で切り揃え、再生位置を終了位置に置きます。
- **デバイス**: `applyAudioDevices(inputDeviceID:outputDeviceID:sampleRate:)`（デバイスのサンプルレートを設定し、デバイスが変わった場合は `bindIODevice`）、`applyInputBufferFrameSize`、`applyAutomaticTimingCompensation`。
- **プラグイン**: `openPluginUI(pluginID:)`、`isPluginUnavailable`、`capturePluginStates`、`setSavedPluginStates`、`prepareForPluginGraphRestore`。
- **その他**: `exportMasterMix(to:startTime:endTime:tracks:fxChannels:)`（マスター経路を実時間で 24-bit WAV へ）、`shutdown()`（エンジン停止、VST3 解放、macOS 既定入出力デバイスの復元）、録音フォルダ関連。

#### 主な内部処理
| メソッド | 内容 |
| --- | --- |
| `startMetronome(at:)` | クリックを 256 拍分予約し、最後のクリックで続きを予約。トランスポート開始時はその開始時刻と位置から、再生中の ON・BPM 変更・続きの予約では、頭が欠けずに鳴らせる最も早い時刻（`earliestPlayerStartHostTime`）とその時刻のトランスポート位置（`transportPosition(atHostTime:)`）から、次の拍に合わせる |
| `setupEngine()` | 入力フォーマット取得、マスター経路と最終メーターの構築、クリック、入力タップ、インプットモニター接続、スライス上限引上げ、エンジン開始 |
| `bindIODevice(inputDeviceID:outputDeviceID:)` | 選択デバイスを macOS の既定入力・既定出力に設定する（入力を使う AVAudioEngine は既定入出力の集約デバイスで動作するため）。初回に元の既定を記録し、`restoreOriginalDefaultDevices()` が `shutdown()` で戻す |
| `startMeterTimer` | 30 Hz でピークを集計し通知。`masterPeak`／`masterStereoPeak` は値が変わったときだけ代入（-100 dB 未満は 0） |
| `wireSend` | Send のゲインミキサーを FX 入力へ接続。`wiredSendTargets` で接続先を覚え、変わったときだけつなぎ直す（毎回の再接続はインプットモニター有効時に `mixingDest` 例外になるため） |
| `applyDeferredRewiresWhenQuiet` | 停止時に、保留した分岐の組み替えとインプットモニターの接続を、マスター出力が -60 dB 未満になるまで（最大 8 秒）待ってから行う。待機中は `isWaitingForQuietRewire` が立ち、`syncTracks` も組み替えをこちらに任せる。再生が始まれば中止し、次の停止で再試行 |
| 停止時の録音確定（`stop` 内のタスク） | writer を確定してクリップを読み込む。録音したファイルがあるときだけ `syncTracks` を呼ぶ |
| `installAudioUnits`／`installFXAudioUnits`／`installMasterAudioUnits` | プラグインを非同期生成し、挿入順に直列接続。VST3 は `VST3AudioUnit` を生成してインスタンスを結び付ける |
| `connectTrackChainTail` | チェーン末尾 → PAN → 分岐 → mainMixer＋Send の配線。1 対多接続は**エンジン停止中のみ**（再生中は `pendingSplitterRewires` で停止時まで保留） |
| `connectReformatting` | 接続先／元の AU が描画リソース確保済みでフォーマットが変わる場合、先に解放してから接続（-10865 例外の回避） |
| `setMixerVolume` | 音量変更後にミキサーを `reset()`（無音入力で音量ランプが止まる問題の回避） |
| `scheduleClips` | `ClipLayering.segments` に従い、plain は `scheduleSegment`、shaped は `makeClipPlaybackBuffer`（エンベロープ適用済み）を `scheduleBuffer`、hidden は予約しない。サンプル時刻指定・プラグイン遅延補正 |
| `startPlayback` | 全トラックを予約し、予約済みノードのみ `play(at:)` |
| `processInputAudioBuffer` | 入力タップ。ピーク計算、hostTime によるサンプル単位のトリミング、armed トラックのチャンネル抽出と書き込み |
| `startRecording`／`stop` | writer 作成、録音中クリップのミュート、パンチ時は通し録音 → 停止時 `trimToPunchRange`（10 ms フェード付与） |
| `updatePunchRecordingState` | 30 Hz タイマーでパンチ範囲の入退出を判定し、範囲内のみ既存クリップをミュート |
| `applyInputMonitoringIfNeeded`／`connectInputMonitors` | I ボタン状態に合わせて inputNode → `InputMonitorAudioUnit` → トラック出力を接続（エンジン停止中に実施） |
| `raiseMaximumFramesPerSlice` | 入出力ユニットのスライス上限を 4096 に上げる（全ノードに反映される） |
| `releaseVST3Instances` | 終了時にエディタを閉じ、ラッパーから参照を外し、VST3 インスタンスを破棄 |
| プラグイン GUI 群 | `requestOriginalPluginUI`、`presentPluginViewController`（ウィンドウをビューの実寸に合わせ、以後のサイズ変更に追従）、`presentGenericPluginView`、`openVST3PluginUI` |

#### スレッド・ロック
`captureLock`（録音設定・writer）、`recordingTimingLock`（開始時刻）、`peakLock`（ピーク）。タップと Timer はこれらを介してメインスレッドと値を交換します。

### `ClipAudioProcessing.swift`（v1.6 新規）
クリップが参照するファイル範囲に対するオフライン処理（メインスレッドで同期実行）。
- **`peakAmplitude(of:sourceStartTime:duration:)`**: 全チャンネルの最大絶対値（ノーマライズ用）。
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

### `DelayCompensationAudioUnit.swift`（v1.8 新規）
`StereoDelayLine`（レンダースレッド用のリングバッファ。保持できない遅延は素通し）と、`delayFrames`・`isMuted`（約 5 ms のランプ）を持つアプリ内 AUv3（`aufx`/`dlcp`/`MyDW`）。最大 1 秒まで。自身のレイテンシーは 0 と報告します。`VST3AudioUnit` も `StereoDelayLine` を使い、バイパス時の出力をプラグインのレイテンシー分だけ遅らせます。

`AudioEngineManager.updateLatencyCompensation()` は各チェーンの `auAudioUnit.latency` を合計し（バイパス中も含む）、D = FX チャンネルの遅延の最大値を求めて遅延ノードに設定し、全プラグインに `kAudioUnitProperty_Latency` のリスナーを付け、再生中に値が変わったら再スケジュールします。`transportPreRoll` P = D ＋ トラックのインサートの遅延の最大値。プレイヤーはトランスポートの時計より P だけ早く動き始めます。`startPlayback` は先に予約してから開始時刻を決めます（`nextTransportStartTime(extraLead:)`：エンジンの計算済み区間の先 ＝ `lastRenderTime` から IO バッファ 2 つ分・最低 50 ms、に加えて、レンダー 1 回分待たされる `play(at:)` を、音が始まる順に全プレイヤーへ呼び終える時間）。録音は、開始時刻が決まった後・プレイヤーの開始前に呼ばれる `beforePlayersStart` で、テイクのファイル作成と入力の取り込みを始めます、各トラックは「P −（自分の遅延 ＋ D）」だけ遅らせて予約するので、開始位置以降の音は欠けません。再生中の再予約（`includePreRoll`）では先読み区間の音も予約します。`exportMasterMix` はエンジンの処理開始を待ってから、同じ方法でトランスポートを始め、`ExportWindow` で「開始位置の音が聞こえるホストタイム（＋マスタープラグインの遅延）」から `end − start` 秒分のフレームだけをタップから切り出します。範囲を取り込みきれなかったときはエラーにします。

### `MonoDownmixAudioUnit.swift`
各トラックの出力ミキサーの直後に置くアプリ内 AUv3（`aufx`/`mndx`/`MyDW`）。`isMono`（トラックがモノラル）のときは `(L + R) / 2` を L/R 両方に書き、それ以外はそのまま通します。モノラルのクリップはプレイヤーが L = R に展開して届くので、どちらの場合も変化しません。

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
上からトランスポート、アレンジャー、ミキサー、ステータスバー（デバイス、`AudioLoadIndicator`、録音フォルダー、ショートカットの案内）を配置。タイトルバーの帯（`.hiddenTitleBar` で標準のタイトルは非表示）の中央に `ProjectState.openProjectName` をオーバーレイで表示する（帯の高さは GeometryReader の `frame(in: .global).minY`＝内容の上端までの距離。その分だけ上にずらして表示し、クリックは通す。`ignoresSafeArea` した GeometryReader の `safeAreaInsets.top` はこの環境では 0 になり使えなかった）。ウィンドウのタイトル（`navigationTitle`）も「MyDAW - <名前>」にする（Window メニュー・Mission Control 用。プラグインのウィンドウとは「MyDAW」で始まるかで区別している）。`currentProjectURL` は表示を更新するため `@Published`。起動ログ（プラグイン検出の進捗。表示を終えたらビュー階層から外す）、マスター書き出しダイアログ、ウィンドウを閉じる時の確認、キー処理（`SpacebarHandler`: ⌘Z／⇧⌘Z／⌘Y、← で先頭へ、⌘X／⌘C／⌘V／⌘A を `EditCommand` として処理、Esc で選択解除（イベントは通過させる）。テキスト入力中は処理しない）を含む。
- **最小サイズ**: 外枠は `.frame(minWidth: 800)` だけで、高さの下限は付けない（付けると内容の最小の高さが隠れ、ウィンドウが内容より小さくなってトランスポートとミキサーが切れる）。ウィンドウの最小の高さ＝トランスポート＋アレンジャーの最小（`minimumArrangerHeight` = 180pt）＋ミキサー＋ステータスバー。
- **アレンジャーの高さ**: `arrangerHeight` を読み取り、`MixerView` へ `growthLimit`（アレンジャーが最小になるまでの余り）として渡す。
- **`TitleBarZoomHandler`** を背景に置く（`WindowCloseHandler.swift`）。
- **`refreshToolTips()`**: プロジェクトを開いたとき・起動ログが消えたときに、メインウィンドウの幅を 1pt 変えて戻し、ツールチップ領域を再登録させる（オーバーレイが消えただけでは SwiftUI が再登録しないため）。

### `ProjectSelectionView.swift`
起動画面。New Project（保存パネルで指定）と Open Project（⌘O、`.mydaw` を選択）。バージョン表示。ボタンの下に「最近使ったプロジェクト」一覧（`RecentProjects.shared`、スクロール可、520 × 240 pt）。各行 `RecentProjectRow` は名前をオレンジのリンクで表示（ホバーで下線と指カーソル、ツールチップにパス、クリックで `onOpenRecent`）し、右に最終保存日時。ファイルがない項目は取り消し線付きでクリック不可。右クリックメニューに Remove from List。

### `AudioLoadIndicator.swift`（v1.8 新規）
ステータスバーの「CPU [バー] 34% ●音飛び」。`AudioLoadMonitor` を監視（再描画はこのビューだけで最大 10 Hz）。バー（64 × 7 pt のカプセル、0.1 秒のリニアアニメーション）の色は緑（0）→黄（0.6）→オレンジ（0.8）→赤（1.0）を補間。数値は 100% を超えることもある。音飛びマークは非表示でも場所を確保（opacity）し、表示がずれない。ツールチップは表示時に文字列を作る AppKit のツールチップ（`DynamicToolTip`、`NSViewToolTipOwner`）で、頻繁な再描画でも表示される。

### `TransportBarView.swift`
- ボタン（左から）: 設定、Undo、Redo、Rewind、Play／Pause（Space）、Record（armed トラックを録音）、P（パンチ有効化）、メトロノーム（再生・録音中も切り替え可）、保存、開く、スナップ、自動スクロール（`ProjectState.autoScrollEnabled`。UserDefaults `MyDAW.autoScroll` に保存）。ツールチップは標準 `.help`。
- 表示: TIME（時間／小節・拍）、TEMPO（BPM 入力 20〜400）、FORMAT（24-bit WAV とサンプルレート）。幅は中身に合わせる。
- バー全体は左寄せで、ウィンドウより幅が広いときは右端から切れる（`frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)` と `clipped()`）。
- 右側: 時間軸ズーム、トラック高さ倍率、波形縦倍率、ルーラー切替、マスター音量。
- **`BufferSettingsView`**（歯車、見出し「Settings」）: 録音フォルダ、言語（`AppLanguage`）、入力／出力デバイス、サンプルレート（44.1〜96 kHz）、録音遅延の補正、クリックの発音タイミング補正、クリック音量、バッファサイズ。言語・デバイス・サンプルレートの変更が適用されると `onAudioDevicesChanged` で再起動の確認を呼ぶ。

### `ArrangerView.swift`
トラックヘッダーと波形レーンの並び、ルーラー（秒または小節・拍、クリックでシーク）、プレイヘッド、パンチ範囲（ルーラー上の左右ハンドルを拍単位でドラッグ）、Add Track ボタン、自動スクロール（`autoScrollEnabled` が ON のときだけ、再生位置が右端 10% に入ると先へ送る）、Delete キー、枠選択の矩形と範囲選択の帯の表示。
- **座標空間 `timelineScroll`**: 波形レーン全体の ZStack に付ける。`trackTopY`、`trackID(atTimelineY:)`、枠選択、範囲選択、クリップのドラッグはこの座標で測る。
- **クリップのドラッグ表示**: `clipDragPreviews` が `clipDragPreview` の全クリップを、自分のトラックの位置から縦の移動量だけずらして描く（波形・フェードは移動先の重なりで表示）。
- **トラックの並べ替え**: 波形レーンの領域は表示域の下端まで広げてあり、最後のトラックより下へドラッグしたレーンも切れない。ヘッダの `DragGesture`（`reorderGesture`、4pt 以上、グローバル座標）。`reorderTargetIndex` は中心がドラッグ中の行の中心より上にあるトラック数。`reorderOffset` でドラッグ中の行はポインタに追従し、通過した行はその行の高さ分よける。`ReorderLift` はヘッダとレーンの両方に掛け、ドラッグ中の行に枠・影を付けて手前に出す。離すと `moveTrack` をアニメーション付きで実行。
- **横スクロール**: `timelineScrollTime` の変更は `setTrackScrollOffset` でトラックの `NSClipView` を直接スクロールし、次のメインキューで新しいレイアウトの後にもう一度合わせ直す（`scrollTo` は古いレイアウトで位置を決めることがあるため）。`ScrollOffsetObserver` がユーザーのスクロールを `timelineScrollTime` へ戻す。
- **`KnobOnlySlider`**: 下部の横スクロールバー。つまみ（●）のドラッグでだけ動き、つまみ以外のクリックは無視。
- **`ArrangerWheelMonitor`**: アレンジャー全体（ルーラー含む）でのスクロールホイールとピンチをローカルイベントモニターで受ける。ルーラー上のホイールとピンチはポインター位置を基準に時間方向ズーム、⌥＋ホイールはトラック高さ、⌥⇧＋ホイールは波形縦倍率（shift による横スクロール変換にも対応）。処理したイベントはスクロールビューへ渡さない。

### `TrackHeaderView.swift`
左端のカラーバー（クリックで `TrackColorPalette`：16 色プリセット＋カスタム）、名前（ダブルクリックで編集）、モノ／ステレオ切替（1／2）、削除、R／M／S／I、入力チャンネル選択、メーター（録音待機時は入力、それ以外は出力）、下端ドラッグで高さ変更（`VerticalResizeHandle`。画面座標で測り、倍率で割って `trackHeight` に反映。表示の高さは `minimumRowHeight` 56pt 以上）。中身は上詰めで、低いときはメーターから下が不透明な下端の帯の裏に隠れる。それ以外の所のドラッグはトラックの並べ替え（ジェスチャーは `ArrangerView` が付ける）。

### `WaveformLaneView.swift`
1 トラック分のレーン。
- **レーン**: 空き領域のドラッグで枠選択（⌘ で範囲選択）、クリックで選択解除、Finder からの WAV ドロップで取り込み。
- **`AudioClipView`**: クリック（⇧／⌘ で追加・解除）、ドラッグで選択クリップをまとめて移動（⌥ で複製、⌘ で範囲選択）、左右トリム、ゲイン（上辺中央）、フェードイン／アウト（左上・右上）、フェードカーブ（フェード線中央のひし形。上下ドラッグで `FadeCurve.withMidpoint`、ダブルクリックで `.auto`）。ゲイン・フェード・カーブのハンドルは押した時点からドラッグとして扱い、値を `EditValueTooltip` で表示。
- **右クリックメニュー**: `LaneMenuMonitor`（右クリック／Control クリックのローカルモニター）がクリック位置で AppKit の `NSMenu` を組み立てる（SwiftUI のメニューは開く前に作られ、直前の選択変更を反映できないため）。範囲選択の内側なら範囲メニュー、クリップ上なら `selectForMenu` で選択してからクリップメニュー、それ以外は Cut／Copy／Paste のメニュー（`LaneMenu`）。クリップメニュー: ファイル名（複数なら個数）、Cut／Copy／Paste、Normalize、Reverse、ファイル選択（1 つのときのみ）、ミュート、複製、分割、削除。複数のときは項目名に個数を付ける。
- **表示**: 波形は `ClipLayering.envelope` の音量で描画し、上位クリップに完全に隠れた区間だけを暗くする。覆われた端のフェードハンドルは非表示。

### `WaveformCanvas.swift`
`WaveformCache` のピークを SwiftUI `Canvas` で描画（チャンネル別、ゲイン倍率、`envelope` による振幅）。
- **`FadeLinesOverlay`**: フェードイン／アウトの線をクリップの高さ全体にカーブの形で描く（ステレオでも 1 本）。

### `MixerView.swift`
Studio One 風ミキサー。
- **全体**: 上端ドラッグで高さ変更（SEND とフェーダー部の境目からミキサー下端までが 220pt 以上残る高さ〜1000pt。さらに、ドラッグ開始時の `growthLimit` を超えては広げない＝アレンジャーを 180pt 未満にしない。境界は AppKit の `VerticalResizeHandle` でカーソル形状とドラッグ範囲が一致）、横スクロールするトラック／FX ストリップ、右端固定の MASTER、右クリックで Add FX。
- **`StripSections`**: INSERT／SEND／コントロールの 3 区画（見出しは `SectionHeader`。`LocalizedStringKey` で翻訳される）と、区画の高さを変える境界（全ストリップ共通・UserDefaults 保存）。
- **`TrackStripView`**: INSERT（＋メニュー、緑丸で ON/OFF、名前クリックで GUI、ドラッグで並べ替え、× で削除）、SEND（FX ごとのレベルバーと dB 値）、PAN、M／S、フェーダー値、目盛り・フェーダー・ステレオメーター、名前（クリックで選択）。
- **`FXStripView`**: INSERT、（SEND 区画は空欄。位置合わせのためだけに残す）、PAN、「FX」表示、フェーダー、名前（ダブルクリックで改名）。右クリックメニューは「FX を追加」「FX チャンネルを削除」（削除は `confirmRemoveFXChannel` で確認ダイアログを経由）（ストリップ上ではミキサー全体のメニューより優先されるため、FX を追加も併記）。
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
