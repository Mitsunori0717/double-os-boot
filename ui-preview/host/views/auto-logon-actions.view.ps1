    $form.Controls.Add($btnNet)

    $btnOK = New-Object System.Windows.Forms.Button
    $btnOK.Text = "保存"
    $btnOK.Location = New-Object System.Drawing.Point(320, 245)
    $btnOK.Size = New-Object System.Drawing.Size(90, 32)
    $btnOK.DialogResult = "OK"
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "キャンセル"
    $btnCancel.Location = New-Object System.Drawing.Point(425, 245)
    $btnCancel.Size = New-Object System.Drawing.Size(95, 32)
    $btnCancel.DialogResult = "Cancel"
    $form.Controls.AddRange(@($btnOK, $btnCancel))
    $form.AcceptButton = $btnOK
    $form.CancelButton = $btnCancel

