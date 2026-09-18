# EdgeBox 同時稼働システム

Windows 11 と EdgeBox (FANUC FIELD system Basic Package) を、**1 台の PC で同時に動かす**ための一式です。
CPU コアを Windows 用と EdgeBox 用に**完全分離**し、左モニターに EdgeBox のコンソールを全画面で固定します。

```
Windows 11 (ネイティブ動作 = 業務はフルスピード)
 ├─ 左モニター : EdgeBox のコンソール (全画面固定)
 ├─ 右モニター : 通常の Windows デスクトップ
 └─ Hyper-V
      └─ EdgeBox : メーカー製ディスクを無改造のまま起動 (コピー・変換なし)
```

## 構成

| フォルダ | 内容 |
|---|---|
| `windows-host/` | EdgeBox の作成・起動・画面表示・自動サインイン・シャットダウン |
| `windows-cpu-partition/` | CPU コアの完全分離、割り当て画面、リアルタイム監視 |
| `installer/` | 新しい PC へ導入するための EXE を作るしくみ |

## 新しい PC への導入

`installer\build-installer.cmd` をダブルクリックすると `EdgeBox-Setup.exe` ができます。
これを新しい PC へ持っていって実行すれば、一式の配置とアイコン作成まで自動で終わります。
くわしくは [installer/README.md](installer/README.md)。

導入後の手順 (Hyper-V の有効化、EdgeBox の作成、CPU の分離) は
[windows-host/SETUP-STEPS.md](windows-host/SETUP-STEPS.md) の①から順に。

## 日常の操作

デスクトップのアイコンだけで完結します。

| アイコン | 動き |
|---|---|
| EdgeBox 起動 | EdgeBox を起動して左画面に全画面表示 |
| EdgeBox 画面 | 左画面にコンソールを出し直す |
| EdgeBox 再起動 | 正常終了 → 起動 → 画面表示 |
| 全部シャットダウン | EdgeBox を正しく終了 → Windows もシャットダウン (選択可) |
| 設定 | 自動サインインの設定 |
| CPU割り当て | CPU コアの分離、リアルタイム監視 |

| キー操作 | 動き |
|---|---|
| Alt+F11 | 左画面の固定を解除 / 再固定 |
| Ctrl+Alt+K 長押し | 左画面のコンソールを収納 ⇔ 全画面に戻す |
| ESC 1 秒長押し | 全画面の解除 |

## 不具合時の切り分け

3 つの切替で、Windows か EdgeBox かハイパーバイザーかを確定できます。
どれも可逆で、EdgeBox のデータには触れません。

| 切替 | 操作 | 分かること |
|---|---|---|
| EdgeBox 単独起動 | 再起動 → F8 → EdgeBox のディスクを選択 | 仮想化を外した素の EdgeBox (同一ディスクなので完全比較) |
| Hyper-V 一時停止 | `bcdedit /set hypervisorlaunchtype off` → 再起動 (戻すのは `auto`) | 分離層ゼロの素の Windows |
| 管理画面へ直接 | ブラウザで EdgeBox の IP | アプリを介さない到達確認 |

## 注意

- EdgeBox の起動画面で **Ctrl キーを押しっぱなしにしない** (工場出荷リセットが選ばれます)
- EdgeBox の稼働中に、そのディスクを Windows からオンラインに戻さない (同時アクセスによる破損防止)
- EdgeBox を仮想環境で動かすことはメーカーのサポート範囲外です。ディスクは無改造のため、
  問題があればネイティブ起動の運用に戻せます
