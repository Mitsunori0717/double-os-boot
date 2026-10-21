# Preview data only. This file never reads the host configuration or credentials.
$cfg = [pscustomobject]@{
    LeftUrl = 'console'
    RightUrl = 'http://192.0.2.10/'
    LeftFullScreen = $true
    RightFullScreen = $false
    EscEnabled = $true
    ConsoleStripFrame = $true
    ConsoleAutoClose = $false
    ConsoleResolution = '自動 (モニターに合わせる)'
}
$LeftUrl = $cfg.LeftUrl
$RightUrl = $cfg.RightUrl
$LeftFull = $cfg.LeftFullScreen
$RightFull = $cfg.RightFullScreen
$ResolutionChoices = @('自動 (モニターに合わせる)', '1920x1080', '1600x900', '1366x768', '1280x720', '2560x1440')
function Get-AutoLogonState {
    [pscustomobject]@{ Enabled = $true; UserName = 'preview-user'; Domain = 'EDGEBOX-PREVIEW' }
}
function Get-MicrosoftAccountMail { return '' }
$st = Get-AutoLogonState
