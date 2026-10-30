$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$output=Join-Path $root '.state\tests'
[IO.Directory]::CreateDirectory($output)|Out-Null
$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
& $compiler /nologo /codepage:65001 /target:exe /platform:x86 /optimize+ /r:System.Drawing.dll /r:System.Web.Extensions.dll ('/out:'+(Join-Path $output 'DeviceSmoke.exe')) (Join-Path $root 'desktop\ApplicationIdentity.cs') (Join-Path $root 'desktop\VideoFrames.cs') (Join-Path $root 'desktop\SessionJournal.cs') (Join-Path $root 'desktop\OperationProcess.cs') (Join-Path $root 'desktop\PointerGeometry.cs') (Join-Path $root 'desktop\DeviceSession.cs') (Join-Path $root 'tests\DeviceSmoke.cs')
if($LASTEXITCODE -ne 0){throw 'Backend smoke test build failed.'}
& $compiler /nologo /codepage:65001 /target:exe /platform:x86 /optimize+ /r:System.Drawing.dll ('/out:'+(Join-Path $output 'PointerTests.exe')) (Join-Path $root 'desktop\VideoFrames.cs') (Join-Path $root 'desktop\PointerGeometry.cs') (Join-Path $root 'tests\PointerTests.cs')
if($LASTEXITCODE -ne 0){throw 'Pointer test build failed.'}
& (Join-Path $output 'PointerTests.exe')
if($LASTEXITCODE -ne 0){throw 'Pointer test failed.'}
& $compiler /nologo /codepage:65001 /target:exe /platform:x86 /optimize+ ('/out:'+(Join-Path $output 'ApplicationIdentityTests.exe')) (Join-Path $root 'desktop\ApplicationIdentity.cs') (Join-Path $root 'tests\ApplicationIdentityTests.cs')
if($LASTEXITCODE -ne 0){throw 'Application identity test build failed.'}
& (Join-Path $output 'ApplicationIdentityTests.exe')
if($LASTEXITCODE -ne 0){throw 'Application identity test failed.'}
& $compiler /nologo /codepage:65001 /target:exe /platform:x86 /optimize+ /r:System.Drawing.dll ('/out:'+(Join-Path $output 'VideoFrameTests.exe')) (Join-Path $root 'desktop\VideoFrames.cs') (Join-Path $root 'desktop\PointerGeometry.cs') (Join-Path $root 'tests\VideoFrameTests.cs')
if($LASTEXITCODE -ne 0){throw 'Video frame test build failed.'}
& (Join-Path $output 'VideoFrameTests.exe')
if($LASTEXITCODE -ne 0){throw 'Video frame ownership or coordinate test failed.'}
& $compiler /nologo /codepage:65001 /target:exe /platform:x86 /optimize+ /r:System.Web.Extensions.dll ('/out:'+(Join-Path $output 'SessionJournalTests.exe')) (Join-Path $root 'desktop\SessionJournal.cs') (Join-Path $root 'tests\SessionJournalTests.cs')
if($LASTEXITCODE -ne 0){throw 'Journal test build failed.'}
& (Join-Path $output 'SessionJournalTests.exe')
if($LASTEXITCODE -ne 0){throw 'Async journal test failed.'}
& $compiler /nologo /codepage:65001 /target:exe /platform:x86 /optimize+ /r:System.Web.Extensions.dll ('/out:'+(Join-Path $output 'OperationProcessFixture.exe')) (Join-Path $root 'tests\OperationProcessFixture.cs')
if($LASTEXITCODE -ne 0){throw 'Local operation fixture build failed.'}
& $compiler /nologo /codepage:65001 /target:exe /platform:x86 /optimize+ /r:System.Web.Extensions.dll /r:System.Windows.Forms.dll ('/out:'+(Join-Path $output 'OperationProcessTests.exe')) (Join-Path $root 'desktop\OperationProcess.cs') (Join-Path $root 'tests\OperationProcessTests.cs')
if($LASTEXITCODE -ne 0){throw 'Operation deadline checks did not compile.'}
& (Join-Path $output 'OperationProcessTests.exe') (Join-Path $output 'OperationProcessFixture.exe') (Join-Path $output ('operation-cases-'+[Guid]::NewGuid().ToString('N')))
if($LASTEXITCODE -ne 0){throw 'Operation process deadline or pipe cleanup failed.'}
& (Join-Path $root 'tests\Video.Health.Model.Tests.ps1')
& (Join-Path $root 'tests\Video.SourceReader.Tests.ps1')
$layoutAssembly=Join-Path $output 'RiceHoloLensControl.Layout.dll'
$layoutSources=@('AssemblyInfo.cs','ApplicationIdentity.cs','VideoFrames.cs','SessionJournal.cs','OperationProcess.cs','PointerGeometry.cs','DeviceSession.cs','MainForm.cs')|ForEach-Object {Join-Path $root ('desktop\'+$_)}
& $compiler /nologo /codepage:65001 /target:library /platform:x86 /optimize+ /r:System.Drawing.dll /r:System.Windows.Forms.dll /r:System.Web.Extensions.dll ('/out:'+$layoutAssembly) @layoutSources
if($LASTEXITCODE -ne 0){throw 'Window layout assembly build failed.'}
& $compiler /nologo /codepage:65001 /target:exe /platform:x86 /optimize+ /r:System.Drawing.dll /r:System.Windows.Forms.dll ('/out:'+(Join-Path $output 'WindowLayoutTests.exe')) (Join-Path $root 'tests\WindowLayoutTests.cs')
if($LASTEXITCODE -ne 0){throw 'Window layout tests did not compile.'}
& (Join-Path $output 'WindowLayoutTests.exe') $layoutAssembly (Split-Path -Parent $root)
if($LASTEXITCODE -ne 0){throw 'Window layout regression failed.'}
