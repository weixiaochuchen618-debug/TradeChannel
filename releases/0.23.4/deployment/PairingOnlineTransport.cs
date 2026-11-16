using System;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Collections.Generic;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Renci.SshNet;
using Renci.SshNet.Common;

namespace TradeChannel.Deployment {
 public sealed class OnlineHttpResult {
  public int StatusCode;
  public string Body;
 }

 // .NET 4.8: callbacks run in managed code, not a PowerShell runspace. A TLS
 // decision belongs to this one request; no global certificate bypass exists.
 public static class PairingOnlineTransport {
  const int Limit = 131072;
  static string dependencyRoot;
  public static void InitializeDependencies(string library) {
   if(dependencyRoot!=null)return;
   dependencyRoot=Path.GetFullPath(library);
   AppDomain.CurrentDomain.AssemblyResolve+=delegate(object sender,ResolveEventArgs e) {
    string name=new System.Reflection.AssemblyName(e.Name).Name;
    string[] allowed={"Renci.SshNet","BouncyCastle.Cryptography","Microsoft.Bcl.AsyncInterfaces","Microsoft.Extensions.Logging.Abstractions",
     "Microsoft.Extensions.DependencyInjection.Abstractions","System.Formats.Asn1","System.Buffers","System.Memory","System.Numerics.Vectors",
     "System.Runtime.CompilerServices.Unsafe","System.Threading.Tasks.Extensions","System.ValueTuple"};
    if(Array.IndexOf(allowed,name)<0)return null;
    string path=Path.Combine(dependencyRoot,name+".dll");
    return File.Exists(path)?System.Reflection.Assembly.LoadFrom(path):null;
   };
  }
  static string Hash(byte[] value) {
   using(var sha=SHA256.Create())return BitConverter.ToString(sha.ComputeHash(value)).Replace("-","").ToLowerInvariant();
  }
  static bool Same(string a,string b) {
   if(a==null||b==null||a.Length!=b.Length)return false;
   int difference=0;for(int i=0;i<a.Length;i++)difference|=a[i]^b[i];return difference==0;
  }
  static string ReadBounded(Stream stream,int limit) {
   using(var output=new MemoryStream()) {
    byte[] buffer=new byte[8192];int count;
    while((count=stream.Read(buffer,0,buffer.Length))>0) {
     if(output.Length+count>limit)throw new InvalidOperationException("[TC:OnlineResponseTooLarge]");
     output.Write(buffer,0,count);
    }
    return new UTF8Encoding(false,true).GetString(output.ToArray());
   }
  }
  public static OnlineHttpResult Request(string url,string tlsSha256,string token,string method,string body,int timeoutMs) {
   Uri address;
   if(!Uri.TryCreate(url,UriKind.Absolute,out address)||address.Scheme!="https"||address.UserInfo.Length!=0||address.Query.Length!=0||address.Fragment.Length!=0
      ||!Regex.IsMatch(tlsSha256??"","^[0-9a-f]{64}$")||!Regex.IsMatch(token??"","^[A-Za-z0-9_-]{43}$")
      ||(method!="GET"&&method!="POST")||timeoutMs<1000||timeoutMs>60000)throw new InvalidOperationException("[TC:InvalidOnlineRequest]");
   bool rejectedCertificate=false;
   RemoteCertificateValidationCallback validate=delegate(object sender,X509Certificate certificate,X509Chain chain,SslPolicyErrors errors) {
    if(certificate==null){rejectedCertificate=true;return false;}
    using(var actual=new X509Certificate2(certificate)) {
     bool valid=DateTime.UtcNow>=actual.NotBefore.ToUniversalTime()&&DateTime.UtcNow<actual.NotAfter.ToUniversalTime()
       &&Same(Hash(actual.RawData),tlsSha256);
     if(!valid)rejectedCertificate=true;
     return valid; // Exact DER pin supplied by authenticated SSH replaces PKI/name trust.
    }
   };
   byte[] payload=Encoding.UTF8.GetBytes(method=="POST"?(body??""):"");
   if(payload.Length>Limit||(method=="POST"&&payload.Length==0))throw new InvalidOperationException("[TC:InvalidOnlineRequest]");
   try {
    using(var client=new TcpClient()) {
     using(var timeout=new Timer(delegate(object state){client.Close();},null,timeoutMs,Timeout.Infinite)) {
     var connect=client.BeginConnect(address.Host,address.Port,null,null);
     try {if(!connect.AsyncWaitHandle.WaitOne(timeoutMs))throw new IOException();client.EndConnect(connect);}
     finally {connect.AsyncWaitHandle.Close();}
     client.SendTimeout=timeoutMs;client.ReceiveTimeout=timeoutMs;
     using(var tls=new SslStream(client.GetStream(),false,validate)) {
      tls.ReadTimeout=timeoutMs;tls.WriteTimeout=timeoutMs;
      var handshake=tls.BeginAuthenticateAsClient(address.Host,null,SslProtocols.Tls12,false,null,null);
      try {if(!handshake.AsyncWaitHandle.WaitOne(timeoutMs))throw new IOException();tls.EndAuthenticateAsClient(handshake);}
      finally {handshake.AsyncWaitHandle.Close();}
      string head=method+" "+address.AbsolutePath+" HTTP/1.1\r\nHost: "+address.Authority+"\r\nAuthorization: Bearer "+token
       +"\r\nConnection: close\r\n"+(method=="POST"?"Content-Type: application/json\r\nContent-Length: "+payload.Length+"\r\n":"")+"\r\n";
      byte[] headers=Encoding.ASCII.GetBytes(head);
      try {tls.Write(headers,0,headers.Length);tls.Write(payload,0,payload.Length);tls.Flush();}
      finally {Array.Clear(headers,0,headers.Length);}
      var text=new StringBuilder();int marker=0;
      while(marker!=4) {
       int next=tls.ReadByte();if(next<0)throw new IOException();
       text.Append((char)next);if(text.Length>16384)throw new InvalidOperationException("[TC:InvalidOnlineResponse]");
       marker=next==(marker%2==0?13:10)?marker+1:(next==13?1:0);
      }
      string[] lines=text.ToString().Split(new[]{"\r\n"},StringSplitOptions.None);
      var status=Regex.Match(lines[0],@"^HTTP/1\.[01] ([0-9]{3}) .*$");
      if(!status.Success)throw new InvalidOperationException("[TC:InvalidOnlineResponse]");
      int statusCode=Int32.Parse(status.Groups[1].Value);
      if(statusCode>=300&&statusCode<400)throw new InvalidOperationException("[TC:OnlineRedirectRefused]");
      var fields=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
      for(int i=1;i<lines.Length&&lines[i].Length>0;i++) {
       int colon=lines[i].IndexOf(':');if(colon<=0)throw new InvalidOperationException("[TC:InvalidOnlineResponse]");
       string name=lines[i].Substring(0,colon).Trim();
       if(fields.ContainsKey(name))throw new InvalidOperationException("[TC:InvalidOnlineResponse]");
       fields.Add(name,lines[i].Substring(colon+1).Trim());
      }
      string contentLength,contentType;int length;
      if(fields.ContainsKey("Transfer-Encoding")||!fields.TryGetValue("Content-Length",out contentLength)||!Int32.TryParse(contentLength,out length)
         ||length<0||length>Limit||!fields.TryGetValue("Content-Type",out contentType)||!contentType.StartsWith("application/json",StringComparison.OrdinalIgnoreCase))
       throw new InvalidOperationException("[TC:InvalidOnlineResponse]");
      byte[] result=new byte[length];int offset=0;
      while(offset<length){int count=tls.Read(result,offset,length-offset);if(count<=0)throw new IOException();offset+=count;}
      return new OnlineHttpResult{StatusCode=statusCode,Body=new UTF8Encoding(false,true).GetString(result)};
     }
     }
    }
   } catch(AuthenticationException) {
    throw new InvalidOperationException(rejectedCertificate?"[TC:OnlineTlsPinMismatch]":"[TC:OnlineConnectionFailed]");
   } catch(IOException) {
    throw new InvalidOperationException(rejectedCertificate?"[TC:OnlineTlsPinMismatch]":"[TC:OnlineConnectionFailed]");
   } catch(SocketException) {
    throw new InvalidOperationException("[TC:OnlineConnectionFailed]");
   } catch(ObjectDisposedException) {
    throw new InvalidOperationException("[TC:OnlineConnectionFailed]");
   } finally {
    Array.Clear(payload,0,payload.Length);
   }
  }

  // This entry can be called inside the existing DeployHost process with its
  // already pinned/authenticated SshClient. It never closes that SSH session.
  public static string ExecuteExisting(SshClient client,string command,string payload) {
   if(client==null||!client.IsConnected||String.IsNullOrEmpty(command)||Encoding.UTF8.GetByteCount(payload)>4194304)
    throw new InvalidOperationException("[TC:OnlineSshSessionRequired]");
   using(var remote=client.CreateCommand(command)) {
    remote.CommandTimeout=TimeSpan.FromSeconds(90);
    var execution=remote.ExecuteAsync(CancellationToken.None);
    var output=Task.Run(delegate{return ReadBounded(remote.OutputStream,262144);});
    var errors=Task.Run(delegate{return ReadBounded(remote.ExtendedOutputStream,65536);});
    byte[] bytes=Encoding.UTF8.GetBytes(payload);
    var sender=Task.Run(delegate {
     try {using(var input=remote.CreateInputStream()){input.Write(bytes,0,bytes.Length);input.Flush();}}
     finally {Array.Clear(bytes,0,bytes.Length);}
    });
    try {
     if(!Task.WaitAll(new Task[]{execution,output,errors,sender},90000))throw new InvalidOperationException("[TC:OnlineSshOutcomeUnknown]");
     // Remote stderr and exception messages may contain private data. Do not
     // surface them. A response envelope is checked by the PS API before use.
     string result=output.Result;
     if(String.IsNullOrWhiteSpace(result))throw new InvalidOperationException("[TC:OnlineSshOutcomeUnknown]");
     return result;
    } catch(Exception) {
     throw new InvalidOperationException("[TC:OnlineSshOutcomeUnknown]");
    }
   }
  }

  public static string ExecuteSsh(string host,int port,string user,string kind,string secret,string passphrase,string pinnedHostKey,string command,string payload) {
   IPAddress address;
   if(!IPAddress.TryParse(host,out address)||address.AddressFamily!=System.Net.Sockets.AddressFamily.InterNetwork||address.ToString()!=host
      ||port<1||port>65535||!Regex.IsMatch(user??"","^[a-z_][a-z0-9_-]{0,31}$")
      ||!Regex.IsMatch(pinnedHostKey??"","^SHA256:[A-Za-z0-9+/]{43}$"))throw new InvalidOperationException("[TC:InvalidOnlineSshTarget]");
   PrivateKeyFile privateKey=null;
   bool hostMismatch=false;
   try {
    AuthenticationMethod auth;
    if(kind=="Password")auth=new PasswordAuthenticationMethod(user,secret);
    else if(kind=="PrivateKey") {
     byte[] raw=Encoding.UTF8.GetBytes(secret);
     try {using(var input=new MemoryStream(raw))privateKey=new PrivateKeyFile(input,passphrase??"");}
     finally {Array.Clear(raw,0,raw.Length);}
     auth=new PrivateKeyAuthenticationMethod(user,privateKey);
    } else throw new InvalidOperationException("[TC:InvalidOnlineSshCredential]");
    var info=new ConnectionInfo(host,port,user,auth);info.Timeout=TimeSpan.FromSeconds(20);
    using(var client=new SshClient(info)) {
     client.HostKeyReceived+=delegate(object sender,HostKeyEventArgs e) {
      string actual;using(var sha=SHA256.Create())actual="SHA256:"+Convert.ToBase64String(sha.ComputeHash(e.HostKey)).TrimEnd('=');
      e.CanTrust=Same(actual,pinnedHostKey);hostMismatch=!e.CanTrust;
     };
     try {client.Connect();}
     catch(Exception error) {throw new InvalidOperationException((hostMismatch?"[TC:OnlineSshHostChanged]":"[TC:OnlineSshAuthenticationFailed]")+" "+error.GetType().Name);}
     return ExecuteExisting(client,command,payload);
    }
   } finally {if(privateKey!=null)privateKey.Dispose();}
  }
 }
}
