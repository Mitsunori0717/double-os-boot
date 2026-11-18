#requires -Version 5.1
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
function Get-AvValue($o,[string]$n,$default=$null){if($null -eq $o){return $default};if($o -is [Collections.IDictionary]){if($o.Contains($n)){return $o[$n]}}else{$p=$o.PSObject.Properties[$n];if($null -ne $p){return $p.Value}};return $default}
function Get-AvText($value){$s=[string]$value;$s=$s -replace '[\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]',' ';if($s.Length -gt 1500){$s=$s.Substring(0,1500)+'…'};return $s}
function Format-AppAssessmentText {
 [CmdletBinding()]param([Parameter(Mandatory)]$Record,[Parameter(Mandatory)]$Assessment)
 $lines=[Collections.Generic.List[string]]::new()
 $lines.Add((Get-AvText (Get-AvValue $Record DisplayName)))
 $lines.Add('判別は表示専用です。安全性・不要性・依存関係の保証ではなく、削除の保護条件を変更しません。')
 $lines.Add('')
 $summary=Get-AvValue $Assessment PurposeSummaryJa (Get-AvValue $Assessment Summary (Get-AvValue $Record PurposeSummary))
 $lines.Add('用途の見立て: '+(Get-AvText $summary))
 $lines.Add('識別の確かさ: '+(Get-AvText (Get-AvValue $Assessment IdentitySummary (Get-AvValue $Assessment IdentityConfidence))))
 foreach($candidate in @(Get-AvValue $Assessment CandidateCategories @())){
  if($null -eq $candidate){continue}
  $label=Get-AvValue $candidate LabelJa (Get-AvValue $candidate Category)
  $lines.Add('・候補: '+(Get-AvText $label)+' / '+(Get-AvText (Get-AvValue $candidate ConfidenceLabelJa (Get-AvValue $candidate Confidence)))+' / 根拠 '+(@(Get-AvValue $candidate BasisCodes @())-join ', '))
 }
 $lines.Add('差異や不足は、別名・更新版でも発生します。偽装・悪性の断定ではありません。')
 $lines.Add('差異・不足コード: '+(@(Get-AvValue $Assessment ConflictCodes @())-join ', '))
 $lines.Add('未確認: '+(@(Get-AvValue $Assessment Unknowns @())-join ', '))
 $lines.Add('')
 $lines.Add('削除保護: '+(Get-AvText (Get-AvValue (Get-AvValue $Record Protection) Protected))+' / '+(@(Get-AvValue (Get-AvValue $Record Protection) Reasons @())-join ', '))
 $lines.Add('登録種別: '+(Get-AvText (Get-AvValue (Get-AvValue $Record Source) Kind))+' / MSI製品ID: '+(Get-AvText (Get-AvValue $Record ProductCode)))
 $lines.Add('パッケージ名（登録値）: '+(Get-AvText (Get-AvValue (Get-AvValue $Record Source) PackageFullName)))
 $lines.Add('登録の説明（未認証）: '+(Get-AvText (Get-AvValue (Get-AvValue $Record Metadata) Comments)))
 $lines.Add('登録上の発行元: '+(Get-AvText (Get-AvValue $Record Publisher))+' / 版: '+(Get-AvText (Get-AvValue $Record DisplayVersion)))
 $lines.Add('名称・会社名・バージョン情報は自己申告です。複数の欄が一致しても、独立した真正性の証明にはなりません。')
 $lines.Add('署名領域が存在しても署名の有効性や安全性を保証しません。この版では署名の信頼検証は行いません。')
 return ($lines -join "`r`n")
}
function Format-AppEvidenceText($Evidence){
 if($null -eq $Evidence){return '実行ファイルの読取は未実施です。選択したローカルEXEの明示照合で情報を追加できます。'}
 $file=Get-AvValue $Evidence File;$signature=Get-AvValue $Evidence Signature;$meta=Get-AvValue $file Metadata
 $status=switch([string](Get-AvValue $file Status)){'Read'{'読取済。ただし選択したアプリの所有ファイルかは未証明。'}'NotRequested'{'ファイル読取は未実施。'}default{'読取不可または未確認。'}}
 $cert=switch([string](Get-AvValue $signature CertificateTable)){'Present'{'署名用の構造あり。有効な署名の証明ではありません。'}'Absent'{'埋込署名の構造は見つからず。別のcatalog署名は否定できません。'}default{'構造を確認できませんでした。'}}
 $lines=@(
  ('ファイル状態: '+$status)
  ('観測時刻 UTC: '+(Get-AvText (Get-AvValue $Evidence ObservedUtc)))
  ('ローカルパス: '+(Get-AvText (Get-AvValue $file Path)))
  ('サイズ bytes: '+(Get-AvText (Get-AvValue $file Size)))
  ('SHA-256: '+(Get-AvText (Get-AvValue $file Sha256)))
  ''
  '以下は実行ファイル自身に記載された自己申告であり、発行元の認証ではありません。'
 )
 foreach($pair in @(@('CompanyName','会社名'),@('ProductName','製品名'),@('FileDescription','説明'),@('FileVersion','ファイル版'),@('ProductVersion','製品版'),@('OriginalFilename','元のファイル名'))){$lines+=($pair[1]+': '+(Get-AvText (Get-AvValue $meta $pair[0])))}
 $lines+=@('',('署名領域: '+$cert),'署名の有効性・証明書主体・失効・発行元の信頼: 未検証。','ネット問い合わせを避けるため、信頼プロバイダーや失効確認は呼び出していません。','ファイルは実行していません。ハッシュ一致も安全性・必要性の証明ではありません。')
 foreach($error in @(Get-AvValue $Evidence Errors @())){if($null -ne $error){$lines+=('読取理由: '+(Get-AvText (Get-AvValue $error ReasonCode (Get-AvValue $error Code))))}}
 return ($lines -join "`r`n")
}
function Get-AvLayerStatus([string]$code){
 $labels=@{DeclaredNotAuthenticated='登録されている識別情報。真正性は未認証';MsiDeclaredNotAuthoritativelyChecked='MSIの申告登録。実体APIでの照合は未実施';RegistryUninstallerUnknown='通常のアンインストール登録。方式・実体は未確認';AppxRegistration='Appxの登録。署名は未検証';Protected='従来の削除保護を維持';ExistingPolicyRetained='従来の削除条件を維持。評価で変更しません';Unknown='不明';ProtectionFlagPresent='部品または削除禁止の登録フラグあり';SelfDeclared='登録された自己申告';SelfDeclaredNotAuthenticated='ファイルの自己申告。発行元の認証ではありません';UnavailableOrNotRequested='未読取または取得できず';CertificateTablePresent='署名用構造あり。ただし有効性未検証';CertificateTableAbsent='埋込署名構造なし。別形式の署名は未調査';CertificateTableUnknown='署名構造を確認できず';NotProvided='追加のファイル根拠は未提供';BoundSnapshot='選択レコードに結び付く根拠。真正性の認証ではありません';BoundPartialSnapshot='選択レコードに結び付く一部の根拠';Rejected='関連づけ不一致のため根拠を採用せず';StaleOrInvalidTime='期限切れまたは時刻不正のため根拠を採用せず'}
 if($labels.ContainsKey($code)){return $labels[$code]+' ['+$code+']'};return $code
}
function Format-AppEvidenceLayers($Assessment){
 $lines=[Collections.Generic.List[string]]::new()
 foreach($layer in @(Get-AvValue $Assessment EvidenceLayers @())){if($null -ne $layer){$lines.Add('■ '+(Get-AvText (Get-AvValue $layer LabelJa (Get-AvValue $layer Layer))));$lines.Add('状態: '+(Get-AvLayerStatus (Get-AvText (Get-AvValue $layer Status))));$lines.Add('根拠コード: '+(@(Get-AvValue $layer Codes @())-join ', '));$lines.Add('')}}
 $lines.Add('登録・ファイルの自己申告・構造検査・一般的用途を同じ「信頼」点数にまとめません。')
 return ($lines -join "`r`n")
}
function New-AppAssessmentWindow {
 [CmdletBinding()]param([Parameter(Mandatory)]$Record,[Parameter(Mandatory)]$Assessment,$AppEvidence,[switch]$Demo)
 $f=New-Object Windows.Forms.Form;$f.Text='ソフトの判別と根拠（削除判断とは別）'+$(if($Demo){' [合成デモ]'}else{''});$f.Size=New-Object Drawing.Size(1080,780);$f.MinimumSize=New-Object Drawing.Size(850,620);$f.StartPosition='CenterParent';$f.Font=New-Object Drawing.Font('Yu Gothic UI',10);$f.AutoScaleMode='Dpi'
 $layout=New-Object Windows.Forms.TableLayoutPanel;$layout.Dock='Fill';$layout.Padding=New-Object Windows.Forms.Padding(14);$layout.ColumnCount=1;$layout.RowCount=3
 foreach($style in @(@('Absolute',70),@('Percent',100),@('Absolute',45))){$null=$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::$($style[0]),$style[1])))}
 $f.Controls.Add($layout)
 $notice=New-Object Windows.Forms.Label;$notice.Dock='Fill';$notice.Text='登録情報、実行ファイルの自己申告、パッケージ識別、用途推定を別々の根拠として表示します。'+"`r`n"+'自動のWeb検索・外部送信・実行ファイル起動は行いません。Unknownは悪性を意味しません。';$layout.Controls.Add($notice,0,0)
 $tabs=New-Object Windows.Forms.TabControl;$tabs.Name='AssessmentTabs';$tabs.Dock='Fill';$layout.Controls.Add($tabs,0,1)
 $research=Get-AvValue $Assessment Research
 $sources=@(Get-AvValue $research OfficialUrls @())
 $researchText="不明なものを無理に分類せず、次の順に確認してください。`r`n1. 登録名・発行元・バージョンと、インストール時の購入/導入記録を比較。`r`n2. 『実行ファイルを照合』で、そのアプリのものと確認したローカルEXEを明示指定。ファイルは実行しません。`r`n3. 下記の公式資料は一般的用途の根拠です。登録されたソフトが正規品である証明ではありません。`r`n4. 業務ソフト/ドライバ/共有部品は管理者またはメーカーに必要性を確認。`r`n`r`nWeb調査をする場合は、公開してよい一般製品名と公開発行元だけを自分で入力してください。社内名、パス、ユーザー名、端末名、ハッシュ、全ソフト一覧を送らないでください。`r`n`r`n公式資料（自動では開きません）:`r`n"+(@($sources|ForEach-Object{Get-AvText $_})-join "`r`n")
 $fileView=Format-AppEvidenceText $AppEvidence
 foreach($page in @(@('概要',(Format-AppAssessmentText $Record $Assessment)),@('根拠の内訳',(Format-AppEvidenceLayers $Assessment)),@('ファイル・署名',$fileView),@('不明な場合の調査',$researchText))){
  $tab=New-Object Windows.Forms.TabPage;$tab.Text=$page[0]
  $text=New-Object Windows.Forms.TextBox;$text.Dock='Fill';$text.Multiline=$true;$text.ReadOnly=$true;$text.ScrollBars='Both';$text.WordWrap=$true;$text.Text=[string]$page[1];$tab.Controls.Add($text);$tabs.TabPages.Add($tab)
 }
 $close=New-Object Windows.Forms.Button;$close.Text='閉じる';$close.Name='CloseAssessment';$close.Dock='Right';$close.Width=130;$close.DialogResult='Cancel';$layout.Controls.Add($close,0,2);$f.CancelButton=$close;$f.AcceptButton=$close;$f.ActiveControl=$close
 return $f
}
Export-ModuleMember -Function Format-AppAssessmentText,Format-AppEvidenceText,New-AppAssessmentWindow
