param(
    [Parameter(Mandatory)][ValidateSet('Dump','SelectTarget','SetHost','Commit','Click','RightClick','Drag','RightDrag','AltDrag','SlowDrag','Move','Key','ScrollTop','SetCheck','Capture','Status')][string]$Action,
    [ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$RunId='gui-probe',
    [string]$Target='HoloLens 2 (Legacy)',
    [string]$Value,
    [int]$X,
    [int]$Y,
    [int]$ToX,
    [int]$ToY,
    [switch]$Off,
    [string]$Name='capture'
)
# Read/write helper for the UNMODIFIED Microsoft Perception Simulation Control window.
# It never generates simulation packets or video frames; it only performs the same
# user-level actions a maintainer would perform and records what the window shows.
$ErrorActionPreference='Stop'
$expectedHash='B31AA8177BE97AF20D0B3C97E59BB3AD169082920C86CB6BFF0BC0B2F8DDA09D'
$expectedPath=Join-Path $env:ProgramFiles 'Microsoft Perception Simulation/Control/PerceptionSimulationControl.exe'
$workspace=Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$folder=Join-Path $workspace ('apps/pc-control/.state/official-window/'+$RunId)
[IO.Directory]::CreateDirectory($folder)|Out-Null

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing

if(-not ('OfficialWindowInput' -as [type])){
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;
public static class OfficialWindowInput {
 [StructLayout(LayoutKind.Sequential)]struct Mouse {public int x,y;public uint data,flags,time;public IntPtr extra;}
 [StructLayout(LayoutKind.Sequential)]struct Key {public ushort vk,scan;public uint flags,time;public IntPtr extra;}
 [StructLayout(LayoutKind.Explicit)]struct Payload {[FieldOffset(0)]public Mouse mouse;[FieldOffset(0)]public Key key;}
 [StructLayout(LayoutKind.Sequential)]struct Input {public uint type;public Payload data;}
 [StructLayout(LayoutKind.Sequential)]public struct Rect {public int Left,Top,Right,Bottom;}
 [DllImport("user32.dll")]static extern bool SetProcessDpiAwarenessContext(IntPtr value);
 [DllImport("user32.dll")]static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")]static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")]static extern bool ShowWindow(IntPtr h,int c);
 [DllImport("user32.dll")]static extern bool BringWindowToTop(IntPtr h);
 [DllImport("user32.dll")]static extern bool SetFocus(IntPtr h);
 [DllImport("user32.dll")]static extern uint GetWindowThreadProcessId(IntPtr h,IntPtr pid);
 [DllImport("user32.dll")]static extern bool AttachThreadInput(uint a,uint b,bool attach);
 [DllImport("kernel32.dll")]static extern uint GetCurrentThreadId();
 [DllImport("user32.dll")]static extern bool GetWindowRect(IntPtr h,out Rect rect);
 [DllImport("user32.dll")]static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")]static extern bool GetCursorPos(out System.Drawing.Point p);
 [DllImport("user32.dll",SetLastError=true)]static extern uint SendInput(uint count,Input[] inputs,int size);
 [DllImport("user32.dll")]static extern IntPtr OpenInputDesktop(uint flags,bool inherit,uint access);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)]static extern bool GetUserObjectInformation(IntPtr handle,int index,StringBuilder text,uint size,out uint required);
 [DllImport("user32.dll")]static extern bool CloseDesktop(IntPtr desktop);
 public static string InputDesktop(){var h=OpenInputDesktop(0,false,1);if(h==IntPtr.Zero)return "access_denied_"+Marshal.GetLastWin32Error();try{uint required;var name=new StringBuilder(256);return GetUserObjectInformation(h,2,name,512,out required)?name.ToString():"read_error_"+Marshal.GetLastWin32Error();}finally{CloseDesktop(h);}}
 public static string DpiAware(){return SetProcessDpiAwarenessContext(new IntPtr(-4))?"per_monitor_v2":"failed";}
 public static object Activate(IntPtr hwnd){
  if(GetForegroundWindow()==hwnd)return new {Foreground=true,Rect=Bounds(hwnd)};
  ShowWindow(hwnd,5);IntPtr fg=GetForegroundWindow();uint fgThread=fg==IntPtr.Zero?0:GetWindowThreadProcessId(fg,IntPtr.Zero);uint myThread=GetCurrentThreadId();bool attached=false;
  if(fgThread!=0&&fgThread!=myThread)attached=AttachThreadInput(myThread,fgThread,true);
  try{BringWindowToTop(hwnd);SetForegroundWindow(hwnd);SetFocus(hwnd);}finally{if(attached)AttachThreadInput(myThread,fgThread,false);}
  System.Threading.Thread.Sleep(250);
  return new {Foreground=(GetForegroundWindow()==hwnd),Rect=Bounds(hwnd)};
 }
 static Rect Bounds(IntPtr hwnd){Rect r;if(!GetWindowRect(hwnd,out r))throw new InvalidOperationException("Window bounds unavailable");return r;}
 public static Rect WindowRect(IntPtr hwnd){return Bounds(hwnd);}
 static void Require(IntPtr hwnd){if(GetForegroundWindow()!=hwnd)throw new InvalidOperationException("Window is not foreground; no input sent.");}
 static void Send(Input[] events){if(SendInput((uint)events.Length,events,Marshal.SizeOf(typeof(Input)))!=events.Length)throw new InvalidOperationException("Input was not accepted.");}
 public static object RightClick(IntPtr hwnd,int screenX,int screenY){
  Require(hwnd);if(!SetCursorPos(screenX,screenY))throw new InvalidOperationException("Cursor move failed");
  System.Threading.Thread.Sleep(120);
  Send(new[]{new Input{type=0,data=new Payload{mouse=new Mouse{flags=8}}},new Input{type=0,data=new Payload{mouse=new Mouse{flags=16}}}});
  System.Threading.Thread.Sleep(250);Require(hwnd);
  return new {RightClicked=true,X=screenX,Y=screenY};
 }
 public static object PressVk(IntPtr hwnd,int vk,int count){Require(hwnd);var events=new List<Input>();for(int i=0;i<count;i++){events.Add(new Input{type=1,data=new Payload{key=new Key{vk=(ushort)vk}}});events.Add(new Input{type=1,data=new Payload{key=new Key{vk=(ushort)vk,flags=2}}});}Send(events.ToArray());System.Threading.Thread.Sleep(250);return new {Vk=vk,Count=count};}
 public static object Move(IntPtr hwnd,int screenX,int screenY){Require(hwnd);if(!SetCursorPos(screenX,screenY))throw new InvalidOperationException("Cursor move failed");System.Threading.Thread.Sleep(200);return new {Moved=true,X=screenX,Y=screenY};}
 public static object Click(IntPtr hwnd,int screenX,int screenY){  Require(hwnd);if(!SetCursorPos(screenX,screenY))throw new InvalidOperationException("Cursor move failed");
  System.Threading.Thread.Sleep(120);
  Send(new[]{new Input{type=0,data=new Payload{mouse=new Mouse{flags=2}}},new Input{type=0,data=new Payload{mouse=new Mouse{flags=4}}}});
  System.Threading.Thread.Sleep(150);Require(hwnd);
  return new {Clicked=true,X=screenX,Y=screenY};
 }
 public static object AltDrag(IntPtr hwnd,int fromX,int fromY,int toX,int toY){
  Require(hwnd);SetCursorPos(fromX,fromY);System.Threading.Thread.Sleep(150);
  Send(new[]{new Input{type=1,data=new Payload{key=new Key{vk=18}}}});
  System.Threading.Thread.Sleep(120);
  Send(new[]{new Input{type=0,data=new Payload{mouse=new Mouse{flags=2}}}});
  const int steps=12;
  for(int i=1;i<=steps;i++){SetCursorPos(fromX+(toX-fromX)*i/steps,fromY+(toY-fromY)*i/steps);System.Threading.Thread.Sleep(50);}
  System.Threading.Thread.Sleep(120);
  Send(new[]{new Input{type=0,data=new Payload{mouse=new Mouse{flags=4}}}});
  System.Threading.Thread.Sleep(120);
  Send(new[]{new Input{type=1,data=new Payload{key=new Key{vk=18,flags=2}}}});
  System.Threading.Thread.Sleep(300);Require(hwnd);
  return new {AltDragged=true,Steps=steps};
 }
 public static object RightDrag(IntPtr hwnd,int fromX,int fromY,int toX,int toY){
  Require(hwnd);SetCursorPos(fromX,fromY);System.Threading.Thread.Sleep(150);
  Send(new[]{new Input{type=0,data=new Payload{mouse=new Mouse{flags=8}}}});
  const int steps=12;
  for(int i=1;i<=steps;i++){SetCursorPos(fromX+(toX-fromX)*i/steps,fromY+(toY-fromY)*i/steps);System.Threading.Thread.Sleep(50);}
  System.Threading.Thread.Sleep(150);
  Send(new[]{new Input{type=0,data=new Payload{mouse=new Mouse{flags=16}}}});
  System.Threading.Thread.Sleep(400);Require(hwnd);
  return new {RightDragged=true,Steps=steps};
 }
 public static object Drag(IntPtr hwnd,int fromX,int fromY,int toX,int toY){
  Require(hwnd);SetCursorPos(fromX,fromY);System.Threading.Thread.Sleep(150);
  Send(new[]{new Input{type=0,data=new Payload{mouse=new Mouse{flags=2}}}});
  const int steps=14;
  for(int i=1;i<=steps;i++){SetCursorPos(fromX+(toX-fromX)*i/steps,fromY+(toY-fromY)*i/steps);System.Threading.Thread.Sleep(45);}
  System.Threading.Thread.Sleep(150);
  Send(new[]{new Input{type=0,data=new Payload{mouse=new Mouse{flags=4}}}});
  System.Threading.Thread.Sleep(400);Require(hwnd);
  return new {Dragged=true,Steps=steps};
 }
 public static object SlowDrag(IntPtr hwnd,int fromX,int fromY,int toX,int toY){
  Require(hwnd);SetCursorPos(fromX,fromY);System.Threading.Thread.Sleep(300);
  Send(new[]{new Input{type=0,data=new Payload{mouse=new Mouse{flags=2}}}});
  System.Threading.Thread.Sleep(600);
  const int steps=30;
  for(int i=1;i<=steps;i++){SetCursorPos(fromX+(toX-fromX)*i/steps,fromY+(toY-fromY)*i/steps);System.Threading.Thread.Sleep(70);}
  System.Threading.Thread.Sleep(300);
  Send(new[]{new Input{type=0,data=new Payload{mouse=new Mouse{flags=4}}}});
  System.Threading.Thread.Sleep(500);Require(hwnd);
  return new {SlowDragged=true,Steps=steps};
 }
 public static object Enter(IntPtr hwnd){Require(hwnd);Send(new[]{new Input{type=1,data=new Payload{key=new Key{vk=13}}},new Input{type=1,data=new Payload{key=new Key{vk=13,flags=2}}}});System.Threading.Thread.Sleep(150);return new {Enter=true};}
}
"@
}
[void][OfficialWindowInput]::DpiAware()

$official=@(Get-Process -Name PerceptionSimulationControl -ErrorAction SilentlyContinue)
$withWindow=@($official|Where-Object{$_.MainWindowHandle -ne [IntPtr]::Zero})
if($withWindow.Count -eq 1){$process=$withWindow[0]}
elseif($official.Count -eq 1){$process=$official[0]}
else{throw "Expected one windowed official process, found $($official.Count) total and $($withWindow.Count) with a window."}
if($process.Path -ine $expectedPath){throw 'Official executable path mismatch.'}
if((Get-FileHash -LiteralPath $expectedPath).Hash -cne $expectedHash){throw 'Official executable hash mismatch.'}
if((Get-AuthenticodeSignature -LiteralPath $expectedPath).Status -ne 'Valid'){throw 'Official signature invalid.'}
$hwnd=$process.MainWindowHandle
if($hwnd -eq [IntPtr]::Zero){throw 'Official window handle unavailable.'}

$root=[System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
function Get-Root { [System.Windows.Automation.AutomationElement]::FromHandle($hwnd) }
function Get-AllControls { @((Get-Root).FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)) }
function Find-ById([string]$id){
    $condition=New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::AutomationIdProperty),$id
    for($i=0;$i -lt 10;$i++){
        $found=(Get-Root).FindFirst([System.Windows.Automation.TreeScope]::Descendants,$condition)
        if($found){return $found}
        Start-Sleep -Milliseconds 200
    }
    return $null
}
function Get-Combo { (Get-AllControls)|Where-Object{$_.Current.ControlType -eq [System.Windows.Automation.ControlType]::ComboBox}|Select-Object -First 1 }
function Get-Edit { Find-ById 'RemoteHostTextBox' }
function Get-Target {
    $combo=Get-Combo
    if(-not $combo){return $null}
    $selection=$combo.GetCurrentPattern([System.Windows.Automation.SelectionPattern]::Pattern)
    $items=$selection.Current.GetSelection()
    if(-not $items -or $items.Length -eq 0){return $null}
    return $items[0].Current.Name
}
function Get-Host {
    $edit=Get-Edit
    if(-not $edit){return $null}
    return $edit.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
}
function Get-StatusTexts {
    @(Get-AllControls|Where-Object{$_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Text -and $_.Current.Name -and $_.Current.BoundingRectangle.Height -gt 0}|ForEach-Object{[pscustomobject]@{Name=$_.Current.Name;Rect=$_.Current.BoundingRectangle.ToString()}})
}
function Get-PreviewRect {
    $element=Find-ById 'CameraPreview'
    if($element){$r=$element.Current.BoundingRectangle;if($r.Width -gt 0 -and $r.Height -gt 0){return $r}}
    return $null
}

$rect=[OfficialWindowInput]::WindowRect($hwnd)
$activation=$null
if($Action -ne 'Dump' -and $Action -ne 'Status' -and $Action -ne 'Capture'){$activation=[OfficialWindowInput]::Activate($hwnd);if(-not $activation.Foreground){throw 'Official window could not be brought to the foreground; no input sent.'}}

switch($Action){
    'Status' {
        $preview=Get-PreviewRect
        $result=[ordered]@{At=[DateTimeOffset]::Now.ToString('o');Administrative='read_only';ProcessId=$process.Id;WindowHandle=$hwnd.ToInt64();InputDesktop=[OfficialWindowInput]::InputDesktop();Target=(Get-Target);Host=(Get-Host);StatusTexts=(Get-StatusTexts);PreviewRect=if($preview){$preview|ForEach-Object{"$($_.X),$($_.Y),$($_.Width),$($_.Height)"}}else{$null};WindowRect="$($rect.Left),$($rect.Top),$($rect.Right-$rect.Left),$($rect.Bottom-$rect.Top)"}
    }
    'Dump' {
        $activation=[OfficialWindowInput]::Activate($hwnd)
        $result=[ordered]@{At=[DateTimeOffset]::Now.ToString('o');ProcessId=$process.Id;WindowHandle=$hwnd.ToInt64();Activation=$activation;InputDesktop=[OfficialWindowInput]::InputDesktop();Target=(Get-Target);Host=(Get-Host);StatusTexts=(Get-StatusTexts);Controls=@(Get-AllControls|ForEach-Object{[pscustomobject]@{Name=$_.Current.Name;Type=$_.Current.ControlType.ProgrammaticName;Id=$_.Current.AutomationId;Rect=$_.Current.BoundingRectangle.ToString();Enabled=$_.Current.IsEnabled}})}
    }
    'SelectTarget' {
        $combo=Get-Combo
        $expand=$combo.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
        if($expand.Current.ExpandCollapseState -ne 'Expanded'){$expand.Expand();Start-Sleep -Milliseconds 500}
        $item=(Get-AllControls)|Where-Object{$_.Current.ControlType -eq [System.Windows.Automation.ControlType]::ListItem -and $_.Current.Name -ceq $Target}|Select-Object -First 1
        if(-not $item){if($expand.Current.ExpandCollapseState -eq 'Expanded'){$expand.Collapse()};throw "Target '$Target' not found in the target list."}
        $selectionItem=$item.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
        $selectionItem.Select()
        Start-Sleep -Milliseconds 500
        if($expand.Current.ExpandCollapseState -eq 'Expanded'){$expand.Collapse()}
        Start-Sleep -Milliseconds 400
        $observed=Get-Target
        $result=[ordered]@{At=[DateTimeOffset]::Now.ToString('o');Requested=$Target;Observed=$observed;Matched=($observed -ceq $Target);Activation=$activation}
    }
    'SetHost' {
        if([string]::IsNullOrWhiteSpace($Value)){throw 'SetHost requires -Value.'}
        if($Value -notmatch '^[0-9A-Za-z\.\-]+:[0-9]{2,5}$'){throw 'SetHost expects host:port.'}
        $edit=Get-Edit
        $pattern=$edit.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
        $before=$pattern.Current.Value
        $pattern.SetValue($Value)
        Start-Sleep -Milliseconds 500
        $after=(Get-Host)
        $result=[ordered]@{At=[DateTimeOffset]::Now.ToString('o');Before=$before;Requested=$Value;Observed=$after;Matched=($after -ceq $Value);Activation=$activation}
    }
    'Commit' {
        $edit=Get-Edit
        $edit.SetFocus()
        Start-Sleep -Milliseconds 300
        $enter=[OfficialWindowInput]::Enter($hwnd)
        $result=[ordered]@{At=[DateTimeOffset]::Now.ToString('o');Target=(Get-Target);Host=(Get-Host);Enter=$enter;Activation=$activation;StatusTexts=(Get-StatusTexts)}
    }
    'SetCheck' {
        $element=(Get-AllControls)|Where-Object{$_.Current.Name -ceq $Name -and $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::CheckBox}|Select-Object -First 1
        if(-not $element){throw "Checkbox '$Name' not found."}
        $pattern=$element.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
        $before=$pattern.Current.ToggleState.ToString()
        $desired=if($Off){'Off'}else{'On'}
        if($before -ne $desired){$pattern.Toggle();Start-Sleep -Milliseconds 600}
        $after=$pattern.Current.ToggleState.ToString()
        $result=[ordered]@{At=[DateTimeOffset]::Now.ToString('o');Control=$Name;Before=$before;After=$after;Matched=($after -eq $desired)}
    }
    'ScrollTop' {
        $viewer=(Get-AllControls)|Where-Object{$_.Current.AutomationId -eq 'SimulationScrollViewer'}|Select-Object -First 1
        if(-not $viewer){throw 'SimulationScrollViewer not found.'}
        $pattern=$viewer.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
        $before=$pattern.Current.VerticalScrollPercent
        $pattern.SetScrollPercent([System.Windows.Automation.ScrollPattern]::NoScroll,0)
        Start-Sleep -Milliseconds 800
        $after=$pattern.Current.VerticalScrollPercent
        $result=[ordered]@{At=[DateTimeOffset]::Now.ToString('o');Before=$before;After=$after;Target=(Get-Target);Host=(Get-Host)}
    }
    'Key' {
        $activation=[OfficialWindowInput]::Activate($hwnd)
        if(-not $activation.Foreground){throw 'Official window could not be brought to the foreground; no key sent.'}
        $count=if($Y -gt 0){$Y}else{1}
        $press=[OfficialWindowInput]::PressVk($hwnd,$X,$count)
        Start-Sleep -Milliseconds 600
        $result=[ordered]@{At=[DateTimeOffset]::Now.ToString('o');Vk=$X;Count=$count;Press=$press;Activation=$activation;StatusTexts=(Get-StatusTexts)}
    }
    'Move' {
        $activation=[OfficialWindowInput]::Activate($hwnd)
        if(-not $activation.Foreground){throw 'Official window could not be brought to the foreground; no move sent.'}
        $move=[OfficialWindowInput]::Move($hwnd,$rect.Left+$X,$rect.Top+$Y)
        Start-Sleep -Milliseconds 500
        $result=[ordered]@{At=[DateTimeOffset]::Now.ToString('o');WindowRelativeX=$X;WindowRelativeY=$Y;Move=$move;Activation=$activation;StatusTexts=(Get-StatusTexts)}
    }
    'Click' {
        $activation=[OfficialWindowInput]::Activate($hwnd)
        if(-not $activation.Foreground){throw 'Official window could not be brought to the foreground; no click sent.'}
        $screenX=$rect.Left+$X;$screenY=$rect.Top+$Y
        $click=[OfficialWindowInput]::Click($hwnd,$screenX,$screenY)
        Start-Sleep -Milliseconds 400
        $result=[ordered]@{At=[DateTimeOffset]::Now.ToString('o');WindowRelativeX=$X;WindowRelativeY=$Y;ScreenX=$screenX;ScreenY=$screenY;Click=$click;Activation=$activation;StatusTexts=(Get-StatusTexts)}
    }
    'RightDrag' {
        $activation=[OfficialWindowInput]::Activate($hwnd)
        if(-not $activation.Foreground){throw 'Official window could not be brought to the foreground; no drag sent.'}
        $drag=[OfficialWindowInput]::RightDrag($hwnd,$rect.Left+$X,$rect.Top+$Y,$rect.Left+$ToX,$rect.Top+$ToY)
        Start-Sleep -Milliseconds 600
        $result=[ordered]@{At=[DateTimeOffset]::Now.ToString('o');From="$X,$Y";To="$ToX,$ToY";Drag=$drag;Activation=$activation;StatusTexts=(Get-StatusTexts)}
    }
    'RightClick' {
        $activation=[OfficialWindowInput]::Activate($hwnd)
        if(-not $activation.Foreground){throw 'Official window could not be brought to the foreground; no click sent.'}
        $screenX=$rect.Left+$X;$screenY=$rect.Top+$Y
        $click=[OfficialWindowInput]::RightClick($hwnd,$screenX,$screenY)
        Start-Sleep -Milliseconds 500
        $result=[ordered]@{At=[DateTimeOffset]::Now.ToString('o');WindowRelativeX=$X;WindowRelativeY=$Y;ScreenX=$screenX;ScreenY=$screenY;Click=$click;Activation=$activation;StatusTexts=(Get-StatusTexts)}
    }
    'AltDrag' {
        $activation=[OfficialWindowInput]::Activate($hwnd)
        if(-not $activation.Foreground){throw 'Official window could not be brought to the foreground; no drag sent.'}
        $drag=[OfficialWindowInput]::AltDrag($hwnd,$rect.Left+$X,$rect.Top+$Y,$rect.Left+$ToX,$rect.Top+$ToY)
        Start-Sleep -Milliseconds 600
        $result=[ordered]@{At=[DateTimeOffset]::Now.ToString('o');From="$X,$Y";To="$ToX,$ToY";Drag=$drag;Activation=$activation;StatusTexts=(Get-StatusTexts)}
    }
    'SlowDrag' {
        $activation=[OfficialWindowInput]::Activate($hwnd)
        if(-not $activation.Foreground){throw 'Official window could not be brought to the foreground; no drag sent.'}
        $drag=[OfficialWindowInput]::SlowDrag($hwnd,$rect.Left+$X,$rect.Top+$Y,$rect.Left+$ToX,$rect.Top+$ToY)
        Start-Sleep -Milliseconds 600
        $result=[ordered]@{At=[DateTimeOffset]::Now.ToString('o');From="$X,$Y";To="$ToX,$ToY";Drag=$drag;Activation=$activation;StatusTexts=(Get-StatusTexts)}
    }
    'Drag' {
        $activation=[OfficialWindowInput]::Activate($hwnd)
        if(-not $activation.Foreground){throw 'Official window could not be brought to the foreground; no drag sent.'}
        $drag=[OfficialWindowInput]::Drag($hwnd,$rect.Left+$X,$rect.Top+$Y,$rect.Left+$ToX,$rect.Top+$ToY)
        Start-Sleep -Milliseconds 600
        $result=[ordered]@{At=[DateTimeOffset]::Now.ToString('o');From="$X,$Y";To="$ToX,$ToY";Drag=$drag;Activation=$activation;StatusTexts=(Get-StatusTexts)}
    }
    'Capture' {
        $activation=[OfficialWindowInput]::Activate($hwnd)
        $width=$rect.Right-$rect.Left;$height=$rect.Bottom-$rect.Top
        $bmp=New-Object System.Drawing.Bitmap $width,$height
        $graphics=[System.Drawing.Graphics]::FromImage($bmp)
        $graphics.CopyFromScreen($rect.Left,$rect.Top,0,0,(New-Object System.Drawing.Size $width,$height))
        $graphics.Dispose()
        $file=Join-Path $folder ($Name+'.png')
        $bmp.Save($file,[System.Drawing.Imaging.ImageFormat]::Png)
        $hash=(Get-FileHash -LiteralPath $file).Hash
        $bmp.Dispose()
        $result=[ordered]@{At=[DateTimeOffset]::Now.ToString('o');File=$file;Sha256=$hash;Width=$width;Height=$height;Activation=$activation;StatusTexts=(Get-StatusTexts)}
    }
}
$result|ConvertTo-Json -Depth 6

