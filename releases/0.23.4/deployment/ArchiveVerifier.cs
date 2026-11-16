using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
namespace TradeChannel.Packaging {
 public static class ArchiveVerifier {
  static readonly uint[] Table=MakeTable();
  static uint[] MakeTable(){var table=new uint[256];for(uint i=0;i<256;i++){uint crc=i;for(int j=0;j<8;j++)crc=(crc&1)!=0?0xedb88320U^(crc>>1):crc>>1;table[i]=crc;}return table;}
  static Dictionary<string,uint> Central(string path){
   using(var file=File.OpenRead(path))using(var reader=new BinaryReader(file)){
    if(file.Length>UInt32.MaxValue)throw new InvalidDataException("ZIP64 is outside this release contract.");long start=Math.Max(0,file.Length-65557);file.Position=start;byte[] tail=reader.ReadBytes((int)(file.Length-start));int found=-1;
    for(int i=tail.Length-22;i>=0;i--)if(BitConverter.ToUInt32(tail,i)==0x06054b50U){found=i;break;}
    if(found<0)throw new InvalidDataException("Missing end-of-central-directory.");
    if(BitConverter.ToUInt16(tail,found+4)!=0||BitConverter.ToUInt16(tail,found+6)!=0)throw new InvalidDataException("Multi-disk ZIP not supported.");
    int count=BitConverter.ToUInt16(tail,found+10);uint size=BitConverter.ToUInt32(tail,found+12),offset=BitConverter.ToUInt32(tail,found+16);if(count>4096||(long)offset+size>file.Length)throw new InvalidDataException("Central directory bounds invalid.");
    file.Position=offset;var crcs=new Dictionary<string,uint>(StringComparer.Ordinal);
    for(int i=0;i<count;i++){if(reader.ReadUInt32()!=0x02014b50U)throw new InvalidDataException("Invalid central entry.");reader.ReadUInt16();reader.ReadUInt16();ushort flags=reader.ReadUInt16();reader.ReadUInt16();reader.ReadUInt16();reader.ReadUInt16();uint crc=reader.ReadUInt32();reader.ReadUInt32();uint expanded=reader.ReadUInt32();int nameLength=reader.ReadUInt16(),extraLength=reader.ReadUInt16(),commentLength=reader.ReadUInt16();reader.ReadUInt16();reader.ReadUInt16();reader.ReadUInt32();reader.ReadUInt32();
     if((flags&1)!=0||expanded>268435456)throw new InvalidDataException("Encrypted or oversized entry.");byte[] name=reader.ReadBytes(nameLength);if(name.Length!=nameLength)throw new EndOfStreamException();string text=((flags&2048)!=0?new UTF8Encoding(false,true):Encoding.GetEncoding(437)).GetString(name);reader.ReadBytes(extraLength+commentLength);if(crcs.ContainsKey(text))throw new InvalidDataException("Duplicate entry.");crcs.Add(text,crc);
    }return crcs;
   }
  }
  public static int Verify(string archivePath,string stageRoot){
   var hashes=new Dictionary<string,string>(StringComparer.Ordinal);string boundary=Path.GetFullPath(stageRoot).TrimEnd(Path.DirectorySeparatorChar)+Path.DirectorySeparatorChar;
   foreach(string file in Directory.GetFiles(stageRoot,"*",SearchOption.AllDirectories)){string name=file.Substring(boundary.Length).Replace('\\','/');using(var algorithm=SHA256.Create())using(var stream=File.OpenRead(file))hashes.Add(name,BitConverter.ToString(algorithm.ComputeHash(stream)).Replace("-",""));}
   return VerifyHashes(archivePath,hashes);
  }
  public static int VerifyExpected(string archivePath,string[] rows){
   if(rows==null||rows.Length>4096)throw new InvalidDataException("Invalid expected file list.");var hashes=new Dictionary<string,string>(StringComparer.Ordinal);
   foreach(string row in rows){if(row==null||row.Length<66||row[64]!='|'||!System.Text.RegularExpressions.Regex.IsMatch(row.Substring(0,64),"^[A-F0-9]{64}$"))throw new InvalidDataException("Invalid expected checksum row.");string name=row.Substring(65).Replace('\\','/');if(hashes.ContainsKey(name))throw new InvalidDataException("Duplicate expected checksum row.");hashes.Add(name,row.Substring(0,64));}
   return VerifyHashes(archivePath,hashes);
  }
  static int VerifyHashes(string archivePath,Dictionary<string,string> hashes){
   var crcMap=Central(archivePath);
   using(var archive=ZipFile.OpenRead(archivePath)){
    if(archive.Entries.Count!=hashes.Count||archive.Entries.Count!=crcMap.Count)throw new InvalidDataException("Entries differ from staging.");
    foreach(var entry in archive.Entries){string name=entry.FullName;if(name.Contains("\\")||name.StartsWith("/")||name.Contains(":")||name.Contains("../")||!hashes.ContainsKey(name))throw new InvalidDataException("Unexpected path.");
     uint crc=0xffffffffU;using(var algorithm=SHA256.Create())using(var stream=entry.Open()){byte[] bytes=new byte[65536];int read;while((read=stream.Read(bytes,0,bytes.Length))>0){for(int i=0;i<read;i++)crc=Table[(crc^bytes[i])&255]^(crc>>8);algorithm.TransformBlock(bytes,0,read,null,0);}algorithm.TransformFinalBlock(new byte[0],0,0);if((crc^0xffffffffU)!=crcMap[name])throw new InvalidDataException("CRC mismatch.");if(BitConverter.ToString(algorithm.Hash).Replace("-","")!=hashes[name])throw new InvalidDataException("SHA256 mismatch.");}
    }
   }return hashes.Count;
  }
 }
}
