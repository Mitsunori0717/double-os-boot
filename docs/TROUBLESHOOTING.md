# トラブルシューティング

## 大原則: まず層を確定する

同時起動モードで問題が出たら、**GRUB から同じ Windows をネイティブ起動して再現確認** してください。

- ネイティブでも再現する → Windows / ソフト自体の問題。本書の範囲外 (通常の Windows 対処へ)
- ネイティブでは再現しない → 調停層 (KVM/VFIO) の問題。本書の該当節へ

---

## セットアップ段階

### 00-check-hardware.sh で「IOMMU が無効」
1. UEFI 設定で Intel VT-d / AMD IOMMU を有効化
2. `01-configure-iommu.sh` を実行して再起動
3. 確認: `sudo dmesg | grep -i -e DMAR -e IOMMU`

### GPU の IOMMU グループに他デバイスが同居している
パススルーはグループ単位です。同居がある場合:
- GPU を挿す PCIe スロットを変える (CPU 直結スロットは分離されていることが多い)
- マザーボードの UEFI 更新
- 最終手段: ACS オーバーライドパッチ (分離保証が弱まるため非推奨。使うなら自己責任で
  `pcie_acs_override=downstream,multifunction` をカーネルパラメータに追加)

### 01 実行・再起動後、GPU が vfio-pci に乗っていない
```bash
lspci -nnk -d <vendor:device>
```
`Kernel driver in use:` が `nvidia`/`amdgpu` のまま → initramfs 更新漏れの可能性:
```bash
sudo update-initramfs -u -k all && sudo reboot
```

### 01 実行後、Linux の画面が映らなくなった
Linux 表示用 GPU の ID を誤って VFIO に渡した可能性があります。
別マシンから SSH するか、GRUB メニューで `e` を押し、起動行の `vfio-pci.ids=...` を
削除して一時起動 → `sudo bash baremetal/01-configure-iommu.sh --revert` で復旧できます。

## Windows 起動段階

### 起動直後に UEFI シェルや Boot Manager で止まる
OVMF が Windows Boot Manager を自動検出できなかった場合:
1. 画面の Boot Manager でディスクエントリを選択して起動
2. 恒久化するには Windows 起動後に一度シャットダウンし、再度起動 (NVRAM に記憶される)

それでも見つからない場合、Windows の EFI パーティションが **別のディスク** にある可能性が
あります (Windows インストール時に他ディスクの EFI に相乗りした場合)。
`sudo fdisk -l` で EFI パーティションの場所を確認してください。
その場合は EFI があるディスクも一緒に渡すか、Windows ディスク内に EFI を再構築します
(ネイティブ Windows の回復環境で `bcdboot C:\Windows /s <EFIドライブ>:`)。

### Windows 起動中にブルースクリーン `INACCESSIBLE_BOOT_DEVICE`
ネイティブ時と同時起動時でストレージコントローラが変わることが原因です。
02 のスクリプトは互換性の高い SATA バスで渡しているため通常発生しませんが、
発生した場合はネイティブ起動 → `bcdedit /set {current} safeboot minimal` で一度
セーフモード起動させると標準ドライバが読み込まれ、以後通常起動できます
(戻し: `bcdedit /deletevalue {current} safeboot`)。

### 画面に何も映らない (VM は起動している)
- モニター1 が **Windows 専有 GPU の出力端子** に接続されているか確認
- モニターの入力ソース切替を確認
- NVIDIA の一部カードは UEFI GOP 非対応 ROM だと初期画面が出ないことがあります。
  Windows が起動しきるとドライバ初期化で映る場合もあるため 1〜2 分待つ
- `sudo virsh console windows` は使えません (シリアル未設定)。状態は `virsh list` で確認

### NVIDIA ドライバがエラー Code 43 を出す (古いドライバのみ)
ドライバ 465 以降では対策不要です。古いドライバを使う場合:
```bash
sudo virt-xml windows --edit --features hyperv.vendor_id.state=on,hyperv.vendor_id.value=1234567890ab,kvm.hidden.state=on
```

### Windows ライセンスが「認証されていません」になる
ハードウェア構成が変わって見えるためです。Microsoft アカウントに紐付いた
デジタルライセンスなら: 設定 → システム → ライセンス認証 →
「このデバイス上のハードウェアを最近変更しました」から再認証できます。
ネイティブ/同時起動それぞれで一度ずつ認証すれば、以後は両方で維持されます。

## 運用段階

### 時計がずれる
`docs/DUAL-BOOT-SETUP.md` の時刻ズレ対策を参照。02 の定義は `offset=localtime` で
Windows 流のローカル時刻に合わせています。

### 同時起動中のパフォーマンスが悪い
- HugePages が確保できているか: `grep Huge /proc/meminfo` (`HugePages_Total` が想定値か)
  断片化で確保に失敗している場合は Linux を再起動すると確保されます
- CPU ピンニングの確認: `sudo virsh vcpupin windows`
- ディスク: 02 は `cache=none,io=native` を設定済み。SATA より高速にしたい場合は
  virtio-blk ドライバ ([virtio-win](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win.iso)) を Windows に入れて `bus=virtio` に変更

### アンチチートのあるゲームが起動しない
仕様です (hypervisor 検出)。そのゲームはネイティブ起動側でプレイしてください。
両モードが同じ C: を使うため、ゲームのインストールやセーブはどちらでも共通です。

### Samba 共有に Windows から繋がらない
```bash
sudo systemctl status smbd
ip -4 addr show virbr0        # 同時起動モードでは virbr0 側の IP を使う
sudo smbstatus
```
Windows 側からは `ping <LinuxのIP>` → `\\<LinuxのIP>\shared`。
資格情報は 04 で `smbpasswd` に設定したもの (Linux ユーザー名 + Samba パスワード)。

### キーボード切替 (左右 Ctrl) が効かない
- 05 実行後に Windows を再起動したか
- `sudo virsh dumpxml windows | grep -A3 evdev` で定義を確認
- デバイスパスが変わった可能性 (USB 差し替え時): 05 を再実行

### 誤って Linux 側から C: をマウントしてしまった
即座に Windows を通常シャットダウンし、`sudo umount` してください。
両側から同時書き込みした場合は、ネイティブ起動の Windows で `chkdsk C: /f` を実行して
NTFS の整合性を確認してください。03 スクリプトは起動時にマウント済みなら拒否する
保護を入れていますが、**起動後の手動マウントは防げません**。運用ルールとして徹底してください。
