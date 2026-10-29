using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;

namespace Rice.HoloLens.Control {
    public sealed class ApplicationIdentity {
        public string Aumid {get;private set;}
        public string PackageFullName {get;private set;}
        public string DisplayName {get;private set;}
        public string Version {get;private set;}
        ApplicationIdentity(){}
        static string Required(Dictionary<string,object> row,string key){object value;if(!row.TryGetValue(key,out value)||!(value is string)||String.IsNullOrWhiteSpace((string)value))throw new InvalidOperationException("应用清单缺少身份字段");return (string)value;}
        public static ApplicationIdentity FromInventory(Dictionary<string,object> row){
            string aumid=Required(row,"Aumid"),full=Required(row,"PackageFullName"),version=Required(row,"Version");
            var match=Regex.Match(full,@"^(?<name>[A-Za-z0-9][A-Za-z0-9.-]{2,})_(?<version>\d+\.\d+\.\d+\.\d+)_[A-Za-z0-9]+_[A-Za-z0-9.-]*_(?<publisher>[a-z0-9]{13})$");
            if(!match.Success||match.Groups["version"].Value!=version||!Regex.IsMatch(aumid,"^"+Regex.Escape(match.Groups["name"].Value+"_"+match.Groups["publisher"].Value)+@"![A-Za-z0-9._-]{1,128}$"))throw new InvalidOperationException("应用身份与包版本不一致");
            object name;row.TryGetValue("DisplayName",out name);
            return new ApplicationIdentity{Aumid=aumid,PackageFullName=full,Version=version,DisplayName=name is string&&!String.IsNullOrWhiteSpace((string)name)?(string)name:aumid};
        }
        public bool SamePackage(ApplicationIdentity other){return other!=null&&Aumid==other.Aumid&&PackageFullName==other.PackageFullName;}
        public override string ToString(){return DisplayName+"  ["+Version+"]";}
    }
}
