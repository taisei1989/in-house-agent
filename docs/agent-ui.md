# 会話・エージェントUIの設計

以下の公式資料を比較し、会話を中心に、必要な実行情報を段階的に開く構成を採用しました。

- [Codex App Server](https://learn.chatgpt.com/docs/app-server)：ツール実行イベント、操作単位の承認、公開reasoning summary。
- [Claude Code interactive mode](https://code.claude.com/docs/en/interactive-mode)：中断、詳細履歴、実行状況。
- [OpenCode TUI](https://opencode.ai/docs/cli/tui) と [permissions](https://opencode.ai/docs/permissions)：会話管理、接続先選択、操作権限。
- [ChatGPT desktop guide](https://help.openai.com/en/articles/20001276-moving-to-the-new-chatgpt-desktop-app)：会話へ集中する構成と最近の会話へのアクセス。

## Mobbinの実画面参照

`mobbin-search`で検索し、画像を実際に確認しました。Web画面を横長macOSレイアウトの参照に用い、配色はmacOSのシステム色へ置き換えています。

- [ChatGPTの会話と思考開閉](https://mobbin.com/screens/d41feba8-464c-4353-839f-dc10efdfe392)：右寄せの入力、背景なしの回答、小さな思考開閉行、下部入力欄。
- [ChatGPTの回答下アクション](https://mobbin.com/screens/0729631b-f0f3-423c-8eff-5903dc2d0ca9)：回答下の控えめなコピー・再試行、左側の会話一覧。
- [Claudeの作業状況](https://mobbin.com/screens/a67f0c5d-058c-4264-b28c-a0bac90b971a)：ツール実行を狭い開閉行にまとめ、進行中の処理名を区別。

## 実装対象

中央幅を抑えた会話、下部の入力欄、サイドバーの履歴、応答ごとの状態・思考・ツール履歴を用意します。ツールの引数・結果・エラーは折りたたみ、長い出力は表示上限を明示します。思考はAntigravity SDKが公開するThought.textだけを表示し、signatureは転送しません。要約とは呼ばず、モデルが提供しない場合に架空の思考は表示しません。

会話はApplication SupportのConversations配下に保存します。モデルの出力やツール結果には個人情報が含まれ得ます。フォルダ700・ファイル600で保存し、アプリから会話を削除できます。会話削除は実行済み操作や作成ファイルを取り消しません。ログやSDKの保存データの削除とは別です。

過去の会話を開く操作は閲覧です。「履歴を添えて続ける」は、現在の接続先と作業フォルダを確認してから新しい実行を開始します。送信するのは最近の会話本文最大16,000文字で、過去のツール実行を再生せず、SDK内部セッションを復元したとは扱いません。思考やツール結果の全文はこの文脈へ自動追加しません。再送は同じ操作を繰り返す可能性があるため確認を必要とします。

## 対応しない操作

バックエンドが提供していない操作を見かけだけのUIとして置きません。ファイル添付、並行エージェント、実行のundo、コンテキスト占有率・消費トークンの推定表示は今回の対象外です。承認は操作単位であり、今後のすべてを許可する操作はありません。

## HIGと検証

NavigationSplitView、Settingsシーン、標準DisclosureGroup、alert・sheetを使います。色と背景はシステム由来にし、状態は色だけに依存させません。固定UI文言はString Catalogの日英、アイコン操作はVoiceOverラベル、キーボード操作を用意します。実UI検証の合否は[検証記録](verification.md)に記載します。この設計文書自体は動作の証明ではありません。

## 現SDKの思考出力の制約

実環境のgoogle-antigravity 0.1.23では、公開`Thought`型はありますが、LiteRT側の`_stream_response`は本文・ツール呼び出しを転送し、思考フィールドを転送していません。`lightweight()`が思考を無効化しているわけではありません。実Gemma応答でもThoughtは0件でした。UIはこの場合に未提供と明示し、SDKが提供する接続の公開Thoughtだけを表示します。SDK私的APIやモデル内部を抽出する変更は加えていません。
