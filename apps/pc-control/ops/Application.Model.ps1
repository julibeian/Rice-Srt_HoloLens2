function ConvertTo-Phase2Application {
    param([Parameter(Mandatory)]$Package)
    $aumid=[string]$Package.PackageRelativeId;$fullName=[string]$Package.PackageFullName
    $match=[regex]::Match($fullName,'^(?<name>[A-Za-z0-9][A-Za-z0-9.-]{2,})_(?<version>\d+\.\d+\.\d+\.\d+)_(?<architecture>[A-Za-z0-9]+)_(?<resource>[A-Za-z0-9.-]*)_(?<publisher>[a-z0-9]{13})$')
    if(-not $match.Success){throw 'Package full name is missing or malformed.'}
    $identity=[regex]::Match($aumid,'^(?<family>[A-Za-z0-9][A-Za-z0-9._-]{1,250})!(?<application>[A-Za-z0-9._-]{1,128})$')
    if(-not $identity.Success){throw 'Enumerated application identity is missing or malformed.'}
    $family=$match.Groups['name'].Value+'_'+$match.Groups['publisher'].Value
    if($identity.Groups['family'].Value -cne $family){throw 'Application identity belongs to a different package.'}
    $name=[string]$Package.Name;if([string]::IsNullOrWhiteSpace($name)){$name=$aumid}
    [pscustomobject]@{Aumid=$aumid;PackageFullName=$fullName;PackageName=$match.Groups['name'].Value;Version=$match.Groups['version'].Value;DisplayName=$name;ActivationVerified=$false}
}
function Resolve-Phase2Application {
    param([Parameter(Mandatory)][object[]]$Applications,[Parameter(Mandatory)][string]$Aumid,[Parameter(Mandatory)][string]$PackageFullName)
    $found=@($Applications|Where-Object {$_.Aumid -ceq $Aumid -and $_.PackageFullName -ceq $PackageFullName})
    if($found.Count -ne 1){throw 'Selected application is absent, ambiguous or has changed version. Refresh the inventory.'}
    return $found[0]
}
