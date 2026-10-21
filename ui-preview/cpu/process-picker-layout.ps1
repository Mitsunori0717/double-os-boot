
    $d = New-Object System.Windows.Forms.Form
    Initialize-UiForm $d
    $d.Text = "実行中のアプリから選ぶ"
    $d.ClientSize = New-Object System.Drawing.Size(660, 470)
    $d.StartPosition = "CenterParent"
    $d.FormBorderStyle = "FixedDialog"
    $d.MaximizeBox = $false
    $d.MinimizeBox = $false
    $d.ShowInTaskbar = $false
    $hint = New-Lbl "登録したいアプリを選んでください (ウィンドウを持つアプリを上に表示します)。" 16 14 628
    $hint.ForeColor = [CoreUi.Theme]::SubText
    $d.Controls.Add($hint)

    $lbFrame = New-Object CoreUi.Card
    $lbFrame.HeaderHeight = 1
    $lbFrame.Padding = New-Object System.Windows.Forms.Padding(1)
    $lbFrame.Location = New-Object System.Drawing.Point(16, 42)
    $lbFrame.Size = New-Object System.Drawing.Size(628, 366)
    $lb = New-Object CoreUi.DarkListBox
    $lb.Dock = "Fill"
    $lbFrame.Controls.Add($lb)
    $d.Controls.Add($lbFrame)

    $entries = @()
    $groups = @(Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -notmatch '^(Idle|System|Registry|Memory Compression)$' } |
        Group-Object ProcessName)
    foreach ($g in $groups) {
        $path = $null
        $titled = $false
        foreach ($pr in $g.Group) {
            try { if (-not $path -and $pr.Path) { $path = $pr.Path } } catch { }
            try { if ($pr.MainWindowHandle -ne 0) { $titled = $true } } catch { }
        }
        $entries += [pscustomobject]@{
            Name = $g.Name; Exe = $path; Count = $g.Count; Titled = $titled
        }
    }
    $entries = @($entries | Sort-Object @{ Expression = "Titled"; Descending = $true }, Name)
    foreach ($e in $entries) {
        [void]$lb.Items.Add(("{0}  ({1} 個)   {2}" -f $e.Name, $e.Count, $(if ($e.Exe) { $e.Exe } else { "(パス不明)" })))
    }

    $ok = New-UiButton "追加" 110 "Primary"
    $ok.DialogResult = "OK"
    $ok.Location = New-Object System.Drawing.Point(416, 422)
    $ng = New-UiButton "キャンセル" 110
    $ng.DialogResult = "Cancel"
    $ng.Location = New-Object System.Drawing.Point(534, 422)
    $d.Controls.AddRange(@($ok, $ng))
    $d.AcceptButton = $ok; $d.CancelButton = $ng

