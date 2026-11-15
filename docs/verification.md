# 実機検証記録

完了と未確認を分けて記録します。モックによるテストは実モデル推論や画面検証の代替にしません。

| フェーズ | 確認済み | 残り |
| --- | --- | --- |
| 1 雛形 | Xcode 26.6、arm64、`xcodebuild` Debug `BUILD SUCCEEDED`。初期アプリの日本語チャット・サーバー・SettingsをネイティブUIで確認 | XCTest初回セットアップ・⌘,設定：1 test passed / 0 failed。最終チャットUIは後続 |
| 2 サイドカー | google-antigravity 0.1.23、litert-lm 0.19.2インストール、モデル取得完了。実モデル `sidecar.smoke` exit 0、list_directoryで既知のalpha.txt・beta.mdを返答、終了後子プロセス消滅 | なし（アプリ経由の検証は後続） |
| 3 サーバー管理 | 実UIで開始/停止/手動再起動、強制終了後の自動復帰、3連続失敗停止、手動復帰を確認。通常終了1 test passed、独立監視4プロセス残存0 | なし（全体テストのrunner制約は下記） |
| 4 連携 | 実モデルのSwiftUI回答でalpha.txt / beta.md一致、生成中の表示更新4段階をXCTestで確認 | なし |
| 5 承認 | 実UIで承認sheet表示中ファイル不存在、Approve後の内容一致。HTTPでは拒否後不存在も確認 | なし |
| 6 ルーティン | アプリ終了中のcalendar自然起動、実モデルalpha/beta回答、exit 0、登録解除、関連プロセス残存0、既存定義不変 | macOS通知の配送確認 |
| 7 インストール | /Applicationsにv0.1.0配置、codesign検証exit 0。installed URL指定の実起動・Settings操作1 test passed | spctlはrejected(exit 3)。ad-hoc署名のためGatekeeperの配布元認証は未達 |
| 8 アップデート | Sparkle 2.10.1統合、EdDSA鍵をKeychainに生成 | v0.1.0からv0.1.1のアプリ内更新 |

HIG: 画面の構成はNavigationSplitView・標準ツールバー、設定はSettingsシーン、承認はsheet、読み込みは不定進捗と経過時間、状態はアイコンと文言を併記します。対応項目の詳細は [UI設計](ui-design.md) に記載しています。

## 追加確認

- 初回ウィザード：XCTest `SetupUITests` 1 passed / 0 failed。実アプリからvenv作成・固定依存インストール・既存モデル認識・Done後チャット表示を確認。Python 3.15.0、`pip check` は `No broken requirements found.`。モデルの新規ダウンロードは先行CLIで確認したものを再利用。
- Release：独立出力先で `scripts/build.sh` が `BUILD SUCCEEDED`、ad-hoc署名検証成功。クラウド統合・キャッシュ禁止を含む最新候補でも再ビルド済み（後述）。
- クラウド：Google/OpenAI互換の設定と認証中継を実装。Pythonの契約テスト21件、Swift設定検証9件成功。実APIキーを使用したクラウド推論は未検証。

## 本番HTTPサイドカーの実モデル検証

`sidecar/test_real_http.py` を専用一時ワークスペースで実行し、終了コード0を確認しました。画面操作は含みません。

- `loading_model` → `ready`。
- ファイル一覧：SSEの非空テキスト23回、`list_directory completed`、alpha.txt / beta.md一致。
- 拒否：承認要求1回、拒否後ファイルなし。
- 許可：承認要求1回、`create_file completed`、内容 `APPROVAL_VERIFIED\n` 完全一致。
- `/shutdown`：終了コード0、所有する関連プロセス残存0。

本番のPython・ThreadedSDKBackend・HTTP・承認経路を通した検証です。SwiftUIの回答表示・承認sheet操作を証明するものではありません。

## 実UIの連携・承認確認

利用者がMac操作を控える時間に再開しました。各入力前の前面アプリ確認ガードを維持し、RuntimeUIは `1 passed / 0 failed / 0 skipped`。実モデルの一覧回答、生成中の表示4段階、書き込み前の承認sheet、承認後の内容一致、Stop後の停止状態まで確認しています。証跡はアプリウィンドウ限定でローカルに保管し、公開リポジトリには含めません。

## 署名済みバンドルの実行時不変性

サイドカーとLaunchAgentのPython起動に `-B` と `PYTHONDONTWRITEBYTECODE=1` を設定し、アプリ本体へのキャッシュ生成を禁止しました。

最新Releaseビルド：`BUILD SUCCEEDED`、`Release privacy checks passed`、ad-hoc署名検証成功。

`sidecar/test_bundle_immutability.py` をアプリ用venv（Python 3.15）とReleaseバンドルで実行：終了コード0、`PASS: startup/error/shutdown, unchanged bundle, no Python cache, valid signature`。意図したモデル欠落エラーの起動・停止を経ても、全バンドルファイルのハッシュが不変で、`codesign --verify --deep --strict` が成功しました。実モデルやGUIの検証ではありません。

Keychainの使用を利用者が許可した後、最新修正でv0.1.0 zipと署名付きappcastを再生成しました。`scripts/release.sh 0.1.0 1 taisei1989/in-house-agent` は終了コード0、zip/appcastのEdDSA署名検証成功。アーカイブは3,702,701 bytes、危険なパス・Pythonキャッシュ・モデル・秘密鍵ファイルの混入なし、appcastのURLとlength一致を確認。最新候補でもバンドル不変性テスト成功。GitHubへのアップロードはしていません。

リリーススクリプトの1コマンド公開フローは、外部公開を行わないmock統合テスト18ケースで成功。これは実GitHub公開やSparkle更新を証明するものではありません。

## サーバー管理の実UI証拠

`xcodebuild -project InHouseAgent.xcodeproj -scheme InHouseAgentLifecycleUI -configuration Debug -derivedDataPath build -destination 'platform=macOS,arch=arm64' -only-testing:InHouseAgentUITests/LifecycleUITests/testNormalQuitReapsOwnedProcesses -resultBundlePath /tmp/InHouseAgent-QuitUI-2.xcresult test`

出力: `Executed 1 test, 0 failures` / `TEST SUCCEEDED`（34.536秒）。ホスト側の独立監視で対象4プロセスを観測し、終了後残存0を確認しました。XCTest runnerは子プロセス列挙が制限されたため、起動・手動再起動・異常終了後復帰・連続失敗停止・手動復帰は先行Lifecycle実行で到達したassertionを再利用し、通常終了だけを限定して再確認しています。先行Lifecycle全体がpassしたとは扱いません。

連携・承認のコマンド: `xcodebuild -project InHouseAgent.xcodeproj -scheme InHouseAgentRuntimeUI -configuration Debug -derivedDataPath build -destination 'platform=macOS,arch=arm64' -resultBundlePath /tmp/InHouseAgent-RuntimeUI-8.xcresult test`。出力: `1 passed, 0 failed, 0 skipped`（143.898秒）。これは追加モダンUI改修前の結果であり、改修後の確認は別途記録します。

## 会話保存の追加確認

`xcrun swiftc -module-cache-path /tmp/inhouse-swift-module-cache App/ConversationStore.swift scripts/test_conversation_store.swift -o /tmp/inhouse-conversation-store-check` と生成バイナリの実行が成功。日英本文・ツール結果の保存復元、ファイル600、symlink除外、破損1件の隔離、削除を確認しました。UI操作の証明ではありません。

## LaunchAgentの実モデル検証

アプリ用venvから `python -B -m sidecar.test_routine_integration --execute --model MODEL_PATH --runner '/Applications/In-House Agent.app/Contents/Resources/sidecar/routine.py'` を実行。検証用の毎日時刻を設定し、`kickstart`を使わずStartCalendarIntervalによる起動を観測しました。

出力・結果: `runs: 1`、`last exit code: 0`、`status: success`、alpha.txt / beta.mdの両名一致、`unregistered: true`、`remaining_owned_processes: []`。既存ルーティンの定義は不変です。この先行テストは通知を除外しており、通知成功とは扱いません。

インストール先起動: NotificationUIは`1 passed / 0 failed`（13秒）。実際のfrontmost bundle URLが`/Applications/In-House Agent.app`と一致し、Settingsの通知要求ボタン操作まで成功しました。ただしproduction通知helperは`Notification permission is not granted.` / exit 1となり、OSの許可は未成立です。通知要求操作と配送成功を分けて扱います。

## 日本語の新UI

ModernInspectUI-8は保存済みの合成会話を使用し、`TEST SUCCEEDED`。本文のアクセシビリティラベル、思考未提供の説明を展開、ツールの外側・個別詳細の展開と結果本文、新規チャット、履歴検索、閲覧専用状態、通常終了後の再起動・本文復元・停止中の起動導線を確認しました。モデルの新規推論は先行ModernUIで成功した結果を再利用しています。LiteRT接続が思考を返さない制約を、思考本文の表示成功と取り違えません。

最新版のPython統合回帰: `PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -m pytest sidecar/test_server.py sidecar/test_cloud.py sidecar/test_event_preview.py -q` → `28 passed in 1.87s`。sandbox内の初回はlocalhost待ち受け制限によって2件失敗したため、ループバック通信を許可して再実行しました。外部の実クラウドAPIは呼んでいません。
