using System;
using System.Collections.Generic;
using Rice.HoloLens.Control;
using ApplicationIdentity=Rice.HoloLens.Control.ApplicationIdentity;
class ApplicationIdentityTests {
    static int count;
    static void Check(bool value,string label){if(!value)throw new Exception(label);count++;}
    static Dictionary<string,object> Row(){return new Dictionary<string,object>{{"Aumid","Rice.HoloLens.InputProbe_r5420n6798s24!Probe"},{"PackageFullName","Rice.HoloLens.InputProbe_1.0.0.0_neutral__r5420n6798s24"},{"Version","1.0.0.0"},{"DisplayName","输入验证"}};}
    static void Rejected(Dictionary<string,object> row){bool rejected=false;try{ApplicationIdentity.FromInventory(row);}catch(InvalidOperationException){rejected=true;}Check(rejected,"Inconsistent inventory identity accepted");}
    static void Main(){
        var app=ApplicationIdentity.FromInventory(Row());Check(app.Version=="1.0.0.0"&&app.DisplayName=="输入验证","Exact inventory identity lost");
        Check(app.SamePackage(ApplicationIdentity.FromInventory(Row())),"Same enumerated package mismatch");
        var changed=Row();changed["PackageFullName"]="Rice.HoloLens.InputProbe_1.0.0.1_neutral__r5420n6798s24";changed["Version"]="1.0.0.1";Check(!app.SamePackage(ApplicationIdentity.FromInventory(changed)),"Version change must invalidate selection");
        var row=Row();row["Aumid"]="Other.App_r5420n6798s24!Probe";Rejected(row);
        row=Row();row["Version"]="1.0.0.2";Rejected(row);
        row=Row();row.Remove("PackageFullName");Rejected(row);
        row=Row();row["Aumid"]="Rice.HoloLens.InputProbe_r5420n6798s24!Probe\nexit";Rejected(row);
        row=Row();row["DisplayName"]="";Check(ApplicationIdentity.FromInventory(row).DisplayName==app.Aumid,"Unnamed application lost its identity");
        Console.WriteLine("Application identity checks passed: "+count);
    }
}
