
    $d = New-Object System.Windows.Forms.Form
    Initialize-UiForm $d
    $d.Text = $Title
    $d.ClientSize = New-Object System.Drawing.Size(700, 480)
    $d.StartPosition = "CenterParent"
    $d.FormBorderStyle = "FixedDialog"
    $d.MaximizeBox = $false
    $d.MinimizeBox = $false
    $d.ShowInTaskbar = $false

    $lbl = New-Lbl "このアプリを動かすコアを選びます (複数選択可)。Edge Box 用のコアは選べないため表示していません。" 16 14 668
    $lbl.ForeColor = [CoreUi.Theme]::SubText
    $d.Controls.Add($lbl)

    $fpFrame = New-Object CoreUi.Card
    $fpFrame.HeaderHeight = 1
    $fpFrame.Padding = New-Object System.Windows.Forms.Padding(10)
    $fpFrame.Location = New-Object System.Drawing.Point(16, 44)
    $fpFrame.Size = New-Object System.Drawing.Size(668, 326)
    $fp = New-Object System.Windows.Forms.FlowLayoutPanel
    $fp.Dock = "Fill"
    $fp.BackColor = [CoreUi.Theme]::Panel
    $fp.AutoScroll = $true
    $fp.WrapContents = $true
    $fpFrame.Controls.Add($fp)
    $d.Controls.Add($fpFrame)

    $boxes = @{}
    foreach ($c in $script:Cores) {
        if (@($c.Lps | Where-Object { $GuestLps -contains $_ }).Count -gt 0) { continue }   # Edge Box 用は選ばせない
        $cb = New-Object CoreUi.DarkCheckBox
        $cb.Text = "{0}  (CPU {1})" -f $c.Label, (ConvertTo-LpRangeText $c.Lps)
        $cb.Size = New-Object System.Drawing.Size(156, 28)
        $cb.Margin = New-Object System.Windows.Forms.Padding(3)
        $cb.Accent = $ColHost   # 選べるのは Windows 用のコアだけ
        $cb.Tag = $c.Id
        $cb.Checked = (@($c.Lps | Where-Object { $Preselect -contains $_ }).Count -gt 0)
        if (@($c.Lps | Where-Object { $GuestLps -contains $_ }).Count -gt 0) { $cb.Accent = $ColGuest }
        $boxes[$c.Id] = $cb
        $fp.Controls.Add($cb)
    }

    $setBoxes = {
        param([string]$Kind)
        foreach ($c in $script:Cores) {
            $b = $boxes[$c.Id]
            if (-not $b) { continue }
            switch ($Kind) {
                "host"  { $b.Checked = ($c.State -eq "Host") }
                "p"     { $b.Checked = ($c.Kind -eq "P" -and $c.State -ne "Guest") }
                "e"     { $b.Checked = ($c.Kind -eq "E" -and $c.State -ne "Guest") }
                default { $b.Checked = $false }
            }
        }
    }
    $qx = 14
    foreach ($q in @(
        @{ T = "Windows 側すべて"; K = "host"; W = 150 },
        @{ T = "P コアのみ";       K = "p";    W = 112 },
        @{ T = "E コアのみ";       K = "e";    W = 112 },
        @{ T = "クリア";           K = "none"; W = 92  })) {
        $b = New-UiButton $q.T $q.W
        $b.Location = New-Object System.Drawing.Point($qx, 380)
        $kind = $q.K
        $b.Add_Click({ & $setBoxes $kind }.GetNewClosure())
        $d.Controls.Add($b)
        $qx += $q.W + 8
    }

    $ok = New-UiButton "OK" 110 "Primary"
    $ok.DialogResult = "OK"
    $ok.Location = New-Object System.Drawing.Point(456, 432)
    $ng = New-UiButton "キャンセル" 110
    $ng.DialogResult = "Cancel"
    $ng.Location = New-Object System.Drawing.Point(574, 432)
    $d.Controls.AddRange(@($ok, $ng))
    $d.AcceptButton = $ok; $d.CancelButton = $ng

