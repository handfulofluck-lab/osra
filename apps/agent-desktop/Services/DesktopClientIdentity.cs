using System.Reflection;

namespace FamilyShield.Agent.Services;

/// <summary>The single build identity used by the client header and ADR-0034 capability report.</summary>
public static class DesktopClientIdentity
{
    private const string App = "agent-desktop";
    private const string Platform = "windows";
    private const string Flavour = "dev";
    private const int MaxBuild = 999_999_999;

    /// <summary>The header for this assembly, or null when it cannot be named truthfully.</summary>
    public static string? Header { get; } = CreateHeader(
        Assembly.GetExecutingAssembly().GetName().Version,
        Assembly.GetExecutingAssembly().GetName().Version?.Revision ?? 0);

    /// <summary>Builds a valid header, or omits it when a version part or build is out of range.</summary>
    public static string? CreateHeader(Version? version, int build)
    {
        if (version is null || build < 1 || build > MaxBuild ||
            version.Major is < 0 or > 9999 || version.Minor is < 0 or > 9999 || version.Build is < 0 or > 9999)
        {
            return null;
        }

        var header = $"{App}/{VersionName(version)}+{build} ({Platform})";
        return header.Length <= 64 ? header : null;
    }

    /// <summary>The strict client block, sharing the header's normalized version and build.</summary>
    public static IReadOnlyDictionary<string, object>? CapabilityClient()
    {
        var version = Assembly.GetExecutingAssembly().GetName().Version;
        var build = version?.Revision ?? 0;
        if (CreateHeader(version, build) is null || version is null) return null;
        return new Dictionary<string, object>
        {
            ["app"] = App,
            ["version"] = VersionName(version),
            ["build"] = build,
            ["flavour"] = Flavour,
        };
    }

    private static string VersionName(Version version) => $"{version.Major}.{version.Minor}.{version.Build}";
}
