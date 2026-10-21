
    $d = New-Object System.Windows.Forms.Form
    Initialize-UiForm $d
    $d.Text = "インストール済みのアプリから選ぶ"
    $d.ClientSize = New-Object System.Drawing.Size(760, 530)
    $d.StartPosition = "CenterParent"
    $d.FormBorderStyle = "Sizable"
    $d.MinimizeBox = $false
    $d.ShowInTaskbar = $false
    $d.MinimumSize = New-Object System.Drawing.Size(520, 360)

    $hint = New-Lbl "登録したいアプリを選んでください。名前の一部を入力すると絞り込めます。" 16 14 728
    $hint.ForeColor = [CoreUi.Theme]::SubText
    $hint.Anchor = "Top,Left,Right"
    $d.Controls.Add($hint)
    $d.Controls.Add((New-Lbl "絞り込み" 16 52))
    $tb = New-Object System.Windows.Forms.TextBox
    $tbFrame = New-UiField $tb 84 46 400 30
    $tbFrame.Anchor = "Top,Left,Right"
    $d.Controls.Add($tbFrame)
    $lblCount = New-Lbl "" 496 52 248
    $lblCount.ForeColor = [CoreUi.Theme]::SubText
    $lblCount.TextAlign = "MiddleRight"
    $lblCount.Anchor = "Top,Right"
    $d.Controls.Add($lblCount)

    $lvFrame = New-Object CoreUi.Card
    $lvFrame.HeaderHeight = 1
    $lvFrame.Padding = New-Object System.Windows.Forms.Padding(1)
    $lvFrame.Location = New-Object System.Drawing.Point(16, 88)
    $lvFrame.Size = New-Object System.Drawing.Size(728, 380)
    $lvFrame.Anchor = "Top,Bottom,Left,Right"
    $lv = New-Object CoreUi.DarkListView
    $lv.Dock = "Fill"
    $lv.View = "Details"; $lv.FullRowSelect = $true; $lv.MultiSelect = $false; $lv.GridLines = $false
    [void]$lv.Columns.Add("アプリ名", 260)
    [void]$lv.Columns.Add("実行ファイル", 380)
    [void]$lv.Columns.Add("情報源", 84)
    $lvFrame.Controls.Add($lv)
    $d.Controls.Add($lvFrame)

    $ok = New-UiButton "追加" 110 "Primary"
    $ok.DialogResult = "OK"
    $ok.Location = New-Object System.Drawing.Point(516, 482)
    $ok.Anchor = "Bottom,Right"
    $ng = New-UiButton "キャンセル" 110
    $ng.DialogResult = "Cancel"
    $ng.Location = New-Object System.Drawing.Point(634, 482)
    $ng.Anchor = "Bottom,Right"
    $d.Controls.AddRange(@($ok, $ng))
    $d.AcceptButton = $ok; $d.CancelButton = $ng

    $d.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $all = @(Get-InstalledApps)
    $d.Cursor = [System.Windows.Forms.Cursors]::Default

    $script:InstShown = @()
    function Fill-List([string]$Filter) {
        $lv.BeginUpdate()
        $lv.Items.Clear()
        $script:InstShown = @()
        foreach ($e in $all) {
            if ($Filter -and ($e.Name -notlike "*$Filter*") -and ($e.Exe -notlike "*$Filter*")) { continue }
            $it = New-Object System.Windows.Forms.ListViewItem($e.Name)
            [void]$it.SubItems.Add($e.Exe)
            [void]$it.SubItems.Add($e.Source)
            [void]$lv.Items.Add($it)
            $script:InstShown += $e
        }
        $lv.EndUpdate()
        $lblCount.Text = "{0} 件 / 全 {1} 件" -f $script:InstShown.Count, $all.Count
    }
    Fill-List ""
    $tb.Add_TextChanged({ Fill-List $tb.Text.Trim() })
    $lv.Add_DoubleClick({ if ($lv.SelectedIndices.Count -gt 0) { $d.DialogResult = "OK"; $d.Close() } })

