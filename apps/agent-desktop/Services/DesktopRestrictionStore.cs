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
}

public interface IRestrictionStore
{
    IReadOnlyList<SessionRestriction> Load();
    void Save(IReadOnlyList<SessionRestriction> restrictions);
}

public sealed class FileDesktopRestrictionStore : IRestrictionStore
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web) { WriteIndented = true };
    private readonly string _path;
    private readonly Action<string, string>? _replace;

    public FileDesktopRestrictionStore(string? path = null, Action<string, string>? replace = null)
    {
        _path = path ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "OSRA", "restrictions.json");
        _replace = replace;
    }

    public IReadOnlyList<SessionRestriction> Load()
    {
        if (!File.Exists(_path)) return [];
        return JsonSerializer.Deserialize<List<SessionRestriction>>(File.ReadAllText(_path), JsonOptions) ?? [];
    }

    public void Save(IReadOnlyList<SessionRestriction> restrictions)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        var temporary = _path + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(restrictions, JsonOptions));
        var security = new FileSecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.AddAccessRule(new FileSystemAccessRule(
            new SecurityIdentifier("S-1-5-18"), FileSystemRights.FullControl, AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(
            new SecurityIdentifier("S-1-5-32-544"), FileSystemRights.FullControl, AccessControlType.Allow));
        new FileInfo(temporary).SetAccessControl(security);
        if (File.Exists(_path))
        {
            if (_replace is not null) _replace(temporary, _path);
            else File.Replace(temporary, _path, destinationBackupFileName: null);
        }
        else File.Move(temporary, _path);
    }
}
