    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Edge Box 表示設定"
    $form.Size = New-Object System.Drawing.Size(600, 505)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false

    function New-Label($text, $x, $y) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, $y); $l.AutoSize = $true
        return $l
    }

    # --- モニター表示 ---
    $grpMon = New-Object System.Windows.Forms.GroupBox
    $grpMon.Text = "モニター表示 (URL を入力 / console = Edge Box のコンソール画面 / 空欄 = 表示しない)"
    $grpMon.Location = New-Object System.Drawing.Point(15, 15)
    $grpMon.Size = New-Object System.Drawing.Size(555, 130)

    $grpMon.Controls.Add((New-Label "左モニター:" 15 30))
    $tbL = New-Object System.Windows.Forms.TextBox
    $tbL.Location = New-Object System.Drawing.Point(110, 27)
    $tbL.Size = New-Object System.Drawing.Size(330, 24)
    $tbL.Text = [string]$cfg.LeftUrl
    $grpMon.Controls.Add($tbL)

    $cbLF = New-Object System.Windows.Forms.CheckBox
    $cbLF.Text = "全画面"
    $cbLF.Location = New-Object System.Drawing.Point(455, 29)
    $cbLF.Size = New-Object System.Drawing.Size(85, 24)
    $cbLF.Checked = $LeftFull
    $grpMon.Controls.Add($cbLF)

    $grpMon.Controls.Add((New-Label "右モニター:" 15 65))
    $tbR = New-Object System.Windows.Forms.TextBox
    $tbR.Location = New-Object System.Drawing.Point(110, 62)
    $tbR.Size = New-Object System.Drawing.Size(330, 24)
    $tbR.Text = [string]$cfg.RightUrl
    $grpMon.Controls.Add($tbR)

    $cbRF = New-Object System.Windows.Forms.CheckBox
    $cbRF.Text = "全画面"
    $cbRF.Location = New-Object System.Drawing.Point(455, 64)
    $cbRF.Size = New-Object System.Drawing.Size(85, 24)
    $cbRF.Checked = $RightFull
    $grpMon.Controls.Add($cbRF)

    $lblMon = New-Label "全画面 = 枠なしで画面全体 (タスクバーも隠れる) / チェックなし = 最大化ウィンドウ" 15 98
    $lblMon.ForeColor = [System.Drawing.Color]::DimGray
    $grpMon.Controls.Add($lblMon)
    $form.Controls.Add($grpMon)

    # --- 操作 ---
    $grpOp = New-Object System.Windows.Forms.GroupBox
    $grpOp.Text = "操作"
    $grpOp.Location = New-Object System.Drawing.Point(15, 155)
    $grpOp.Size = New-Object System.Drawing.Size(555, 120)
    $cbEsc = New-Object System.Windows.Forms.CheckBox
    $cbEsc.Text = "ESC キーでブラウザの最大化を解除する (ブラウザ画面が前面のときのみ)"
    $cbEsc.Location = New-Object System.Drawing.Point(15, 25)
    $cbEsc.Size = New-Object System.Drawing.Size(530, 24)
    $cbEsc.Checked = ($cfg.EscEnabled -ne $false)
    $grpOp.Controls.Add($cbEsc)

    $cbSF = New-Object System.Windows.Forms.CheckBox
    $cbSF.Text = "コンソールの全画面が効かないときは、黒背景の上に中央表示する (代替の全画面)"
    $cbSF.Location = New-Object System.Drawing.Point(15, 55)
    $cbSF.Size = New-Object System.Drawing.Size(530, 24)
    $cbSF.Checked = ($cfg.ConsoleStripFrame -ne $false)
    $grpOp.Controls.Add($cbSF)

    $cbAC = New-Object System.Windows.Forms.CheckBox
    $cbAC.Text = "Edge Box の起動を確認したら、コンソール画面を自動で閉じる (通常はオフ。閉じても Edge Box は動き続ける)"
    $cbAC.Location = New-Object System.Drawing.Point(15, 85)
    $cbAC.Size = New-Object System.Drawing.Size(530, 24)
    $cbAC.Checked = ($cfg.ConsoleAutoClose -eq $true)
    $grpOp.Controls.Add($cbAC)
    $form.Controls.Add($grpOp)

    # --- コンソールの表示サイズ ---
    $grpRes = New-Object System.Windows.Forms.GroupBox
    $grpRes.Text = "コンソールの表示サイズ (Edge Box 側の画面解像度)"
    $grpRes.Location = New-Object System.Drawing.Point(15, 285)
    $grpRes.Size = New-Object System.Drawing.Size(555, 115)

    # このチェック 1 つで「解像度をモニターに合わせる」+「コンソール側を全画面」がまとまる
    $cbFit = New-Object System.Windows.Forms.CheckBox
    $cbFit.Text = "モニターいっぱいに全画面表示する (解像度をモニターに合わせ、全画面にする)"
    $cbFit.Location = New-Object System.Drawing.Point(15, 25)
    $cbFit.Size = New-Object System.Drawing.Size(530, 24)
    $resCur = [string]$cfg.ConsoleResolution
    $consoleFull = if ($LeftUrl -match '^(console|コンソール)$') { $LeftFull }
                   elseif ($RightUrl -match '^(console|コンソール)$') { $RightFull }
                   else { $false }
    $cbFit.Checked = (((-not $resCur) -or ($resCur -match '^(auto|自動)')) -and $consoleFull)
    $grpRes.Controls.Add($cbFit)

    $grpRes.Controls.Add((New-Label "解像度:" 15 58))
    $cmbRes = New-Object System.Windows.Forms.ComboBox
    $cmbRes.Location = New-Object System.Drawing.Point(85, 55)
    $cmbRes.Size = New-Object System.Drawing.Size(220, 24)
    $cmbRes.DropDownStyle = "DropDown"        # 一覧から選ぶほか、直接入力もできる
    $cmbRes.Items.AddRange($ResolutionChoices)
    $cmbRes.Text = if ($cfg.ConsoleResolution) { [string]$cfg.ConsoleResolution } else { $ResolutionChoices[0] }
    $grpRes.Controls.Add($cmbRes)

    $lblRes = New-Label "一覧にないサイズは直接入力できます (例: 2560x1440)" 315 58
    $lblRes.ForeColor = [System.Drawing.Color]::DimGray
    $grpRes.Controls.Add($lblRes)

    $lblRes2 = New-Label "※ 変更は Edge Box を起動し直したときに反映されます" 15 85
    $lblRes2.ForeColor = [System.Drawing.Color]::DimGray
    $grpRes.Controls.Add($lblRes2)
    $form.Controls.Add($grpRes)

    # チェックを入れたら、解像度は自動、コンソール側のモニターは全画面にそろえる
    $syncFit = {
        if ($cbFit.Checked) {
            $cmbRes.Text = $ResolutionChoices[0]
            $cmbRes.Enabled = $false
            if ($tbL.Text.Trim() -match '^(console|コンソール)$') { $cbLF.Checked = $true }
            if ($tbR.Text.Trim() -match '^(console|コンソール)$') { $cbRF.Checked = $true }
        } else {
            $cmbRes.Enabled = $true
        }
    }
    $cbFit.Add_CheckedChanged($syncFit)
    & $syncFit

    # --- ボタン ---
    $btnOK = New-Object System.Windows.Forms.Button
    $btnOK.Text = "保存"
    $btnOK.Location = New-Object System.Drawing.Point(370, 415)
    $btnOK.Size = New-Object System.Drawing.Size(90, 32)
    $btnOK.DialogResult = "OK"
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "キャンセル"
    $btnCancel.Location = New-Object System.Drawing.Point(475, 415)
    $btnCancel.Size = New-Object System.Drawing.Size(90, 32)
    $btnCancel.DialogResult = "Cancel"
    $form.Controls.AddRange(@($btnOK, $btnCancel))
    $form.AcceptButton = $btnOK
    $form.CancelButton = $btnCancel

