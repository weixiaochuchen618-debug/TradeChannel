// .NET Framework 4.8, SSH.NET pinned in assets/lib. No credentials in argv/files.
using System;
using System.IO;
using System.IO.Pipes;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Security.Cryptography;
using System.Text;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using Renci.SshNet;

namespace TradeChannel.Deployment {
 public static class Entry {
  [STAThread] public static int Main(string[] args) {
   try {
    if(args.Length != 5 || !System.Text.RegularExpressions.Regex.IsMatch(args[0],"^TCDeploy-[0-9a-f]{32}$")) return 64;
    Guid.ParseExact(args[1],"D"); Guid.ParseExact(args[2],"D");
    string package=Path.GetFullPath(args[4]);
    AppDomain.CurrentDomain.AssemblyResolve += delegate(object sender, ResolveEventArgs e) {
      string name=new System.Reflection.AssemblyName(e.Name).Name;
      string path=Path.Combine(package,"assets","lib",name+".dll");
      return File.Exists(path) ? System.Reflection.Assembly.LoadFrom(path) : null;
    };
    return Run(args,package);
   } catch { return 65; }
  }
  [System.Runtime.CompilerServices.MethodImpl(System.Runtime.CompilerServices.MethodImplOptions.NoInlining)]
  private static int Run(string[] args,string package) { return new Host(args[0],args[1],args[2],args[3],package).Run(); }
 }

 internal sealed class Host {
  readonly string pipeName,runId,instanceId,root,package,sid;
  readonly object gate=new object(); readonly JavaScriptSerializer json=new JavaScriptSerializer(){MaxJsonLength=4194304,RecursionLimit=40};
  readonly List<object> events=new List<object>();
  SshClient client; SshCommand active; bool stop,busy,operationMutating; int generation;
  string status="AwaitingCredential",stage="PrepareAccess",code="AwaitingCredential",observed="",operationId="",operation="",operationDigest="";
  object data; DateTime lastRequest=DateTime.UtcNow;
  static readonly Dictionary<string,string[]> fields=new Dictionary<string,string[]>(StringComparer.Ordinal) {
   {"inspect",new[]{"NetworkProbe","CaptureSeconds","ProbeRelayPort","ProbeSourceIPv4"}},
   {"plan",new[]{"Name","PublicEndpoint","TunnelSubnet","ClientRequest","Transport"}},
   {"apply",new[]{"PlanId"}}, {"status",new[]{"NetworkProbe","CaptureSeconds","ProbeRelayPort","ProbeSourceIPv4"}},
   {"authorize",new[]{"ClientRequest","ClientAddress"}}, {"recover",new string[0]}, {"finalize",new[]{"PlanId"}},
   {"capabilities",new string[0]}, {"server_info",new string[0]}, {"devices",new[]{"Offset","Limit","IncludeRevoked"}},
   {"device_rename",new[]{"DeviceId","Name","ExpectedConfigRevision"}}, {"management_plan",new string[0]},
   {"management_apply",new[]{"PlanId","ApprovedChangeDigest"}},
   {"invite_create",new[]{"InviteId","DeviceName","ExpiresInHours"}}, {"invite_cancel",new[]{"InviteId"}},
   {"invite_status",new[]{"InviteId"}}, {"authorize_external",new[]{"InviteId","PairRequest"}},
   {"request_status",new[]{"RequestId","RequestDigest","IncludeTelemetry","RefreshAuthorization"}}, {"revoke_preview",new[]{"DeviceId"}},
   {"revoke",new[]{"DeviceId","ExpectedConfigRevision","ApprovedChangeDigest"}},
   {"uninstall_preview",new string[0]}, {"uninstall",new[]{"ExpectedConfigRevision","ApprovedChangeDigest"}},
   {"transport_plan",new[]{"Transport"}}, {"transport_apply",new[]{"PlanId","ApprovedChangeDigest"}},
   {"transport_info",new[]{"ClientPublicKey","ServerPublicKey"}}
  };
  static bool Mutating(string action) { return new[]{"apply","authorize","recover","finalize","management_apply","device_rename","invite_create","invite_cancel","authorize_external","revoke","uninstall","transport_apply"}.ContainsValue(action); }
  public Host(string p,string r,string i,string state,string pkg) {pipeName=p;runId=r;instanceId=i;root=Path.GetFullPath(state);package=pkg;sid=WindowsIdentity.GetCurrent().User.Value;}
  string Serialize(object value) { lock(json) return json.Serialize(value); }
  static object Canonical(object value) {var dict=value as Dictionary<string,object>;if(dict!=null){var sorted=new SortedDictionary<string,object>(StringComparer.Ordinal);foreach(var item in dict)sorted[item.Key]=Canonical(item.Value);return sorted;}var array=value as object[];if(array!=null){var output=new object[array.Length];for(int i=0;i<array.Length;i++)output[i]=Canonical(array[i]);return output;}var list=value as System.Collections.ArrayList;if(list!=null){var output=new object[list.Count];for(int i=0;i<list.Count;i++)output[i]=Canonical(list[i]);return output;}return value;}
  Dictionary<string,object> Parse(string text) {lock(json) return json.Deserialize<Dictionary<string,object>>(text);}
  static void Only(Dictionary<string,object> value,params string[] allowed) {
   if(value==null) throw new InvalidOperationException("InvalidRequest");
   foreach(string key in value.Keys) if(Array.IndexOf(allowed,key)<0) throw new InvalidOperationException("InvalidRequest");
  }
  static string Str(Dictionary<string,object> value,string key,int limit,bool optional=false) {
   object x; if(!value.TryGetValue(key,out x)) {if(optional)return "";throw new InvalidOperationException("InvalidRequest");}
   if(!(x is string) || ((string)x).Length>limit || ((string)x).IndexOf('\0')>=0) throw new InvalidOperationException("InvalidRequest");return (string)x;
  }
  void Event(string state,string result) {
   lock(gate) {events.Add(new{AtUtc=DateTime.UtcNow.ToString("o"),Stage=state,Code=result,OperationId=operationId});if(events.Count>128)events.RemoveAt(0);}
   Persist();
  }
  void Persist() {
   // State contains no server output, credentials, source, or input. Root ACL is set by the caller.
   try { string file=Path.Combine(root,"receipt.json"),tmp=Path.Combine(root,".receipt-"+Guid.NewGuid().ToString("N"));
    object value;lock(gate)value=new{SchemaVersion=1,RunId=runId,InstanceId=instanceId,Status=status,Stage=stage,Code=code,OperationId=operationId,Operation=operation,Mutating=operationMutating,ProcessId=System.Diagnostics.Process.GetCurrentProcess().Id,StartTimeUtcTicks=System.Diagnostics.Process.GetCurrentProcess().StartTime.ToUniversalTime().Ticks.ToString(),AtUtc=DateTime.UtcNow.ToString("o")};
    using(var stream=new FileStream(tmp,FileMode.CreateNew,FileAccess.Write,FileShare.None)){};
    var security=new FileSecurity();security.SetAccessRuleProtection(true,false);security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(sid),FileSystemRights.FullControl,AccessControlType.Allow));security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier("S-1-5-18"),FileSystemRights.FullControl,AccessControlType.Allow));File.SetAccessControl(tmp,security);
    File.WriteAllText(tmp,Serialize(value),new UTF8Encoding(false));if(File.Exists(file))File.Replace(tmp,file,null);else File.Move(tmp,file);
   } catch { }
  }
  object Snapshot() { lock(gate) return new{Ok=status!="Failed"&&status!="OutcomeUnknown",RunId=runId,InstanceId=instanceId,Status=status,Stage=stage,Code=code,ObservedFingerprint=observed,HasSession=client!=null&&client.IsConnected,OperationId=operationId,Operation=operation,Data=data,Events=events.ToArray()}; }
  public int Run() {
   Persist();
   while(!stop) {
    var security=new PipeSecurity();security.SetAccessRuleProtection(true,false);
    security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(sid),PipeAccessRights.FullControl,AccessControlType.Allow));
    security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier("S-1-5-18"),PipeAccessRights.FullControl,AccessControlType.Allow));
    using(var pipe=new NamedPipeServerStream(pipeName,PipeDirection.InOut,1,PipeTransmissionMode.Byte,PipeOptions.Asynchronous,65536,65536,security)) {
     var wait=pipe.BeginWaitForConnection(null,null);
     while(!wait.AsyncWaitHandle.WaitOne(1000)) { if(stop)break; if(!busy && DateTime.UtcNow-lastRequest>TimeSpan.FromMinutes(10)) {stop=true;break;} }
     if(stop)break;
     try {pipe.EndWaitForConnection(wait);string actor="";pipe.RunAsClient(delegate {actor=WindowsIdentity.GetCurrent().User.Value;});
      if(actor!=sid && actor!="S-1-5-18")throw new InvalidOperationException("AccessDenied");
      string input=ReadFrame(pipe,4194304);var request=Parse(input);input=null;
      string boundRun=Str(request,"RunId",36),boundInstance=Str(request,"InstanceId",36);
      if(boundRun!=runId || boundInstance!=instanceId)throw new InvalidOperationException("SessionMismatch");
      lastRequest=DateTime.UtcNow;object response=Dispatch(request);WriteFrame(pipe,Serialize(response));
     } catch(InvalidOperationException ex) { try {WriteFrame(pipe,Serialize(new{Ok=false,Code=SafeCode(ex.Message),Status="Rejected"}));}catch{} }
       catch {try {WriteFrame(pipe,"{\"Ok\":false,\"Code\":\"InvalidRequest\",\"Status\":\"Rejected\"}");}catch{} }
    }
   }
   lock(gate){if(client!=null)client.Dispose();client=null;status="Closed";stage="Closed";code="SessionClosed";}Persist();return 0;
  }
  object Dispatch(Dictionary<string,object> request) {
   string command=Str(request,"Command",24);
   switch(command) {
    case "Poll":Only(request,"RunId","InstanceId","Command");return Snapshot();
    case "Authenticate":
     Only(request,"RunId","InstanceId","Command","Connection","Credential","PinnedFingerprint");
     lock(gate){if(busy)throw new InvalidOperationException("SessionBusy");if(client!=null&&client.IsConnected)return Snapshot();if(client!=null){client.Dispose();client=null;}busy=true;status="Connecting";stage="PrepareAccess";code="Connecting";data=null;observed="";generation++;}
     ThreadPool.QueueUserWorkItem(delegate {Connect(request);});return new{Ok=true,Status="Connecting",Code="AuthenticationStarted"};
    case "Execute":
     Only(request,"RunId","InstanceId","Command","Operation","Input","OperationId");string action=Str(request,"Operation",40);
     if(!fields.ContainsKey(action))throw new InvalidOperationException("InvalidOperation");
     var args=request.ContainsKey("Input")?request["Input"] as Dictionary<string,object>:null;Only(args,fields[action]);
     if(Encoding.UTF8.GetByteCount(Serialize(args))>262144)throw new InvalidOperationException("InputTooLarge");
     string id=Str(request,"OperationId",36,true);if(id.Length==0)id=Guid.NewGuid().ToString();Guid.ParseExact(id,"D");string digest;using(var sha=SHA256.Create())digest=Convert.ToBase64String(sha.ComputeHash(Encoding.UTF8.GetBytes(Serialize(Canonical(args)))));
     lock(gate){if(operationId==id){if(operation!=action||operationDigest!=digest)throw new InvalidOperationException("OperationMismatch");return Snapshot();}if(busy)throw new InvalidOperationException("SessionBusy");if(client==null||!client.IsConnected)throw new InvalidOperationException("AuthenticationRequired");busy=true;status="Running";stage=action;code="OperationStarted";data=null;operation=action;operationId=id;operationDigest=digest;operationMutating=Mutating(action)||(action=="request_status"&&args.ContainsKey("RefreshAuthorization")&&args["RefreshAuthorization"] is bool&&(bool)args["RefreshAuthorization"]);generation++;}
     Event(stage,code);int current=generation;ThreadPool.QueueUserWorkItem(delegate {Execute(action,args,current);});return new{Ok=true,OperationId=operationId,Operation=action,Status="Running",Stage=stage,Code=code};
    case "Cancel":
     Only(request,"RunId","InstanceId","Command");lock(gate){generation++;if(active!=null)active.Dispose();active=null;if(client!=null)client.Dispose();client=null;busy=false;status=operationMutating?"OutcomeUnknown":"Failed";stage="Cancelled";code="OperationCancelled";data=null;}Event(stage,code);return Snapshot();
    case "Close":Only(request,"RunId","InstanceId","Command");lock(gate){if(busy)throw new InvalidOperationException("SessionBusy");stop=true;}return new{Ok=true,Code="SessionClosed",Status="Closed"};
    default:throw new InvalidOperationException("InvalidOperation");
   }
  }
  void Connect(Dictionary<string,object> request) {
   SshClient candidate=null;PrivateKeyFile key=null;
   try {
    var connection=request["Connection"] as Dictionary<string,object>;Only(connection,"Host","Port","User");
    string host=Str(connection,"Host",64),user=Str(connection,"User",32);int port=Convert.ToInt32(connection["Port"]);
    System.Net.IPAddress ip;if(!System.Net.IPAddress.TryParse(host,out ip)||ip.AddressFamily!=System.Net.Sockets.AddressFamily.InterNetwork||host!=ip.ToString()||port<1||port>65535||!System.Text.RegularExpressions.Regex.IsMatch(user,"^[a-z_][a-z0-9_-]{0,31}$"))throw new InvalidOperationException("InvalidConnection");
    var credential=request["Credential"] as Dictionary<string,object>;Only(credential,"Kind","Password","PrivateKeyPem","Passphrase");
    string kind=Str(credential,"Kind",16);AuthenticationMethod auth;
    if(kind=="Password") {Only(credential,"Kind","Password");string password=Str(credential,"Password",4096);auth=new PasswordAuthenticationMethod(user,password);password=null;}
    else if(kind=="PrivateKey") {Only(credential,"Kind","PrivateKeyPem","Passphrase");byte[] bytes=Encoding.UTF8.GetBytes(Str(credential,"PrivateKeyPem",1048576));using(var stream=new MemoryStream(bytes))key=new PrivateKeyFile(stream,Str(credential,"Passphrase",4096,true));Array.Clear(bytes,0,bytes.Length);auth=new PrivateKeyAuthenticationMethod(user,key);}
    else throw new InvalidOperationException("InvalidCredential");
    string pinned=Str(request,"PinnedFingerprint",64,true);if(pinned.Length>0&&!System.Text.RegularExpressions.Regex.IsMatch(pinned,"^SHA256:[A-Za-z0-9+/]{43}$"))throw new InvalidOperationException("InvalidFingerprint");
    var info=new ConnectionInfo(host,port,user,auth);info.Timeout=TimeSpan.FromSeconds(20);candidate=new SshClient(info);candidate.KeepAliveInterval=TimeSpan.FromSeconds(15);
    candidate.HostKeyReceived+=delegate(object sender,Renci.SshNet.Common.HostKeyEventArgs e) {using(var sha=SHA256.Create())observed="SHA256:"+Convert.ToBase64String(sha.ComputeHash(e.HostKey)).TrimEnd('=');e.CanTrust=pinned.Length>0&&observed==pinned;};
    candidate.Connect();lock(gate){client=candidate;candidate=null;status="Ready";stage="Inspect";code="Authenticated";busy=false;data=null;}Event(stage,code);
   } catch {
    lock(gate){busy=false;status="Failed";stage="PrepareAccess";string pinned=request.ContainsKey("PinnedFingerprint")?request["PinnedFingerprint"] as string:"";code=observed.Length>0&&(String.IsNullOrEmpty(pinned)||pinned!=observed)?(String.IsNullOrEmpty(pinned)?"HostTrustRequired":"HostKeyChanged"):"AuthenticationFailed";data=null;}Event(stage,code);
   } finally {if(candidate!=null)candidate.Dispose();if(key!=null)key.Dispose();if(request.ContainsKey("Credential")){var c=request["Credential"] as Dictionary<string,object>;if(c!=null)c.Clear();request.Remove("Credential");}}
  }
  void Execute(string action,Dictionary<string,object> args,int current) {
   SshCommand command=null;
   string executionStage="BackendSource";
   try {
    string source=BackendSource();string hash;using(var sha=SHA256.Create())hash=BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(source))).Replace("-","").ToLowerInvariant();
    string payload=Serialize(new{Source=source,SourceSHA256=hash,Action=action,Input=args});
    string bootstrap="import sys,json,hashlib,io; p=json.loads(sys.stdin.buffer.read(4194305).decode(\"utf-8\")); s=p[\"Source\"]; (hashlib.sha256(s.encode(\"utf-8\")).hexdigest()==p[\"SourceSHA256\"]) or sys.exit(76); a=p[\"Action\"]; (a in (\""+String.Join("\",\"",fields.Keys)+"\")) or sys.exit(77); sys.argv=[\"tradechannel_linux.py\",a,\"--input\",\"-\"]; sys.stdin=io.StringIO(json.dumps(p[\"Input\"])); exec(compile(s,\"tradechannel_linux.py\",\"exec\"),{\"__name__\":\"__main__\",\"__file__\":\"tradechannel_linux.py\"})";
    string remote="python3 -I -c '"+bootstrap+"'";
    lock(gate){if(current!=generation) return;if(client.ConnectionInfo.Username!="root")remote="sudo -n -- "+remote;command=client.CreateCommand(remote);command.CommandTimeout=TimeSpan.FromMinutes(operationMutating?15:3);active=command;}
    executionStage="CommandStart";var execution=command.ExecuteAsync(CancellationToken.None);var stdout=Task.Run(delegate{try{return ReadBounded(command.OutputStream,4194304);}catch{command.Dispose();throw;}});var stderr=Task.Run(delegate{try{return ReadBounded(command.ExtendedOutputStream,65536);}catch{command.Dispose();throw;}});
    executionStage="SendPayload";
    using(var input=command.CreateInputStream()){byte[] bytes=Encoding.UTF8.GetBytes(payload);input.Write(bytes,0,bytes.Length);input.Flush();Array.Clear(bytes,0,bytes.Length);}payload=null;args.Clear();
    executionStage="WaitResult";execution.GetAwaiter().GetResult();string output=stdout.GetAwaiter().GetResult();stderr.GetAwaiter().GetResult();executionStage="ParseReply";
    var envelope=Parse(output);output=null;Only(envelope,"Ok","Action","Code","Message","Data","AtUtc");
    if(!(envelope["Ok"] is bool)||Str(envelope,"Action",40)!=action)throw new InvalidOperationException("InvalidEnvelope");
    bool ok=(bool)envelope["Ok"];if(ok&&command.ExitStatus!=0)throw new InvalidOperationException("BackendExitMismatch");
    var body=envelope.ContainsKey("Data")?envelope["Data"] as Dictionary<string,object>:null;
    lock(gate){if(current!=generation)return;busy=false;active=null;status=ok?"Completed":"Failed";stage=action;code=ok?"Completed":SafeCode(body!=null&&body.ContainsKey("Code")?body["Code"] as string:"RemoteRejected");data=envelope.ContainsKey("Data")?envelope["Data"]:null;}
    Event(stage,code);
   } catch(InvalidOperationException ex) {FailExecution(current,action,SafeCode(ex.Message));}
     catch(Exception ex) {FailExecution(current,action,SafeCode(executionStage+"_"+ex.GetType().Name));}
   finally {if(command!=null)command.Dispose();}
  }
  void FailExecution(int current,string action,string error) {lock(gate){if(current!=generation)return;busy=false;active=null;status=operationMutating?"OutcomeUnknown":"Failed";stage=action;code=error;data=null;}Event(stage,code);}
  string BackendSource() {
   string folder=Path.Combine(package,"linux");var builder=new StringBuilder();
   foreach(string name in new[]{"transport_support","management_support"}) {string path=Path.Combine(folder,name+".py");if(!File.Exists(path)||new FileInfo(path).Length>1048576)throw new InvalidOperationException("BackendMissing");string source=File.ReadAllText(path);builder.Append("import sys,types; _m=types.ModuleType(\"").Append(name).Append("\"); _m.__file__=\"").Append(name).Append(".py\"; sys.modules[\"").Append(name).Append("\"]=_m; exec(compile(").Append(Serialize(source)).Append(",\"").Append(name).Append(".py\",\"exec\"),_m.__dict__)\n");}
   string main=Path.Combine(folder,"tradechannel_linux.py");if(new FileInfo(main).Length>2097152)throw new InvalidOperationException("BackendMissing");builder.Append(File.ReadAllText(main));if(Encoding.UTF8.GetByteCount(builder.ToString())>3500000)throw new InvalidOperationException("BackendTooLarge");return builder.ToString();
  }
  static string SafeCode(string value){return value!=null&&System.Text.RegularExpressions.Regex.IsMatch(value,"^[A-Za-z][A-Za-z0-9_]{0,63}$")?value:"RemoteRejected";}
  static string ReadBounded(Stream input,int limit) {using(var buffer=new MemoryStream()){byte[] bytes=new byte[8192];int count;while((count=input.Read(bytes,0,bytes.Length))>0){if(buffer.Length+count>limit)throw new InvalidOperationException("OutputTooLarge");buffer.Write(bytes,0,count);}return new UTF8Encoding(false,true).GetString(buffer.ToArray());}}
  static byte[] ReadBytes(Stream input,int count) {byte[] bytes=new byte[count];int offset=0;while(offset<count){var pending=input.BeginRead(bytes,offset,count-offset,null,null);if(!pending.AsyncWaitHandle.WaitOne(5000))throw new InvalidOperationException("PipeTimeout");int got=input.EndRead(pending);if(got<=0)throw new InvalidOperationException("PipeClosed");offset+=got;}return bytes;}
  static string ReadFrame(Stream stream,int limit){int count=BitConverter.ToInt32(ReadBytes(stream,4),0);if(count<2||count>limit)throw new InvalidOperationException("InputTooLarge");return new UTF8Encoding(false,true).GetString(ReadBytes(stream,count));}
  static void WriteFrame(Stream stream,string text){byte[] bytes=Encoding.UTF8.GetBytes(text);if(bytes.Length>4194304)throw new InvalidOperationException("OutputTooLarge");byte[] length=BitConverter.GetBytes(bytes.Length);stream.Write(length,0,4);stream.Write(bytes,0,bytes.Length);stream.Flush();}
 }
 internal static class ListExtensions { public static bool ContainsValue(this string[] values,string value){return Array.IndexOf(values,value)>=0;} }
}
