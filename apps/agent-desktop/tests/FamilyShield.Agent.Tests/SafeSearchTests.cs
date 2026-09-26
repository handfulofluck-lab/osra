using FamilyShield.Agent.Services;
using Xunit;

namespace FamilyShield.Agent.Tests;

/// <summary>
/// Unit tests for <see cref="SafeSearch"/>: host matching (google/bing/youtube URL shapes),
/// query-param replacement (never duplicate), and fragment preservation.
/// </summary>
public sealed class SafeSearchTests
{
    [Theory]
    [InlineData("google.com")]
    [InlineData("www.google.com")]
    [InlineData("google.co.uk")]
    [InlineData("images.google.de")]
    public void GoogleHostsGetSafeStrict(string host)
    {
        Assert.True(SafeSearch.TryRewrite(host, $"https://{host}/search?q=cats", out var rewritten));
        Assert.Equal($"https://{host}/search?q=cats&safe=strict", rewritten);
    }

    [Theory]
    [InlineData("bing.com")]
    [InlineData("www.bing.com")]
    [InlineData("cn.bing.com")]
    public void BingHostsGetAdltStrict(string host)
    {
        Assert.True(SafeSearch.TryRewrite(host, $"https://{host}/search?q=cats", out var rewritten));
        Assert.Equal($"https://{host}/search?q=cats&adlt=strict", rewritten);
    }

    [Theory]
    [InlineData("youtube.com")]
    [InlineData("www.youtube.com")]
    [InlineData("m.youtube.com")]
    public void YoutubeHostsGetSafeStrict(string host)
    {
        Assert.True(SafeSearch.TryRewrite(host, $"https://{host}/results?search_query=cats", out var rewritten));
        Assert.Equal($"https://{host}/results?search_query=cats&safe=strict", rewritten);
    }

    [Theory]
    [InlineData("example.com")]
    [InlineData("notgoogle.com")]
    [InlineData("mybing.com")]
    [InlineData("notyoutube.com")]
    [InlineData("duckduckgo.com")]
    public void UnrelatedHostsAreNotRewritten(string host)
    {
        Assert.False(SafeSearch.TryRewrite(host, $"https://{host}/", out var rewritten));
        Assert.Equal($"https://{host}/", rewritten);
    }

    [Fact]
    public void ExistingSafeParamIsReplacedNotDuplicated()
    {
        // A child trying to loosen the filter must not keep a working safe=active param.
        Assert.True(SafeSearch.TryRewrite("www.google.com",
            "https://www.google.com/search?q=cats&safe=active", out var rewritten));
        Assert.Equal("https://www.google.com/search?q=cats&safe=strict", rewritten);
        Assert.Equal(1, CountOccurrences(rewritten, "safe="));
    }

    [Fact]
    public void ExistingAdltParamIsReplacedCaseInsensitively()
    {
        Assert.True(SafeSearch.TryRewrite("bing.com",
            "https://bing.com/search?ADLT=off&q=cats", out var rewritten));
        Assert.Equal("https://bing.com/search?q=cats&adlt=strict", rewritten);
    }

    [Fact]
    public void ParamIsAddedWhenNoQueryStringExists()
    {
        Assert.True(SafeSearch.TryRewrite("google.com", "https://google.com/", out var rewritten));
        Assert.Equal("https://google.com/?safe=strict", rewritten);
    }

    [Fact]
    public void FragmentIsPreservedAfterTheQueryString()
    {
        Assert.True(SafeSearch.TryRewrite("www.youtube.com",
            "https://www.youtube.com/watch?v=abc&safe=off#t=30", out var rewritten));
        Assert.Equal("https://www.youtube.com/watch?v=abc&safe=strict#t=30", rewritten);
    }

    [Fact]
    public void MixedCaseHostIsNormalized()
    {
        Assert.True(SafeSearch.TryRewrite("WWW.GOOGLE.COM.", "https://WWW.GOOGLE.COM./search", out var rewritten));
        Assert.Equal("https://WWW.GOOGLE.COM./search?safe=strict", rewritten);
    }

    [Fact]
    public void SetQueryParamReplacesEveryDuplicateOccurrence()
    {
        var result = SafeSearch.SetQueryParam("http://h/x?safe=active&a=1&safe=off", "safe", "strict");
        Assert.Equal("http://h/x?a=1&safe=strict", result);
    }

    private static int CountOccurrences(string haystack, string needle)
    {
        var count = 0;
        for (var i = haystack.IndexOf(needle, StringComparison.Ordinal); i >= 0;
             i = haystack.IndexOf(needle, i + needle.Length, StringComparison.Ordinal))
        {
            count++;
        }
        return count;
    }
}
