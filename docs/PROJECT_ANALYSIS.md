# MyDAW Project Analysis

詳細な型・関数・メソッド仕様は [SOURCE_SPECIFICATION.md](SOURCE_SPECIFICATION.md) を参照してください。実装との差分を含む全体構造図も同書に掲載しています。

## 1. 概要
MyDAW は macOS 向けのオーディオ録音・編集・再生を行う DAW プロトタイプです。

主要な特徴:
- Core Audio / AVAudioEngine を利用した入力収録
- 24-bit WAV 直接保存（Direct-to-Disk）
- 複数トラックの録音と再生
- 波形表示とタイムライン操作
- クリップの直線フェードイン／フェードアウト
- プロジェクト保存/読込
- Logic Pro 風のダーク UI
- AU／VST3エフェクトのトラック挿入と状態保存
- 起動時のプラグイン検出ログ表示

## 2. 主要コンポーネント

### 2.1 アプリ起動
- [Sources/MyDAWApp.swift](../Sources/MyDAWApp.swift)
- `@main` でアプリ起動
- `ProjectState` を `@StateObject` として保持
- マイク権限の要求を初期化時に実行

### 2.2 状態管理
- [Sources/Models/ProjectState.swift](../Sources/Models/ProjectState.swift)
- `ProjectState` が全体のドメイン状態を管理する中心オブジェクト
- トラック追加、選択、ズーム、スクロール状態、プロジェクト保存/読込を担当
- `AudioEngineManager` を保持して、再生・録音・プレイヘッド時間を制御

### 2.3 オーディオエンジン
- [Sources/Audio/AudioEngineManager.swift](../Sources/Audio/AudioEngineManager.swift)
- `AVAudioEngine` を使ってマイク入力、再生、レベル検出、録音ファイルの保存を処理
- `inputNode.installTap` により入力バッファを監視
- `AudioDiskWriter` を利用して WAV をリアルタイムにディスクへ書き出し
- `playheadTimer` や `meterTimer` により UI と同期

### 2.4 トラックとクリップ
- [Sources/Models/AudioTrack.swift](../Sources/Models/AudioTrack.swift)
- [Sources/Models/AudioClip.swift](../Sources/Models/AudioClip.swift)
- `AudioTrack` は名前、チャンネル設定、入力チャンネル、ミュート、ソロ、音量、パン、クリップ集合を持つ
- `AudioClip` は WAV ファイルへの参照、開始時間、ソース内オフセット、編集済み時間を保持
- ゲイン、フェードイン／フェードアウト長も保持
- トリミング、フェード、分割、複製、削除が可能

### 2.5 UI
- [Sources/Views/MainDAWView.swift](../Sources/Views/MainDAWView.swift)
- [Sources/Views/TransportBarView.swift](../Sources/Views/TransportBarView.swift)
- [Sources/Views/ArrangerView.swift](../Sources/Views/ArrangerView.swift)
- [Sources/Views/WaveformLaneView.swift](../Sources/Views/WaveformLaneView.swift)
- トランスポートバー、タイムライン、トラックヘッダー、波形レーンを構成
- `WaveformCanvas` は波形の描画を担当する想定で、今後の表示最適化の中心になる
- 起動時はプラグイン検出ログを表示し、完了後に閉じる。ログは黒背景と枠線付き。

### 2.6 プラグイン
- `PluginManager` がAudio UnitとVST3エフェクトを検出する。
- VST3は `VST3HostBridge` と `VST3NativeInstance` を通して生成・処理・状態保存・GUI接続を行う。
- VST3のInstrumentサブカテゴリはエフェクト一覧から除外する。
- VST3付きトラックのクリップはブロック単位で処理され、再生中のパラメータ変更を反映する。
- AUとVST3は同じトラックへ挿入でき、同一AUの複数インスタンスも許可する。
- Relab LX480 AUの複数GUIには互換性制約があるため、複数インスタンス時はGeneric UIへフォールバックする。
- ミキサーの挿入済みプラグイン名は `AU:`／`VST:` 接頭辞付きで表示する。

## 3. 実際の動作フロー

### 3.1 録音
1. トラックの `[R]` を有効化
2. `ProjectState.toggleRecordArm` でトラックを録音待機状態にする
3. `AudioEngineManager.startPlayOrRecord` が再生/録音を開始
4. 入力タップがオーディオバッファを取得
5. `processInputAudioBuffer` で各トラックの入力チャンネルに対応するピークと録音データを処理
6. `AudioDiskWriter` が WAV を `Recordings` 配下へ保存
7. チャンネル別のライブピークが通知され、UIへリアルタイム反映

### 3.2 再生
1. `AudioEngineManager` が各トラックの `AudioClip` を `AVAudioPlayerNode` に接続
2. 時間位置 `currentTime` に基づいて再生位置を制御
3. ミュート/ソロ/音量/パンを反映
4. 全トラックをまとめて出力してミックス
5. トラック内のプラグイン遅延は再生スケジュールを前倒しして補正する
6. マスタープラグインの遅延は、録音オブジェクトの配置補正へ加算する
7. モノラル音源は2ch再生バッファへ変換し、左右へ同じ信号を出力する

### 3.3 プロジェクト保存
- [Sources/Models/ProjectDocument.swift](../Sources/Models/ProjectDocument.swift)
- `ProjectState.saveProject()` で JSON 形式の `ProjectDocument` を保存
- トラック、クリップ、タイムライン位置、BPM、波形スケールなどを記録

### 3.4 プロジェクト読込
- `ProjectState.loadProject()` が JSON を読み込み、`AudioTrack` と `AudioClip` に復元
- 保存済みファイルのパスを再利用し、オーディオ波形とトリム情報を復元

## 4. 実装上の特徴

### 強み
- macOS Core Audio に直接依存しており、ハードウェア入力にも対応しやすい
- 24-bit WAV 直接保存によって長時間録音に向く設計
- トラック単位での入力選択、ミュート、ソロ、ボリューム制御が明確
- トラック／マスタープラグインの遅延補正を再生・録音配置で分離して扱う
- モノラル／ステレオの録音とチャンネル別ライブ波形に対応
- UI とオーディオ処理が比較的分離されている

### 制約・注意点
- 実行環境は macOS / Apple Silicon 前提
- `AVAudioEngine` と UI の状態同期が多く、スレッド境界を意識した実装が必要
- 録音と編集操作の同時禁止が実装されているが、複雑な編集操作に対する堅牢性は改善余地がある
- 波形レンダリング周りとプロジェクトデータ整合性の強化が今後の重要課題
- サードパーティVST3のObjective-Cクラス登録により、VST3モジュール列挙はメインスレッドで行う必要がある。
- AU GUIはプラグインごとの実装差があり、Relab LX480の複数カスタムGUI表示はGeneric UIへ切り替える。

## 5. 改善候補と優先順位

### 優先度高
1. プロジェクトの再開時の復元整合性の強化
   - 破損ファイルの処理
   - 保存失敗時のロールバック
   - インポート済み WAV の参照整合性

2. オーディオ編集機能の強化
   - クリップのズーム編集とグリッドスナップ
   - 複数クリップのマルチ選択

3. UI/UX 改善
   - クリップ選択時の強調表示改善
   - キーボードショートカットの一貫性
   - トラックのドラッグと並び替え

### 優先度中
1. バッファ設定の自動最適化
2. 入力チャンネル配列の一般化とデバイス別チャンネル検証
3. 再生・録音時のエラー通知の改善

### 優先度低
1. プロジェクトテンプレート
2. MIDI 対応
3. 自動保存機能
4. 物理ミキサー風のエフェクト処理

## 6. 実装上の直近の確認事項
- `./scripts/build.sh` によりビルド成功を確認済み
- 録音時刻はホスト時刻を基準に扱い、入力バッファ先頭の前方切り詰めは行わない
- 設定ダイアログの録音遅延調整は手動の `Additional recording compensation` を使用する
- 診断用のCore Audio遅延内訳とAutoボタンは設定ダイアログに表示しない

## 7. 次の開発フェーズの方向性
- Phase 1: 安定化とリファクタリング
- Phase 2: クリップ編集とタイムライン UX 強化
- Phase 3: MIDI/エフェクト/ミキサーの追加
- Phase 4: 高度なプロジェクト管理とバージョン管理

## 8. 実務的な着手順
1. 実行・保存・読込の基本フローをテストする
2. ブラッシュアップ対象の UI 部分を絞る
3. `ProjectState` と `AudioEngineManager` の責務を整理する
4. 追加機能を小さく切り出して PR 化する
5. 変更後は毎回ビルド確認を行う
