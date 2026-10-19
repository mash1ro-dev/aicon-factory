# Test-only commit path. Production application functions are not replaced or changed.
# Dot-source inside the AiconFactory module to reuse its validation and directory leases.
function Write-AiconExactProbeFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PreparedLink,
        [Parameter(Mandatory)][string]$ExactPath,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Icon,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ExpectedPathIdentity,
        [Parameter(Mandatory)][string]$ExpectedIconHash,
        [Parameter(Mandatory)][string]$ExpectedLinkHash,
        [scriptblock]$BeforeCreate,
        [scriptblock]$WhileExclusive
    )
    $lease=$null;$inputStream=$null;$outputStream=$null;$sha=$null;$created=$false;$complete=$false
    try {
        $path=Assert-AiconWritableTarget $ExactPath
        if([IO.Path]::GetExtension($path) -ine '.lnk'){throw 'Exact output must be a shortcut'}
        $dest=[IO.Path]::GetDirectoryName($path)
        if(-not [IO.Directory]::Exists($dest)){throw 'Destination must already exist'}
        [void](Get-AiconFullPath $PreparedLink)
        $lease=[Aicon.PathValidation]::LeaseDirectories([string[]]@($dest,$Target,$Icon,$Root,$PreparedLink))
        if((Get-AiconApplyPathIdentity $Icon $Target $dest $Root) -cne $ExpectedPathIdentity){throw 'Path identity changed'}
        if((Get-AiconHash $Icon) -ne $ExpectedIconHash){throw 'ICO changed'}
        $inputStream=[IO.File]::Open($PreparedLink,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $sha=[Security.Cryptography.SHA256]::Create()
        $preparedHash=[BitConverter]::ToString($sha.ComputeHash($inputStream)).Replace('-','')
        if($preparedHash -ne $ExpectedLinkHash){throw 'Prepared shortcut changed'}
        if($inputStream.Length -le 0 -or $inputStream.Length -gt 1048576){throw 'Unexpected shortcut size'}
        $inputStream.Position=0
        if(Test-Path -LiteralPath $path){throw 'Exact output already exists; no numbering and no replacement'}
        # Tests deliberately create a competing entry AFTER the preliminary check.
        if($BeforeCreate){&$BeforeCreate}
        # CreateNew is the atomic no-overwrite gate, not the preliminary Test-Path.
        # None denies competing reads/writes/deletion while this handle owns the file.
        $outputStream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $created=$true
        if($WhileExclusive){&$WhileExclusive}
        $inputStream.CopyTo($outputStream)
        $outputStream.Flush($true)
        $outputStream.Position=0
        $actualHash=[BitConverter]::ToString($sha.ComputeHash($outputStream)).Replace('-','')
        if($actualHash -ne $ExpectedLinkHash){throw 'Written shortcut hash mismatch'}
        $length=$outputStream.Length;$complete=$true
        return [pscustomobject]@{Path=$path;Length=$length;SHA256=$actualHash;Created=$true;Complete=$true;CommitMode='CreateNew / exclusive handle';DesktopTemporaryFiles=0;DeletedFiles=0}
    } catch {
        # Never delete or overwrite a final name, even after a partial failure.
        # Caller must record it and stop; any later deletion needs separate approval.
        $_.Exception.Data['ExactPath']=$ExactPath
        $_.Exception.Data['CreatedByThisCall']=$created
        $_.Exception.Data['Complete']=$complete
        throw
    } finally {
        if($outputStream){$outputStream.Dispose()}
        if($inputStream){$inputStream.Dispose()}
        if($sha){$sha.Dispose()}
        if($lease){$lease.Dispose()}
    }
}
