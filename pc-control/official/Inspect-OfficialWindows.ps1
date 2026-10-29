param([switch]$MetadataOnly)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
if(-not ('OfficialWindowRead' -as [type])){
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public sealed class OfficialWindowMetadata {
    public long Handle,Owner;public int ProcessId;public string Title,ClassName;public bool Visible,Enabled;
}
public static class OfficialWindowRead {
    delegate bool Enumerator(IntPtr hwnd,IntPtr argument);
    [DllImport("user32.dll")]static extern bool EnumWindows(Enumerator callback,IntPtr argument);
    [DllImport("user32.dll")]static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint pid);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)]static extern int GetWindowText(IntPtr hwnd,StringBuilder text,int length);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)]static extern int GetClassName(IntPtr hwnd,StringBuilder text,int length);
    [DllImport("user32.dll")]static extern IntPtr GetWindow(IntPtr hwnd,uint command);
    [DllImport("user32.dll")]static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")]static extern bool IsWindowEnabled(IntPtr hwnd);
    [DllImport("user32.dll",SetLastError=true)]static extern IntPtr OpenInputDesktop(uint flags,bool inherit,uint access);
    [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)]static extern bool GetUserObjectInformation(IntPtr handle,int index,StringBuilder text,uint size,out uint required);
    [DllImport("user32.dll")]static extern bool CloseDesktop(IntPtr desktop);
    public static string InputDesktop(){var h=OpenInputDesktop(0,false,1);if(h==IntPtr.Zero)return "access_denied_"+Marshal.GetLastWin32Error();try{uint required;var name=new StringBuilder(256);return GetUserObjectInformation(h,2,name,512,out required)?name.ToString():"read_error_"+Marshal.GetLastWin32Error();}finally{CloseDesktop(h);}}
    public static OfficialWindowMetadata[] Enumerate(int[] pids){var result=new List<OfficialWindowMetadata>();EnumWindows((h,a)=>{uint p;GetWindowThreadProcessId(h,out p);if(Array.IndexOf(pids,(int)p)>=0){var title=new StringBuilder(512);var cls=new StringBuilder(256);GetWindowText(h,title,512);GetClassName(h,cls,256);result.Add(new OfficialWindowMetadata {Handle=h.ToInt64(),Owner=GetWindow(h,4).ToInt64(),ProcessId=(int)p,Title=title.ToString(),ClassName=cls.ToString(),Visible=IsWindowVisible(h),Enabled=IsWindowEnabled(h)});}return true;},IntPtr.Zero);return result.ToArray();}
}
'@
}
$processes=@(Get-CimInstance Win32_Process -Filter "Name='PerceptionSimulationControl.exe' OR Name='CredentialUIBroker.exe'")
$windows=@([OfficialWindowRead]::Enumerate([int[]]@($processes.ProcessId)))
$observations=@(foreach($window in $windows){
    $controls=@();$errorType=$null
    if($window.Visible -and -not $MetadataOnly){
        try{
            $element=[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$window.Handle)
            $controls=@(foreach($e in $element.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)){
                [pscustomobject]@{Name=if($e.Current.IsPassword){'[password input]'}else{$e.Current.Name};Type=$e.Current.ControlType.ProgrammaticName;AutomationId=$e.Current.AutomationId;Password=$e.Current.IsPassword;ProcessId=$e.Current.ProcessId;Patterns=@($e.GetSupportedPatterns().ProgrammaticName)}
            })
        }catch{$errorType=$_.Exception.GetType().Name}
    }
    [pscustomobject]@{Window=$window;Controls=$controls;ErrorType=$errorType}
})
[ordered]@{At=[DateTimeOffset]::Now.ToString('o');InputDesktop=[OfficialWindowRead]::InputDesktop();Windows=$observations}|ConvertTo-Json -Depth 7
