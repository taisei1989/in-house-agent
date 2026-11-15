# In-House Agent

SwiftUIで作る個人用macOSエージェントです。Google Antigravity Python SDKをローカルのサイドカーに置き、Gemma 4 26B A4BをLiteRT-LMで実行します。

**個人利用向けのad-hoc署名版です。** 実モデル推論、承認付き書き込み、LaunchAgentの通知、v0.1.0からv0.1.1へのアプリ内更新を実機で確認しています。Appleの公証はなく、標準Gatekeeper評価はrejectedです。実証の範囲と制約は[検証記録](docs/verification.md)に記載します。

## セットアップ

配布物は[GitHub Releases](https://github.com/taisei1989/in-house-agent/releases/latest)から取得できます。

- Apple Silicon、macOS 14以降、ユニファイドメモリ24GB以上が必要です。
- Python 3.10以降が必要です。固定した依存関係のインストール実績はPython 3.14と3.15です。
- モデルは約15.3GiBです。モデル・Python環境・ダウンロード用一時領域の空き容量を確保してください。

アプリを起動し、初回セットアップ画面でPython実行ファイルを指定します。セットアップは次を順に行います。

1. `~/Library/Application Support/InHouseAgent/venv` を作成します。
2. 同梱の `requirements.lock` の固定バージョンをインストールします。
3. `litert-lm import` でモデルを取得します。モデルの既定パスは `~/.litert-lm/models/gemma4-26b/model.litertlm` です。
4. 設定で作業ディレクトリを指定し、サーバーを起動します。既定は専用の `Application Support/InHouseAgent/Workspace` です。ホームフォルダ全体を自動的に読み取り対象にしません。

モデルはアプリやGitHubリポジトリに含めません。依存関係のロックが更新された場合はセットアップ画面で再インストールします。モデル読み込みの進捗率はSDKから得られないため、段階・経過時間・ログを表示します。

表示言語はmacOSのアプリ言語設定に従い、日本語と英語に対応します。チャットの送信は⌘↩、新規チャットは⌘N、設定は⌘,です。ファイル作成・編集・コマンド実行は操作内容を確認して承認します。ルーティンは毎日の時刻を指定してLaunchAgentに登録します。無人実行で承認が必要な操作は拒否されます。

既定の推論はローカルです。ただし初回インストール・モデル取得・更新確認はネットワークを使います。承認したコマンドもネットワークやユーザー権限のファイルへアクセスできます。OSによるサンドボックスではありません。詳細は [SECURITY.md](SECURITY.md) を参照してください。

### クラウド併用（任意）

既定はOFFです。設定の「クラウドモデル」でGoogleまたはOpenAI互換を選び、モデル名とAPIキーを設定します。OpenAI互換ではプロバイダーのHTTPS APIベースURLも指定します。キーはmacOS Keychainに保存され、保存後は画面に再表示しません。

設定変更時は送信を停止し、稼働中のサーバーを終了します。次の手動起動から選択した接続先が使われます。ONの間、プロンプトとツールの実行結果は選択したプロバイダーに送信されます。自動的なクラウドへのフォールバックは行いません。

GoogleはSDKのAPIキー対応設定を利用します。OpenAI互換はSDKに認証ヘッダー設定がないため、限定されたローカル中継からキーを付加します。中継はHTTPSの固定接続先にのみ送信し、リダイレクトを追いません。

ルーティンはローカル専用です。共有サーバーがクラウドモードの場合は実行を拒否し、定期タスクの内容を意図せず外部送信しないようにします。外部プロバイダーの実APIへの接続確認は、利用者の認証設定が必要です。

## 会話と実行履歴

会話画面にはモデル・接続先・作業フォルダを表示します。各回答の「モデルの思考」と「ツールの実行」を開くと、SDKが提供した思考テキストやツール名・引数・結果・エラーを確認できます。長い内容はプレビュー上限を明示します。提供されない思考を生成して表示することはありません。

会話はMac内に保存され、サイドバーから検索・閲覧・名前変更・削除できます。過去の会話から続ける場合は、接続先を確認したうえで最近の本文最大16,000文字を新しい実行へ添えます。SDK内部セッションやツール操作の復元ではありません。中断や再送にも対応しますが、再送は同じ操作を再度行う可能性があるため確認が出ます。

保存内容にはプロンプト・回答・思考・ツールの結果が含まれ得ます。会話削除は作成済みファイルやSDKログを削除しません。UIの参照資料と対応範囲は[エージェントUI](docs/agent-ui.md)を参照してください。

## 開発・リリース

Xcodeをインストールし、プロジェクトをビルドします。

```sh
python3 scripts/generate_project.py
xcodebuild -project InHouseAgent.xcodeproj -scheme InHouseAgent \
  -configuration Debug -derivedDataPath build build
```

配布用は `scripts/build.sh` を使います。Pythonソースを許可リストから同梱し、ローカルキャッシュ・テスト・ログの混入を防ぎます。表示名は `In-House Agent`、Bundle IDは `com.taisei1989.inhouseagent` です。

Sparkle 2の署名鍵はKeychainに置き、`release-config.json` には公開鍵だけを保存します。既存鍵を上書き・再生成せず、保管を継続してください。

```sh
scripts/release.sh 0.1.2 3 taisei1989/in-house-agent
```

この例は次のバージョンをローカルに準備するものです。コマンドはビルド・署名・zip・署名付きappcastを生成します。公開はcleanなmainブランチから `scripts/release.sh VERSION BUILD taisei1989/in-house-agent --publish` の1コマンドで行います。署名検証後にバージョン設定だけをコミットし、タグとブランチをatomic pushしてGitHub Releaseを作成します。事前条件や失敗時の復旧、Developer IDがある場合の公証、GitHub Actionsについては [リリース手順](docs/releases.md) を参照してください。

現在の署名方式は個人利用向けad-hocです。Appleによる公証やDeveloper IDの信頼とは異なります。Gatekeeperの結果と初回起動の確認を、署名検証とは別に扱います。

## トラブルシューティング

- **Pythonのインストールに失敗する**：セットアップログを確認し、対応するPython実行ファイルを指定してください。ネットワークエラーは再試行できます。
- **モデルを読み込めない**：設定のモデルパス、空きメモリ、サーバーログを確認してください。モデルはアプリとは別に保存されます。
- **再起動が止まった**：短時間の連続異常終了を検出すると自動再起動を停止します。原因をログで確認してから手動起動してください。
- **ルーティンが変更を実行しない**：無人時の書き込み・コマンドは拒否します。アプリのチャットで対話的に実行してください。
- **通知が届かない**：アプリの設定で通知を有効にし、macOSの通知設定も確認してください。通知の許可と実際の配送は別です。
- **アップデートできない**：フィードURL、公開鍵、ネットワーク、公開済みバージョンを確認してください。署名検証を無効にして回避しないでください。

ログとルーティン結果は `~/Library/Application Support/InHouseAgent/` 内に保存されます。問い合わせに添付する前にプロンプト・ファイル内容・個人パスを確認してください。

## 参考資料

- [Googleのローカルモデル対応紹介](https://developers.googleblog.com/introducing-support-for-local-ai-models-in-the-antigravity-sdk/)
- [Antigravity SDK](https://github.com/google-antigravity/antigravity-sdk-python#local-ai-models)
- [Sparkle](https://sparkle-project.org/documentation/)
- [画面構成とApple HIG対応](docs/ui-design.md)
