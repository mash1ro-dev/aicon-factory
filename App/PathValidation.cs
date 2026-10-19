using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Win32.SafeHandles;

namespace Aicon {
    public sealed class PathEntry {
        public string Path;
        public string FinalPath;
        public uint Attributes;
        public uint ReparseTag;
        public uint PlaceholderState;
        public int SyncRootHResult;
        public uint SyncRootReturnedLength;
        public ulong SyncRootFileId;
        public uint VolumeSerial;
        public ulong FileId;
        public string Kind;
    }

    // Metadata-only inspection. Never hydrates file contents or changes Cloud Files policy.
    public static class PathValidation {
        const uint ReadAttributes = 0x80, ShareAll = 7, OpenExisting = 3;
        const uint OpenReparse = 0x00200000, BackupSemantics = 0x02000000;
        const uint ReparseAttribute = 0x400, DirectoryAttribute = 0x10;
        [StructLayout(LayoutKind.Sequential)] struct AttributeTag { public uint Attributes, Tag; }
        [StructLayout(LayoutKind.Sequential)] struct HandleInfo {
            public uint Attributes, CreationLow, CreationHigh, AccessLow, AccessHigh, WriteLow, WriteHigh;
            public uint VolumeSerial, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool GetFileInformationByHandleEx(SafeFileHandle handle, int kind, out AttributeTag info, uint length);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool GetFileInformationByHandle(SafeFileHandle handle, out HandleInfo info);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, StringBuilder path, uint length, uint flags);
        [DllImport("cldapi.dll")]
        static extern uint CfGetPlaceholderStateFromAttributeTag(uint attributes, uint tag);
        [DllImport("cldapi.dll")]
        static extern int CfGetSyncRootInfoByHandle(SafeFileHandle handle, int infoClass, out ulong syncRootId, uint length, out uint returned);
        [DllImport("shell32.dll")]
        static extern int SHGetKnownFolderPath(ref Guid folder, uint flags, IntPtr token, out IntPtr path);

        public static string DesktopDirectory() {
            Guid id = new Guid("B4BFCC3A-DB2C-424C-B029-7FE99A87C641");
            IntPtr value;
            int hr = SHGetKnownFolderPath(ref id, 0, IntPtr.Zero, out value);
            if(hr != 0) Marshal.ThrowExceptionForHR(hr);
            try { return Marshal.PtrToStringUni(value); }
            finally { Marshal.FreeCoTaskMem(value); }
        }

        public static bool IsCloudTag(uint tag) {
            // Exactly Microsoft's CLOUD and CLOUD_1..F; excludes ONEDRIVE legacy,
            // PROJFS, APPEXECLINK, mount points, symlinks, and every unknown tag.
            return (tag & 0xFFFF0FFFu) == 0x9000001Au;
        }

        // Pure decision function, also exercised with explicit synthetic metadata in tests.
        // Production never accepts externally supplied metadata.
        public static string Classify(uint attributes, uint tag, uint state, int syncHr, uint returned, ulong rootId) {
            if((attributes & ReparseAttribute) == 0) {
                if(tag != 0) throw new IOException("属性と再解析タグが一致しません。");
                return "Ordinary";
            }
            if((tag & 0x20000000u) != 0) throw new IOException("シンボリックリンク／ジャンクション経由のパスは使用できません。");
            if(!IsCloudTag(tag)) throw new IOException("未対応の再解析タグを持つパスは使用できません。");
            if(state == 0xFFFFFFFFu || (state & 1u) == 0 || syncHr != 0 || returned < 8 || rootId == 0)
                throw new IOException("クラウドフォルダの同期ルートをWindowsで確認できません。");
            return "Cloud";
        }

        static string Normalize(string path) {
            if(String.IsNullOrWhiteSpace(path) || !Regex.IsMatch(path, @"^[A-Za-z]:[\\/]"))
                throw new IOException("ローカルの絶対パスを指定してください。");
            foreach(string part in path.Substring(3).Split(new char[]{'\\','/'})) {
                if(part.Length > 0 && (part == "." || part == ".." || Regex.IsMatch(part, @"[. ]$|[<>:""|?*\x00-\x1f]") ||
                    Regex.IsMatch(part, @"^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)", RegexOptions.IgnoreCase)))
                    throw new IOException("パスに無効な要素が含まれています。");
            }
            string full = System.IO.Path.GetFullPath(path);
            return full.Length > 3 ? full.TrimEnd('\\') : full;
        }
        static IOException InspectionError(string path, int error) {
            return new IOException("パスを安全に確認できません: " + path + " (Windows " + error + ")", new Win32Exception(error));
        }

        static PathEntry InspectOne(string path, bool allowMissing, bool enforce) {
            // OPEN_REPARSE_POINT opens the entry itself. Ancestors are verified root-first.
            using(SafeFileHandle handle = CreateFileW(path, ReadAttributes, ShareAll, IntPtr.Zero, OpenExisting, OpenReparse | BackupSemantics, IntPtr.Zero)) {
                if(handle.IsInvalid) {
                    int error = Marshal.GetLastWin32Error();
                    if(allowMissing && (error == 2 || error == 3)) return null;
                    throw InspectionError(path, error);
                }
                AttributeTag tag;
                if(!GetFileInformationByHandleEx(handle, 9, out tag, 8)) throw InspectionError(path, Marshal.GetLastWin32Error());
                HandleInfo info;
                if(!GetFileInformationByHandle(handle, out info)) throw InspectionError(path, Marshal.GetLastWin32Error());
                uint state = 0, returned = 0; ulong rootId = 0; int hr = -1;
                if((tag.Attributes & ReparseAttribute) != 0 && IsCloudTag(tag.Tag)) {
                    state = CfGetPlaceholderStateFromAttributeTag(tag.Attributes, tag.Tag);
                    hr = CfGetSyncRootInfoByHandle(handle, 0, out rootId, 8, out returned);
                }
                string kind = enforce ? Classify(tag.Attributes, tag.Tag, state, hr, returned, rootId) : "UnvalidatedMetadata";
                StringBuilder final = new StringBuilder(32768);
                uint count = GetFinalPathNameByHandleW(handle, final, (uint)final.Capacity, 0);
                if(count == 0 || count >= final.Capacity) throw InspectionError(path, Marshal.GetLastWin32Error());
                string resolved = final.ToString();
                if(!resolved.StartsWith(@"\\?\", StringComparison.Ordinal)) throw new IOException("最終パスを確認できません。");
                resolved = resolved.Substring(4);
                if(!String.Equals(resolved.TrimEnd('\\'), path.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
                    throw new IOException("指定パスとWindowsが解決した最終パスが一致しません。");
                if(info.Links > 1 && (tag.Attributes & DirectoryAttribute) == 0)
                    throw new IOException("複数のハードリンクを持つファイルは使用できません。");
                return new PathEntry { Path=path, FinalPath=resolved, Attributes=tag.Attributes, ReparseTag=tag.Tag,
                    PlaceholderState=state, SyncRootHResult=hr, SyncRootReturnedLength=returned, SyncRootFileId=rootId, VolumeSerial=info.VolumeSerial,
                    FileId=((ulong)info.IndexHigh << 32) | info.IndexLow, Kind=kind };
            }
        }

        public static PathEntry[] Inspect(string path, bool requireExists) {
            string full = Normalize(path);
            string root = System.IO.Path.GetPathRoot(full);
            List<string> pieces = new List<string>(); pieces.Add(root);
            string cursor = root;
            foreach(string part in full.Substring(root.Length).Split(new char[]{'\\'}, StringSplitOptions.RemoveEmptyEntries)) {
                cursor = System.IO.Path.Combine(cursor, part); pieces.Add(cursor);
            }
            List<PathEntry> entries = new List<PathEntry>();
            foreach(string component in pieces) {
                PathEntry entry = InspectOne(component, !requireExists, true);
                if(entry == null) break;
                if(component != full && (entry.Attributes & DirectoryAttribute) == 0) throw new IOException("パスの途中にファイルがあります。");
                entries.Add(entry);
            }
            if(requireExists && (entries.Count != pieces.Count)) throw new IOException("パスが見つかりません。");
            return entries.ToArray();
        }
        public static string Validate(string path) { Inspect(path, false); return Normalize(path); }
        public static PathEntry ReadMetadata(string path) { return InspectOne(Normalize(path), false, false); }
        public static string Identity(string path) {
            StringBuilder identity = new StringBuilder();
            foreach(PathEntry entry in Inspect(path, true))
                identity.Append(entry.Path.ToUpperInvariant()).Append('|').Append(entry.VolumeSerial).Append(':').Append(entry.FileId).Append('\n');
            return identity.ToString();
        }
        public sealed class DirectoryLease : IDisposable {
            internal readonly List<SafeFileHandle> Handles = new List<SafeFileHandle>();
            public void Dispose() { foreach(SafeFileHandle handle in Handles) handle.Dispose(); Handles.Clear(); }
        }
        public static DirectoryLease LeaseDirectories(string[] paths) {
            DirectoryLease lease = new DirectoryLease();
            HashSet<string> seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            try {
                foreach(string path in paths) foreach(PathEntry entry in Inspect(path, true)) {
                    if((entry.Attributes & DirectoryAttribute) == 0 || !seen.Add(entry.Path)) continue;
                    // Keep ancestors from being renamed/replaced during the write transaction.
                    // FILE_LIST_DIRECTORY participates in delete sharing; an attributes-only
                    // handle does not prevent rename on Windows.
                    SafeFileHandle handle = CreateFileW(entry.Path, ReadAttributes | 1, 3, IntPtr.Zero, OpenExisting, OpenReparse | BackupSemantics, IntPtr.Zero);
                    if(handle.IsInvalid) { int error=Marshal.GetLastWin32Error(); handle.Dispose(); throw InspectionError(entry.Path,error); }
                    lease.Handles.Add(handle);
                    HandleInfo info;
                    if(!GetFileInformationByHandle(handle,out info) || info.VolumeSerial != entry.VolumeSerial ||
                        (((ulong)info.IndexHigh << 32) | info.IndexLow) != entry.FileId)
                        throw new IOException("確認中にフォルダが変更されました。");
                    // Recheck tag, Windows cloud validation and final path after acquiring the lease.
                    Inspect(entry.Path,true);
                }
                return lease;
            } catch { lease.Dispose(); throw; }
        }
    }
}
