# リリース手順

`release-config.json` がアプリ名、Bundle ID、表示バージョン、ビルド番号、公開先、Sparkle 公開鍵の設定元です。アプリ名は In-House Agent、Bundle ID は com.taisei1989.inhouseagent、公開先は taisei1989/in-house-agent です。アプリ名と Bundle ID は更新時に変更しないでください。

## 初回準備

1. `xcodebuild -resolvePackageDependencies -project InHouseAgent.xcodeproj -scheme InHouseAgent -derivedDataPath build` で Sparkle を取得します。
2. `scripts/release.sh --generate-key` を実行します。秘密鍵は login Keychain に保存されます。表示された公開鍵だけを `release-config.json` の `sparkle_public_key` に設定します。鍵を失うと ad-hoc 配布の更新を継続できないため、Keychain を保護してください。
3. `github_repository` は `taisei1989/in-house-agent` に設定済みです。既定のフィードは `https://github.com/taisei1989/in-house-agent/releases/latest/download/appcast.xml` です。GitHub Pages を使う場合は `feed_url` を変更し、生成された appcast をその URL に配置してください。非公開リポジトリの認証付き配布は未対応です。

## 1コマンドで公開する

レビュー済みのソースと初期設定をコミットし、リポジトリの既定ブランチをチェックアウトしておきます。`origin` の取得先・push先は指定したGitHubリポジトリと一致させます。そこから次の1コマンドで、設定のバージョン更新、ビルド、署名検証、設定だけのコミット、タグ作成、branchとtagのatomic push、GitHub Release公開まで実行します。

```sh
scripts/release.sh 0.1.1 2 taisei1989/in-house-agent --publish
```

初回は `0.1.0 1` を指定できます。既に存在するローカルタグ・リモートタグ・リリースは上書きしません。アプリ名、Bundle ID、鍵、公開先を変更する操作はリリースコマンドに含めず、事前に別途レビュー・コミットしてください。

公開せず生成物だけを確認する場合は `--publish` を省略します。

```sh
scripts/release.sh 0.1.1 2 taisei1989/in-house-agent
```

この準備モードは `release-config.json` の変更を作業ツリーに残します。その後公開する場合は、設定変更を確認してコミットし、クリーンな状態から同じ引数に `--publish` を付けて実行してください。手動のタグ作成やpushは不要です。公開モードはこの場合も再ビルド・再署名してから公開します。

既定は ad-hoc 署名です。Developer ID を使う場合は `SIGN_IDENTITY='Developer ID Application: …'` を指定します。公証には `xcrun notarytool store-credentials` で Keychain プロファイルを準備し、`NOTARY_PROFILE` を渡してください。秘密値を引数や設定ファイルに保存しないでください。公証・staple 後の最終 zip に EdDSA 署名します。

公開開始前にクリーンな作業ツリー、通常のブランチ（detached HEAD不可）、GitHubの既定ブランチ、`origin` の取得・push先、未使用のタグを確認します。既存のlatestリリースがある場合、その署名済みappcastを取得して検証し、表示バージョンとビルド番号の両方が増加していることを確認します。公開鍵とKeychainの鍵の一致、zipとappcastの署名を公開前に検証します。アプリは署名済みフィードと展開前の更新署名検証を必須にします。

ビルド中に別のファイルや設定が変更された場合はコミットせず停止します。作成するコミットは検証済みの `release-config.json` の変更だけで、タグはそのコミットを指します。branchとtagはforceなしでatomic pushし、GitHub側のタグSHAが一致した後にReleaseを公開します。
`--publish` はコミット済みのルート `release-config.json` を必須とし、外部の `RELEASE_CONFIG` は拒否します。認証なしの更新配信に合わせ、公開先リポジトリが public であることも確認します。設定のアプリ名・Bundle ID・バージョン・HTTPSフィード・公開鍵を検証してからビルドし、Info.plist は文字列コマンドではなく構造化データとして更新します。

Pythonサイドカーは明示した実行用 `.py` ファイルだけをReleaseアプリへコピーし、キャッシュ・テスト・作業用ファイルを同梱しません。生成物は `dist/` 内で管理し、リポジトリへコミットしないでください。

公開前は `.gitignore` だけに頼らず、実際のコミット対象と配布アーカイブを確認してください。`.env`、署名鍵、Keychain、モデル、ログ、個人用の設定を含めないことを確認します。署名済みアーカイブは署名後に変更しないでください。アプリの安全境界と脆弱性報告は [SECURITY.md](../SECURITY.md) を参照してください。

```sh
SIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)' \
NOTARY_PROFILE=in-house-agent-notary \
scripts/release.sh 0.1.1 2 taisei1989/in-house-agent --publish
```

## 失敗時の扱い

失敗しても、作業ツリーの変更・コミット・タグを自動で削除したり元に戻したりしません。

- ビルドまたは署名で失敗した場合：ログと設定変更を確認して原因を直し、変更をレビュー・コミットしてから再実行してください。
- pushで失敗した場合：ローカルのリリースコミットとタグは残ります。リモートとの差分を確認してください。既存タグを無条件に削除・上書きして再試行しないでください。
- push後のRelease公開で失敗した場合：同じタグがあるため、スクリプト全体の再実行は拒否されます。タグSHA・アーカイブ署名・appcast署名・設定を照合したうえで、検証済みの同じ生成物を `gh release create ... --verify-tag` で公開するか、原因解決後に新しいバージョンを作成します。すでに公開済みのバージョンへ別のアーカイブを差し替えないでください。

`python3 scripts/test_release.py` は一時Gitリポジトリとmockを使って、公開の制御フローと失敗ガードを検証します。ネットワークへのpush、実署名、実アプリビルドは行いません。実機アップデート確認の代わりにはなりません。

## 更新確認

v0.1.0 を `/Applications` にインストールし、v0.1.1 を公開してから、アプリの「アップデートを確認…」を選びます。適用前にサイドカーが停止すること、再起動後のバージョンとビルド番号、新しいサイドカーが動作することを確認します。アプリ内更新の実機確認は別途必要で、ビルドや署名検証だけでは完了になりません。

## トラブルシューティング

- `Missing Sparkle …`: 先にパッケージを解決してください。別配置の場合は `SPARKLE_BIN` を指定します。
- 更新が見つからない: 公開された appcast の URL、`CFBundleVersion` の増加、`SUPublicEDKey` と署名鍵の一致を確認します。同じビルド番号は再試行用で、新しいリリースでは増加が必要です。
- framework のロードに失敗: ad-hoc モードは Hardened Runtime を無効にしています。Developer ID モードでは Framework とヘルパーを含む署名を Xcode に任せます。
- Gatekeeper に拒否される: ad-hoc は Apple の公証済み配布ではありません。ローカル起動成功とダウンロードした配布物の Gatekeeper 検証は区別してください。
- CI: ワークフローはビルド用です。署名鍵を自動で新規作成しません。公開は Keychain に同じ EdDSA 鍵を保持する Mac で行います。

公式資料: [導入と鍵管理](https://sparkle-project.org/documentation/)、[更新公開](https://sparkle-project.org/documentation/publishing/)、[SwiftUI 連携](https://sparkle-project.org/documentation/programmatic-setup/)。
