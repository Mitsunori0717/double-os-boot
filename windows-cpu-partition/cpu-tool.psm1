function Assert-EdgeBoxCpuTool([string]$Path) {
    $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or
        $signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) -ne 'Microsoft Corporation') {
        throw "A valid Microsoft Corporation signature is required for CpuGroups.exe: $Path"
    }
}
Export-ModuleMember -Function Assert-EdgeBoxCpuTool
