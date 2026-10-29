using System;
using System.Security.Cryptography;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Security.Credentials;
using Windows.Security.Cryptography.Certificates;
using Windows.Web.Http;
using Windows.Web.Http.Filters;
public static class NativePinnedHttpSeed {
    public static HttpClient Create(string baseUri,string pin,string user,string password){
        var uri=new Uri(baseUri);
        if(uri.Scheme!="https"||!uri.Host.StartsWith("169.254.")||pin==null||pin.Length!=64)throw new ArgumentException();
        var filter=new HttpBaseProtocolFilter();
        filter.AllowUI=false;filter.UseProxy=false;filter.AllowAutoRedirect=false;
        filter.IgnorableServerCertificateErrors.Add(ChainValidationResult.Untrusted);
        filter.IgnorableServerCertificateErrors.Add(ChainValidationResult.InvalidName);
        filter.ServerCustomValidationRequested+=(sender,args)=>{
            try{
                var bytes=args.ServerCertificate.GetCertificateBlob().ToArray();
                string observed;
                using(var hash=SHA256.Create())observed=BitConverter.ToString(hash.ComputeHash(bytes)).Replace("-","");
                if(args.RequestMessage.RequestUri.Host!=uri.Host||observed!=pin)args.Reject();
            }catch{args.Reject();}
        };
        filter.ServerCredential=new PasswordCredential(baseUri,user,password);
        return new HttpClient(filter);
    }
}
