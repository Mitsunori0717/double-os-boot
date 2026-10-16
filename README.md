# Edge Box 同時稼働システム

Windows 11 と Edge Box (FANUC FIELD system Basic Package) を、**1 台の PC で同時に動かす**ための一式です。
CPU コアを Windows 用と Edge Box 用に**完全分離**し、左モニターに Edge Box のコンソールを全画面で固定します。

```
Windows 11 (ネイティブ動作 = 業務はフルスピード)
 ├─ 左モニター : Edge Box のコンソール (全画面固定)
 ├─ 右モニター : 通常の Windows デスクトップ
 └─ Hyper-V
      └─ Edge Box : メーカー製ディスクを無改造のまま起動 (コピー・変換なし)
```

## 構成

| フォルダ | 内容 |
|---|---|
| `windows-host/` | Edge Box の作成・起動・画面表示・自動サインイン・シャットダウン |
| `windows-cpu-partition/` | CPU コアの完全分離、割り当て画面、リアルタイム監視 |
| `installer/` | 新しい PC へ導入するための EXE を作るしくみ |
| `setup/` | 実環境を判定して進める一括・番号別セットアップ、ログと再実行の案内 |

## 新しい PC への導入

`installer\build-installer.cmd` をダブルクリックすると `EdgeBox-Setup.exe` ができます。
これを新しい PC へ持っていって実行すると、一式を配置して一括セットアップへ進みます。
くわしくは [installer/README.md](installer/README.md)。

ZIP を展開して使う場合はルートの `setup-all.cmd` を実行してください。
途中まで設定済みでも、Hyper-V・VM・自動表示・自動サインイン・CPU 分離などを再確認して必要な設定だけを行います。
失敗時は `setup/logs` の `summary.txt` に原因・対処法・再実行する番号別バッチを表示します。
確認だけなら `setup/check-status.cmd`。詳しくは [setup/README.md](setup/README.md)。
従来の手動手順は [windows-host/SETUP-STEPS.md](windows-host/SETUP-STEPS.md) に残しています。

## 日常の操作

デスクトップのアイコンだけで完結します。
アイコンが無い PC では、このフォルダの `start.cmd` をダブルクリックしても同じ動き (Edge Box 起動) になります。

| アイコン | 動き |
|---|---|
| Edge Box 起動 | Edge Box を起動して左画面に全画面表示 |
| Edge Box 画面 | 左画面にコンソールを出し直す |
| Edge Box 再起動 | 正常終了 → 起動 → 画面表示 |
| 全部シャットダウン | Edge Box を正しく終了 → Windows もシャットダウン (選択可) |
| 設定 | 自動サインインの設定 |
| CPU割り当て | CPU コアの分離、リアルタイム監視 |

| キー操作 | 動き |
|---|---|
| Alt+F11 | 左画面の固定を解除 / 再固定 |
| Ctrl+Alt+K 長押し | 左画面のコンソールを収納 ⇔ 全画面に戻す |
| ESC 1 秒長押し | 全画面の解除 |

## 不具合時の切り分け

3 つの切替で、Windows か Edge Box かハイパーバイザーかを確定できます。
どれも可逆で、Edge Box のデータには触れません。

| 切替 | 操作 | 分かること |
|---|---|---|
| Edge Box 単独起動 | 再起動 → F8 → Edge Box のディスクを選択 | 仮想化を外した素の Edge Box (同一ディスクなので完全比較) |
| Hyper-V 一時停止 | `bcdedit /set hypervisorlaunchtype off` → 再起動 (戻すのは `auto`) | 分離層ゼロの素の Windows |
| 管理画面へ直接 | ブラウザで Edge Box の IP | アプリを介さない到達確認 |

## 注意

- Edge Box の起動画面で **Ctrl キーを押しっぱなしにしない** (工場出荷リセットが選ばれます)
- Edge Box の稼働中に、そのディスクを Windows からオンラインに戻さない (同時アクセスによる破損防止)
- Edge Box を仮想環境で動かすことはメーカーのサポート範囲外です。ディスクは無改造のため、
  問題があればネイティブ起動の運用に戻せます
