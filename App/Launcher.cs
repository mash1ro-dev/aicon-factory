using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Windows.Forms;
using System.Collections.Generic;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Runtime.InteropServices;
using System.Web.Script.Serialization;
using Microsoft.PowerShell;
[assembly: System.Reflection.AssemblyVersion("0.1.1.0")]
[assembly: System.Reflection.AssemblyFileVersion("0.1.1.0")]
[assembly: System.Reflection.AssemblyInformationalVersion("0.1.1")]
internal static class IconFactoryLauncher {
    [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
    static readonly JavaScriptSerializer Json=new JavaScriptSerializer();
    static string Plain(string p){
        if(String.IsNullOrWhiteSpace(p)||p.Length<3||p[1]!=':'||p[2]!='\\'||p.Substring(2).Contains(':'))throw new InvalidOperationException("Local path required");
        foreach(string s in p.Substring(3).Split('\\'))if(s=="."||s==".."||s.EndsWith(".")||s.EndsWith(" "))throw new InvalidOperationException("Ambiguous path");
        string full=Path.GetFullPath(p).TrimEnd('\\'),cursor=full;
        while(!String.IsNullOrEmpty(cursor)){if((File.Exists(cursor)||Directory.Exists(cursor))&&(File.GetAttributes(cursor)&FileAttributes.ReparsePoint)!=0)throw new InvalidOperationException("Reparse path rejected");cursor=Path.GetDirectoryName(cursor);}
        return full;
    }
    static void Log(string root,string operation,bool success,object details){
        string dir=Plain(Path.Combine(root,"Logs"));Directory.CreateDirectory(dir);
        var r=new Dictionary<string,object>{{"Timestamp",DateTime.UtcNow.ToString("o")},{"Operation",operation},{"Success",success},{"ProcessId",System.Diagnostics.Process.GetCurrentProcess().Id},{"ConsoleHandle",GetConsoleWindow().ToInt64()},{"Details",details}};
        File.AppendAllText(Path.Combine(dir,"launcher.jsonl"),Json.Serialize(r)+Environment.NewLine,new UTF8Encoding(true));
    }
    [STAThread] static int Main(string[] args){
        string app=Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location),root=app;
        try{
            app=Plain(app);root=app;
            if(args.Length!=0){
                if(args.Length!=2||args[0]!="--test-root")throw new InvalidOperationException("Unsupported launcher arguments");
                string test=Plain(args[1]),baseDir=Path.Combine(app,"Tests","Sandbox");
                if(!test.StartsWith(baseDir+"\\",StringComparison.OrdinalIgnoreCase))throw new InvalidOperationException("Test Root outside Sandbox");
                string owner=test;
                while(owner.Length>baseDir.Length&&!File.Exists(Path.Combine(owner,".aicon-test-owner.json")))owner=Path.GetDirectoryName(owner);
                if(owner.Length<=baseDir.Length)throw new InvalidOperationException("Owned test marker missing");
                var marker=Json.Deserialize<Dictionary<string,object>>(File.ReadAllText(Path.Combine(owner,".aicon-test-owner.json"),Encoding.UTF8));
                if((string)marker["Purpose"]!="AiconFactory.Automation"||!String.Equals((string)marker["Root"],owner,StringComparison.OrdinalIgnoreCase))throw new InvalidOperationException("Invalid test ownership");
                root=test;
            }
            var initial=InitialSessionState.CreateDefault();
            // Keep the standard shell authorization manager. Do not override execution policy.
            initial.AuthorizationManager=new PSAuthorizationManager("Microsoft.PowerShell");
            using(Runspace run=RunspaceFactory.CreateRunspace(initial)){
                run.ApartmentState=System.Threading.ApartmentState.STA;run.ThreadOptions=PSThreadOptions.UseCurrentThread;run.Open();
                using(PowerShell ps=PowerShell.Create()){
                    ps.Runspace=run;ps.AddCommand("Get-ExecutionPolicy");string policy=String.Join(",",ps.Invoke().Select(x=>x.ToString()).ToArray());ps.Commands.Clear();
                    if(ps.HadErrors)throw ps.Streams.Error[0].Exception;
                    Log(root,"Startup",true,new{Host="In-process Windows PowerShell",AuthorizationManager=initial.AuthorizationManager.GetType().FullName,ExecutionPolicy=policy,Subsystem="Windows GUI"});
                    ps.AddCommand("Import-Module").AddParameter("Name",Path.Combine(app,"App","AiconFactory.psm1")).AddParameter("Force",true).AddParameter("ErrorAction","Stop");ps.Invoke();
                    if(ps.HadErrors)throw ps.Streams.Error[0].Exception;
                    ps.Commands.Clear();ps.AddCommand("Start-AiconFactory").AddParameter("Root",root);ps.Invoke();
                    if(ps.HadErrors)throw ps.Streams.Error[0].Exception;
                }
            }
            return 0;
        }catch(Exception e){
            bool saved=true;try{Log(root,"Startup",false,new{Exception=e.ToString(),Type=e.GetType().FullName,Stack=e.StackTrace});}catch{saved=false;}
            string message="アプリを起動できませんでした。配置先と必要なファイルを確認してください。";
            message+=saved?"\n詳しい記録はアプリのLogsフォルダに保存しました。":"\n詳しい記録も保存できませんでした。保存先の空き容量や権限を確認してください。";
            MessageBox.Show(message,"あいこんふぁくとりー",MessageBoxButtons.OK,MessageBoxIcon.Information);return 1;
        }
    }
}
