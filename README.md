# AI Usage for Mac

Codex・Claude Code・OpenCode Go・SuperGrokの**定額プランの残り枠**を並べる、個人用macOSアプリとWidgetKitウィジェット。macOS 14以降。

## 使い方

1. `MacAIUsage.app`をApplicationsに置いて起動。
2. 接続設定でCodex／Claude Code／Grok CLIの既存ログインを確認。OpenCode GoのAPIキーを入力して保存。使うサービスだけ設定すればよい。
3. 「接続確認」を押す。ClaudeのKeychainアクセスを求められたら許可。
4. デスクトップを右クリック →「ウィジェットを編集」→「AI Usage」。小・中・大から追加。

小はアイコン＋週間%＋月間%（あれば）、最大4行。週・月以外の契約枠は対応するラベルで表示。中は短時間枠も併記、大はバーと各リセット時間を表示。割合はすべて**残り**。モデル別の追加制限は詳細画面で確認できる。

未設定のプロバイダーはウィジェットと使用状況から省き、接続設定では見出し行をクリックして展開する。設定済みの取得失敗・認証切れは警告付きで残る。

メニューバーから更新・詳細・設定を開ける。設定画面を閉じても動作し、ログイン時に起動する。終了すると新規取得は止まるため、ウィジェットの更新ボタンを使うにはアプリを起動しておく。

## 認証

- **Codex:** `codex login`のChatGPTログインを、公式`codex app-server` RPCから利用。CLIの場所は設定で変更可能。
- **Claude:** `Claude Code-credentials` Keychain（なければ標準`~/.claude/.credentials.json`）を読み取り、OAuth usage APIを呼ぶ。期限切れはClaude Code側で更新／再ログイン。アプリはClaudeの認証情報を書き換えない。`setup-token`ではusage権限が不足する。
- **Go:** OpenCode ConsoleのAPIキーをこのアプリ専用のKeychain項目に保存。`/zen/go/v1/usage`からGo定額枠だけを取得する。
- **Grok:** 初回は`grok login`でSuperGrokへログイン。Grok CLIの`~/.grok/auth.json`を読み取り、`https://cli-chat-proxy.grok.com/v1/billing?format=credits`から契約枠の割合を取得する。`GROK_HOME`がアプリの環境に渡されていればそのパスを利用。access tokenの有効期限が60秒以内なら、`grok models`を非対話で実行してCLI自身の自動更新を利用し、認証ファイルを読み直す。会話は生成しない。通常のトークン期限切れだけでは再ログインを要求せず、自動更新できない場合に通信状態・CLIの確認を案内する。アプリが認証ファイルを直接書き換えることはない。API残高・追加課金額を定額枠の代用にはしない。取得期間が判別できない場合は週／月を推測せず「契約枠」と表示。

ClaudeとGrokの取得APIは非公開仕様、Goの取得APIは公式ソースで確認した経路。上流の変更で調整が必要になる可能性がある。キーやレスポンス本文はログへ出さない。共有領域には使用状況と認証情報の一方向ハッシュだけを保存し、生の認証情報は渡さない。

Grokの取得形式の調査資料：[CodexBar GrokCreditsProxyFetcher](https://github.com/steipete/CodexBar/blob/main/Sources/CodexBarCore/Providers/Grok/GrokCreditsProxyFetcher.swift)、[GrokAuth](https://github.com/steipete/CodexBar/blob/main/Sources/CodexBarCore/Providers/Grok/GrokAuth.swift)。

GrokのCLI billingが割合を返さない契約では、同じ認証で`grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig`も確認する。既知のprotobufフィールドだけを解析し、RPCエラー・壊れたデータは拒否する。割合の省略を使用率0として扱うのは、protobufのゼロ省略仕様に加え、現在有効な期間の種別・開始・終了を検証できた場合だけ。調査資料：[GrokWebBillingFetcher](https://github.com/steipete/CodexBar/blob/main/Sources/CodexBarCore/Providers/Grok/GrokWebBillingFetcher.swift)。

## 更新の仕組み

- バックグラウンド取得：約20分（許容幅5分）、スリープ復帰時にも取得。
- WidgetKitの表示更新時刻はOS管理。毎分や15〜30分以内の反映を保証するものではない。
- 中・大の更新ボタンはApp Group内に要求を書き込み、起動中のアプリが取得して結果を返す。約55秒で確認できなければアプリを開くよう案内。
- 失敗時は最終取得値を保持し、警告と取得時刻を表示。1時間以上前の情報・リセット確認待ちにも警告。期限を過ぎても残り100%に推測で戻さない。
- アカウント／キーの変化を検知した場合、以前のアカウントの値は引き継がない。Claudeのトークン更新時も、再取得に成功するまでは以前の値を破棄する。GrokはユーザーIDが取得できればそのハッシュで識別し、同一アカウントのトークン更新ではキャッシュを失わない。
- 429では最低60秒、通常5分またはサービス指定秒数のバックオフ。

## 開発

必要：フルXcode、XcodeGen、Apple Development署名。

```sh
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project MacAIUsage.xcodeproj -scheme MacAIUsage -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build ONLY_ACTIVE_ARCH=YES build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

このMac用のTeam IDとApp Groupを`project.yml`・`Config/*.entitlements`・`Shared/SharedStore.swift`に設定済み。別の署名で使う場合は3か所を合わせる。`xcodegen generate`でプロジェクト・Info.plistを再生成できる。

### インストール済みアプリを更新するとき

- `project.yml`のアプリ／拡張両方の`CFBundleVersion`を同じ新しい番号に進めてからビルドする。
- アプリを終了し、検証済みのビルドで`~/Applications/MacAIUsage.app`を更新する。
- **ファイルを入れ替えるだけでは実行中の旧Widget Extensionは終了しない。** `pgrep -fl UsageWidget`でインストール先の拡張プロセスを確認し、そのPIDを`kill -TERM <PID>`で終了する。次の更新で最新版が起動する。
- `pluginkit`の登録先をインストール先だけに揃え、アプリを再起動する。既に登録解除済みのパスへの`pluginkit -r`は失敗するため、その失敗で後続の登録・起動を飛ばさない。
- アプリ側の取得確認だけで完了とせず、新しい拡張プロセスと**実デスクトップウィジェットの表示**を確認する。

未知のサービスが共有データに含まれても既知サービスの表示は維持する。データ破損やアクセス失敗は「共有データ読込失敗」と表示し、未設定と区別する。

構成：`App/`補助アプリ、`Widget/`3サイズ、`Providers/`接続とパーサー、`Shared/`モデル・共有キャッシュ・共通表示、`Tests/`データの意味と例外の検証。

Debugビルドの実行ファイルに`--render-previews <出力ディレクトリ>`を渡すと、明暗・3サイズの合成データ画像を生成する（ライブデータは変更しない）。インストール済みアプリを起動した状態で`--verify-widget-refresh`を渡すと、ウィジェットと同じ更新要求・応答経路を検証する。Release版にはこれらの診断機能を含めない。
