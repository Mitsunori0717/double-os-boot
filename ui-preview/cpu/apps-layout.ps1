
    $sel = Get-Selection
    $work = New-Object System.Collections.ArrayList
    foreach ($a in $script:Apps) {
        [void]$work.Add([pscustomobject]@{
            Name = [string]$a.Name; Exe = [string]$a.Exe; Match = [string]$a.Match
            Lps = @([int[]]$a.Lps); Priority = $(if ($a.Priority) { [string]$a.Priority } else { "通常" })
        })
    }

    $d = New-Object System.Windows.Forms.Form
    Initialize-UiForm $d
    $d.Text = "アプリの割り当て"
    $d.ClientSize = New-Object System.Drawing.Size(880, 560)
    $d.StartPosition = "CenterParent"
    $d.FormBorderStyle = "FixedDialog"
    $d.MaximizeBox = $false
    $d.MinimizeBox = $false
    $d.ShowInTaskbar = $false

    $hint = New-Lbl "登録したアプリは、起動のたびに指定したコアへ自動で固定されます (1 分ごとに確認)。" 16 14 848
    $hint.ForeColor = [CoreUi.Theme]::SubText
    $d.Controls.Add($hint)

    $lvFrame = New-Object CoreUi.Card
    $lvFrame.HeaderHeight = 1
    $lvFrame.Padding = New-Object System.Windows.Forms.Padding(1)
    $lvFrame.Location = New-Object System.Drawing.Point(16, 42)
    $lvFrame.Size = New-Object System.Drawing.Size(848, 324)
    $lv = New-Object CoreUi.DarkListView
    $lv.Dock = "Fill"
    $lv.View = "Details"
    $lv.FullRowSelect = $true
    $lv.MultiSelect = $false
    $lv.GridLines = $false
    [void]$lv.Columns.Add("アプリ名", 190)
    [void]$lv.Columns.Add("実行ファイル", 380)
    [void]$lv.Columns.Add("割り当てコア", 170)
    [void]$lv.Columns.Add("優先度", 90)
    $lvFrame.Controls.Add($lv)
    $d.Controls.Add($lvFrame)

    function Sync-AppList {
        $lv.BeginUpdate()
        $lv.Items.Clear()
        foreach ($a in $work) {
            $it = New-Object System.Windows.Forms.ListViewItem([string]$a.Name)
            [void]$it.SubItems.Add($(if ($a.Exe) { [string]$a.Exe } else { "(名前で照合: " + $a.Match + ")" }))
            [void]$it.SubItems.Add((ConvertTo-LpRangeText @([int[]]$a.Lps)))
            [void]$it.SubItems.Add([string]$a.Priority)
            [void]$lv.Items.Add($it)
        }
        $lv.EndUpdate()
    }

    function Get-SelectedApp {
        if ($lv.SelectedIndices.Count -eq 0) { return $null }
        return $work[$lv.SelectedIndices[0]]
    }

    function Add-App([string]$Name, [string]$Exe, [string]$Match) {
        $defaultLps = @($sel.HostLps)
        if ($defaultLps.Count -eq 0) { $defaultLps = @(0) }
        [void]$work.Add([pscustomobject]@{
            Name = $Name; Exe = $Exe; Match = $Match; Lps = $defaultLps; Priority = "通常"
        })
        Sync-AppList
        $lv.Items[$work.Count - 1].Selected = $true
    }

    $bx = 14
    $btnInst = New-UiButton "インストール済みから追加..." 216
    $btnInst.Location = New-Object System.Drawing.Point($bx, 376)
    $btnInst.Add_Click({
        $e = Show-InstalledAppPicker
        if ($e) {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($e.Exe)
            Add-App $e.Name $e.Exe $base
        }
    })
    $bx += 222

    $btnFile = New-UiButton "ファイルから追加..." 160
    $btnFile.Location = New-Object System.Drawing.Point($bx, 376)
    $btnFile.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "実行ファイル (*.exe)|*.exe|すべてのファイル (*.*)|*.*"
        $ofd.Title = "登録するアプリの実行ファイルを選んでください"
        if ($ofd.ShowDialog() -eq "OK") {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($ofd.FileName)
            Add-App $base $ofd.FileName $base
        }
    })
    $bx += 166

    $btnRun = New-UiButton "実行中から追加..." 160
    $btnRun.Location = New-Object System.Drawing.Point($bx, 376)
    $btnRun.Add_Click({
        $e = Show-ProcessPicker
        if ($e) { Add-App $e.Name $(if ($e.Exe) { $e.Exe } else { "" }) $e.Name }
    })
    $bx += 166

    $btnCores = New-UiButton "コアを編集..." 140 "Default" "edit"
    $btnCores.Location = New-Object System.Drawing.Point($bx, 376)
    $btnCores.Add_Click({
        $a = Get-SelectedApp
        if (-not $a) { Show-Info "一覧からアプリを選んでください。" "Warning"; return }
        $lps = Show-CoreChooser @([int[]]$a.Lps) ("コアの選択 - " + $a.Name) @($sel.GuestLps)
        if ($lps) { $a.Lps = @($lps); Sync-AppList }
    })
    $bx += 146

    $btnDel = New-UiButton "削除" 96 "Danger"
    $btnDel.Location = New-Object System.Drawing.Point($bx, 376)
    $btnDel.Add_Click({
        if ($lv.SelectedIndices.Count -eq 0) { Show-Info "一覧からアプリを選んでください。" "Warning"; return }
        $work.RemoveAt($lv.SelectedIndices[0])
        Sync-AppList
    })
    $d.Controls.AddRange(@($btnInst, $btnFile, $btnRun, $btnCores, $btnDel))

    $d.Controls.Add((New-Lbl "選んだアプリの優先度" 16 428))
    $cmbPri = New-Object CoreUi.DarkComboBox
    $cmbPri.Location = New-Object System.Drawing.Point(176, 422)
    $cmbPri.Size = New-Object System.Drawing.Size(130, 30)
    $cmbPri.DropDownStyle = "DropDownList"
    [void]$cmbPri.Items.AddRange(@("通常", "高", "低"))
    $cmbPri.SelectedIndex = 0
    $cmbPri.Add_SelectedIndexChanged({
        $a = Get-SelectedApp
        if ($a -and $a.Priority -ne [string]$cmbPri.SelectedItem) {
            $a.Priority = [string]$cmbPri.SelectedItem
            Sync-AppList
        }
    })
    $d.Controls.Add($cmbPri)
    $lv.Add_SelectedIndexChanged({
        $a = Get-SelectedApp
        if ($a) { $cmbPri.SelectedItem = [string]$a.Priority }
    })

    $note = New-Lbl "『高』は取り合いになったときに優先されます。Edge Box 用のコアは避けてください (Edge Box と取り合いになります)。" 16 466 848
    $note.ForeColor = [CoreUi.Theme]::SubText
    $note.Font = [CoreUi.Theme]::UiSmall
    $d.Controls.Add($note)

    $ok = New-UiButton "保存して適用" 140 "Primary" "check"
    $ok.DialogResult = "OK"
    $ok.Location = New-Object System.Drawing.Point(606, 508)
    $ng = New-UiButton "キャンセル" 110
    $ng.DialogResult = "Cancel"
    $ng.Location = New-Object System.Drawing.Point(754, 508)
    $d.Controls.AddRange(@($ok, $ng))
    $d.CancelButton = $ng

    Sync-AppList
