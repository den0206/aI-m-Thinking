# aI'm Thinking を Mac App Store の審査へ提出する手順

調査日：2026年10月3日。対象は、このリポジトリの SwiftUI + Rust 製メニューバーアプリです。Appleの公式資料とリポジトリの実装を照合しました。

**App Store向けの基本設計は実装済みですが、現状のビルドは審査提出用ではありません。** まずXcodeのmacOS Appターゲットを追加し、アクセス範囲を制限するSandbox環境で実機確認を行います。審査担当者がClaude CodeやCodexの認証なしで主機能を確認できる環境も、まだ準備が必要です。その後、提出用のビルド成果物であるArchiveをApp Store Connectへアップロードし、掲載情報を入力して審査へ送ります。

既存の [APP_STORE.md](APP_STORE.md) は技術設計と実装状況を扱っています。本書は、初回提出までに必要な作業と操作手順を補足します。アカウント登録、契約同意、アップロード、審査提出は今回の調査では実行していません。

進捗は末尾の[提出までの作業チェックリスト](#submission-checklist)で管理します。

## 1. 現状では、提出用ビルドと実機確認が残っている

| 項目 | リポジトリで確認できた状態 | 提出までの対応 |
|---|---|---|
| UI | SwiftUIの`MenuBarExtra`。Dockにアイコンを表示せず、メニューバーから操作する構成 | 起動後にメニューバーを開く手順を説明する |
| 対応OS | `app/Package.swift`、ビルドスクリプトともmacOS 26.0以降 | ストア説明とXcode設定を一致させる |
| ビルド環境 | このMacはXcode 27.0 / Swift 6.4。PackageもSwift 6.4を指定 | 提出用ターゲットを同じ環境で構築する |
| CPU | 既存Release文書ではApple Silicon向け。スクリプトは実行環境のCPU向けにビルド | 初回はarm64で揃える案が簡単。Intel対応ならSwiftとRustの両方を対応させる |
| 本番Bundle ID候補 | `com.den0206.AImThinking` | Developerアカウントで登録・利用可能か確認する |
| 配布モード | `direct`と`app-store`を切り替える実装あり | 提出用Info.plistに`AImThinkingDistribution = app-store`を入れる |
| Sandbox | 本体とRust補助プロセスの権限設定（entitlements）あり | 署名済みArchiveとインストール後の実動作を確認する |
| フォルダ権限 | 標準フォルダ選択画面（`NSOpenPanel`）と、アクセス許可を保存するbookmarkを実装。再起動時の復元と取り消しにも対応 | 実際のセッションフォルダで確認する |
| Privacy Manifest | `PrivacyInfo.xcprivacy`あり | 提出用ターゲットにも同梱する |
| Xcode Archive | `.xcodeproj` / `.xcworkspace`が見つからない | macOS Appターゲットと共有Schemeを追加する |
| CI | Sandboxのsmokeビルドと権限検査あり | CI設定の存在は確認したが、最新実行の成功や実機動作は未確認 |
| 審査用の再現環境 | Rustテスト用fixtureはある。利用者向けの再現機能は確認できない | 第三者の有料アカウントに依存しない確認方法を用意する |
| 掲載ページ | 公開済みのサポート／プライバシーURLは未確認 | アクセス可能なページを用意する |

根拠： [Package.swift](../app/Package.swift)、[build-app.sh](../scripts/build-app.sh)、[DistributionMode.swift](../app/Sources/AImThinking/DistributionMode.swift)、[AgentRootProvider.swift](../app/Sources/AImThinking/AgentRootProvider.swift)、[App CI](../.github/workflows/app.yml)、[Release文書](RELEASE.md)。

## 2. Developer IDによるDMG配布とは、署名と提出先が異なる

現在のGitHub Releases向け経路は、Developer ID署名、公証、DMG生成です。Mac App Store向けは、App Store用の署名とApp Store Connectへのアップロードを使います。既存の`notarytool`認証情報だけでは、App Store向け署名を設定できません。

| 用途 | 署名・配布方法 |
|---|---|
| GitHub等で配るアプリ | Developer ID Application署名 + 公証 |
| App Storeへ送るアプリ本体 | Apple Distribution / Mac App Distribution等、Xcodeが選ぶApp Store用の署名 |
| Mac App Store提出用インストーラパッケージ | Mac Installer Distribution |

証明書名は環境や方式で異なるため、最初はXcodeの自動署名を使い、Organizerで実際に選ばれた署名を確認する方法を勧めます。Mac Installer Distributionは、ストア外配布用のDeveloper ID Installerとも別です。[Appleの証明書一覧](https://developer.apple.com/help/account/certificates/certificates-overview)

`CONFIG=appstore-smoke bash scripts/build-app.sh`で作るアプリは開発・CI確認用です。Bundle IDも`com.den0206.AImThinking.appstore-smoke`であり、提出用には使いません。Mac App StoreではXcodeの技術によるパッケージ化・提出が必要です。[審査ガイドライン 2.4.5](https://developer.apple.com/app-store/review/guidelines/#hardware-compatibility)

## 3. アカウントとアプリの登録を先に済ませる

### Developer Programへ加入する

App Store配布にはApple Developer Programへの加入が必要です。年会費は99 USDで、地域によって現地通貨の価格になります。日本円の実際の請求額は加入画面で確認します。

個人で加入すると、販売者名として本人の法的氏名が表示されます。法人・団体で加入する場合は、原則としてD-U-N-S Numberと組織の確認が必要です。[加入条件と料金](https://developer.apple.com/programs/enroll/)

既に加入済みなら、XcodeのAccounts設定でチームを選べることと、App Store ConnectのBusinessに未同意の契約がないことを確認します。無料配布はDeveloper Programの契約で扱えます。有料販売やアプリ内課金をする場合はPaid Apps Agreementへの同意と、入金に必要な銀行・税務情報の登録が加わります。[契約の種類](https://developer.apple.com/help/app-store-connect/manage-agreements/sign-and-update-agreements)、[税務情報](https://developer.apple.com/help/app-store-connect/manage-tax-information/provide-tax-information)

### Bundle IDを登録し、App Store Connectにアプリを作る

DeveloperアカウントのCertificates, Identifiers & Profilesで、提出用の明示的なBundle IDを登録します。候補は`com.den0206.AImThinking`です。リポジトリの文字列だけでは、チームでの登録済み・利用可能を確認できません。

App Store Connectの「Apps → ＋ → New App」で、次を入力します。

| フィールド | このアプリでの候補 |
|---|---|
| Platform | macOS |
| Name | aI'm Thinking。名称の利用可能性は作成時に確認 |
| Primary Language | 初回の説明・サポートを提供する言語。既存UIは英語 |
| Bundle ID | 登録した本番ID |
| SKU | 例：`aimthinking-mac`。利用者には見えない内部管理用ID |
| User Access | チームの必要なメンバーにアクセスを付与 |

アプリレコードはビルドのアップロード前に必要です。作成にはAccount Holder、Admin、App Managerのいずれかの役割が必要です。[アプリの新規作成](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app)

Bundle IDはXcodeとApp Store Connectで一致させます。ビルドをアップロードした後はApp Store Connect側で変更できません。SKUもアプリ作成後に変更できません。[アプリ情報の仕様](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/)

既存のDMG版と同じBundle IDを使うかは、この段階で確定します。同じIDを採用する場合は、Sandbox導入後の設定保存先、ログイン項目、既存版からの置き換えを実機で確認してください。

## 4. Xcodeに提出用のmacOS Appターゲットを追加する

以下は実装方針の提案です。今回、プロジェクトの追加やコード変更は行っていません。

1. Xcodeの「File → New → Project → macOS → App」で提出用プロジェクトを作る。
2. 自動生成されたAppのエントリーポイントを削除し、既存の`app/Sources/AImThinking`を参照する。既存の`@main`を使い、Swiftソースを複製しない。
3. Deployment TargetをmacOS 26.0にし、Swift 6モードで既存ソースをビルドできるようにする。
4. 本番Bundle ID、Developer Team、Version、Buildを設定する。初回バージョン例は`1.0.0`、ビルド例は`1`。再アップロードするビルドは番号を増やす。
5. Signing & Capabilitiesで自動署名とApp Sandboxを設定し、既存の本体用entitlementsを参照する。
6. Info.plistに`LSUIElement = true`、`AImThinkingDistribution = app-store`、`NSHumanReadableCopyright`、適切な`LSApplicationCategoryType`を設定する。カテゴリはUtilitiesを第一候補とする。
7. アイコン、`Sounds`ディレクトリ、`PrivacyInfo.xcprivacy`をアプリのリソースとして組み込む。音源は`Contents/Resources/Sounds/kc1000/*.wav`の階層を維持する。
8. RustのRelease実行ファイルをビルドし、アプリの`Contents/MacOS/im-thinking-core`に埋め込む。現在の`CoreBridge`がこの位置を探すため、配置を変えるなら参照先も合わせる。
9. Rust実行ファイルを本体より先に署名する。Archiveだけでなく、Organizerの配布時の再署名後も、補助プロセスの署名と権限が正しいことを確認する。
10. 共有Schemeを作り、ArchiveアクションがRelease構成を使うようにする。

Appleは、外部ビルドシステムで作ったコマンドラインツールをSandboxアプリに埋め込む構成も説明しています。RustをSwiftへ移植する必要はありません。補助ツール用ターゲットを設ける場合は、`SKIP_INSTALL = YES`としてArchiveに単独の実行ファイルを混入させないことが重要です。[補助ツールの組み込み](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app)

本体の権限は現在の以下を使います。

```text
com.apple.security.app-sandbox = true
com.apple.security.files.user-selected.read-only = true
com.apple.security.files.bookmarks.app-scope = true
```

Rust補助プロセスは、次の2つを基本にします。

```text
com.apple.security.app-sandbox = true
com.apple.security.inherit = true
```

補助プロセスに`get-task-allow`等の余分な権限を注入しないようにします。Appleの例ではツール用ターゲットの`CODE_SIGN_INJECT_BASE_ENTITLEMENTS`を無効にしています。既存のdebug用entitlementsを提出用に流用しないでください。[補助プロセスの署名設定](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app?language=objc)

Apple Siliconのみで出すなら、本体もRustもarm64で統一します。Intel対応を加える場合は、Rustもx86_64用をビルドしてUniversal Binaryにするなど、両方の実行ファイルのCPU対応を揃えます。

### SDK要件と最低対応OSを区別する

このMacはXcode 27.0 / Swift 6.4で、現在のリポジトリの指定と一致しています。Appleの2026年4月28日からのSDK最低要件の告知は、iOS、iPadOS、tvOS、visionOS、watchOSが対象で、macOSは列挙されていません。「その告知によってMacアプリにもmacOS 26 SDKが必須になった」とは解釈できません。[2026年の告知](https://developer.apple.com/news/?id=ueeok6yw)

ビルドに使うSDKと、利用者の最低対応OSは別の設定です。このアプリの最低OSがmacOS 26なのは、Packageとアプリ側の指定によります。実際の提出日に、Appleの提出ページとOrganizerの検証結果を再確認してください。[提出時の最新案内](https://developer.apple.com/app-store/submitting/)

## 5. Sandboxの権限は、インストールしたアプリで確認する

entitlementsがファイルに書かれているだけでは、Rust側で選択したフォルダを監視できることは証明できません。実際のSandboxアプリで、次を確認します。

| 確認場面 | 期待する結果 |
|---|---|
| 初回起動・権限なし | 初回ウィンドウが開き、フォルダを1つ許可するまでDoneと閉じるボタンが無効 |
| 別Agentや親フォルダの選択 | 赤いエラーが表示され、bookmarkは保存されない |
| Claude Codeのフォルダ選択 | 選択した`.claude/projects`内の新しいセッション活動を検出する |
| Codexのフォルダ選択 | 選択した`.codex/sessions`内の活動を検出する |
| アプリ終了・再起動 | bookmarkからアクセスを復元する |
| フォルダ移動・削除 | クラッシュせず、再選択等で復旧できる |
| Revoke | 監視・音が止まり、再起動後も権限が復活しない |
| 許可していない隣接フォルダ | 読み取り権限がない |
| セッション作成・追記・置換 | FSEventsと追記読み取りが正常に動く |
| アプリ終了 | Rust補助プロセスが残らない |
| Start at Login | 利用者の明示操作で設定され、解除もできる |

`NSOpenPanel`は隠しフォルダを表示する実装です。選択が難しい場合は、標準パネルの「⌘⇧G」でフォルダへ移動する方法を案内します。ただしSandbox内ではホームディレクトリの扱いが変わるため、現在の`homeDirectoryForCurrentUser`から作る候補パスが、実際の利用者のセッションフォルダへ案内できるかも確認します。[Sandbox内のファイルアクセス](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)

Rustには、Claudeの`projects`と同階層の`sessions`を追加で参照する任意の処理もあります。`projects`だけを許可した場合に、その隣の`sessions`も読めるとは限りません。その補助情報が読めなくても正常動作することと、終了状態の表示が利用者の期待に合うことを確認します。これはソースから見つかった確認事項であり、不具合の実機再現はしていません。

検証時は、アクティビティモニタのSandbox列や`codesign`でも権限を確認できます。[Sandboxの確認方法](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)

```bash
# パスは、実際に検証する提出用アプリへ置き換える。
codesign --verify --strict --verbose=2 "/path/to/aI'm Thinking.app"
codesign -dvvv --entitlements - "/path/to/aI'm Thinking.app"
codesign -dvvv --entitlements - "/path/to/aI'm Thinking.app/Contents/MacOS/im-thinking-core"
lipo -archs "/path/to/aI'm Thinking.app/Contents/MacOS/AImThinking"
lipo -archs "/path/to/aI'm Thinking.app/Contents/MacOS/im-thinking-core"
```

## 6. プライバシー申告と公開ページを用意する

### 「データを収集しない」は、最終バイナリの挙動で判断する

現在の実装は、選択されたローカルセッションを読み、活動状態を処理する構成です。調査範囲で、セッション内容をサーバーへ送る通信処理は見つかりませんでした。Privacy Manifestもtrackingなし、収集データなしと宣言しています。

AppleのApp Privacyでいう「収集」は、開発者や第三者がアクセスできる形でデータを端末外へ送信することを基準にしています。最終ビルドもローカル処理だけなら、App Store Connectの「データを収集しない」が有力です。ローカルファイルを読むことと、ストアの収集データ申告は区別します。解析SDK、クラッシュ送信、外部通信を追加した場合は再評価します。[App Privacyの定義](https://developer.apple.com/app-store/app-privacy-details/)

診断ログにはアプリ／OS情報と活動状態などがあります。利用者が明示的にコピーして問い合わせに添える場合の扱いも、プライバシーポリシーに書きます。「一切データを扱わない」といった、ローカル処理まで否定する説明は避けます。

### プライバシーポリシーURLは、収集なしでも必要

App Store ConnectはすべてのアプリにプライバシーポリシーURLを要求しています。ログインなしで読める公開ページを用意します。[URLの必須条件](https://developer.apple.com/help/app-store-connect/reference/app-privacy/)

このアプリのポリシーには、ローカルのセッションフォルダを読む目的、読み取り専用であること、端末内で処理すること、設定とbookmarkの保存、Revokeでアクセスを取り消す方法、問い合わせ窓口を記載します。アプリ内からもポリシーへアクセスできる導線を用意します。サポートページには、対応OS、対応エージェント、フォルダ選択手順、音が出ない場合の確認と連絡先を載せます。

### Privacy Manifestは同梱し、macOSへの適用範囲を正しく扱う

既存の`PrivacyInfo.xcprivacy`は`UserDefaults`の理由`CA92.1`を宣言しています。Xcodeターゲットにも追加し、Macアプリの`Contents/Resources/`に入っていることを確認します。[Manifestの配置](https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk?language=objc)

Appleの現行資料では、収集データの情報は全プラットフォームを対象とする一方、Required Reason APIの申告対象として列挙しているのはiOS、iPadOS、tvOS、visionOS、watchOSです。macOSアプリに、iOSと同じ理由申告義務があるとは断定しません。[適用対象の公式説明](https://developer.apple.com/documentation/BundleResources/privacy-manifest-files?changes=_9__2)

参考として、Rustはファイルの更新・作成時刻を使います。理由の記載を任意に整える場合、利用者が許可したファイルのメタデータには`3B52.1`が候補です。タイマー等の低レベルAPIも含め、最終成果物を調べて実際の用途と一致させます。これはmacOS版の確定した提出阻害要因として挙げるものではありません。[理由の一覧](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)

## 7. ストア掲載情報は、フォルダ選択が必要なことまで説明する

| 準備するもの | 記載・作成方針 |
|---|---|
| アプリ名 | aI'm Thinkingを候補に、名称の空きと権利を確認 |
| 説明文 | AIコーディングツールの活動に合わせて打鍵音を鳴らすメニューバーアプリであることを説明 |
| 動作条件 | macOS 26以降、対応CPU、Claude Code / Codexのローカルセッションが必要なことを明記 |
| 設定手順 | App Store版では利用者がセッションフォルダを選択することを明記 |
| カテゴリ | Utilitiesを第一候補。ストアとアプリ内のカテゴリを整合させる |
| キーワード | 自アプリの機能を表す語を選ぶ。別アプリ・会社名を検索用に詰め込まない |
| Support URL | 公開サポートページと連絡先 |
| Privacy Policy URL | 公開プライバシーポリシー |
| Copyright | 権利者と年。アプリ側の情報とも整合させる |
| 年齢制限 | App Store Connectの現行質問へ実際の機能に沿って回答 |
| Content Rights | 音源・アイコン等の利用権を確認 |
| 価格・配信地域 | 無料／有料、公開対象の国・地域を決定 |
| App Review Information | 連絡先、再現手順、必要な添付資料 |

説明文は最大4,000文字、Keywordsは最大100 bytesです。日本語キーワードでは文字数とバイト数が異なります。[掲載情報の仕様](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information)

音源は[CREDITS.md](../app/Resources/Sounds/CREDITS.md)にCC0として記録されています。提出前に入手元と実際の同梱素材を照合し、追加した画像・音源も確認します。Claude CodeやCodexは対応対象の説明に使い、公式アプリや提携製品と誤認させる表現を避けます。

### Macのスクリーンショットを作る

Mac用には16:10のスクリーンショットが必要です。Appleが受け付けるサイズは、1280×800、1440×900、2560×1600、2880×1800です。[スクリーンショット仕様](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications)

このアプリでは、メニューバーのポップオーバーを開いた状態、フォルダ許可の画面、活動状態と音量・速度調整の画面を候補にします。必要な掲載枚数・形式はアップロード画面でも確認してください。実際の提出用ビルドを撮影し、個人のプロンプト、ソースコード、ユーザー名、パスを写さないようにします。

音が主機能なので、短い動作動画を審査の補足として添えると理解を助けます。ストアに載せるApp Preview動画は任意です。動画だけで操作確認を代替せず、アプリ自体を操作できる手順も提供します。

## 8. 審査担当者が第三者のアカウントなしで確認できるようにする

このアプリは自前のログインを持ちませんが、通常の動作確認にはClaude CodeかCodexの活動が必要です。審査担当者に第三者サービスへの契約や認証を求めると、確認が止まる可能性があります。これは本アプリの審査上の主要な不確実性です。

提案は、個人情報を含まないサンプルセッションを使い、実際の監視経路を再現できる方法を用意することです。選択したサンプルフォルダに、新しいJSONLイベントを時間差で追加し、活動表示・音・停止・Revokeを確認できるようにします。現在の監視は、監視開始時点のファイル末尾から、その後の追記を読みます。既存のサンプルファイルを置くだけでは音が出ない可能性があります。

サンプルフォルダの名前にも制約があります。アプリは選択フォルダの名前を確認し、Claude Code用は`projects`、Codex用は`sessions`でなければ拒否します。初回ウィンドウはフォルダを1つ許可するまで閉じられないため、名前が違うと審査担当者は先へ進めません。たとえばClaude Code用なら`<任意>/projects`に、`-`で始まるプロジェクトフォルダとJSONLを置きます。

実装方式は、通常の利用者にも説明可能な動作確認機能や、添付サンプルと具体的な再生手順から選びます。審査時だけ隠し機能を有効にする構成は避け、実際に提出するビルドで再現手順を通します。Appleの「ログイン用デモアカウントの代わりに組み込みデモを使う」規定には事前承認の条件があるため、それと本アプリのサンプル監視を混同しないようにします。[審査時のアプリ完成度](https://developer.apple.com/app-store/review/guidelines/#app-completeness)

### Review Notesに入れる英語説明の下書き

以下の説明を出発点に、最終ビルドで確認した内容へ修正します。サンプルのファイル名、再生操作、期待する状態変化、所要時間を追記するまでは提出用として完成していません。

```text
aI'm Thinking is a macOS menu bar utility that plays optional typing
sounds while supported AI coding tools are active.

On first launch a welcome window opens. Click "Choose Folder…" for
Claude Code (a folder named "projects") or Codex (a folder named
"sessions") and click Done. The window stays open until at least one
folder is allowed. Access is read-only and is granted through the
standard macOS folder picker.

The app has no Dock icon. Afterwards, click the keycap icon in the macOS
menu bar to open it; folder access can be changed there under Agent
Folder Access. The app stores a security-scoped
bookmark and allows the user to revoke access with the Revoke button.

Session data is processed locally. The app does not upload prompts,
responses, source code, or session files. It does not install plugins,
modify agent configuration, or request administrator privileges.

The bundled Rust helper runs as a child process of the app and inherits
its sandbox. It stops when the app quits. Start at Login is controlled
by the user.
```

再現手順には、アプリ起動、メニューバーのアイコン位置、フォルダ選択、サンプルの再生、音と状態の変化、ミュート、Revoke、終了を順に記載します。Appleへ提供するファイルやURLは、審査環境から取得可能であることを確認します。

## 9. Archiveをアップロードし、TestFlightで確認する

Xcodeターゲットが完成したら、次の順に進めます。

1. 提出用SchemeとMacの実行先を選び、「Product → Archive」を実行する。
2. Organizerで、アプリのArchiveとして認識されていることを確認する。Generic Archiveになった場合は、補助ツールの単独インストール設定等を調べる。
3. Bundle ID、バージョン、ビルド番号、リソース、Privacy Manifest、本体と補助プロセスの署名を確認する。
4. Organizerの検証・配布フローを進める。画面名はXcodeの版で変わるが、配布先は「App Store Connect」を選ぶ。
5. 自動署名で選ばれた証明書、プロファイル、entitlementsを確認し、アップロードする。
6. App Store Connectでビルドの処理完了を待ち、エラーや警告を確認する。
7. 暗号化・輸出コンプライアンスの質問に回答する。
8. TestFlightの内部テスターへ配布し、実際にインストールしたアプリでSandboxと再現手順を確認する。

Xcodeは配布時に必要な署名資材を扱います。macOSアプリにはSandboxとCopyright情報等の準備も必要です。[配布の準備](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution)

**「TestFlight Internal Only」を選ぶと、そのビルドをApp Store審査へ提出できません。** 内部テスト後に同じビルドを審査へ使う予定なら、通常の「App Store Connect」経路でアップロードします。[配布方式の違い](https://developer.apple.com/tutorials/develop-in-swift/test-your-beta-app)

TestFlightはMacにも対応しています。内部テスターは最大100人、外部テスターは最大10,000人で、外部テストには別途Beta App Reviewが必要になる場合があります。TestFlight自体は本番審査の必須前提ではありませんが、このアプリでは配布後のSandbox動作を確認するために内部テストを勧めます。[TestFlight概要](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/)

### 暗号化の回答は、通信がないことだけで決めない

依存ライブラリと最終バイナリを含めて暗号化の利用を確認します。該当しない、または適切な免除に当たることを確認した場合は、`ITSAppUsesNonExemptEncryption = NO`をInfo.plistに設定する方法があります。今回の調査では輸出分類を確定していません。[輸出コンプライアンスの手順](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/)

## 10. App Store Connectで審査へ送る

1. 対象アプリのmacOSバージョンを開く。
2. 説明文、キーワード、スクリーンショット、サポートURL等を保存する。
3. App Informationのカテゴリ、年齢制限、コンテンツ権利等を回答する。
4. App Privacyを設定し、価格、税カテゴリ、配信地域を指定する。
5. Build欄で、テストした正しいビルドを選択する。
6. App Review Informationに担当者の連絡先と完成した再現手順を入れる。自前のログインがないことに合わせてサインイン要否を回答する。
7. 公開方式を選ぶ。初回は、承認後に掲載内容を確認して公開できる「Manually release this version」を勧める。
8. 「Add for Review」で提出内容に追加する。
9. Draft SubmissionsまたはApp Reviewで内容を確認し、「Submit for Review」を押す。

「Add for Review」だけではAppleへ送信されません。「Ready for Review」は提出準備の状態です。最後の「Submit for Review」まで必要です。提出にはAccount Holder、Admin、App Managerのいずれかの役割が必要です。[審査提出の公式手順](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-app/)

EUのデジタルサービス法（DSA）に基づき、事業者（Trader）に該当するかどうかを申告します。EUで配信しない場合も、この申告は必要です。TraderとしてEUで配信する場合、住所・電話番号・メールアドレスの確認とストアでの表示があります。無料アプリかどうかだけではTrader該当性は決まりません。[DSA申告の手順](https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements)

## 11. 審査後は、指摘への回答と公開を分けて進める

提出後はWaiting for Review、In Review等の状態を確認します。却下や質問が来たら、App Review欄で理由を読み、必要な操作説明、画面、ファイルを添えて回答します。メタデータだけの指摘なら、修正後に同じビルドを再提出できる場合があります。バイナリの変更が必要なら、ビルド番号を上げて再アップロードします。[審査メッセージへの返信](https://developer.apple.com/jp/help/app-store-connect/manage-submissions-to-app-review/reply-to-app-review-messages)

手動公開を選んでいれば、承認後はPending Developer Releaseとなり、「Release This Version」で公開します。公開操作からストアへの反映には最大24時間かかることがあります。これは審査所要時間の保証ではありません。[公開方式と手動公開](https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/select-an-app-store-version-release-option/)

<a id="submission-checklist"></a>

## 12. 提出までの作業チェックリスト

更新日：2026年10月3日。現在は基本実装と調査が済み、提出用ビルドの準備に進む段階です。

`[x]`は完了を確認できた作業、`[ ]`は未完了または未確認の作業です。実装の存在と実機での動作確認は別々に記録します。各項目が完了したらチェックを付け、必要に応じて確認日やビルド番号を追記してください。有料販売やIntel対応などの条件付き項目が不要なら、チェックを付けずに「対象外」と理由を記録します。

### 0. 基本実装と調査

- [x] Apple公式資料とリポジトリを照合し、提出手順を調査する
- [x] `direct`と`app-store`の配布モードを用意する
- [x] 本体用のSandbox権限設定を用意する
- [x] Rust補助プロセス用のSandbox継承権限設定を用意する
- [x] 標準パネルによる読み取り専用フォルダ選択を実装する
- [x] bookmarkの保存・復元とRevokeを実装する
- [x] Privacy Manifestを用意する
- [x] CIにApp Store向けsmokeビルドと権限検査を定義する
- [x] 英語のReview Notesの説明文を下書きする
- [x] 初回ウィンドウでフォルダ許可を案内する
- [x] 別Agentや親フォルダの選択を拒否する

ここでのチェックは、実装や設定が存在することを確認した記録です。提出用の署名・実機動作・CIの実行成功は、後続の項目で確認します。

### 1. アカウントと配布方針を確定する（詳細：第3章）

- [ ] Apple Developer Programの加入状況と有効期限を確認する
- [ ] Xcodeで提出に使うDeveloper Teamを選択できることを確認する
- [ ] App Store Connectの必要な契約に同意し、提出できる状態にする
- [ ] 本番Bundle IDを確定し、Developerアカウントに登録する
- [ ] DMG版と同じBundle IDを使うか決定する
- [ ] 対応CPUを決定する（Apple Siliconのみ／Intelも対応）
- [ ] 初回バージョンとビルド番号を決める
- [ ] 無料／有料、配信地域、手動／自動公開を決める
- [ ] 有料販売・アプリ内課金をする場合：Paid Apps Agreement、銀行・税務情報を整える
- [ ] App Store ConnectにmacOSアプリレコードを作成する

### 2. Xcodeの提出用ビルドを作る（詳細：第4章）

- [ ] macOS Appターゲットを追加し、既存Swiftソースを参照する
- [ ] 本番Bundle ID、Team、Version、Build、最低OS、対応CPUを設定する
- [ ] 自動署名と本体用Sandbox権限を設定する
- [ ] Info.plistに`AImThinkingDistribution = app-store`と`LSUIElement = true`を設定する
- [ ] Copyrightとアプリカテゴリを設定する
- [ ] アイコン、音源、Privacy Manifestを同梱する
- [ ] 音源の`Contents/Resources/Sounds/kc1000/*.wav`の階層を維持する
- [ ] RustのRelease実行ファイルをビルドし、`Contents/MacOS/im-thinking-core`に埋め込む
- [ ] Rust補助プロセスの署名とSandbox継承権限を設定する
- [ ] 本体とRustの対応CPUを一致させる
- [ ] 共有Schemeを用意し、ArchiveがRelease構成を使うようにする
- [ ] Organizerで提出用のアプリArchiveとして認識されることを確認する

### 3. Sandboxを実機で検証する（詳細：第5章）

- [ ] 権限なしの初回起動で初回ウィンドウが開き、フォルダを許可するまで閉じられない
- [ ] 別Agentや親フォルダを選ぶとエラーが表示され、保存されない
- [ ] 標準パネルから実際の隠しセッションフォルダを選択できる
- [ ] Claude Codeの選択フォルダで活動表示と打鍵音が動く
- [ ] Codexの選択フォルダで活動表示と打鍵音が動く
- [ ] 再起動後にbookmarkからアクセスを復元できる
- [ ] フォルダの移動・削除後もクラッシュせず復旧できる
- [ ] Revokeで監視と音が止まり、再起動後も権限が復活しない
- [ ] 許可していない隣接フォルダをRustが読めない
- [ ] Claudeの隣接する`sessions`を読めなくても正常に動く
- [ ] セッションファイルの新規作成・追記・置換を検出できる
- [ ] アプリ終了後にRust補助プロセスが残らない
- [ ] Start at Loginの有効化・解除が利用者の操作で行える
- [ ] ミュート、音量、打鍵速度の調整が動く
- [ ] 本体と補助プロセスの署名・entitlementsを確認する
- [ ] 関連CIが成功していることを確認し、実行結果を記録する

### 4. 審査担当者向けの再現環境を用意する（詳細：第8章）

- [ ] 個人情報を含まないサンプルセッションを用意する
- [ ] 監視開始後にJSONLを追記し、主機能を再現できる方法を用意する
- [ ] Claude Code／Codexの契約・認証なしで再現手順を通す
- [ ] 起動、フォルダ選択、活動表示、音、ミュート、Revoke、終了の手順を書く
- [ ] Review Notesの英語説明を最終実装に合わせて確定する
- [ ] サンプルの名前、再生操作、期待する状態変化、所要時間をReview Notesに追記する
- [ ] 添付ファイルや補足動画を、審査担当者が取得できる形で用意する

### 5. 公開ページとストア掲載情報を用意する（詳細：第6・7章）

- [ ] サポートページと問い合わせ窓口を公開する
- [ ] プライバシーポリシーを公開する
- [ ] アプリ内からプライバシーポリシーを開けるようにする
- [ ] 最終ビルドの挙動を確認し、App Privacyの回答を確定する
- [ ] 音源・アイコン・スクリーンショット等の利用権を確認する
- [ ] アプリ名、説明文、キーワード、カテゴリ、Copyrightを準備する
- [ ] 最低OS、対応CPU、対応エージェント、フォルダ選択が必要なことを説明文に記載する
- [ ] 提出用ビルドのMac用スクリーンショットを作成する
- [ ] スクリーンショットとサンプルに実データや個人情報がないことを確認する
- [ ] App Store Connectに掲載情報と公開URLを入力する
- [ ] 年齢制限、コンテンツ権利、価格、税カテゴリ、配信地域を設定する
- [ ] DSAのTrader statusを申告し、必要な連絡先確認を済ませる

### 6. アップロードとTestFlight確認を行う（詳細：第9章）

- [ ] 提出用Archiveを作成する
- [ ] Archive内の本体・Rustの署名、権限、CPU、リソースを確認する
- [ ] Organizerの検証を通し、指摘を解消する
- [ ] 通常の「App Store Connect」経路でアップロードする
- [ ] App Store Connectでビルド処理が完了し、エラーがないことを確認する
- [ ] 暗号化の利用を確認し、輸出コンプライアンスの質問に回答する
- [ ] TestFlightの内部テスターへ配布する
- [ ] TestFlightからインストールしたアプリでSandbox動作を確認する
- [ ] 同じ配布ビルドで審査用の再現手順を通す

内部テストは本アプリで推奨する確認作業です。「TestFlight Internal Only」でアップロードしたビルドは、本番審査に使えません。

### 7. 審査へ提出する（詳細：第10章）

- [ ] macOSの提出バージョンに、テストした正しいビルドを選択する
- [ ] 必須の掲載情報・プライバシー・コンプライアンス回答が揃っていることを確認する
- [ ] App Review Informationに連絡先と再現手順を入力する
- [ ] 公開サポート／プライバシーURLへアクセスできることを確認する
- [ ] 手動／自動公開の設定を確認する
- [ ] 「Add for Review」で提出内容に追加する
- [ ] Draft SubmissionsまたはApp Reviewで提出内容を最終確認する
- [ ] 「Submit for Review」で審査へ送信する
- [ ] Waiting for Review等、送信後のステータスを確認する

### 8. 審査対応と公開を行う（詳細：第11章）

- [ ] 審査結果を確認し、質問・指摘がある場合は回答や修正を行う
- [ ] 必要な場合はビルド番号を上げ、再アップロード・再提出する
- [ ] 審査承認を確認する
- [ ] 手動公開の場合：「Release This Version」で公開する
- [ ] ストアの掲載内容とダウンロードを確認する
- [ ] App Storeからインストールしたアプリの動作を確認する

## 調査の範囲と未確認事項

調査はAppleの公式ヘルプ・開発者文書・審査ガイドラインと、現在のソース、ビルドスクリプト、CI設定の読み取りで行いました。XcodeとSwiftのローカルバージョンも確認しています。

Developerアカウントの加入・契約・証明書・登録済みID、App Store Connectのアプリ作成状況、最新CI結果、署名済みアプリのSandbox実機動作は確認していません。提出用ターゲットの新規作成、アプリの起動試験、Archive、アップロードは未実施です。技術設計がAppleの構成例に沿っていることは確認できますが、審査承認までは保証できません。

次の具体的な作業は、既存SwiftソースとRustを使ったXcode提出用ターゲットの追加です。その成果物でSandboxの実機確認を行ってから、ストアの申告内容とReview Notesを確定する順序が適しています。
