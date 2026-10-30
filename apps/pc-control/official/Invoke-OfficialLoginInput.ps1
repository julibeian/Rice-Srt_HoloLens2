param(
    [Parameter(Mandatory)][ValidateSet('Inspect','Username','Password','Submit')][string]$Mode,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$RunId,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$LeaseRunId,
    [string]$ObservedPortalAddress,
    [ValidateSet('Unicode','Clipboard')][string]$InputMethod='Unicode',
    [switch]$AccountFieldVisuallyVerified,
    [switch]$PasswordFieldVisuallyVerified
)
$ErrorActionPreference='Stop'
if($Mode -in @('Password','Submit') -and -not $AccountFieldVisuallyVerified){throw 'The account field must be visually verified before any password is sent.'}
if($Mode -eq 'Submit' -and -not $PasswordFieldVisuallyVerified){throw 'The password field must be visually verified before submitting the official dialog.'}
$workspace=Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$folder=Join-Path $workspace ('apps/pc-control/.state/official-tests/'+$RunId)
[IO.Directory]::CreateDirectory($folder)|Out-Null
$checkpoint=Join-Path $folder ($Mode+'.json')
if(Test-Path -LiteralPath $checkpoint){Get-Content -LiteralPath $checkpoint -Raw;return}
$metadata=& (Join-Path $PSScriptRoot 'Inspect-OfficialWindows.ps1') -MetadataOnly|ConvertFrom-Json
if($metadata.InputDesktop -cne 'Default'){throw 'The normal desktop is not available.'}
$official=@(Get-Process -Name PerceptionSimulationControl)
if($official.Count -ne 1 -or $official[0].Path -cne (Join-Path $env:ProgramFiles 'Microsoft Perception Simulation/Control/PerceptionSimulationControl.exe')){throw 'Official application identity mismatch.'}
if((Get-FileHash -LiteralPath $official[0].Path).Hash -cne 'B31AA8177BE97AF20D0B3C97E59BB3AD169082920C86CB6BFF0BC0B2F8DDA09D'){throw 'Unexpected official executable.'}
$dialogs=@($metadata.Windows|Where-Object {$_.Window.Visible -and $_.Window.ClassName -ceq 'Credential Dialog Xaml Host' -and $_.Window.Owner -eq $official[0].MainWindowHandle.ToInt64()})
if($dialogs.Count -ne 1){throw 'The official application does not have one owned authentication dialog.'}
$dialog=[IntPtr]$dialogs[0].Window.Handle
if(-not ('OfficialLoginInput' -as [type])){
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class OfficialLoginInput {
    [StructLayout(LayoutKind.Sequential)]struct Mouse {public int x,y;public uint data,flags,time;public IntPtr extra;}
    [StructLayout(LayoutKind.Sequential)]struct Key {public ushort vk,scan;public uint flags,time;public IntPtr extra;}
    [StructLayout(LayoutKind.Explicit)]struct Payload {[FieldOffset(0)]public Mouse mouse;[FieldOffset(0)]public Key key;}
    [StructLayout(LayoutKind.Sequential)]struct Input {public uint type;public Payload data;}
    [StructLayout(LayoutKind.Sequential)]public struct Rect {public int Left,Top,Right,Bottom;}
    [DllImport("user32.dll")]static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")]static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]static extern bool GetWindowRect(IntPtr hwnd,out Rect rect);
    [DllImport("user32.dll")]static extern bool SetCursorPos(int x,int y);
    [DllImport("user32.dll",SetLastError=true)]static extern uint SendInput(uint count,Input[] inputs,int size);
    public static object Focus(IntPtr hwnd){SetForegroundWindow(hwnd);System.Threading.Thread.Sleep(150);Rect rect;if(!GetWindowRect(hwnd,out rect))throw new InvalidOperationException();return new {Foreground=(GetForegroundWindow()==hwnd),Bounds=rect};}
    static void Require(IntPtr hwnd){if(GetForegroundWindow()!=hwnd)throw new InvalidOperationException("Official authentication dialog is not foreground; no input sent.");}
    static void Send(Input[] events){if(SendInput((uint)events.Length,events,Marshal.SizeOf(typeof(Input)))!=events.Length)throw new InvalidOperationException("Input was not accepted.");}
    public static void Click(IntPtr hwnd,double x,double y){Require(hwnd);Rect r;if(!GetWindowRect(hwnd,out r))throw new InvalidOperationException();SetCursorPos(r.Left+(int)((r.Right-r.Left)*x),r.Top+(int)((r.Bottom-r.Top)*y));Send(new[]{new Input{type=0,data=new Payload{mouse=new Mouse{flags=2}}},new Input{type=0,data=new Payload{mouse=new Mouse{flags=4}}}});System.Threading.Thread.Sleep(120);Require(hwnd);}
    public static int Text(IntPtr hwnd,string value){Require(hwnd);var events=new Input[value.Length*2];for(int i=0;i<value.Length;i++){events[2*i]=new Input{type=1,data=new Payload{key=new Key{scan=value[i],flags=4}}};events[2*i+1]=new Input{type=1,data=new Payload{key=new Key{scan=value[i],flags=6}}};}Send(events);return events.Length;}
    public static void Enter(IntPtr hwnd){Require(hwnd);Send(new[]{new Input{type=1,data=new Payload{key=new Key{vk=13}}},new Input{type=1,data=new Payload{key=new Key{vk=13,flags=2}}}});}
    public static void Paste(IntPtr hwnd){Require(hwnd);Send(new[]{new Input{type=1,data=new Payload{key=new Key{vk=17}}},new Input{type=1,data=new Payload{key=new Key{vk=86}}},new Input{type=1,data=new Payload{key=new Key{vk=86,flags=2}}},new Input{type=1,data=new Payload{key=new Key{vk=17,flags=2}}}});}
}
'@
}
$focus=[OfficialLoginInput]::Focus($dialog)
if($Mode -eq 'Inspect'){$focus|ConvertTo-Json -Depth 3;return}
if(-not $focus.Foreground){throw 'Official authentication dialog could not be focused; no input sent.'}
. (Join-Path $workspace 'apps/holographic-control/ops/Holographic.Common.ps1')
$context=New-HoloAuthenticatedPortalContext
try{
    $lease=& (Join-Path $workspace 'apps/holographic-control/ops/Control-Lease.ps1') -Mode Status -RunId $LeaseRunId|ConvertFrom-Json
    if(-not $lease.Active){throw 'The named device guard is no longer active.'}
    if($ObservedPortalAddress -cne $context.Device.Address){throw 'The visually observed portal target does not match the verified USB peer.'}
    $focus=[OfficialLoginInput]::Focus($dialog)
    if(-not $focus.Foreground){throw 'Official authentication focus changed; no input sent.'}
    $proof=[ordered]@{At=[DateTimeOffset]::Now.ToString('o');RunId=$RunId;Mode=$Mode;LeaseRunId=$LeaseRunId;OfficialPid=$official[0].Id;DialogPid=$dialogs[0].Window.ProcessId;DialogOwnedByOfficial=$true;ObservedPortalAddress=$ObservedPortalAddress;InputAttempted=$true;CredentialsLogged=$false}
    $proof.InputMethod=$InputMethod
    $proof.VisualEffectVerified=$false
    [IO.File]::WriteAllText($checkpoint,($proof|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    if($Mode -eq 'Submit'){[OfficialLoginInput]::Enter($dialog)}else{
        $saved=Import-Clixml -LiteralPath (Join-Path $workspace 'apps/holographic-control/.state/portal-credential.clixml')
        $network=$saved.Credential.GetNetworkCredential()
        $value=if($Mode -eq 'Username'){$network.UserName}else{$network.Password}
        [OfficialLoginInput]::Click($dialog,.5,$(if($Mode -eq 'Username'){.5}else{.65625}))
        if($InputMethod -eq 'Clipboard'){
            Add-Type -AssemblyName System.Windows.Forms
            try{[Windows.Forms.Clipboard]::SetText($value);[OfficialLoginInput]::Paste($dialog);Start-Sleep -Milliseconds 700}
            finally{if([Windows.Forms.Clipboard]::ContainsText() -and [Windows.Forms.Clipboard]::GetText() -ceq $value){[Windows.Forms.Clipboard]::Clear()}}
        }else{$null=[OfficialLoginInput]::Text($dialog,$value)}
        $value=$null
        $network=$null;$saved=$null
    }
    $proof.InputAccepted=$true
    [IO.File]::WriteAllText($checkpoint,($proof|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    $proof|ConvertTo-Json
}finally{$context.Client.Dispose()}
