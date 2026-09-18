# 新しい PC への導入 (EXE を作る / 使う)

## 1. EXE を作る (作業用 PC で 1 回)

`build-installer.cmd` を**ダブルクリック**するだけです。

```
installer\EdgeBox-Setup.exe   ← これができます
```

Windows に標準で入っている IExpress を使うため、追加のソフトは要りません。
管理者権限も不要です (作るだけなので)。

中身は `windows-host` と `windows-cpu-partition` の一式です。
**この PC だけの設定や記録** (画面設定・CPU 割り当て・動作記録) は自動で除かれるため、
そのまま別の PC に持っていけます。

## 2. 新しい PC に導入する

`EdgeBox-Setup.exe` をコピーし、**右クリック →「管理者として実行」**。

やってくれること:

| | 内容 |
|---|---|
| 1 | 一式を `C:\EdgeBox` に配置 (既にあれば入れ替え。**設定と記録は残す**) |
| 2 | ダウンロードの印 (Mark of the Web) を外す |
| 3 | デスクトップのアイコンを作る (EdgeBox 起動 / 設定 / 全部シャットダウン / EdgeBox 再起動・画面 / CPU割り当て) |

この PC に固有の作業 (Hyper-V の有効化、EdgeBox の作成、CPU の分離) は行いません。
配置後、`C:\EdgeBox\windows-host\SETUP-STEPS.md` の①から順に進めてください。

> Hyper-V がまだ有効でない PC では、EdgeBox に関わるアイコンは作れません。
> Hyper-V を有効にして再起動したあと、**この EXE をもう一度実行**すれば作られます。

## 更新のときも同じ

すでに運用している PC でも、新しい `EdgeBox-Setup.exe` を実行すれば中身が入れ替わります。
画面設定・CPU 割り当て・自動サインインはそのまま残ります。

## 配置先を変える

```powershell
# EXE を展開せずに中の install.ps1 を直接使う場合
.\install.ps1 -InstallDir "D:\EdgeBox"
```
