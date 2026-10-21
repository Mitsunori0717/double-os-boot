    $form = New-Object System.Windows.Forms.Form
    $form.Text = "自動サインイン設定"
    $form.Size = New-Object System.Drawing.Size(560, 350)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false

    function New-Label($text, $x, $y, $w) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text
        $l.Location = New-Object System.Drawing.Point($x, $y)
        $l.Size = New-Object System.Drawing.Size($w, 20)
        return $l
    }

    $cbOn = New-Object System.Windows.Forms.CheckBox
    $cbOn.Text = "電源 ON でサインイン画面を省略し、デスクトップまで自動で進む"
    $cbOn.Location = New-Object System.Drawing.Point(20, 18)
    $cbOn.Size = New-Object System.Drawing.Size(500, 24)
    $cbOn.Checked = $st.Enabled
    $form.Controls.Add($cbOn)

    $grp = New-Object System.Windows.Forms.GroupBox
    $grp.Text = "サインインするアカウント"
    $grp.Location = New-Object System.Drawing.Point(20, 50)
    $grp.Size = New-Object System.Drawing.Size(500, 150)

    $grp.Controls.Add((New-Label "アカウント名:" 15 32 100))
    $tbUser = New-Object System.Windows.Forms.TextBox
    $tbUser.Location = New-Object System.Drawing.Point(125, 29)
    $tbUser.Size = New-Object System.Drawing.Size(355, 24)
    $tbUser.Text = $st.UserName
    $grp.Controls.Add($tbUser)

    $grp.Controls.Add((New-Label "パスワード:" 15 68 100))
    $tbPass = New-Object System.Windows.Forms.TextBox
    $tbPass.Location = New-Object System.Drawing.Point(125, 65)
    $tbPass.Size = New-Object System.Drawing.Size(355, 24)
    $tbPass.UseSystemPasswordChar = $true
    # パスワードを入力し始めたら「有効にする」の意思表示とみなしてチェックを入れる
    $tbPass.Add_TextChanged({ if ($tbPass.Text) { $cbOn.Checked = $true } })
    $grp.Controls.Add($tbPass)

    $note = New-Label "※ パスワード欄を空のまま保存すると、今保存されているパスワードをそのまま使います。" 15 100 470
    $note.Size = New-Object System.Drawing.Size(470, 40)
    $note.ForeColor = [System.Drawing.Color]::DimGray
    $grp.Controls.Add($note)
    $form.Controls.Add($grp)

    $mail = Get-MicrosoftAccountMail
    $info = New-Label ("現在: {0}  ({1}\{2}){3}" -f
        $(if ($st.Enabled) { '有効' } else { '無効' }), $st.Domain, $st.UserName,
        $(if ($mail) { "  ― Microsoft アカウント ($mail)" } else { "  ― ローカル アカウント" })) 20 210 500
    if ($mail) { $info.ForeColor = [System.Drawing.Color]::FromArgb(180, 90, 0) }
    $form.Controls.Add($info)

    # Microsoft アカウントなどで保存がうまくいかない場合の逃げ道 (Windows 純正の設定画面)
    $btnNet = New-Object System.Windows.Forms.Button
    $btnNet.Text = "Windows 標準の方法 (netplwiz)"
    $btnNet.Location = New-Object System.Drawing.Point(20, 245)
    $btnNet.Size = New-Object System.Drawing.Size(230, 32)
