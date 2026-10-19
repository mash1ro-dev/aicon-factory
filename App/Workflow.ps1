# Window-independent session model. Display numbers never identify an item.
function Read-AiconSettings([string]$Root) {
    $path=Get-AiconFullPath (Join-Path $Root 'settings.json')
    $result=@{Path=$path;Data=[pscustomobject]@{};Valid=$true;Warning=''}
    if([IO.File]::Exists($path)) {
        try {
            $json=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)
            if(-not $json.TrimStart().StartsWith('{')){throw 'Object required'}
            $data=$json|ConvertFrom-Json -ErrorAction Stop
            if($null -eq $data -or $data -isnot [pscustomobject]){throw 'Object required'}
            $result.Data=$data
        } catch {$result.Valid=$false;$result.Warning='設定ファイルを読み込めませんでした。元の設定は保持しています。保存先を確認してください。'}
    }
    return $result
}
function Write-AiconSettings([string]$Root,[hashtable]$Changes,[switch]$OnlyIfMissing) {
    $rootPath=Assert-AiconWritableTarget $Root
    [void][IO.Directory]::CreateDirectory($rootPath)
    $path=Get-AiconFullPath (Join-Path $rootPath 'settings.json')
    $lockPath=Get-AiconFullPath ($path+'.lock');$lock=$null;$stage=$null
    try {
        # The OS releases this exclusive handle on a crash; a leftover empty file
        # must never prevent the next process from saving its settings.
        $lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        if($OnlyIfMissing -and [IO.File]::Exists($path)){return}
        $settings=Read-AiconSettings $rootPath
        if(-not $settings.Valid){throw $settings.Warning}
        foreach($key in $Changes.Keys){$settings.Data|Add-Member -NotePropertyName $key -NotePropertyValue $Changes[$key] -Force}
        $stage=Join-Path $rootPath ('.aicon-settings-'+[guid]::NewGuid().ToString('N')+'.tmp')
        $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($settings.Data|ConvertTo-Json -Depth 100))
        $stream=[IO.File]::Open($stage,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
        [void](Get-AiconFullPath $path)
        if([IO.File]::Exists($path)){[IO.File]::Replace($stage,$path,[Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($stage,$path)}
        $stage=$null
    } finally {
        if($stage -and [IO.File]::Exists($stage)){[IO.File]::Delete($stage)}
        if($lock){$lock.Dispose()}
    }
}
function Get-AiconUserDataRoot([string]$Override) {
    if($Override){return (Assert-AiconWritableTarget $Override)}
    $local=[Environment]::GetFolderPath('LocalApplicationData')
    if(-not $local){throw 'ユーザーデータの保存場所を取得できません。Windowsのユーザープロファイルを確認してください。'}
    return (Assert-AiconWritableTarget (Join-Path $local 'AiconFactory'))
}
function New-AiconSession([string]$Root,[string]$UserDataRoot) {
    Initialize-AiconEngine
    $appRoot=Assert-AiconWritableTarget $Root
    $rootPath=Get-AiconUserDataRoot $UserDataRoot
    $settings=Read-AiconSettings $rootPath
    $migrationNotice='';$settingsBlocked=$false
    # Import only settings, once, without touching any legacy ICO or backup.
    # Stable settings always win over app-local settings shipped with an update.
    if($appRoot -ine $rootPath -and -not [IO.File]::Exists($settings.Path)){
        $legacy=Read-AiconSettings $appRoot
        if([IO.File]::Exists($legacy.Path)){
            if($legacy.Valid){
                $changes=@{};foreach($p in $legacy.Data.PSObject.Properties){$changes[$p.Name]=$p.Value}
                try{Write-AiconSettings $rootPath $changes -OnlyIfMissing;$settings=Read-AiconSettings $rootPath;$migrationNotice='以前の設定と保存履歴を引き継ぎました。既存ICO・バックアップは元の場所に残しています。'}
                catch{$settings=$legacy;$settingsBlocked=$true;$migrationNotice='以前の設定の引き継ぎを記録できませんでした。元の設定は保持しています。ユーザーデータのアクセス権を確認してください。'}
            }else{$settings=$legacy;$settingsBlocked=$true}
        }
    }
    $state=@{Root=$rootPath;AppRoot=$appRoot;SettingsBlocked=$settingsBlocked;MigrationNotice=$migrationNotice;IcoSaveMode='Library';Items=[Collections.ObjectModel.ObservableCollection[object]]::new();RemovalIds=[Collections.Generic.HashSet[string]]::new();CurrentId='';Category='Image';IcoOutputDirectoryPreference='';LastIcoSavedDirectory='';ShortcutOutputDirectory='';AppliedTargetDirectory='';SkipShortcutExplanation=$false;Warning=$settings.Warning;Busy=$false;Kind='';CancelRequested=$false;CloseAfter=$false;AllowClose=$false;Closed=$false;AppliedSignature='';LastBackupId=''}
    if($settings.Valid){
        foreach($key in @('IcoOutputDirectoryPreference','LastIcoSavedDirectory')){
            $p=$settings.Data.PSObject.Properties[$key]
            if($p -and $p.Value -is [string]){
                $state[$key]=$p.Value
                if($p.Value){try{[void](Assert-AiconWritableTarget $p.Value)}catch{$state.Warning='記録された保存先を利用できません。「変更」から選び直してください。'}}
            }
        }
        $p=$settings.Data.PSObject.Properties['SkipShortcutExplanation'];if($p -and $p.Value -is [bool]){$state.SkipShortcutExplanation=$p.Value}
        $p=$settings.Data.PSObject.Properties['IcoSaveMode']
        if($p){if($p.Value -in @('Library','Custom')){$state.IcoSaveMode=$p.Value}else{$state.IcoSaveMode='Invalid';$state.Warning='保存方法の設定を読み取れません。保存方法を選び直してください。'}}elseif($state.IcoOutputDirectoryPreference){$state.IcoSaveMode='Custom'}
        $p=$settings.Data.PSObject.Properties['IcoCategory'];if($p -and $p.Value -in @('Image','Audio','Development','Tools','Apps','Business','AI','Other')){$state.Category=$p.Value}
    }
    $state.LastTargetSelectionDirectory=''
    $state.CompletedApplications=@{};$state.ShowApplyMore=$false
    if($settings.Valid){$p=$settings.Data.PSObject.Properties['LastTargetSelectionDirectory'];if($p -and $p.Value -is [string]){$state.LastTargetSelectionDirectory=$p.Value}}
    return $state
}
function Get-AiconTargetInitialDirectory($State,[string[]]$FallbackDirectories=@((Get-AiconDesktopDirectory),[Environment]::GetFolderPath('MyDocuments'),[Environment]::GetFolderPath('UserProfile'))) {
    $excluded=@([Environment]::GetFolderPath('LocalApplicationData'),[Environment]::GetFolderPath('ApplicationData'),(Join-Path ([Environment]::GetFolderPath('UserProfile')) 'AppData'))
    foreach($candidate in @($State.LastTargetSelectionDirectory)+$FallbackDirectories){
        if(-not $candidate){continue}
        try{
            $path=Get-AiconFullPath $candidate
            if(@($excluded|Where-Object {$_ -and ($path -ieq $_ -or $path.StartsWith($_.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase))}).Count){continue}
            if(-not [IO.Directory]::Exists($path)){continue}
            $null=Get-ChildItem -LiteralPath $path -ErrorAction Stop|Select-Object -First 1
            return $path
        }catch{}
    }
    throw '選択画面の初期場所を開けません。デスクトップやドキュメントの場所を確認してください。'
}
function Remember-AiconTargetDirectory($State,[string]$Path) {
    $kind=Get-AiconTargetKind $Path;if($kind -eq 'Invalid'){return}
    $State.LastTargetSelectionDirectory=if($kind -eq 'Folder'){Get-AiconFullPath $Path}else{[IO.Path]::GetDirectoryName((Get-AiconFullPath $Path))}
    try{Write-AiconSessionSettings $State @{LastTargetSelectionDirectory=$State.LastTargetSelectionDirectory}}catch{$State.Warning='選んだ場所を次回用に記憶できませんでした。今回の設定先は画面の場所です。'}
}
function Write-AiconSessionSettings($State,[hashtable]$Changes) {
    if($State.SettingsBlocked){throw '以前の設定を安全に引き継げないため、設定の更新を中止しました。'}
    Write-AiconSettings $State.Root $Changes
}
function Get-AiconCurrent($State) { return ($State.Items|Where-Object Id -eq $State.CurrentId|Select-Object -First 1) }
function Set-AiconCurrent($State,[string]$Id) {if(@($State.Items|Where-Object Id -eq $Id).Count -eq 1){$State.CurrentId=$Id}}
function Add-AiconInputs($State,[string[]]$Paths) {
    if($State.Busy){return}
    foreach($path in $Paths){
        try{$safe=Get-AiconFullPath $path;if(-not [IO.File]::Exists($safe) -or [IO.Path]::GetExtension($safe).ToLowerInvariant() -notin @('.png','.jpg','.jpeg','.webp')){throw 'Unsupported input'}}catch{$State.Warning='PNG・JPEG・静止WebPのファイルを選んでください。';continue}
        if(@($State.Items|Where-Object Source -eq $safe).Count){continue}
        $State.Items.Add([Aicon.SessionItem]@{Id=[guid]::NewGuid().ToString('N');Number=0;Source=$safe;FileName=[IO.Path]::GetFileName($safe);Name=[IO.Path]::GetFileNameWithoutExtension($safe);SaveChecked=$false;Result=$null;SavedPath='';Status='未変換';Error='';Thumbnail=$null})
    }
    Update-AiconNumbers $State
    if($State.Items.Count -eq 1){$State.Items[0].SaveChecked=$true}
    if(-not (Get-AiconCurrent $State) -and $State.Items.Count){$State.CurrentId=$State.Items[0].Id}
}
function Update-AiconNumbers($State) {
    for($i=0;$i -lt $State.Items.Count;$i++){$State.Items[$i].Number=$i+1}
    if($State.Items.Count -gt 1){foreach($item in $State.Items){$stem=[IO.Path]::GetFileNameWithoutExtension($item.Source);if($item.Name -ne $stem){$item.Name=$stem;$item.SavedPath='';$item.Status=if($item.Result){'未保存'}else{'未変換'}}}}
}
function Remove-AiconInputs($State,[string[]]$Ids) {
    if($State.Busy){return}
    $oldIndex=-1;for($i=0;$i -lt $State.Items.Count;$i++){if($State.Items[$i].Id -eq $State.CurrentId){$oldIndex=$i}}
    foreach($id in $Ids){$item=$State.Items|Where-Object Id -eq $id|Select-Object -First 1;if($item){$item.Result=$null;$State.Items.Remove($item)|Out-Null};[void]$State.RemovalIds.Remove($id)}
    Update-AiconNumbers $State
    if(-not (Get-AiconCurrent $State)){$State.CurrentId=if($State.Items.Count){$State.Items[[Math]::Min([Math]::Max(0,$oldIndex),$State.Items.Count-1)].Id}else{''}}
}
function Test-AiconUnsaved($State) {return @($State.Items|Where-Object {-not $_.SavedPath}).Count -gt 0}
function Set-AiconItemName($State,[string]$Name) {
    if($State.Busy -or $State.Items.Count -ne 1){return}
    $item=$State.Items[0]
    if($item.Name -cne $Name){$item.Name=$Name;$item.SavedPath='';$item.Status=if($item.Result){'未保存'}else{'未変換'}}
}
function Get-AiconSaveCandidates($State) {return @($State.Items|Where-Object {$_.SaveChecked -and $_.Result -and -not $_.SavedPath})}
function Get-AiconOutputDirectory($State) {
    if($State.IcoSaveMode -eq 'Custom'){
        if(-not $State.IcoOutputDirectoryPreference){throw '保存先フォルダを選んでください。'}
        return (Assert-AiconWritableTarget $State.IcoOutputDirectoryPreference)
    }
    if($State.IcoSaveMode -ne 'Library'){throw '保存方法を選んでください。'}
    return (Assert-AiconWritableTarget (Join-Path $State.Root ('Library\ICO\'+(Assert-AiconName $State.Category))))
}
function Set-AiconSaveMode($State,[ValidateSet('Library','Custom')][string]$Mode) {
    if($State.Busy){return}
    $State.IcoSaveMode=$Mode
    try{Write-AiconSessionSettings $State @{IcoSaveMode=$Mode;IcoOutputDirectoryPreference=$State.IcoOutputDirectoryPreference;IcoCategory=$State.Category}}catch{$State.Warning='保存先設定を記憶できませんでした。今回の保存先は画面の場所です。設定ファイルを確認してください。'}
}
function Set-AiconOutputPreference($State,[string]$Directory) {
    if($State.Busy){return}
    if($Directory){$Directory=Assert-AiconWritableTarget $Directory;if(-not [IO.Directory]::Exists($Directory)){throw '保存先が見つかりません。「変更」から選び直してください。'}}
    if($Directory){$State.IcoOutputDirectoryPreference=$Directory;Set-AiconSaveMode $State 'Custom'}else{Set-AiconSaveMode $State 'Library'}
}
function Get-AiconSavedDirectory($State) {
    if(-not $State.LastIcoSavedDirectory){throw 'まだ保存履歴がありません。仕上がりを確認してアイコンを保存してください。'}
    $path=Get-AiconFullPath $State.LastIcoSavedDirectory
    if(-not [IO.Directory]::Exists($path)){throw '前回の保存先が見つかりません。移動先やアクセス権を確認してください。'}
    # Force an access check; Directory.Exists alone converts access errors to false.
    $null=Get-ChildItem -LiteralPath $path -Force -ErrorAction Stop|Select-Object -First 1
    return $path
}
function Save-AiconPreviewBytes([byte[]]$Bytes,[string]$Directory,[string]$Name,[switch]$CreateDirectory) {
    $dir=Assert-AiconWritableTarget $Directory;$Name=Assert-AiconName $Name
    if($CreateDirectory){[void][IO.Directory]::CreateDirectory($dir)}
    if(-not [IO.Directory]::Exists($dir)){throw '保存先が見つかりません。「変更」から選び直してください。'}
    $stage=Get-AiconFullPath (Join-Path $dir ('.aicon-ico-'+[guid]::NewGuid().ToString('N')+'.tmp'))
    try{
        $stream=[IO.File]::Open($stage,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$stream.Write($Bytes,0,$Bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
        for($i=1;$i -le 9999;$i++){
            $suffix=if($i -eq 1){''}else{'_{0:D2}' -f $i}
            $path=Get-AiconFullPath (Join-Path $dir ($Name+$suffix+'.ico'))
            try{[IO.File]::Move($stage,$path);$stage=$null;return $path}catch [IO.IOException]{if([IO.File]::Exists($path)){continue};throw}
        }
        throw '同名ファイルが多すぎます。別の名前を指定してください。'
    }finally{if($stage -and [IO.File]::Exists($stage)){[IO.File]::Delete($stage)}}
}
function Save-AiconSessionItem($State,$Item) {
    if(-not $Item.SaveChecked -or -not $Item.Result -or $Item.SavedPath){return}
    try{
        $dir=Get-AiconOutputDirectory $State
        $create=$State.IcoSaveMode -eq 'Library'
        $Item.SavedPath=Save-AiconPreviewBytes -Bytes $Item.Result.Ico -Directory $dir -Name $Item.Name -CreateDirectory:$create
        $Item.Status='保存済み';$Item.Error='';$State.LastIcoSavedDirectory=[IO.Path]::GetDirectoryName($Item.SavedPath)
        try{Write-AiconSessionSettings $State @{LastIcoSavedDirectory=$State.LastIcoSavedDirectory;IcoSaveMode=$State.IcoSaveMode;IcoOutputDirectoryPreference=$State.IcoOutputDirectoryPreference;IcoCategory=$State.Category}}catch{$State.Warning='ICOは保存済みですが、保存先の記憶に失敗しました。設定ファイルを確認してください。'}
    }catch{$Item.Status='保存失敗';$Item.Error='保存できませんでした。保存先・権限・空き容量を確認してください。';throw}
}
function Get-AiconTargetKind([string]$Path) {
    try{$safe=Get-AiconFullPath $Path;if([IO.Directory]::Exists($safe)){[void](Assert-AiconWritableTarget $safe);return 'Folder'};if([IO.File]::Exists($safe)){switch([IO.Path]::GetExtension($safe).ToLowerInvariant()){'.lnk'{[void](Assert-AiconWritableTarget $safe);return 'Shortcut'} {$_ -in @('.exe','.ps1','.bat','.cmd')}{return 'NewShortcut'}}}}catch{}
    return 'Invalid'
}
function New-AiconApplySnapshot($State,[string]$Target,[string]$Destination,[string]$OutputDirectory,[string]$ShortcutName,[string]$Signature) {
    $item=Get-AiconCurrent $State
    if(-not $item -or -not $item.SavedPath -or -not [IO.File]::Exists($item.SavedPath)){throw "このアイコンはまだ保存されていないよ。`n先に02で保存してから、ここで設定してね。"}
    $kind=Get-AiconTargetKind $Target
    if($kind -eq 'Invalid'){throw '設定先が見つからないか、対応していない種類です。フォルダ・ショートカット・EXE・PS1・BAT・CMDを選んでね。'}
    $icon=Get-AiconFullPath $item.SavedPath;$targetPath=Get-AiconFullPath $Target
    if(-not $item.Result -or [Convert]::ToBase64String([IO.File]::ReadAllBytes($icon)) -ne [Convert]::ToBase64String($item.Result.Ico)){throw '保存したICOの内容が変わっています。02で内容を確認して、保存し直してね。'}
    $args=@{Icon=$icon;Target=$targetPath;Root=$State.Root};$dest=''
    if($kind -eq 'NewShortcut'){
        $dest=switch($Destination){'Desktop'{Get-AiconDesktopDirectory} 'SameFolder'{[IO.Path]::GetDirectoryName($targetPath)} 'Custom'{$OutputDirectory} default{throw 'ショートカットの保存先を選んでね。'}}
        try{$dest=Assert-AiconWritableTarget $dest}catch{throw 'ショートカットの保存先を安全に確認できません。「保存先を変更」から、リンクやジャンクションではないフォルダを選んでね。'}
        if(-not [IO.Directory]::Exists($dest)){throw 'ショートカットの保存先が見つかりません。「保存先を変更」から選び直してね。'}
        $ShortcutName=Assert-AiconName $ShortcutName
        $args.Destination=$Destination;$args.OutputDirectory=$dest;$args.ShortcutName=$ShortcutName
    }
    $identity=Get-AiconApplyPathIdentity $icon $targetPath $dest $State.Root;$hash=Get-AiconHash $icon
    $args.ExpectedPathIdentity=$identity;$args.ExpectedIconHash=$hash
    $operationKey=Get-AiconApplyOperationKey $targetPath $Destination $OutputDirectory $ShortcutName
    return @{Id=$item.Id;Number=$item.Number;Icon=$icon;IconName=[IO.Path]::GetFileName($icon);IconHash=$hash;PathIdentity=$identity;OperationKey=$operationKey;Kind=$kind;Target=$targetPath;Destination=$Destination;DestinationDirectory=$dest;Arguments=$args;Signature=$Signature;CheckedCount=@($State.Items|Where-Object SaveChecked).Count}
}
function Get-AiconApplySuccessText([string]$Kind) {
    if($Kind -eq 'Folder'){return 'アイコンを設定したよ。見た目が変わらないときは、少し待ってみてね。'}
    return 'アイコンを設定できたよ。'
}
function Get-AiconApplyOperationKey([string]$Target,[string]$Destination,[string]$OutputDirectory,[string]$ShortcutName) {
    $kind=Get-AiconTargetKind $Target;if($kind -eq 'Invalid'){return ''}
    $targetPath=Get-AiconFullPath $Target
    if($kind -ne 'NewShortcut'){return ($kind+'|'+$targetPath)}
    $dest=switch($Destination){'Desktop'{Get-AiconDesktopDirectory} 'SameFolder'{[IO.Path]::GetDirectoryName($targetPath)} 'Custom'{$OutputDirectory}}
    if(-not $dest){return ''};$dest=Get-AiconFullPath $dest
    return ('NewShortcut|'+$targetPath+'|'+$dest+'|'+$ShortcutName)
}
function Test-AiconAlreadyApplied($State,[string]$Target,[string]$Destination,[string]$OutputDirectory,[string]$ShortcutName) {
    try{
        $item=Get-AiconCurrent $State;if(-not $item -or -not $item.SavedPath){return $false}
        $key=Get-AiconApplyOperationKey $Target $Destination $OutputDirectory $ShortcutName
        if(-not $key -or -not $State.CompletedApplications.ContainsKey($key)){return $false}
        $record=$State.CompletedApplications[$key]
        return ($item.SavedPath -ieq $record.Icon -and (Get-AiconHash $item.SavedPath) -eq $record.IconHash -and $record.TargetHash -and (Get-AiconHash $record.TargetPath) -eq $record.TargetHash)
    }catch{return $false}
}
function Test-AiconApplySnapshot($State,$Snapshot,[string]$Signature) {
    try{
        $item=Get-AiconCurrent $State
        return ($item -and $item.Id -eq $Snapshot.Id -and $item.Number -eq $Snapshot.Number -and $item.SavedPath -eq $Snapshot.Icon -and $Signature -ceq $Snapshot.Signature -and @($State.Items|Where-Object SaveChecked).Count -eq $Snapshot.CheckedCount -and (Get-AiconTargetKind $Snapshot.Target) -eq $Snapshot.Kind -and (Get-AiconHash $Snapshot.Icon) -eq $Snapshot.IconHash -and (Get-AiconApplyPathIdentity $Snapshot.Icon $Snapshot.Target $Snapshot.DestinationDirectory $State.Root) -ceq $Snapshot.PathIdentity)
    }catch{return $false}
}
function Get-AiconApplyPrompt($Snapshot,[ValidateSet('Explain','Final','Multiple')][string]$Stage) {
    $nl=[Environment]::NewLine;$s=$Snapshot
    if($Stage -eq 'Multiple'){return @{Message="保存する画像が$($s.CheckedCount)枚選ばれているよ。${nl}${nl}ここで使うのは、いま02に表示している『$($s.Number)番：$($s.IconName)』の1枚です。${nl}${nl}このアイコンでいい？";Accept='この1枚を設定する';Cancel='プレビューに戻る';Remember=$false}}
    if($Stage -eq 'Explain'){
        $location=if($s.Destination -eq 'Desktop'){'デスクトップ'}else{'「'+$s.DestinationDirectory+'」'}
        return @{Message="元のファイルはそのままに、好きなアイコンをつけたショートカットを作るよ。${nl}${nl}保存先は${location}です。変えたいときだけ『保存先を変更』から選んでね。";Accept='ショートカットを作る';Cancel='やめる';Remember=$true}
    }
    $details="${nl}${nl}設定する場所：$($s.Target)${nl}ICO：$($s.Icon)"
    if($s.Kind -eq 'Folder'){return @{Message="このフォルダのアイコンを『$($s.IconName)』に変えるよ。${nl}中に入っているファイルはそのままです。$details";Accept='このアイコンにする';Cancel='やめる';Remember=$false}}
    if($s.Kind -eq 'Shortcut'){return @{Message="このショートカットのアイコンを『$($s.IconName)』に変えるよ。${nl}リンク先のファイルはそのままです。$details";Accept='このアイコンにする';Cancel='やめる';Remember=$false}}
    return @{Message="このアイコンでショートカットを作るよ。${nl}${nl}アイコン：$($s.Number)番 $($s.IconName)${nl}元のファイル：$($s.Target)${nl}保存先：$($s.DestinationDirectory)${nl}名前：$($s.Arguments.ShortcutName).lnk";Accept='ショートカットを作る';Cancel='やめる';Remember=$false}
}
