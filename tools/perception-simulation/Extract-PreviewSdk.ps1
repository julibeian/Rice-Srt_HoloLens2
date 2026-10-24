$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot 'PerceptionSimulation-preview.msi'
$destination=Join-Path $PSScriptRoot 'preview-extracted'
$signature=Get-AuthenticodeSignature -LiteralPath $source
if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '^CN=Microsoft Corporation,'){throw 'The Microsoft installer signature is not valid.'}
if((Get-FileHash -LiteralPath $source).Hash -ne 'E2873EB2633477AE32430D0A566FE5612AA45BF5552B95B83A20C78B518A1B8E'){throw 'The preview installer differs from the verified 3.0.24.0 package.'}
if(-not('PerceptionMsiRead' -as [type])){Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
public static class PerceptionMsiRead {
 [DllImport("msi.dll",CharSet=CharSet.Unicode)] static extern uint MsiOpenDatabase(string path,IntPtr mode,out uint db);
 [DllImport("msi.dll",CharSet=CharSet.Unicode)] static extern uint MsiDatabaseOpenView(uint db,string query,out uint view);
 [DllImport("msi.dll")] static extern uint MsiViewExecute(uint view,uint record);
 [DllImport("msi.dll")] static extern uint MsiViewFetch(uint view,out uint record);
 [DllImport("msi.dll")] static extern uint MsiCloseHandle(uint handle);
 [DllImport("msi.dll")] static extern uint MsiRecordGetFieldCount(uint record);
 [DllImport("msi.dll",CharSet=CharSet.Unicode)] static extern uint MsiRecordGetString(uint record,uint field,StringBuilder text,ref uint length);
 [DllImport("msi.dll")] static extern uint MsiRecordReadStream(uint record,uint field,byte[] bytes,ref uint length);
 static void Check(uint n){if(n!=0)throw new InvalidOperationException("MSI read error "+n);}
 public static string[][] Query(string path,string sql){
  uint db=0,view=0,record=0;var rows=new List<string[]>();
  try{Check(MsiOpenDatabase(path,IntPtr.Zero,out db));Check(MsiDatabaseOpenView(db,sql,out view));Check(MsiViewExecute(view,0));
   uint status;while((status=MsiViewFetch(view,out record))==0){try{var row=new string[MsiRecordGetFieldCount(record)];for(uint i=1;i<=row.Length;i++){uint n=4096;var b=new StringBuilder((int)n);Check(MsiRecordGetString(record,i,b,ref n));row[i-1]=b.ToString();}rows.Add(row);}finally{MsiCloseHandle(record);record=0;}}if(status!=259)Check(status);
  }finally{if(record!=0)MsiCloseHandle(record);if(view!=0)MsiCloseHandle(view);if(db!=0)MsiCloseHandle(db);}return rows.ToArray();
 }
 public static void Export(string path,string name,string output){
  if(name.IndexOf('\'')>=0)throw new ArgumentException("Invalid MSI stream name");uint db=0,view=0,record=0;
  try{Check(MsiOpenDatabase(path,IntPtr.Zero,out db));Check(MsiDatabaseOpenView(db,"SELECT `Data` FROM `_Streams` WHERE `Name`='"+name+"'",out view));Check(MsiViewExecute(view,0));Check(MsiViewFetch(view,out record));using(var file=new FileStream(output,FileMode.CreateNew)){byte[] b=new byte[65536];while(true){uint n=(uint)b.Length;Check(MsiRecordReadStream(record,1,b,ref n));if(n==0)break;file.Write(b,0,(int)n);}}}
  finally{if(record!=0)MsiCloseHandle(record);if(view!=0)MsiCloseHandle(view);if(db!=0)MsiCloseHandle(db);}
 }
}
'@}
[IO.Directory]::CreateDirectory($destination)|Out-Null
$raw=Join-Path $destination 'raw'
[IO.Directory]::CreateDirectory($raw)|Out-Null
$media=[PerceptionMsiRead]::Query($source,'SELECT `Cabinet` FROM `Media`')
foreach($m in $media){
 if(-not $m[0].StartsWith('#')){throw 'Only installer-embedded cabinets are accepted.'}
 $name=$m[0].Substring(1)
 $cab=Join-Path $destination $name
 if(-not(Test-Path -LiteralPath $cab)){[PerceptionMsiRead]::Export($source,$name,$cab)}
 & expand.exe '-F:*' $cab $raw *> (Join-Path $destination ($name+'.expand.log'))
 if($LASTEXITCODE -ne 0){throw 'Embedded cabinet extraction failed.'}
}
$directories=@{}
foreach($row in [PerceptionMsiRead]::Query($source,'SELECT `Directory`,`Directory_Parent`,`DefaultDir` FROM `Directory`')){$directories[$row[0]]=@{Parent=$row[1];Name=$row[2]}}
$components=@{}
foreach($row in [PerceptionMsiRead]::Query($source,'SELECT `Component`,`Directory_` FROM `Component`')){$components[$row[0]]=$row[1]}
function Resolve-PreviewDirectory([string]$Key){
 if(-not $Key -or $Key -eq 'TARGETDIR'){return (Join-Path $destination 'files')}
 $entry=$directories[$Key];if(-not $entry){throw 'Unknown MSI directory.'}
 $parent=Resolve-PreviewDirectory $entry.Parent
 $name=($entry.Name.Split(':')[0].Split('|')|Select-Object -Last 1)
 if($name -in @('.','SourceDir')){return $parent}
 if($name -match '[\\/:]' -or $name -eq '..'){throw 'Unexpected installer path component.'}
 Join-Path $parent $name
}
$count=0
foreach($row in [PerceptionMsiRead]::Query($source,'SELECT `File`,`Component_`,`FileName` FROM `File`')){
 $file=Join-Path $raw $row[0];if(-not(Test-Path -LiteralPath $file)){throw ('Missing extracted file '+$row[0])}
 $folder=Resolve-PreviewDirectory $components[$row[1]]
 [IO.Directory]::CreateDirectory($folder)|Out-Null
 $name=$row[2].Split('|')|Select-Object -Last 1
 if($name -match '[\\/:]' -or $name -eq '..'){throw 'Unexpected installer filename.'}
 Copy-Item -LiteralPath $file -Destination (Join-Path $folder $name) -Force
 $count++
}
[ordered]@{Installer=$source;Destination=$destination;Files=$count;Installed=$false;DriversChanged=$false;Product=@([PerceptionMsiRead]::Query($source,"SELECT ``Property``,``Value`` FROM ``Property`` WHERE ``Property``='ProductVersion' OR ``Property``='ProductName'"))}|ConvertTo-Json -Depth 5
