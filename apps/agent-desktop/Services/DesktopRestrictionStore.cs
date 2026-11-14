using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json;

namespace FamilyShield.Agent.Services;

public sealed class SessionRestriction
{
    public int SessionId { get; set; }
    public bool Locked { get; set; }
    public bool Paused { get; set; }
    public DateTime? WindDownAt { get; set; }
    public DateTime? ObservedAt { get; set; }
    public DateTime? DisconnectedAt { get; set; }
    public DateTime? FallbackAt { get; set; }
    public bool TamperAlerted { get; set; }
    public bool Unreadable { get; set; }
}

public interface IRestrictionStore
{
    IReadOnlyList<SessionRestriction> Load();
    void Save(IReadOnlyList<SessionRestriction> restrictions);
}

public sealed class FileDesktopRestrictionStore : IRestrictionStore
{
    private const string SystemSid = "S-1-5-18";
    private const string AdministratorsSid = "S-1-5-32-544";
    private const FileSystemRights WriteRights = FileSystemRights.FullControl | FileSystemRights.Modify |
        FileSystemRights.Write | FileSystemRights.Delete | FileSystemRights.DeleteSubdirectoriesAndFiles |
        FileSystemRights.CreateFiles | FileSystemRights.CreateDirectories;
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web) { WriteIndented = true };
    private readonly string _path;
    private readonly Action<string, string>? _replace;
    private readonly Func<DirectoryInfo, bool>? _directoryIsTrusted;

    public FileDesktopRestrictionStore(string? path = null, Action<string, string>? replace = null,
        Func<DirectoryInfo, bool>? directoryIsTrusted = null)
    {
        _path = path ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "OSRA", "restrictions.json");
        _replace = replace;
        _directoryIsTrusted = directoryIsTrusted;
    }

    public IReadOnlyList<SessionRestriction> Load()
    {
        try
        {
            SecureDirectory();
            if (!File.Exists(_path)) return [];
            return Deserialize(File.ReadAllText(_path));
        }
        catch (SystemException)
        {
            return UnreadableState();
        }
    }

    internal static IReadOnlyList<SessionRestriction> Deserialize(string json)
    {
        try
        {
            return JsonSerializer.Deserialize<List<SessionRestriction>>(json, JsonOptions) ?? [];
        }
        catch (JsonException)
        {
            return UnreadableState();
        }
    }

    public void Save(IReadOnlyList<SessionRestriction> restrictions)
    {
        SecureDirectory();
        var temporary = _path + ".tmp";
        File.Delete(temporary);
        var security = ProtectedFile();
        using (var stream = new FileInfo(temporary).Create(FileMode.CreateNew, FileSystemRights.FullControl,
                   FileShare.Read, bufferSize: 4096, FileOptions.SequentialScan, security))
        using (var writer = new StreamWriter(stream))
        {
            writer.Write(JsonSerializer.Serialize(restrictions, JsonOptions));
            writer.Flush();
            stream.Flush(flushToDisk: true);
        }
        if (File.Exists(_path))
        {
            if (_replace is not null) _replace(temporary, _path);
            else File.Replace(temporary, _path, destinationBackupFileName: null);
        }
        else File.Move(temporary, _path);
    }

    private DirectoryInfo SecureDirectory()
    {
        var directory = new DirectoryInfo(Path.GetDirectoryName(_path)!);
        if (!directory.Exists) directory.Create(ProtectedDirectory());
        directory.Refresh();
        if (directory.Attributes.HasFlag(FileAttributes.ReparsePoint))
            throw new UnauthorizedAccessException("The restriction directory must not be a reparse point.");
        if (_directoryIsTrusted is not null)
        {
            if (!_directoryIsTrusted(directory))
                throw new UnauthorizedAccessException("The restriction directory is not trusted.");
        }
        else
        {
            var security = directory.GetAccessControl();
            var owner = security.GetOwner(typeof(SecurityIdentifier))?.Value;
            if (owner != SystemSid && owner != AdministratorsSid)
                throw new UnauthorizedAccessException("The restriction directory owner is not trusted.");
            foreach (var rule in security.GetAccessRules(true, false, typeof(SecurityIdentifier))
                         .Cast<FileSystemAccessRule>())
            {
                if (rule.AccessControlType == AccessControlType.Allow &&
                    rule.IdentityReference.Value != SystemSid && rule.IdentityReference.Value != AdministratorsSid &&
                    (rule.FileSystemRights & WriteRights) != 0)
                {
                    throw new UnauthorizedAccessException("Another principal can write the restriction directory.");
                }
            }
        }
        directory.SetAccessControl(ProtectedDirectory());
        return directory;
    }

    private static DirectorySecurity ProtectedDirectory()
    {
        var security = new DirectorySecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.AddAccessRule(new FileSystemAccessRule(
            new SecurityIdentifier(SystemSid), FileSystemRights.FullControl, AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(
            new SecurityIdentifier(AdministratorsSid), FileSystemRights.FullControl, AccessControlType.Allow));
        return security;
    }

    internal static FileSecurity ProtectedFile()
    {
        var security = new FileSecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.AddAccessRule(new FileSystemAccessRule(
            new SecurityIdentifier(SystemSid), FileSystemRights.FullControl, AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(
            new SecurityIdentifier(AdministratorsSid), FileSystemRights.FullControl, AccessControlType.Allow));
        return security;
    }

    private static SessionRestriction[] UnreadableState() =>
    [
        new SessionRestriction
        {
            SessionId = 0,
            Locked = true,
            Unreadable = true,
            ObservedAt = DateTime.UtcNow,
        },
    ];
}
