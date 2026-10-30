param([switch]$DesktopShortcut)
$ErrorActionPreference='Stop'
$frameworkRelease=(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Release -ErrorAction Stop).Release
if($frameworkRelease -lt 528040){throw 'The desktop controller requires .NET Framework 4.8 or newer for per-monitor DPI support.'}
$workspace=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$output=Join-Path $PSScriptRoot 'dist'
[IO.Directory]::CreateDirectory($output)|Out-Null
$videoTool=(Get-Command ffmpeg -ErrorAction Stop).Source
$runtime=@{Ffmpeg=$videoTool;BuiltAt=[DateTimeOffset]::Now.ToString('o')}
[IO.File]::WriteAllText((Join-Path $output 'runtime.json'),($runtime|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
$exe=Join-Path $output 'RiceHoloLensControl.exe'
$sources=@('desktop\AssemblyInfo.cs','desktop\ApplicationIdentity.cs','desktop\VideoFrames.cs','desktop\SessionJournal.cs','desktop\OperationProcess.cs','desktop\PointerGeometry.cs','desktop\DeviceSession.cs','desktop\MainForm.cs')|ForEach-Object {Join-Path $PSScriptRoot $_}
& (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe') /nologo /codepage:65001 /target:winexe /platform:x86 /optimize+ /r:System.Drawing.dll /r:System.Windows.Forms.dll /r:System.Web.Extensions.dll ('/win32manifest:'+(Join-Path $PSScriptRoot 'desktop\app.manifest')) ('/out:'+$exe) @sources
if($LASTEXITCODE -ne 0){throw 'Desktop controller build failed.'}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'desktop\App.config') -Destination ($exe+'.config') -Force
if($DesktopShortcut){
    $desktop=[Environment]::GetFolderPath('Desktop')
    $shell=New-Object -ComObject WScript.Shell
    $shortcut=$shell.CreateShortcut((Join-Path $desktop '稻视界眼镜控制.lnk'))
    $shortcut.TargetPath=$exe;$shortcut.WorkingDirectory=$workspace;$shortcut.Description='查看并控制本机已配对的 HoloLens';$shortcut.Save()
}
Get-FileHash -LiteralPath $exe | Select-Object Path,Hash | ConvertTo-Json -Compress
