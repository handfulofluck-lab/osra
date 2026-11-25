using System.ComponentModel;
using System.Diagnostics;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;

namespace FamilyShield.Agent.Services;

public sealed record ClientIdentity(int SessionId, string UserSid, int ProcessId = 0, string? ImagePath = null);

public interface IClientIdentitySource
{
    ClientIdentity Read(int clientPid);
}

public sealed class TrayClientIdentity
{
    private readonly IClientIdentitySource _source;

    public TrayClientIdentity(IClientIdentitySource? source = null)
    {
        _source = source ?? new WindowsClientIdentitySource();
    }

    public void Verify(int clientPid, int expectedSessionId, string expectedSid,
        int? expectedPid = null, string? expectedImagePath = null)
    {
        var identity = _source.Read(clientPid);
        if (identity.SessionId != expectedSessionId || identity.UserSid != expectedSid)
            throw new UnauthorizedAccessException("The tray client is not the expected user in this session.");
        if (expectedPid is not null && identity.ProcessId != expectedPid)
            throw new UnauthorizedAccessException("The pipe client is not the process launched for this session.");
        if (expectedImagePath is not null &&
            (identity.ImagePath is null || !string.Equals(Path.GetFullPath(identity.ImagePath),
                Path.GetFullPath(expectedImagePath), StringComparison.OrdinalIgnoreCase)))
        {
            throw new UnauthorizedAccessException("The pipe client is not the installed tray image.");
        }
    }

    public static int ClientProcessId(PipeStream stream)
    {
        if (!NativePipeMethods.GetNamedPipeClientProcessId(stream.SafePipeHandle.DangerousGetHandle(), out var pid))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        return checked((int)pid);
    }

    public static int ServerProcessId(PipeStream stream)
    {
        if (!NativePipeMethods.GetNamedPipeServerProcessId(stream.SafePipeHandle.DangerousGetHandle(), out var pid))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        return checked((int)pid);
    }

    public static int ServerSessionId(PipeStream stream)
    {
        if (!NativePipeMethods.GetNamedPipeServerSessionId(stream.SafePipeHandle.DangerousGetHandle(), out var sessionId))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        return checked((int)sessionId);
    }
}

internal sealed class WindowsClientIdentitySource : IClientIdentitySource
{
    public ClientIdentity Read(int clientPid)
    {
        using var process = Process.GetProcessById(clientPid);
        if (!NativePipeMethods.OpenProcessToken(process.Handle, NativePipeMethods.TokenQuery, out var token))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        try
        {
            using var identity = new WindowsIdentity(token);
            return new ClientIdentity(process.SessionId, identity.User!.Value, process.Id, process.MainModule?.FileName);
        }
        finally
        {
            NativePipeMethods.CloseHandle(token);
        }
    }
}

internal static class ProcessIdentityQuery
{
    private const int SystemProcessIdInformation = 88;
    private const uint SeKernelObject = 6;
    private const uint OwnerSecurityInformation = 0x00000001;

    /// <summary>
    /// Reads the process token user SID when accessible via <c>PROCESS_QUERY_LIMITED_INFORMATION</c>,
    /// returning null when access is denied (e.g., a standard user inspecting a SYSTEM service).
    /// </summary>
    public static string? TryReadProcessUserSid(int pid)
    {
        var hProc = NativePipeMethods.OpenProcess(NativePipeMethods.ProcessQueryLimitedInformation, false, pid);
        if (hProc == IntPtr.Zero) return null;
        try
        {
            if (!NativePipeMethods.OpenProcessToken(hProc, NativePipeMethods.TokenQuery, out var hToken))
                return null;
            try
            {
                using var identity = new WindowsIdentity(hToken);
                return identity.User?.Value;
            }
            finally
            {
                NativePipeMethods.CloseHandle(hToken);
            }
        }
        finally
        {
            NativePipeMethods.CloseHandle(hProc);
        }
    }

    /// <summary>
    /// Reads the kernel owner SID of a connected named-pipe handle via <c>GetSecurityInfo</c>.
    /// Requires only <c>READ_CONTROL</c> on the pipe handle and is kernel-enforced (a non-admin
    /// process cannot forge <c>S-1-5-18</c> as pipe owner).
    /// </summary>
    public static string? TryReadPipeOwnerSid(PipeStream stream)
    {
        var status = NativePipeMethods.GetSecurityInfo(
            stream.SafePipeHandle.DangerousGetHandle(),
            SeKernelObject,
            OwnerSecurityInformation,
            out var pOwnerSid,
            out _,
            out _,
            out _,
            out var pSecurityDescriptor);
        if (status != 0) return null;
        try
        {
            if (pOwnerSid == IntPtr.Zero) return null;
            return new SecurityIdentifier(pOwnerSid).Value;
        }
        finally
        {
            if (pSecurityDescriptor != IntPtr.Zero)
                NativePipeMethods.LocalFree(pSecurityDescriptor);
        }
    }

    /// <summary>
    /// Reads a process's full Win32 image path, first via <c>QueryFullProcessImageNameW</c> and
    /// falling back to <c>NtQuerySystemInformation(SystemProcessIdInformation)</c> when the caller
    /// is a non-admin user inspecting a Session 0 SYSTEM service.
    /// </summary>
    public static string? TryReadImagePath(int pid)
    {
        var hProc = NativePipeMethods.OpenProcess(NativePipeMethods.ProcessQueryLimitedInformation, false, pid);
        if (hProc != IntPtr.Zero)
        {
            try
            {
                var buffer = new StringBuilder(1024);
                var capacity = buffer.Capacity;
                if (NativePipeMethods.QueryFullProcessImageNameW(hProc, 0, buffer, ref capacity) && capacity > 0)
                    return buffer.ToString(0, capacity);
            }
            finally
            {
                NativePipeMethods.CloseHandle(hProc);
            }
        }

        var ntPath = TryQueryNtImagePath(pid);
        return ntPath is null ? null : TranslateNtDevicePathToWin32(ntPath);
    }

    internal static string? TranslateNtDevicePathToWin32(string ntPath, IReadOnlyDictionary<string, string>? deviceToDrive = null)
    {
        if (string.IsNullOrWhiteSpace(ntPath)) return null;
        if (Path.IsPathFullyQualified(ntPath) && ntPath.Length >= 2 && ntPath[1] == ':')
            return ntPath;

        var map = deviceToDrive ?? BuildDeviceToDriveMap();
        foreach (var (devicePrefix, drive) in map)
        {
            if (ntPath.StartsWith(devicePrefix, StringComparison.OrdinalIgnoreCase) &&
                (ntPath.Length == devicePrefix.Length || ntPath[devicePrefix.Length] == '\\'))
            {
                return drive + ntPath[devicePrefix.Length..];
            }
        }
        return null;
    }

    private static string? TryQueryNtImagePath(int pid)
    {
        const int bufferBytes = 2048;
        var buf = Marshal.AllocHGlobal(bufferBytes);
        try
        {
            var info = new NativePipeMethods.SystemProcessIdInformation
            {
                ProcessId = (IntPtr)pid,
                ImageName = new NativePipeMethods.UnicodeString
                {
                    Length = 0,
                    MaximumLength = bufferBytes,
                    Buffer = buf,
                },
            };
            var status = NativePipeMethods.NtQuerySystemInformation(
                SystemProcessIdInformation, ref info, Marshal.SizeOf<NativePipeMethods.SystemProcessIdInformation>(), out _);
            if (status != 0 || info.ImageName.Length == 0 || info.ImageName.Buffer == IntPtr.Zero)
                return null;
            return Marshal.PtrToStringUni(info.ImageName.Buffer, info.ImageName.Length / 2);
        }
        finally
        {
            Marshal.FreeHGlobal(buf);
        }
    }

    private static Dictionary<string, string> BuildDeviceToDriveMap()
    {
        var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var target = new StringBuilder(512);
        foreach (var driveRoot in Directory.GetLogicalDrives())
        {
            var drive = driveRoot.TrimEnd('\\');
            target.Clear();
            var len = NativePipeMethods.QueryDosDeviceW(drive, target, target.Capacity);
            if (len == 0) continue;
            var device = target.ToString();
            var nul = device.IndexOf('\0');
            if (nul >= 0) device = device[..nul];
            if (device.Length > 0) map[device] = drive;
        }
        return map;
    }
}

internal static class NativePipeMethods
{
    public const int TokenQuery = 0x0008;
    public const int ProcessQueryLimitedInformation = 0x1000;

    [StructLayout(LayoutKind.Sequential)]
    public struct UnicodeString
    {
        public ushort Length;
        public ushort MaximumLength;
        public IntPtr Buffer;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct SystemProcessIdInformation
    {
        public IntPtr ProcessId;
        public UnicodeString ImageName;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetNamedPipeClientProcessId(IntPtr namedPipe, out uint clientProcessId);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetNamedPipeServerProcessId(IntPtr namedPipe, out uint serverProcessId);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetNamedPipeServerSessionId(IntPtr namedPipe, out uint sessionId);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr OpenProcess(int desiredAccess, bool inheritHandle, int processId);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool QueryFullProcessImageNameW(IntPtr hProcess, int dwFlags, StringBuilder lpExeName, ref int lpdwSize);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern uint QueryDosDeviceW(string lpDeviceName, StringBuilder lpTargetPath, int ucchMax);

    [DllImport("ntdll.dll")]
    public static extern int NtQuerySystemInformation(
        int systemInformationClass, ref SystemProcessIdInformation systemInformation, int systemInformationLength, out int returnLength);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool OpenProcessToken(IntPtr processHandle, int desiredAccess, out IntPtr tokenHandle);

    [DllImport("advapi32.dll")]
    public static extern uint GetSecurityInfo(
        IntPtr handle, uint objectType, uint securityInfo,
        out IntPtr ppsidOwner, out IntPtr ppsidGroup, out IntPtr ppDacl, out IntPtr ppSacl,
        out IntPtr ppSecurityDescriptor);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr LocalFree(IntPtr hMem);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr handle);
}
