using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using Devolutions.MultiPwsh.Remoting.WSMan;
using Xunit;

namespace Devolutions.MultiPwsh.Remoting.WSMan.Tests;

public sealed class DevolutionsWsmanAdapterTests
{
    private const string ContractDescriptor =
        "devolutions.wsman|1|static ProviderId:string|static ContractHash:string|static ProviderVersion:string|" +
        "static Capabilities:uint64|ctor()|" +
        "CreateRunspacePool(string,PSCredential,Func<string,int,bool,CancellationToken,Task<Stream>>):RunspacePool";

    [Fact]
    public void ReflectionContract_MatchesMultiPwshDescriptor()
    {
        Type adapterType = typeof(DevolutionsWsmanAdapter);

        Assert.NotNull(adapterType.GetConstructor(Type.EmptyTypes));
        AssertStaticStringProperty(adapterType, nameof(DevolutionsWsmanAdapter.ProviderId));
        AssertStaticStringProperty(adapterType, nameof(DevolutionsWsmanAdapter.ContractHash));
        AssertStaticStringProperty(adapterType, nameof(DevolutionsWsmanAdapter.ProviderVersion));

        PropertyInfo capabilities = Assert.IsAssignableFrom<PropertyInfo>(
            adapterType.GetProperty(nameof(DevolutionsWsmanAdapter.Capabilities), BindingFlags.Public | BindingFlags.Static));
        Assert.Equal(typeof(ulong), capabilities.PropertyType);

        MethodInfo method = Assert.IsAssignableFrom<MethodInfo>(adapterType.GetMethod(
            nameof(DevolutionsWsmanAdapter.CreateRunspacePool),
            BindingFlags.Public | BindingFlags.Instance,
            [
                typeof(string),
                typeof(PSCredential),
                typeof(Func<string, int, bool, CancellationToken, Task<Stream>>),
            ]));
        Assert.Equal(typeof(RunspacePool), method.ReturnType);

        string expectedHash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(ContractDescriptor)))
            .ToLowerInvariant();
        Assert.Equal("devolutions.wsman", DevolutionsWsmanAdapter.ProviderId);
        Assert.Equal(expectedHash, DevolutionsWsmanAdapter.ContractHash);
        Assert.Equal((ulong)DevolutionsWsmanCapabilities.None, DevolutionsWsmanAdapter.Capabilities);
        Assert.Equal(1UL << 0, (ulong)DevolutionsWsmanCapabilities.CustomClientTransport);
        Assert.Equal(1UL << 1, (ulong)DevolutionsWsmanCapabilities.RemoteRunspacePool);
        Assert.Equal(1UL << 2, (ulong)DevolutionsWsmanCapabilities.HostStreamRelay);
        Assert.Equal(1UL << 3, (ulong)DevolutionsWsmanCapabilities.Negotiate);
        Assert.Equal(1UL << 4, (ulong)DevolutionsWsmanCapabilities.Kerberos);
        Assert.Equal(1UL << 5, (ulong)DevolutionsWsmanCapabilities.Ntlm);
        Assert.Equal(1UL << 6, (ulong)DevolutionsWsmanCapabilities.KdcProxy);
    }

    [Fact]
    public void Parse_MinimalOptions_AppliesDocumentedDefaults()
    {
        DevolutionsWsmanOptions options = DevolutionsWsmanOptions.Parse(
            """{"endpointUri":"https://server.example.test:5986/wsman"}""");

        Assert.Equal(new Uri("https://server.example.test:5986/wsman"), options.EndpointUri);
        Assert.Equal(DevolutionsWsmanAuthentication.Negotiate, options.Authentication);
        Assert.Equal("http://schemas.microsoft.com/powershell/Microsoft.PowerShell", options.ShellUri);
        Assert.Equal(1, options.MinRunspaces);
        Assert.Equal(1, options.MaxRunspaces);
        Assert.Equal(180_000, options.OpenTimeoutMilliseconds);
        Assert.Equal(180_000, options.OperationTimeoutMilliseconds);
        Assert.Equal(500, options.MaxEnvelopeSizeKilobytes);
        Assert.False(options.SkipCertificateCheck);
        Assert.Null(options.KdcProxyUri);
        Assert.Null(options.Spn);
    }

    [Theory]
    [InlineData("""{"endpointUri":"ftp://server.example.test/wsman"}""")]
    [InlineData("""{"endpointUri":"https://server.example.test/wsman","minRunspaces":2,"maxRunspaces":1}""")]
    [InlineData("""{"endpointUri":"https://server.example.test/wsman","kdcProxyUri":"http://proxy.example.test"}""")]
    [InlineData("""{"endpointUri":"https://server.example.test/wsman","unknown":true}""")]
    public void Parse_InvalidOptions_RejectsConfiguration(string optionsJson)
    {
        Assert.ThrowsAny<ArgumentException>(() => DevolutionsWsmanOptions.Parse(optionsJson));
    }

    private static void AssertStaticStringProperty(Type adapterType, string propertyName)
    {
        PropertyInfo property = Assert.IsAssignableFrom<PropertyInfo>(
            adapterType.GetProperty(propertyName, BindingFlags.Public | BindingFlags.Static));
        Assert.Equal(typeof(string), property.PropertyType);
    }
}
