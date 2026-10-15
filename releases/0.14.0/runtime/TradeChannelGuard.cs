// TradeChannelGuard: Windows x64 / Windows PowerShell 5.1 / C# 5.
// Loading with Add-Type and calling SelfTest do NOT open WFP or change policy.
// Administrative mutation APIs are explicit; there is no static initializer I/O.
//
// SDK source (Microsoft, pinned commit, not inferred constants/layouts):
// https://github.com/microsoft/win32metadata/tree/5c5efbc01d4c87f6830ec304d42777991d533154/generation/WinSDK/RecompiledIdlHeaders
//   shared/fwptypes.h: FWP_VALUE0/CONDITION_VALUE0 unions, actions, match types, flags.
//   shared/fwpmtypes.h: FWPM_*0 structures and persistence/session flags.
//   um/fwpmu.h: layer/condition GUIDs and Fwpm*0 declarations.
//   shared/netioapi.h, shared/ifdef.h: interface conversion and NET_LUID.
// Contracts:
// https://learn.microsoft.com/en-us/windows/win32/fwp/filter-arbitration
// https://learn.microsoft.com/en-us/windows/win32/fwp/object-management
// https://learn.microsoft.com/en-us/windows/win32/api/fwpmu/nf-fwpmu-fwpmfilterenum0
// https://learn.microsoft.com/en-us/windows/win32/api/fwpmu/nf-fwpmu-fwpmfilterdeletebykey0
//
// Intended lifecycle (examples only; this file executes none of them):
// Add-Type -Path .\tools\TradeChannelGuard.cs
// [TradeChannelGuard]::SelfTest()
// [TradeChannelGuard]::InstallPersistentBlocks([string[]]$testExePaths)
// $lease = [TradeChannelGuard]::OpenTunPermit([string[]]$testExePaths, [uint32]$index)
// try { [TradeChannelGuard]::GetStatus() } finally { $lease.Dispose() }
// [TradeChannelGuard]::RemovePersistentBlocks()  # explicitly removes protection
//
// Install is ADDITIVE and idempotent: omitted programs remain blocked. Reinstall
// and Open replace/revoke the permit owned by THIS loaded helper first, even on
// invalid input. Only one permit lease per helper/provider may be open. Keep the
// returned lease alive; Dispose/process exit removes its dynamic filters, never
// the persistent blocks. A foreign session is reported, not forcefully deleted.
// List/GetStatus are read-only snapshots; they are not health attestations.
//
// Scope/limits: first-hop ALE connect policy, not WireGuard health supervision,
// per-packet enforcement, child-process policy, or proof of sing-box routing.
// Persistent filters start with BFE, not before BFE (no boot-time filters here).
// An earlier hard-permit/callout from another provider may affect arbitration.
// No watcher reopens permits after adapter recreation. Explicitly reopen after
// verifying TUN/route/health; do not reuse an interface index as a stable identity.
// Native/RPC cleanup failure is surfaced; no userspace helper can guarantee BFE
// cleanup while BFE/RPC itself is failing. Terminating the owning process also
// tears down its dynamic session. Never interpret an exception as successful
// removal of protection or successful permit revocation.

using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

public static class TradeChannelGuard
{
    // Project-owned GUIDs. These two are NOT Windows SDK identifiers.
    public static readonly Guid ProviderKey = new Guid("dac9cf91-079e-4e7b-92eb-27c142119d82");
    public static readonly Guid SubLayerKey = new Guid("5ae19025-7645-4e4f-bb8b-8c8d1a5de30d");
    public const string ProviderName = "TradeChannelGuard";
    public const string RequiredInterfaceAlias = "TradeChannel";

    // um/fwpmu.h, lines 455, 473, 1532, 1778, 1863 at the pinned SDK commit.
    private static readonly Guid Connect4 = new Guid("c38d57d1-05a7-4c33-904f-7fbceee60e82");
    private static readonly Guid Connect6 = new Guid("4a72393b-319f-44bc-84c3-ba54dcb3b6b4");
    private static readonly Guid NextHopInterface = new Guid("93ae8f5b-7f6f-4719-98c8-14e97429ef04");
    private static readonly Guid ConditionFlags = new Guid("632ce23b-5167-435c-86d7-e903684aa80c");
    private static readonly Guid AppId = new Guid("d78e1e87-8644-4ea5-9437-d809ecefc971");
    private static readonly Guid[] Layers = new Guid[] { Connect4, Connect6 };
    private static readonly byte[] OwnerMarker = Encoding.ASCII.GetBytes("TradeChannelGuard/v1");
    private const uint Persistent = 0x1;
    private const uint DynamicSession = 0x1;
    private const uint FilterDisabled = 0x20;
    private const uint FilterIndexed = 0x40;
    private const uint Block = 0x1001;
    private const uint Permit = 0x1002;
    private const uint UInt32Type = 3;
    private const uint UInt64Type = 4;
    private const uint ByteBlobType = 12;
    private const uint MatchEqual = 0;
    private const uint MatchFlagsNoneSet = 8;
    private const uint LoopbackFlag = 1;
    private const uint FilterNotFound = 0x80320003;
    private const uint ProviderNotFound = 0x80320005;
    private const uint SubLayerNotFound = 0x80320007;
    private const uint NoTransaction = 0x8032000D;
    private const ulong BlockWeight = 0x1000;
    private const ulong PermitWeight = 0x2000;
    private const ushort SubLayerWeight = 0xFFFF;
    private const string SubLayerName = "TradeChannelGuard ALE connect";
    private static readonly object Sync = new object();
    private static WeakReference activeLease;

    /// <summary>Adds missing blocks; never prunes previous programs. Returns both-family filter IDs.</summary>
    public static ulong[] InstallPersistentBlocks(string[] programPaths)
    {
        lock (Sync)
        {
            RevokeLocalPermit();
            SelfTest();
            using (OperationLock operation = new OperationLock())
            {
                ProgramIdentity[] programs = ResolvePrograms(programPaths);
                return WithEngine<ulong[]>(delegate(EngineHandle engine)
                {
                    return Transaction<ulong[]>(engine, false, delegate
                    {
                        EnsureInfrastructure(engine);
                        RejectExistingPermits(EnumerateFilters(engine));
                        List<ulong> ids = new List<ulong>();
                        foreach (ProgramIdentity program in programs)
                        {
                            foreach (Guid layer in Layers)
                            {
                                Guid key = FilterKey(program.AppBytes, layer, false);
                                FilterInfo found = ReadFilter(engine, key);
                                if (found != null)
                                {
                                    RequireBlock(found, program, layer);
                                    ids.Add(found.FilterId);
                                }
                                else
                                {
                                    ids.Add(AddFilter(engine, program, layer, false, 0));
                                }
                            }
                        }
                        return ids.ToArray();
                    });
                });
            }
        }
    }

    /// <summary>Requires installed exact blocks. Replaces this helper's old lease fail-closed.</summary>
    public static TunPermitLease OpenTunPermit(string[] programPaths, uint interfaceIndex)
    {
        lock (Sync)
        {
            RevokeLocalPermit();
            SelfTest();
            using (OperationLock operation = new OperationLock())
            {
                ProgramIdentity[] programs = ResolvePrograms(programPaths);
                ulong luid = ResolveTun(interfaceIndex);
                EngineHandle engine = OpenEngine(true);
                try
                {
                    // Allocate the lease before committing any allows.
                    TunPermitLease lease = new TunPermitLease(engine, interfaceIndex, luid);
                    WeakReference reference = new WeakReference(lease);
                    lease.SetFilterIds(Transaction<ulong[]>(engine, false, delegate
                    {
                        RequireInfrastructure(engine);
                        RejectExistingPermits(EnumerateFilters(engine));
                        foreach (ProgramIdentity program in programs)
                        {
                            foreach (Guid layer in Layers)
                                RequireBlock(ReadFilter(engine, FilterKey(program.AppBytes, layer, false)), program, layer);
                        }
                        List<ulong> ids = new List<ulong>();
                        foreach (ProgramIdentity program in programs)
                            foreach (Guid layer in Layers)
                                ids.Add(AddFilter(engine, program, layer, true, luid));
                        if (ResolveTun(interfaceIndex) != luid)
                            throw new InvalidOperationException("TradeChannel changed while opening the permit; transaction aborted.");
                        return ids.ToArray();
                    }));
                    activeLease = reference;
                    return lease; // ownership of engine transferred to the IDisposable lease
                }
                catch (Exception error)
                {
                    throw CloseAfterFailure(engine, error);
                }
            }
        }
    }

    /// <summary>Explicitly removes this project's protection; never deletes another provider's objects.</summary>
    public static int RemovePersistentBlocks()
    {
        lock (Sync)
        {
            RevokeLocalPermit();
            SelfTest();
            using (OperationLock operation = new OperationLock())
            {
                return WithEngine<int>(delegate(EngineHandle engine)
                {
                    return Transaction<int>(engine, false, delegate
                    {
                        bool provider = InspectProvider(engine, true);
                        bool subLayer = InspectSubLayer(engine, true);
                        FilterInfo[] filters = EnumerateFilters(engine);
                        foreach (FilterInfo filter in filters)
                        {
                            if (filter.IsPermit || !filter.IsPersistent)
                                throw new InvalidOperationException("Another session still owns a permit. Dispose its lease/process before removal: " + filter.FilterKey);
                            if (!filter.Recognized || !filter.IsPersistent || !filter.IsBlock)
                                throw new InvalidOperationException("Unrecognized project filter; refusing partial removal: " + filter.FilterKey);
                            Guid key = filter.FilterKey;
                            Check(Native.FwpmFilterDeleteByKey0(engine, ref key), "FwpmFilterDeleteByKey0");
                        }
                        if (subLayer)
                        {
                            Guid key = SubLayerKey;
                            Check(Native.FwpmSubLayerDeleteByKey0(engine, ref key), "FwpmSubLayerDeleteByKey0");
                        }
                        if (provider)
                        {
                            Guid key = ProviderKey;
                            Check(Native.FwpmProviderDeleteByKey0(engine, ref key), "FwpmProviderDeleteByKey0");
                        }
                        // Unexpected dependencies in OTHER layers/providers cause IN_USE and
                        // roll this entire transaction back. Never sweep unrelated objects.
                        return filters.Length;
                    });
                });
            }
        }
    }

    /// <summary>Read-only snapshot of this provider's two ALE connect layers, including disabled filters.</summary>
    public static FilterInfo[] List()
    {
        return GetStatus().Filters;
    }

    public static GuardStatus GetStatus()
    {
        lock (Sync)
        {
            SelfTest();
            return WithEngine<GuardStatus>(delegate(EngineHandle engine)
            {
                return Transaction<GuardStatus>(engine, true, delegate
                {
                    GuardStatus status = new GuardStatus();
                    status.ProviderKey = ProviderKey;
                    status.SubLayerKey = SubLayerKey;
                    status.ProviderPresent = InspectProvider(engine, false);
                    status.SubLayerPresent = InspectSubLayer(engine, false);
                    // Also detect GUID/name/marker conflicts; do not report them as healthy.
                    status.InfrastructureVerified = status.ProviderPresent && status.SubLayerPresent
                        && InspectProvider(engine, true) && InspectSubLayer(engine, true);
                    status.Filters = EnumerateFilters(engine);
                    TunPermitLease local = GetLocalLease();
                    status.LocalPermitOpen = local != null && !local.IsDisposed;
                    status.Scope = "Provider-scoped ALE_AUTH_CONNECT_V4/V6 snapshot; not a route/tunnel/boot-time health check.";
                    return status;
                });
            });
        }
    }

    /// <summary>Pure managed x64 ABI checks; does not load/open the WFP engine.</summary>
    public static LayoutInfo[] SelfTest()
    {
        if (Environment.OSVersion.Platform != PlatformID.Win32NT || IntPtr.Size != 8)
            throw new PlatformNotSupportedException("TradeChannelGuard requires 64-bit Windows and 64-bit PowerShell.");
        List<LayoutInfo> result = new List<LayoutInfo>();
        Size<DisplayData>(16, result);
        Size<ByteBlob>(16, result);
        Size<FwpValue>(16, result);
        Size<FwpConditionValue>(16, result);
        Size<FilterCondition>(40, result);
        Size<ActionData>(20, result);
        Size<ContextUnion>(16, result);
        Size<SessionData>(72, result);
        Size<ProviderData>(64, result);
        Size<SubLayerData>(72, result);
        Size<FilterData>(200, result);
        Size<FilterEnumTemplate>(72, result);
        Offset<ByteBlob>("Data", 8);
        Offset<FwpValue>("Pointer", 8);
        Offset<FwpConditionValue>("Pointer", 8);
        Offset<FilterCondition>("Value", 24);
        Offset<ActionData>("Key", 4);
        Offset<SessionData>("Sid", 48);
        Offset<SessionData>("KernelMode", 64);
        Offset<ProviderData>("Data", 40);
        Offset<ProviderData>("ServiceName", 56);
        Offset<SubLayerData>("ProviderKey", 40);
        Offset<SubLayerData>("Weight", 64);
        Offset<FilterData>("ProviderKey", 40);
        Offset<FilterData>("LayerKey", 64);
        Offset<FilterData>("Weight", 96);
        Offset<FilterData>("Conditions", 120);
        Offset<FilterData>("Action", 128);
        Offset<FilterData>("Context", 152);
        Offset<FilterData>("Reserved", 168);
        Offset<FilterData>("FilterId", 176);
        Offset<FilterData>("EffectiveWeight", 184);
        Offset<FilterEnumTemplate>("Conditions", 48);
        Offset<FilterEnumTemplate>("CalloutKey", 64);
        return result.ToArray();
    }

    public sealed class TunPermitLease : IDisposable
    {
        private readonly EngineHandle engine;
        private ulong[] filterIds = new ulong[0];
        public uint InterfaceIndex { get; private set; }
        public ulong InterfaceLuid { get; private set; }
        public string InterfaceAlias { get { return RequiredInterfaceAlias; } }
        public bool IsDisposed { get { return engine.IsClosed || engine.IsInvalid; } }
        public ulong[] FilterIds { get { return (ulong[])filterIds.Clone(); } }

        internal TunPermitLease(EngineHandle handle, uint index, ulong luid)
        {
            engine = handle;
            InterfaceIndex = index;
            InterfaceLuid = luid;
        }

        internal void SetFilterIds(ulong[] ids) { filterIds = ids; }

        public void Dispose()
        {
            lock (Sync)
            {
                engine.CloseChecked(); // does not mark closed if native close fails
                if (Object.ReferenceEquals(GetLocalLease(), this))
                    activeLease = null;
            }
        }
        // EngineHandle's critical finalizer is the fallback if the caller drops the lease.
    }

    public sealed class FilterInfo
    {
        public Guid FilterKey { get; internal set; }
        public ulong FilterId { get; internal set; }
        public Guid ProviderKey { get; internal set; }
        public Guid SubLayerKey { get; internal set; }
        public string Family { get; internal set; }
        public string Name { get; internal set; }
        public string ApplicationId { get; internal set; }
        public string Action { get; internal set; }
        public bool IsBlock { get; internal set; }
        public bool IsPermit { get; internal set; }
        public bool IsPersistent { get; internal set; }
        public bool IsDisabled { get; internal set; }
        public ulong Weight { get; internal set; }
        public ulong? NextHopInterfaceLuid { get; internal set; }
        public bool ExcludesLoopback { get; internal set; }
        public uint ConditionCount { get; internal set; }
        public bool Recognized { get; internal set; }
        internal byte[] ApplicationBytes;
        internal Guid LayerKey;
    }

    public sealed class GuardStatus
    {
        public Guid ProviderKey { get; internal set; }
        public Guid SubLayerKey { get; internal set; }
        public bool ProviderPresent { get; internal set; }
        public bool SubLayerPresent { get; internal set; }
        public bool InfrastructureVerified { get; internal set; }
        public bool LocalPermitOpen { get; internal set; }
        public FilterInfo[] Filters { get; internal set; }
        public string Scope { get; internal set; }
    }

    public sealed class LayoutInfo
    {
        public string Structure { get; internal set; }
        public int ActualSize { get; internal set; }
        public int ExpectedSize { get; internal set; }
    }

    public sealed class WfpException : Win32Exception
    {
        public uint WfpErrorCode { get; private set; }
        public string Operation { get; private set; }
        internal WfpException(string operation, uint code)
            : base(unchecked((int)code), operation + " failed: 0x" + code.ToString("X8")
                + " (" + code + "): " + new Win32Exception(unchecked((int)code)).Message)
        {
            WfpErrorCode = code;
            Operation = operation;
        }
    }

    private sealed class ProgramIdentity
    {
        internal string Path;
        internal byte[] AppBytes;
    }

    private static ProgramIdentity[] ResolvePrograms(string[] paths)
    {
        if (paths == null || paths.Length == 0)
            throw new ArgumentException("At least one absolute existing program path is required.", "programPaths");
        List<ProgramIdentity> programs = new List<ProgramIdentity>();
        HashSet<string> seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (string input in paths)
        {
            if (String.IsNullOrWhiteSpace(input))
                throw new ArgumentException("Program path is empty.", "programPaths");
            string path = input.Replace('/', '\\');
            bool drive = path.Length >= 3 && Char.IsLetter(path[0]) && path[1] == ':' && path[2] == '\\';
            bool unc = path.StartsWith("\\\\", StringComparison.Ordinal)
                && !path.StartsWith("\\\\?\\", StringComparison.Ordinal)
                && !path.StartsWith("\\\\.\\", StringComparison.Ordinal);
            if (!drive && !unc)
                throw new ArgumentException("Use a fully qualified DOS or UNC file path, not a relative/device path: " + input);
            path = System.IO.Path.GetFullPath(path);
            if (path.IndexOf(':', drive ? 2 : 0) >= 0 || !File.Exists(path))
                throw new ArgumentException("Program must be an existing file, not a directory or alternate data stream: " + path);
            IntPtr blob = IntPtr.Zero;
            try
            {
                Check(Native.FwpmGetAppIdFromFileName0(path, out blob), "FwpmGetAppIdFromFileName0(" + path + ")");
                byte[] app = ReadBlob(Read<ByteBlob>(blob));
                if (app.Length < 2 || (app.Length & 1) != 0)
                    throw new InvalidOperationException("Invalid application-ID blob returned for " + path);
                string identity = Convert.ToBase64String(app);
                if (seen.Add(identity))
                    programs.Add(new ProgramIdentity { Path = path, AppBytes = app });
            }
            finally { FreeWfp(ref blob); }
        }
        return programs.ToArray();
    }

    private static ulong ResolveTun(uint index)
    {
        if (index == 0) throw new ArgumentOutOfRangeException("interfaceIndex");
        ulong luid;
        Check(Native.ConvertInterfaceIndexToLuid(index, out luid), "ConvertInterfaceIndexToLuid");
        StringBuilder alias = new StringBuilder(257); // IF_MAX_STRING_SIZE + 1
        Check(Native.ConvertInterfaceLuidToAlias(ref luid, alias, new UIntPtr(257)), "ConvertInterfaceLuidToAlias");
        if (luid == 0 || !String.Equals(alias.ToString(), RequiredInterfaceAlias, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Interface " + index + " must be named " + RequiredInterfaceAlias + "; found " + alias + ".");
        return luid;
    }

    private static Guid FilterKey(byte[] app, Guid layer, bool permit)
    {
        // Deterministic project namespaced key over the EXACT SDK appId bytes.
        // Runtime filter IDs are assigned by BFE; key GUIDs remain stable across calls.
        byte[] prefix = Encoding.ASCII.GetBytes(ProviderKey.ToString("D") + "/v1/"
            + (permit ? "permit/" : "block/") + layer.ToString("D") + "/");
        byte[] data = new byte[prefix.Length + app.Length];
        Buffer.BlockCopy(prefix, 0, data, 0, prefix.Length);
        Buffer.BlockCopy(app, 0, data, prefix.Length, app.Length);
        using (SHA256 hash = SHA256.Create())
        {
            byte[] digest = hash.ComputeHash(data);
            byte[] key = new byte[16];
            Buffer.BlockCopy(digest, 0, key, 0, key.Length);
            return new Guid(key);
        }
    }

    private static void EnsureInfrastructure(EngineHandle engine)
    {
        using (Arena arena = new Arena())
        {
            if (!InspectProvider(engine, true))
            {
                ProviderData provider = new ProviderData();
                provider.Key = ProviderKey;
                provider.Display = arena.Display(ProviderName, "Persistent per-program TradeChannel guard, schema v1");
                provider.Flags = Persistent;
                provider.Data = arena.Blob(OwnerMarker);
                // No service binding: blocks must remain when the launching process exits.
                Check(Native.FwpmProviderAdd0(engine, ref provider, IntPtr.Zero), "FwpmProviderAdd0");
            }
            if (!InspectSubLayer(engine, true))
            {
                SubLayerData sub = new SubLayerData();
                sub.Key = SubLayerKey;
                sub.Display = arena.Display(SubLayerName, "High-weight soft permits above low-weight persistent blocks");
                sub.Flags = Persistent;
                sub.ProviderKey = arena.Struct(ProviderKey);
                sub.Data = arena.Blob(OwnerMarker);
                sub.Weight = SubLayerWeight;
                Check(Native.FwpmSubLayerAdd0(engine, ref sub, IntPtr.Zero), "FwpmSubLayerAdd0");
            }
        }
    }

    private static bool InspectProvider(EngineHandle engine, bool validate)
    {
        Guid key = ProviderKey;
        IntPtr ptr = IntPtr.Zero;
        try
        {
            uint code = Native.FwpmProviderGetByKey0(engine, ref key, out ptr);
            if (code == ProviderNotFound) return false;
            Check(code, "FwpmProviderGetByKey0");
            ProviderData provider = Read<ProviderData>(ptr);
            if (validate && (provider.Key != ProviderKey || provider.Flags != Persistent
                || provider.ServiceName != IntPtr.Zero
                || Marshal.PtrToStringUni(provider.Display.Name) != ProviderName
                || !EqualBytes(ReadBlob(provider.Data), OwnerMarker)))
                throw new InvalidOperationException("Provider GUID exists with a different definition; refusing to adopt or delete it.");
            return true;
        }
        finally { FreeWfp(ref ptr); }
    }

    private static bool InspectSubLayer(EngineHandle engine, bool validate)
    {
        Guid key = SubLayerKey;
        IntPtr ptr = IntPtr.Zero;
        try
        {
            uint code = Native.FwpmSubLayerGetByKey0(engine, ref key, out ptr);
            if (code == SubLayerNotFound) return false;
            Check(code, "FwpmSubLayerGetByKey0");
            SubLayerData sub = Read<SubLayerData>(ptr);
            if (validate && (sub.Key != SubLayerKey || sub.Flags != Persistent
                || ReadGuid(sub.ProviderKey) != ProviderKey || sub.Weight != SubLayerWeight
                || Marshal.PtrToStringUni(sub.Display.Name) != SubLayerName
                || !EqualBytes(ReadBlob(sub.Data), OwnerMarker)))
                throw new InvalidOperationException("Sub-layer GUID exists with a different definition; refusing to adopt or delete it.");
            return true;
        }
        finally { FreeWfp(ref ptr); }
    }

    private static void RequireInfrastructure(EngineHandle engine)
    {
        if (!InspectProvider(engine, true) || !InspectSubLayer(engine, true))
            throw new InvalidOperationException("Persistent guard is not installed; call InstallPersistentBlocks first.");
    }

    private static void RequireBlock(FilterInfo filter, ProgramIdentity program, Guid layer)
    {
        if (filter == null || !filter.Recognized || !filter.IsPersistent || filter.IsDisabled
            || !filter.IsBlock || filter.LayerKey != layer || !EqualBytes(filter.ApplicationBytes, program.AppBytes))
            throw new InvalidOperationException("Missing or mismatched persistent block for " + program.Path
                + " (" + (layer == Connect4 ? "IPv4" : "IPv6") + "); no permit opened.");
    }

    private static void RejectExistingPermits(FilterInfo[] filters)
    {
        foreach (FilterInfo filter in filters)
        {
            if (filter.IsPermit || !filter.IsPersistent)
                throw new InvalidOperationException("A different session or unrecognized filter still owns a permit: "
                    + filter.FilterKey + ". Dispose its owning lease/process first; persistent blocks were not removed.");
            if (!filter.Recognized || !filter.IsBlock || filter.IsDisabled)
                throw new InvalidOperationException("Unexpected project filter definition: " + filter.FilterKey);
        }
    }

    private static ulong AddFilter(EngineHandle engine, ProgramIdentity program, Guid layer, bool permit, ulong luid)
    {
        using (Arena arena = new Arena())
        {
            FilterCondition app = new FilterCondition();
            app.FieldKey = AppId;
            app.MatchType = MatchEqual;
            app.Value.Type = ByteBlobType;
            app.Value.Pointer = arena.Struct(arena.Blob(program.AppBytes));
            List<FilterCondition> conditions = new List<FilterCondition>();
            conditions.Add(app);
            if (permit)
            {
                FilterCondition nextHop = new FilterCondition();
                nextHop.FieldKey = NextHopInterface;
                nextHop.MatchType = MatchEqual;
                nextHop.Value.Type = UInt64Type;
                nextHop.Value.Pointer = arena.Struct(luid); // UINT64*, NOT inline UINT64!
                conditions.Add(nextHop);
                FilterCondition flags = new FilterCondition();
                flags.FieldKey = ConditionFlags;
                flags.MatchType = MatchFlagsNoneSet;
                flags.Value.Type = UInt32Type;
                flags.Value.UInt32 = LoopbackFlag;
                conditions.Add(flags);
            }
            FilterData filter = new FilterData();
            filter.Key = FilterKey(program.AppBytes, layer, permit);
            filter.Display = arena.Display(ProviderName + (permit ? " permit " : " block ")
                + (layer == Connect4 ? "IPv4 " : "IPv6 ") + program.Path, "TradeChannelGuard/v1");
            filter.Flags = permit ? 0U : Persistent;
            filter.ProviderKey = arena.Struct(ProviderKey);
            filter.Data = arena.Blob(OwnerMarker);
            filter.LayerKey = layer;
            filter.SubLayerKey = SubLayerKey;
            filter.Weight.Type = UInt64Type;
            filter.Weight.Pointer = arena.Struct(permit ? PermitWeight : BlockWeight);
            filter.ConditionCount = (uint)conditions.Count;
            filter.Conditions = arena.StructArray(conditions.ToArray());
            filter.Action.Type = permit ? Permit : Block;
            // Deliberately NO CLEAR_ACTION_RIGHT on permits: other firewall policy
            // retains the right to block. Ordering is only within OUR sub-layer.
            ulong id;
            Check(Native.FwpmFilterAdd0(engine, ref filter, IntPtr.Zero, out id), "FwpmFilterAdd0");
            return id;
        }
    }

    private static FilterInfo ReadFilter(EngineHandle engine, Guid key)
    {
        IntPtr ptr = IntPtr.Zero;
        try
        {
            uint code = Native.FwpmFilterGetByKey0(engine, ref key, out ptr);
            if (code == FilterNotFound) return null;
            Check(code, "FwpmFilterGetByKey0");
            return Describe(Read<FilterData>(ptr));
        }
        finally { FreeWfp(ref ptr); }
    }

    private static FilterInfo[] EnumerateFilters(EngineHandle engine)
    {
        List<FilterInfo> filters = new List<FilterInfo>();
        using (Arena arena = new Arena())
        {
            foreach (Guid layer in Layers)
            {
                FilterEnumTemplate template = new FilterEnumTemplate();
                template.ProviderKey = arena.Struct(ProviderKey);
                template.LayerKey = layer;
                template.EnumType = 0; // FWP_FILTER_ENUM_FULLY_CONTAINED
                template.Flags = 0x8 | 0x10; // INCLUDE_BOOTTIME | INCLUDE_DISABLED
                template.ActionMask = UInt32.MaxValue;
                IntPtr enumerator = IntPtr.Zero;
                Check(Native.FwpmFilterCreateEnumHandle0(engine, ref template, out enumerator), "FwpmFilterCreateEnumHandle0");
                try
                {
                    while (true)
                    {
                        IntPtr entries = IntPtr.Zero;
                        uint count;
                        try
                        {
                            Check(Native.FwpmFilterEnum0(engine, enumerator, 64, out entries, out count), "FwpmFilterEnum0");
                            for (uint i = 0; i < count; i++)
                            {
                                FilterData filter = Read<FilterData>(Marshal.ReadIntPtr(entries, checked((int)i * IntPtr.Size)));
                                if (ReadGuid(filter.ProviderKey) != ProviderKey)
                                    throw new InvalidOperationException("WFP enumeration returned a foreign provider; refusing to proceed.");
                                filters.Add(Describe(filter));
                            }
                        }
                        finally { FreeWfp(ref entries); } // free returned array once, not each element
                        if (count < 64) break;
                    }
                }
                finally { Check(Native.FwpmFilterDestroyEnumHandle0(engine, enumerator), "FwpmFilterDestroyEnumHandle0"); }
            }
        }
        return filters.ToArray();
    }

    private static FilterInfo Describe(FilterData filter)
    {
        FilterInfo info = new FilterInfo();
        info.FilterKey = filter.Key;
        info.FilterId = filter.FilterId;
        info.ProviderKey = ReadGuid(filter.ProviderKey);
        info.SubLayerKey = filter.SubLayerKey;
        info.LayerKey = filter.LayerKey;
        info.Family = filter.LayerKey == Connect4 ? "IPv4" : (filter.LayerKey == Connect6 ? "IPv6" : "Unknown");
        info.Name = Marshal.PtrToStringUni(filter.Display.Name);
        info.IsBlock = filter.Action.Type == Block;
        info.IsPermit = filter.Action.Type == Permit;
        info.Action = info.IsBlock ? "Block" : (info.IsPermit ? "Permit" : "Other");
        info.IsPersistent = (filter.Flags & Persistent) != 0;
        info.IsDisabled = (filter.Flags & FilterDisabled) != 0;
        info.ConditionCount = filter.ConditionCount;
        bool weightOk = filter.Weight.Type == UInt64Type && filter.Weight.Pointer != IntPtr.Zero;
        if (weightOk) info.Weight = unchecked((ulong)Marshal.ReadInt64(filter.Weight.Pointer));
        bool conditionsOk = filter.ConditionCount > 0 && filter.ConditionCount <= 3 && filter.Conditions != IntPtr.Zero;
        int apps = 0, nextHops = 0, flagConditions = 0;
        if (conditionsOk)
        {
            int size = Marshal.SizeOf(typeof(FilterCondition));
            for (int i = 0; i < (int)filter.ConditionCount; i++)
            {
                FilterCondition condition = Read<FilterCondition>(IntPtr.Add(filter.Conditions, i * size));
                if (condition.FieldKey == AppId && condition.MatchType == MatchEqual
                    && condition.Value.Type == ByteBlobType && condition.Value.Pointer != IntPtr.Zero)
                {
                    apps++;
                    info.ApplicationBytes = ReadBlob(Read<ByteBlob>(condition.Value.Pointer));
                    info.ApplicationId = Encoding.Unicode.GetString(info.ApplicationBytes).TrimEnd('\0');
                }
                else if (condition.FieldKey == NextHopInterface && condition.MatchType == MatchEqual
                    && condition.Value.Type == UInt64Type && condition.Value.Pointer != IntPtr.Zero)
                {
                    nextHops++;
                    info.NextHopInterfaceLuid = unchecked((ulong)Marshal.ReadInt64(condition.Value.Pointer));
                }
                else if (condition.FieldKey == ConditionFlags && condition.MatchType == MatchFlagsNoneSet
                    && condition.Value.Type == UInt32Type && condition.Value.UInt32 == LoopbackFlag)
                {
                    flagConditions++;
                    info.ExcludesLoopback = true;
                }
                else conditionsOk = false;
            }
        }
        bool baseOk = conditionsOk && apps == 1 && info.ApplicationBytes.Length >= 2
            && (info.ApplicationBytes.Length & 1) == 0 && info.ProviderKey == ProviderKey
            && info.SubLayerKey == SubLayerKey && info.Family != "Unknown" && weightOk
            && EqualBytes(ReadBlob(filter.Data), OwnerMarker)
            && filter.Action.Key == Guid.Empty && filter.Context.Key == Guid.Empty
            && (filter.Flags & ~(Persistent | FilterDisabled | FilterIndexed)) == 0;
        if (baseOk)
        {
            info.Recognized = info.FilterKey == FilterKey(info.ApplicationBytes, filter.LayerKey, info.IsPermit)
                && ((info.IsBlock && info.IsPersistent && info.Weight == BlockWeight
                    && filter.ConditionCount == 1 && nextHops == 0 && flagConditions == 0)
                || (info.IsPermit && !info.IsPersistent && info.Weight == PermitWeight
                    && filter.ConditionCount == 3 && nextHops == 1 && flagConditions == 1
                    && info.NextHopInterfaceLuid.HasValue && info.NextHopInterfaceLuid.Value != 0));
        }
        return info;
    }

    private static T WithEngine<T>(Func<EngineHandle, T> work)
    {
        EngineHandle engine = OpenEngine(false);
        try
        {
            T result = work(engine);
            engine.CloseChecked();
            return result;
        }
        catch (Exception error) { throw CloseAfterFailure(engine, error); }
    }

    private static T Transaction<T>(EngineHandle engine, bool readOnly, Func<T> work)
    {
        Check(Native.FwpmTransactionBegin0(engine, readOnly ? 1U : 0U), "FwpmTransactionBegin0");
        try
        {
            T result = work();
            Check(Native.FwpmTransactionCommit0(engine), "FwpmTransactionCommit0");
            return result;
        }
        catch (Exception error)
        {
            uint code = Native.FwpmTransactionAbort0(engine);
            if (code != 0 && code != NoTransaction)
                throw new AggregateException("Operation and WFP rollback both failed; the session will be closed.",
                    error, new WfpException("FwpmTransactionAbort0", code));
            throw;
        }
    }

    private static Exception CloseAfterFailure(EngineHandle engine, Exception error)
    {
        try { engine.CloseChecked(); }
        catch (Exception closeError)
        {
            return new AggregateException("Operation failed AND WFP session close failed; revocation is unconfirmed. "
                + "Do not infer policy state from this exception. Close the owning process to trigger RPC rundown, then inspect status.", error, closeError);
        }
        return error;
    }

    private static EngineHandle OpenEngine(bool dynamic)
    {
        using (Arena arena = new Arena())
        {
            SessionData session = new SessionData();
            session.Display = arena.Display(ProviderName, dynamic ? "Dynamic TUN permit lease" : "Guard management/read session");
            session.Flags = dynamic ? DynamicSession : 0U;
            session.TransactionWaitMilliseconds = 10000;
            IntPtr handle;
            // RPC_C_AUTHN_WINNT == 10, explicit local authenticated session.
            Check(Native.FwpmEngineOpen0(null, 10, IntPtr.Zero, ref session, out handle), "FwpmEngineOpen0");
            return new EngineHandle(handle);
        }
    }

    internal sealed class EngineHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        internal EngineHandle(IntPtr value) : base(true) { SetHandle(value); }
        internal void CloseChecked()
        {
            if (IsClosed || IsInvalid) return;
            // All explicit uses/closure are under Sync. P/Invoke methods using this
            // SafeHandle also retain it for the duration of the native call.
            Check(Native.FwpmEngineClose0(handle), "FwpmEngineClose0");
            SetHandleAsInvalid();
            Dispose();
        }
        protected override bool ReleaseHandle()
        {
            return Native.FwpmEngineClose0(handle) == 0;
        }
    }

    private sealed class OperationLock : IDisposable
    {
        private readonly Mutex mutex;
        private bool acquired;
        internal OperationLock()
        {
            mutex = new Mutex(false, "Global\\TradeChannelGuard-" + ProviderKey.ToString("D"));
            try
            {
                try { acquired = mutex.WaitOne(10000); }
                catch (AbandonedMutexException) { acquired = true; }
                if (!acquired) throw new TimeoutException("Another TradeChannelGuard operation holds the management lock.");
            }
            catch { mutex.Dispose(); throw; }
        }
        public void Dispose()
        {
            try { if (acquired) mutex.ReleaseMutex(); }
            finally { acquired = false; mutex.Dispose(); }
        }
    }

    private static TunPermitLease GetLocalLease()
    {
        return activeLease == null ? null : activeLease.Target as TunPermitLease;
    }

    private static void RevokeLocalPermit()
    {
        TunPermitLease lease = GetLocalLease();
        if (lease != null) lease.Dispose();
        activeLease = null;
    }

    private static void Check(uint code, string operation)
    {
        if (code != 0) throw new WfpException(operation, code);
    }

    private static T Read<T>(IntPtr pointer) where T : struct
    {
        if (pointer == IntPtr.Zero) throw new InvalidOperationException("WFP returned an unexpected NULL pointer.");
        return (T)Marshal.PtrToStructure(pointer, typeof(T));
    }

    private static Guid ReadGuid(IntPtr pointer)
    {
        return pointer == IntPtr.Zero ? Guid.Empty : Read<Guid>(pointer);
    }

    private static byte[] ReadBlob(ByteBlob blob)
    {
        if (blob.Size > 1048576 || (blob.Size > 0 && blob.Data == IntPtr.Zero))
            throw new InvalidOperationException("Invalid or oversized WFP byte blob.");
        byte[] bytes = new byte[checked((int)blob.Size)];
        if (bytes.Length != 0) Marshal.Copy(blob.Data, bytes, 0, bytes.Length);
        return bytes;
    }

    private static bool EqualBytes(byte[] a, byte[] b)
    {
        if (a == null || b == null || a.Length != b.Length) return false;
        for (int i = 0; i < a.Length; i++) if (a[i] != b[i]) return false;
        return true;
    }

    private static void FreeWfp(ref IntPtr pointer)
    {
        if (pointer != IntPtr.Zero) Native.FwpmFreeMemory0(ref pointer);
    }

    private static void Size<T>(int expected, List<LayoutInfo> result)
    {
        int actual = Marshal.SizeOf(typeof(T));
        if (actual != expected) throw new TypeLoadException(typeof(T).Name + " ABI size: " + actual + "; expected " + expected);
        result.Add(new LayoutInfo { Structure = typeof(T).Name, ActualSize = actual, ExpectedSize = expected });
    }

    private static void Offset<T>(string field, int expected)
    {
        int actual = Marshal.OffsetOf(typeof(T), field).ToInt32();
        if (actual != expected) throw new TypeLoadException(typeof(T).Name + "." + field + " ABI offset: " + actual + "; expected " + expected);
    }

    private sealed class Arena : IDisposable
    {
        private readonly List<IntPtr> allocations = new List<IntPtr>();
        private IntPtr Allocate(int size)
        {
            IntPtr ptr = Marshal.AllocHGlobal(size);
            try { allocations.Add(ptr); }
            catch { Marshal.FreeHGlobal(ptr); throw; }
            return ptr;
        }
        internal IntPtr Struct<T>(T value) where T : struct
        {
            IntPtr ptr = Allocate(Marshal.SizeOf(typeof(T)));
            Marshal.StructureToPtr(value, ptr, false);
            return ptr;
        }
        internal IntPtr StructArray<T>(T[] values) where T : struct
        {
            int size = Marshal.SizeOf(typeof(T));
            IntPtr ptr = Allocate(checked(size * values.Length));
            for (int i = 0; i < values.Length; i++)
                Marshal.StructureToPtr(values[i], IntPtr.Add(ptr, i * size), false);
            return ptr;
        }
        internal ByteBlob Blob(byte[] data)
        {
            IntPtr ptr = data.Length == 0 ? IntPtr.Zero : Allocate(data.Length);
            if (data.Length != 0) Marshal.Copy(data, 0, ptr, data.Length);
            return new ByteBlob { Size = (uint)data.Length, Data = ptr };
        }
        private IntPtr Text(string value)
        {
            return Blob(Encoding.Unicode.GetBytes(value + "\0")).Data;
        }
        internal DisplayData Display(string name, string description)
        {
            return new DisplayData { Name = Text(name), Description = Text(description) };
        }
        public void Dispose()
        {
            for (int i = allocations.Count - 1; i >= 0; i--) Marshal.FreeHGlobal(allocations[i]);
            allocations.Clear();
        }
    }

    // All interop structures are blittable; no managed references inside native unions.
    // x64 Windows SDK packing is 8; explicit unions retain their full native sizes.
    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    private struct DisplayData { public IntPtr Name; public IntPtr Description; }

    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    private struct ByteBlob { public uint Size; public IntPtr Data; }

    [StructLayout(LayoutKind.Explicit, Size = 16)]
    private struct FwpValue
    {
        [FieldOffset(0)] public uint Type;
        [FieldOffset(8)] public uint UInt32;
        [FieldOffset(8)] public IntPtr Pointer;
    }

    [StructLayout(LayoutKind.Explicit, Size = 16)]
    private struct FwpConditionValue
    {
        [FieldOffset(0)] public uint Type;
        [FieldOffset(8)] public uint UInt32;
        [FieldOffset(8)] public IntPtr Pointer;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    private struct FilterCondition { public Guid FieldKey; public uint MatchType; public FwpConditionValue Value; }

    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    private struct ActionData { public uint Type; public Guid Key; }

    [StructLayout(LayoutKind.Explicit, Size = 16)]
    private struct ContextUnion
    {
        [FieldOffset(0)] public ulong RawContext;
        [FieldOffset(0)] public Guid Key;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    private struct SessionData
    {
        public Guid Key;
        public DisplayData Display;
        public uint Flags;
        public uint TransactionWaitMilliseconds;
        public uint ProcessId;
        public IntPtr Sid;
        public IntPtr Username;
        public int KernelMode;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    private struct ProviderData
    {
        public Guid Key;
        public DisplayData Display;
        public uint Flags;
        public ByteBlob Data;
        public IntPtr ServiceName;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    private struct SubLayerData
    {
        public Guid Key;
        public DisplayData Display;
        public uint Flags;
        public IntPtr ProviderKey;
        public ByteBlob Data;
        public ushort Weight;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    private struct FilterData
    {
        public Guid Key;
        public DisplayData Display;
        public uint Flags;
        public IntPtr ProviderKey;
        public ByteBlob Data;
        public Guid LayerKey;
        public Guid SubLayerKey;
        public FwpValue Weight;
        public uint ConditionCount;
        public IntPtr Conditions;
        public ActionData Action;
        public ContextUnion Context;
        public IntPtr Reserved;
        public ulong FilterId;
        public FwpValue EffectiveWeight;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    private struct FilterEnumTemplate
    {
        public IntPtr ProviderKey;
        public Guid LayerKey;
        public uint EnumType;
        public uint Flags;
        public IntPtr ProviderContextTemplate;
        public uint ConditionCount;
        public IntPtr Conditions;
        public uint ActionMask;
        public IntPtr CalloutKey;
    }

    private static class Native
    {
        // WFP returns DWORD status directly. Never use GetLastWin32Error for these APIs.
        [DllImport("fwpuclnt.dll", ExactSpelling = true, CharSet = CharSet.Unicode)]
        internal static extern uint FwpmEngineOpen0(string serverName, uint authenticationService, IntPtr authenticationIdentity, ref SessionData session, out IntPtr engine);
        [DllImport("fwpuclnt.dll", ExactSpelling = true)]
        internal static extern uint FwpmEngineClose0(IntPtr engine);
        [DllImport("fwpuclnt.dll", ExactSpelling = true)]
        internal static extern uint FwpmTransactionBegin0(EngineHandle engine, uint flags);
        [DllImport("fwpuclnt.dll", ExactSpelling = true)]
        internal static extern uint FwpmTransactionCommit0(EngineHandle engine);
        [DllImport("fwpuclnt.dll", ExactSpelling = true)]
        internal static extern uint FwpmTransactionAbort0(EngineHandle engine);
        [DllImport("fwpuclnt.dll", ExactSpelling = true)]
        internal static extern uint FwpmProviderAdd0(EngineHandle engine, ref ProviderData provider, IntPtr securityDescriptor);
        [DllImport("fwpuclnt.dll", ExactSpelling = true)]
        internal static extern uint FwpmProviderGetByKey0(EngineHandle engine, ref Guid key, out IntPtr provider);
        [DllImport("fwpuclnt.dll", ExactSpelling = true)]
        internal static extern uint FwpmProviderDeleteByKey0(EngineHandle engine, ref Guid key);
        [DllImport("fwpuclnt.dll", ExactSpelling = true)]
        internal static extern uint FwpmSubLayerAdd0(EngineHandle engine, ref SubLayerData subLayer, IntPtr securityDescriptor);
        [DllImport("fwpuclnt.dll", ExactSpelling = true)]
        internal static extern uint FwpmSubLayerGetByKey0(EngineHandle engine, ref Guid key, out IntPtr subLayer);
        [DllImport("fwpuclnt.dll", ExactSpelling = true)]
        internal static extern uint FwpmSubLayerDeleteByKey0(EngineHandle engine, ref Guid key);
        [DllImport("fwpuclnt.dll", ExactSpelling = true)]
        internal static extern uint FwpmFilterAdd0(EngineHandle engine, ref FilterData filter, IntPtr securityDescriptor, out ulong id);
        [DllImport("fwpuclnt.dll", ExactSpelling = true)]
        internal static extern uint FwpmFilterGetByKey0(EngineHandle engine, ref Guid key, out IntPtr filter);
        [DllImport("fwpuclnt.dll", ExactSpelling = true)]
        internal static extern uint FwpmFilterDeleteByKey0(EngineHandle engine, ref Guid key);
        [DllImport("fwpuclnt.dll", ExactSpelling = true)]
        internal static extern uint FwpmFilterCreateEnumHandle0(EngineHandle engine, ref FilterEnumTemplate template, out IntPtr enumerator);
        [DllImport("fwpuclnt.dll", ExactSpelling = true)]
        internal static extern uint FwpmFilterEnum0(EngineHandle engine, IntPtr enumerator, uint requested, out IntPtr entries, out uint returned);
        [DllImport("fwpuclnt.dll", ExactSpelling = true)]
        internal static extern uint FwpmFilterDestroyEnumHandle0(EngineHandle engine, IntPtr enumerator);
        [DllImport("fwpuclnt.dll", ExactSpelling = true)]
        internal static extern void FwpmFreeMemory0(ref IntPtr memory);
        [DllImport("fwpuclnt.dll", ExactSpelling = true, CharSet = CharSet.Unicode)]
        internal static extern uint FwpmGetAppIdFromFileName0(string fileName, out IntPtr appId);
        [DllImport("iphlpapi.dll", ExactSpelling = true)]
        internal static extern uint ConvertInterfaceIndexToLuid(uint index, out ulong luid);
        [DllImport("iphlpapi.dll", ExactSpelling = true, CharSet = CharSet.Unicode)]
        internal static extern uint ConvertInterfaceLuidToAlias(ref ulong luid, StringBuilder alias, UIntPtr length);
    }
}
