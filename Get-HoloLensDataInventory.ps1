param([string]$OutputDirectory,[int]$MaximumEntries=20000,[int]$MaximumSeconds=120)
. (Join-Path $PSScriptRoot 'HoloLens.Common.ps1')
function Get-HlInventorySum($Items,[string]$Property){
    [long]$total=0
    foreach($item in $Items){if($null -ne $item[$Property]){$total+=[long]$item[$Property]}}
    return $total
}
if(-not $OutputDirectory){$OutputDirectory=Join-Path $PSScriptRoot ('reports\'+[DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmss')+'-data')}
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($OutputDirectory)|Out-Null
$shellApplication=New-Object -ComObject Shell.Application
$deviceItems=@($shellApplication.NameSpace(17).Items()|Where-Object Name -eq $script:HlConfig.DeviceName)
if($deviceItems.Count -ne 1){throw 'Expected one connected target HoloLens in USB file transfer.'}
$storageItems=@($deviceItems[0].GetFolder.Items()|Where-Object Name -eq 'Internal Storage')
if($storageItems.Count -ne 1){throw 'The HoloLens USB internal storage is not available.'}
$storageItem=$storageItems[0]
$rootItems=@($storageItem.GetFolder.Items())
$capacity=[long]$storageItem.ExtendedProperty('System.Capacity')
$free=[long]$storageItem.ExtendedProperty('System.FreeSpace')
$entries=[Collections.Generic.List[object]]::new()
$errors=[Collections.Generic.List[object]]::new()
$summaries=[Collections.Generic.List[object]]::new()
$clock=[Diagnostics.Stopwatch]::StartNew()
$complete=$true
$roots=@('Documents','Music','Videos','Pictures','3D Objects','Downloads')
foreach($rootName in $roots){
    $root=@($rootItems|Where-Object Name -eq $rootName)
    if($root.Count -ne 1){$errors.Add(@{Path=$rootName;Error='Not exposed over USB MTP'});$complete=$false;continue}
    $pending=[Collections.Generic.Stack[object]]::new()
    $pending.Push(@{Item=$root[0];Path=$rootName;Depth=0})
    while($pending.Count){
        if($entries.Count -ge $MaximumEntries -or $clock.Elapsed.TotalSeconds -ge $MaximumSeconds){$complete=$false;break}
        $folder=$pending.Pop()
        try{$children=@($folder.Item.GetFolder.Items())}catch{$errors.Add(@{Path=$folder.Path;Error=$_.Exception.Message});$complete=$false;continue}
        foreach($child in $children){
            if($entries.Count -ge $MaximumEntries -or $clock.Elapsed.TotalSeconds -ge $MaximumSeconds){$complete=$false;break}
            $relative=$folder.Path+'\'+$child.Name
            $size=$null;$date=$null
            try{if(-not $child.IsFolder){$size=$child.ExtendedProperty('System.Size')};$date=$child.ExtendedProperty('System.DateModified')}catch{$errors.Add(@{Path=$relative;Error='Some metadata unavailable'})}
            $entries.Add([ordered]@{Path=$relative;Root=$rootName;Name=$child.Name;IsFolder=[bool]$child.IsFolder;SizeBytes=$size;Modified=$date;ShellMetadataFile=($child.Name -in @('desktop.ini','Thumbs.db'));Extension=if($child.IsFolder){$null}else{[IO.Path]::GetExtension($child.Name).ToLowerInvariant()}})
            if($child.IsFolder){
                if($folder.Depth -ge 20){$complete=$false;$errors.Add(@{Path=$relative;Error='Depth limit reached'})}
                else{$pending.Push(@{Item=$child;Path=$relative;Depth=($folder.Depth+1)})}
            }
        }
    }
    $files=@($entries|Where-Object {$_.Root -eq $rootName -and -not $_.IsFolder})
    $content=@($files|Where-Object {-not $_.ShellMetadataFile})
    $summary=[ordered]@{Folder=$rootName;Files=$files.Count;ContentFiles=$content.Count;ContentBytes=(Get-HlInventorySum $content 'SizeBytes');UnknownSizeFiles=@($content|Where-Object {$null -eq $_.SizeBytes}).Count;Directories=@($entries|Where-Object {$_.Root -eq $rootName -and $_.IsFolder}).Count}
    $summaries.Add($summary)
    $summary|ConvertTo-Json -Compress|Write-Output
}
$rootFiles=@($rootItems|Where-Object {-not $_.IsFolder}|ForEach-Object{[ordered]@{Name=$_.Name;SizeBytes=$_.ExtendedProperty('System.Size')}})
$privateVisibility=@(foreach($privateRoot in @('Application Data','Local Settings','Cookies','Favorites')){
    $privateItem=@($rootItems|Where-Object Name -eq $privateRoot)
    if($privateItem.Count -eq 1){try{[ordered]@{Folder=$privateRoot;MtpTopLevelItems=@($privateItem[0].GetFolder.Items()).Count;Conclusion='MTP view only; an empty listing does not establish absence of private data'}}catch{[ordered]@{Folder=$privateRoot;Error=$_.Exception.Message}}}
})
$device=Invoke-HlBridge @{action='info'}
$rawPackages=& (Join-Path $script:HlConfig.SdkDirectory 'WinAppDeployCmd.exe') list -ip $device.Address
if($LASTEXITCODE -ne 0){throw 'Current SDK package enumeration failed.'}
$packages=@($rawPackages|Where-Object{$_ -match '^\S+_\d+\.\d+\.\d+\.\d+_'})
[IO.File]::WriteAllLines((Join-Path $OutputDirectory 'installed-packages.txt'),[string[]]$packages,[Text.UTF8Encoding]::new($false))
$toolFiles=@()
try{
    $toolDirectory=Invoke-HlBridge @{action='ls';path=$script:HlConfig.RemoteWorkingDirectory}
    $toolFiles=@(foreach($toolFile in $toolDirectory.Entries|Where-Object Type -eq 'File'){Invoke-HlBridge @{action='stat';path=$toolFile.Path}})
}catch{$errors.Add(@{Path=$script:HlConfig.RemoteWorkingDirectory;Error=$_.Exception.Message})}
$report=[ordered]@{
    CapturedAt=[DateTimeOffset]::Now.ToString('o');Device=$script:HlConfig.DeviceName;MetadataOnly=$true;PersonalFileBodiesOpened=$false
    Storage=[ordered]@{CapacityBytes=$capacity;FreeBytes=$free;UsedBytes=($capacity-$free)}
    LibraryScopeComplete=$complete;LibraryScope=$roots;LibrarySummaries=$summaries.ToArray();FilesAndDirectories=$entries.ToArray()
    UserProfileRootFiles=$rootFiles;PrivateAppDataVisibility=$privateVisibility;InstalledPackageCount=$packages.Count;InstalledPackages=$packages;ConnectionToolFiles=$toolFiles;Errors=$errors.ToArray()
    Limitations=@('MTP only exposes selected user-profile paths; it is not a complete device filesystem inventory.','Private app state, maps, cached credentials, browser data and protected system data have not been fully inventoried.','Reported storage usage must not be interpreted as the size of personal files.','No backup or copying of personal file contents was performed.')
}
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'data-inventory.json'),($report|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
$entries|Where-Object {-not $_.IsFolder}|ForEach-Object{[pscustomobject]$_}|Export-Csv -LiteralPath (Join-Path $OutputDirectory 'user-file-metadata.csv') -NoTypeInformation -Encoding utf8BOM
$contentFiles=@($entries|Where-Object {-not $_.IsFolder -and -not $_.ShellMetadataFile})
[ordered]@{ReportDirectory=$OutputDirectory;Storage=$report.Storage;LibraryScopeComplete=$complete;ContentFileCount=$contentFiles.Count;ContentBytes=(Get-HlInventorySum $contentFiles 'SizeBytes');LargestFiles=@($contentFiles|Sort-Object {[long]$_.SizeBytes} -Descending|Select-Object -First 12);InstalledPackageCount=$packages.Count;ConnectionToolBytes=(Get-HlInventorySum $toolFiles 'Length');Errors=$errors.ToArray()}|ConvertTo-Json -Depth 6
