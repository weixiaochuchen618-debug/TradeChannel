using System;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Text;
using System.Web.Script.Serialization;
using Jose;
namespace TradeChannel.Deployment {
 public static class PairCrypto {
  static readonly JavaScriptSerializer serializer=new JavaScriptSerializer(){MaxJsonLength=131072,RecursionLimit=24};
  static Dictionary<string,object> Parse(string value){if(value==null||Encoding.UTF8.GetByteCount(value)>131072)throw new InvalidOperationException("PairingTooLarge");lock(serializer)return serializer.Deserialize<Dictionary<string,object>>(value);}
  static string Json(object value){lock(serializer)return serializer.Serialize(value);}
  public static string B64(byte[] value){return Convert.ToBase64String(value).TrimEnd('=').Replace('+','-').Replace('/','_');}
  public static byte[] Unb64(string value){if(value==null||value.Length>131072||!System.Text.RegularExpressions.Regex.IsMatch(value,"^[A-Za-z0-9_-]*$"))throw new InvalidOperationException("InvalidEncoding");return Convert.FromBase64String(value.Replace('-','+').Replace('_','/')+new string('=',(4-value.Length%4)%4));}
  public static string NewPrivateKey(){using(var rsa=new RSACng(3072)){return rsa.ToXmlString(true);}}
  static RSACng Private(string xml){var rsa=new RSACng();rsa.FromXmlString(xml);if(rsa.KeySize!=3072){rsa.Dispose();throw new InvalidOperationException("InvalidRecipientKey");}return rsa;}
  public static string PublicJwk(string xml){using(var rsa=Private(xml)){var p=rsa.ExportParameters(false);return Json(new Dictionary<string,object>{{"kty","RSA"},{"n",B64(p.Modulus)},{"e",B64(p.Exponent)}});}}
  static RSACng Public(string jwk){var j=Parse(jwk);if(j.Count!=3||!j.ContainsKey("kty")||!j.ContainsKey("n")||!j.ContainsKey("e")||(string)j["kty"]!="RSA"||(string)j["e"]!="AQAB")throw new InvalidOperationException("InvalidRecipientKey");var modulus=Unb64((string)j["n"]);if(modulus.Length!=384||(modulus[0]&128)==0)throw new InvalidOperationException("InvalidRecipientKey");var rsa=new RSACng();rsa.ImportParameters(new RSAParameters{Modulus=modulus,Exponent=Unb64((string)j["e"])});return rsa;}
  static Dictionary<string,object> Header(string compact,int parts,string alg,string enc=null){if(compact==null||Encoding.UTF8.GetByteCount(compact)>131072)throw new InvalidOperationException("PairingTooLarge");string[] p=compact.Split('.');if(p.Length!=parts)throw new InvalidOperationException("InvalidEnvelope");var h=Parse(new UTF8Encoding(false,true).GetString(Unb64(p[0])));foreach(var n in h.Keys)if(n!="alg"&&n!="enc"&&n!="typ"&&n!="cty"&&n!="p2c"&&n!="p2s")throw new InvalidOperationException("UnsupportedHeader");if(!h.ContainsKey("alg")||(string)h["alg"]!=alg||(enc!=null&&(!h.ContainsKey("enc")||(string)h["enc"]!=enc)))throw new InvalidOperationException("UnsupportedAlgorithm");if(parts==3&&(h.ContainsKey("enc")||h.ContainsKey("p2c")||h.ContainsKey("p2s")))throw new InvalidOperationException("UnsupportedHeader");return h;}
  public static string UnverifiedPayload(string compact){Header(compact,3,"RS256");return new UTF8Encoding(false,true).GetString(Unb64(compact.Split('.')[1]));}
  public static string Sign(string payload,string privateXml){Parse(payload);using(var rsa=Private(privateXml)){return JWT.Encode(payload,rsa,JwsAlgorithm.RS256,new Dictionary<string,object>{{"typ","JWT"}});}}
  public static string Verify(string compact,string jwk){Header(compact,3,"RS256");using(var rsa=Public(jwk)){return JWT.Decode(compact,rsa,JwsAlgorithm.RS256);}}
  public static string Encrypt(string signed,string jwk){Header(signed,3,"RS256");using(var rsa=Public(jwk)){return JWT.Encode(signed,rsa,JweAlgorithm.RSA_OAEP_256,JweEncryption.A256CBC_HS512,null,new Dictionary<string,object>{{"cty","TC-Pairing-v1"}});}}
  public static string Decrypt(string compact,string privateXml){Header(compact,5,"RSA-OAEP-256","A256CBC-HS512");using(var rsa=Private(privateXml)){return JWT.Decode(compact,rsa,JweAlgorithm.RSA_OAEP_256,JweEncryption.A256CBC_HS512);}}
  public static string Fingerprint(string jwk){using(var rsa=Public(jwk)){var p=rsa.ExportParameters(false);string canonical="{\"e\":\""+B64(p.Exponent)+"\",\"kty\":\"RSA\",\"n\":\""+B64(p.Modulus)+"\"}";using(var sha=SHA256.Create())return "SHA256:"+Convert.ToBase64String(sha.ComputeHash(Encoding.UTF8.GetBytes(canonical))).TrimEnd('=');}}
  public static string EncryptRecovery(string payload,string password,int iterations){Parse(payload);if(password==null||password.Length<12||password.Length>1024||iterations<10000||iterations>120000)throw new InvalidOperationException("InvalidRecoveryPassword");return JWT.Encode(payload,password,JweAlgorithm.PBES2_HS512_A256KW,JweEncryption.A256CBC_HS512,null,new Dictionary<string,object>{{"p2c",iterations},{"cty","TC-ManagementRecovery-v1"}});}
  public static string DecryptRecovery(string compact,string password){var h=Header(compact,5,"PBES2-HS512+A256KW","A256CBC-HS512");if(!h.ContainsKey("p2c")||!h.ContainsKey("p2s")||!(h["p2c"] is int))throw new InvalidOperationException("InvalidKdf");int iterations=(int)h["p2c"];byte[] salt=Unb64((string)h["p2s"]);if(iterations<10000||iterations>120000||salt.Length<12||salt.Length>64)throw new InvalidOperationException("InvalidKdf");if(password==null||password.Length>1024)throw new InvalidOperationException("InvalidRecoveryPassword");return JWT.Decode(compact,password,JweAlgorithm.PBES2_HS512_A256KW,JweEncryption.A256CBC_HS512);}
 }
}
