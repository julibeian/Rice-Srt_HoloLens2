param([Parameter(Mandatory)][string]$BuildDirectory)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot;$workspace=Split-Path -Parent $root
$build=Get-Content -LiteralPath (Join-Path $BuildDirectory 'build-evidence.json') -Raw|ConvertFrom-Json
if($build.architecture -cne 'x64' -or (Get-FileHash -LiteralPath $build.dll).Hash -cne $build.dll_sha256){throw 'Use an unchanged x64 build for the local ABI test.'}
foreach($source in $build.files){if((Get-FileHash -LiteralPath (Join-Path $workspace $source.path)).Hash -cne $source.sha256){throw 'Native source differs from the x64 build; rebuild before testing.'}}
$vc='C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.44.35207';$sdk='C:\Program Files (x86)\Windows Kits\10'
$includes=@('-isystem',(Join-Path $vc 'include'));foreach($part in @('um','shared','ucrt','winrt')){$includes+=@('-isystem',(Join-Path $sdk ('Include\10.0.26100.0\'+$part)))}
$env:ZIG_GLOBAL_CACHE_DIR=Join-Path $workspace 'capture-app\device-research\.cache\zig-global';$env:ZIG_LOCAL_CACHE_DIR=Join-Path $workspace 'capture-app\device-research\.cache\zig-local'
$object=Join-Path $BuildDirectory 'ScreenNative.Abi.obj';$exe=Join-Path $BuildDirectory 'ScreenNative.Abi.exe'
& (Join-Path $workspace '.tools\zig-pypi\ziglang\zig.exe') cc -target x86_64-windows-msvc -O2 -std=c11 -fno-stack-protector -fno-builtin -nostdlib -Wall -Wextra -Werror @includes -I $BuildDirectory -c (Join-Path $root 'tests\ScreenNative.Abi.c') -o $object *> (Join-Path $BuildDirectory 'abi-compile.log')
if($LASTEXITCODE -ne 0){throw ('ABI test compilation failed: '+$BuildDirectory)}
$libRoot=Join-Path $sdk 'Lib\10.0.26100.0\um\x64'
& (Join-Path $vc 'bin\Hostx64\x64\link.exe') /nologo /NODEFAULTLIB /MACHINE:X64 /SUBSYSTEM:CONSOLE /ENTRY:screen_native_abi_entry /DYNAMICBASE /NXCOMPAT $object (Join-Path $libRoot 'OneCore.lib') (Join-Path $libRoot 'shell32.lib') ('/OUT:'+$exe) *> (Join-Path $BuildDirectory 'abi-link.log')
if($LASTEXITCODE -ne 0){throw ('ABI test linking failed: '+$BuildDirectory)}
$start=[Diagnostics.ProcessStartInfo]::new($exe);$start.ArgumentList.Add($build.dll);$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
$process=[Diagnostics.Process]::new();$process.StartInfo=$start
try{
 if(-not $process.Start()){throw 'ABI test did not start'}
 $output=$process.StandardOutput.ReadToEndAsync();$errors=$process.StandardError.ReadToEndAsync()
 if(-not $process.WaitForExit(30000)){$process.Kill();throw 'ABI test exceeded 30-second observation budget; stopped its own process'}
 $stdout=$output.GetAwaiter().GetResult();$stderr=$errors.GetAwaiter().GetResult()
 [IO.File]::WriteAllText((Join-Path $BuildDirectory 'abi-output.json'),$stdout,[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText((Join-Path $BuildDirectory 'abi-stderr.txt'),$stderr)
 if($process.ExitCode -ne 0){throw ('ABI test exit '+$process.ExitCode)}
 $proof=$stdout|ConvertFrom-Json
 if(-not $proof.abi_pass -or $proof.inspection.component_protocol -ne 2 -or $proof.picker_requests -ne 0 -or $proof.inspection.active -or $proof.inspection.capture_started -or $proof.after_invalid_requests.active -or $proof.after_invalid_requests.capture_started){throw 'ABI test protocol mismatch or unexpected operation'}
 $proof|Add-Member -NotePropertyName dll_sha256 -NotePropertyValue $build.dll_sha256
 $proof|Add-Member -NotePropertyName evidence_at -NotePropertyValue ([DateTimeOffset]::Now.ToString('o'))
}finally{$process.Dispose()}
$cancelObject=Join-Path $BuildDirectory 'ScreenNative.Cancellation.obj';$cancelExe=Join-Path $BuildDirectory 'ScreenNative.Cancellation.exe'
& (Join-Path $workspace '.tools\zig-pypi\ziglang\zig.exe') cc -target x86_64-windows-msvc -O2 -std=c11 -fno-stack-protector -fno-builtin -nostdlib -Wall -Wextra -Werror @includes -I (Join-Path $root 'screen-probe') -I $BuildDirectory -c (Join-Path $root 'tests\ScreenNative.Cancellation.c') -o $cancelObject *> (Join-Path $BuildDirectory 'cancel-compile.log')
if($LASTEXITCODE -ne 0){throw ('Cancellation test compilation failed: '+$BuildDirectory)}
& (Join-Path $vc 'bin\Hostx64\x64\link.exe') /nologo /NODEFAULTLIB /MACHINE:X64 /SUBSYSTEM:CONSOLE /ENTRY:screen_native_cancellation_entry /DYNAMICBASE /NXCOMPAT /OPT:REF $cancelObject (Join-Path $libRoot 'WindowsApp.lib') (Join-Path $libRoot 'd3d11.lib') ('/OUT:'+$cancelExe) *> (Join-Path $BuildDirectory 'cancel-link.log')
if($LASTEXITCODE -ne 0){throw ('Cancellation test linking failed: '+$BuildDirectory)}
$start=[Diagnostics.ProcessStartInfo]::new($cancelExe);$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
$process=[Diagnostics.Process]::new();$process.StartInfo=$start
try{
 if(-not $process.Start()){throw 'Cancellation test did not start'}
 $output=$process.StandardOutput.ReadToEndAsync();$errors=$process.StandardError.ReadToEndAsync()
 if(-not $process.WaitForExit(30000)){$process.Kill();throw 'Cancellation test exceeded 30 seconds; stopped its own process'}
 $stdout=$output.GetAwaiter().GetResult();$stderr=$errors.GetAwaiter().GetResult()
 [IO.File]::WriteAllText((Join-Path $BuildDirectory 'cancel-output.json'),$stdout,[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText((Join-Path $BuildDirectory 'cancel-stderr.txt'),$stderr)
 if($process.ExitCode -ne 0){throw ('Cancellation test exit '+$process.ExitCode)}
 $cancellation=$stdout|ConvertFrom-Json
 if(-not $cancellation.pass -or $cancellation.picker_ui_created -or $cancellation.real_capture_sessions -ne 0){throw 'Cancellation regression did not pass'}
 $proof|Add-Member -NotePropertyName cancellation -NotePropertyValue $cancellation
 $proof|ConvertTo-Json -Depth 10
}finally{$process.Dispose()}
