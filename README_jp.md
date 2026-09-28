# MyDAW — Mac 用マルチトラック・オーディオ DAW（Apple Silicon）

**バージョン 1.5** ・ [English README](README.md)

MyDAW は、Apple Silicon Mac 向けのマルチトラック・オーディオ録音／編集／ミキシング DAW（Digital Audio Workstation）です。Core Audio（AVAudioEngine / Core Audio HAL）を基盤とし、Audio Unit と VST3 のエフェクトを使用できます。

[NOTE]
このプロジェクトは、AI（Copilot、Antigravity）を使用して自動生成されました。詳細については、以下の記事をご参照ください。

* [日本語] https://note.com/tokada375/n/n750bfe9ef3f7
* [英語, 機械翻訳] https://note.com/tokada375/n/n750bfe9ef3f7?hl=en

---

## ドキュメント

| 資料 | 内容 |
| --- | --- |
| [OperationManual_jp.pdf](OperationManual_jp.pdf) / [OperationManual_en.pdf](OperationManual_en.pdf) | 初めて使う方向けの操作マニュアル |
| [docs/PROJECT_ANALYSIS_jp.md](docs/PROJECT_ANALYSIS_jp.md) / [_en](docs/PROJECT_ANALYSIS_en.md) | システム解析（構成、信号経路、スレッド、設計判断） |
| [docs/SOURCE_SPECIFICATION_jp.md](docs/SOURCE_SPECIFICATION_jp.md) / [_en](docs/SOURCE_SPECIFICATION_en.md) | ファイル・型ごとのソース仕様書 |

---

## 主な機能

### 録音
- 24-bit Linear PCM WAV（44.1 / 48 kHz）、モノラル／ステレオ、ディスク直書き。
- トラックごとに Core Audio デバイスの入力チャンネルを選択。
- 録音位置をサンプル単位で補正（自動＋手動の遅延補正）。
- **パンチイン／アウト**: パンチ範囲だけを録音。録音は通しで保存されるので、後から範囲を広げられます。
- **インプットモニタリング**（`I` ボタン）: 録音待機中の入力を、トラックのエフェクトを通して試聴（録音は原音）。
- メトロノーム（BPM、小節・拍ルーラー、クリックのタイミング・音量調整）。

### 編集
- クリップの移動（トラック間も可）、両端のトリム、クリップゲイン、フェードイン／アウト、分割、複製、削除、ミュート。
- クリップ編集の UNDO／REDO、拍へのスナップ。
- **重なり処理**: 後から追加したクリップが古いクリップより優先され、境界には等パワーのクロスフェードが自動で付きます。上のクリップのフェードがそのままクロスフェードになります。
- Finder から WAV をドラッグ＆ドロップで取り込み。

### ミキシング
- Studio One 風ミキサー。各ストリップは **INSERT**、**SEND**、**コントロール** の 3 区画で、高さを変更できます。
- dB 目盛りのフェーダー（最大 **+6 dB**）、ピークホールド付き L/R ステレオメーター、横 PAN、ミュート／ソロ、数値のダブルクリック入力。
- トラック、FX チャンネル（名前変更可）、マスター。Send はインサート後・PAN 後。
- トラック色をパレットから変更。

### プラグイン
- Audio Unit と VST3 のエフェクトを、トラック・FX・マスターに任意の順で挿入。
- VST3 はオーディオグラフ内でリアルタイム処理され、GUI での変更がすぐに音に反映されます。
- VST3 の検出は別プロセス＋キャッシュで実行。同じ製品の AU 版がある VST3 は、衝突を避けるため一覧に表示しません。
- プラグインの遅延補正、プラグイン設定のプロジェクト保存。

### プロジェクト
- プロジェクトはフォルダー単位（`MySong/MySong.mydaw` と `MySong/Recordings/`）。フォルダーごと別の Mac へ移行できます。
- マスター出力を 24-bit WAV へ書き出し。

---

## 動作環境

- Apple Silicon Mac、macOS 13 以上
- Xcode コマンドラインツールと CMake（ビルド時）
- マイクまたは Core Audio 対応オーディオインターフェース、ヘッドホンまたはモニタースピーカー

---

## ビルドと起動

正式なビルド手順はシェルスクリプトです。

```bash
./scripts/build.sh      # VST3 ブリッジ（CMake）とアプリをビルド
open build/MyDAW.app    # 起動

./scripts/run.sh        # ビルドして起動
```

> Xcode でもビルドできます。`MyDAW.xcodeproj` を開いて Product > Build（⌘B）を実行するか、`xcodebuild -project MyDAW.xcodeproj -target MyDAW -configuration Release build` を実行してください。成果物は `build/Release/MyDAW.app` です。最初のビルドフェーズで VST3 ブリッジを CMake でビルドするため、CMake を `/opt/homebrew/bin` か `/usr/local/bin` に入れておく必要があります。`Package.swift` は現行ソースに追従して**いません**。

Google Drive のフォルダー内でビルドする場合、スクリプトが署名前に拡張属性を取り除きます。

---

## クイックスタート

1. MyDAW を起動し、**New Project**（フォルダーを選択）または **Open Project** を選びます。
2. macOS がマイクへのアクセスを求めたら許可します。
3. 歯車ボタンで入出力デバイスとバッファサイズを選びます。
4. トラックの **R** をオンにして入力チャンネルを選び、メーターが動くことを確認します。
5. 赤い **Record** ボタンで録音を開始し、**Space** で停止します。
6. **Space** で再生します。画面下のミキサーで音量を調整します。

詳しい手順は [操作マニュアル](OperationManual_jp.pdf) を参照してください。

---

## ディレクトリ構成

```
MyDAW/
├── Sources/            Swift ソース（Models / Audio / Views）
├── VST3Host/           C++ VST3 ホストブリッジ
├── ThirdParty/vst3sdk/ Steinberg VST3 SDK
├── scripts/            build.sh、run.sh
├── docs/               解析書、仕様書、マニュアル原稿（docs/manual）
├── OperationManual_*.pdf
└── snapshots/          作業ごとのソーススナップショット
```

---

## 既知の制約

- VST3 インストゥルメントには対応していません（エフェクトのみ）。
- プロジェクトを開いたままデバイスのサンプルレートを変えた場合、VST3 プラグインを挿し直す必要があります。
- プラグインの挿入・削除・並べ替えは停止中のみ可能です。
- Relab LX480 は複数インスタンス時に Generic UI で表示されます（プラグイン側の GUI の既知の制約）。

---

## バージョン

現在の About ダイアログのバージョンは **1.5** です。
