using System.Reflection;
using System.Security;
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
        Assert.Equal("/wsman", options.AppName);
        Assert.Equal(DevolutionsWsmanAuthentication.Negotiate, options.Authentication);
        Assert.Equal("http://schemas.microsoft.com/powershell/Microsoft.PowerShell", options.ShellUri);
        Assert.Equal(1, options.MinRunspaces);
        Assert.Equal(1, options.MaxRunspaces);
        Assert.Equal(20, options.MaxConnections);
        Assert.Null(options.Domain);
        Assert.Equal(DevolutionsWsmanSspiProvider.Default, options.SspiProvider);
        Assert.Equal(180_000, options.OpenTimeoutMilliseconds);
        Assert.Equal(180_000, options.OperationTimeoutMilliseconds);
        Assert.Equal(60_000, options.CancelTimeoutMilliseconds);
        Assert.Equal(60_000, options.EffectiveCancelTimeoutMilliseconds);
        Assert.Equal(512, options.MaxEnvelopeSizeKilobytes);
        Assert.False(options.SkipCertificateCheck);
        Assert.Null(options.KdcProxyName);
        Assert.Null(options.Spn);
    }

    [Fact]
    public void Parse_ConnectionInfoOptions_PreservesWsmanSemantics()
    {
        DevolutionsWsmanOptions options = DevolutionsWsmanOptions.Parse(
            """
            {
              "endpointUri": "http://server.example.test:5985/custom-wsman",
              "maxConnections": 64,
              "domain": "EXAMPLE",
              "sspiProvider": "Platform",
              "cancelTimeoutMilliseconds": 1000,
              "kdcProxyName": "proxy.example.test:443:kdcproxy"
            }
            """);

        Assert.Equal("/custom-wsman", options.AppName);
        Assert.Equal(64, options.MaxConnections);
        Assert.Equal("EXAMPLE", options.Domain);
        Assert.Equal(DevolutionsWsmanSspiProvider.Platform, options.SspiProvider);
        Assert.Equal(1_000, options.CancelTimeoutMilliseconds);
        Assert.Equal(5_000, options.EffectiveCancelTimeoutMilliseconds);
        Assert.Equal("proxy.example.test:443:kdcproxy", options.KdcProxyName);
    }

    [Fact]
    public void CreateRunspacePool_ValidArguments_ThrowsUntilTransportIsOperational()
    {
        using SecureString password = new();
        password.AppendChar('p');
        password.MakeReadOnly();
        PSCredential credential = new("user", password);
        DevolutionsWsmanAdapter adapter = new();

        NotSupportedException exception = Assert.Throws<NotSupportedException>(() => adapter.CreateRunspacePool(
            """{"endpointUri":"https://server.example.test:5986/wsman"}""",
            credential,
            (_, _, _, _) => Task.FromResult<Stream>(new MemoryStream())));

        Assert.Contains("managed WSMan transport is not yet included", exception.Message);
    }

    [Theory]
    [InlineData("""{"endpointUri":null}""")]
    [InlineData("""{"endpointUri":"ftp://server.example.test/wsman"}""")]
    [InlineData("""{"endpointUri":"https://server.example.test/wsman","authentication":0}""")]
    [InlineData("""{"endpointUri":"https://server.example.test/wsman","authentication":999}""")]
    [InlineData("""{"endpointUri":"https://server.example.test/wsman","minRunspaces":2,"maxRunspaces":1}""")]
    [InlineData("""{"endpointUri":"https://server.example.test/wsman","maxConnections":0}""")]
    [InlineData("""{"endpointUri":"https://server.example.test/wsman","maxConnections":65}""")]
    [InlineData("""{"endpointUri":"https://server.example.test/wsman","sspiProvider":0}""")]
    [InlineData("""{"endpointUri":"https://server.example.test/wsman","sspiProvider":999}""")]
    [InlineData("""{"endpointUri":"https://server.example.test/wsman","sspiProvider":"Windows"}""")]
    [InlineData("""{"endpointUri":"https://server.example.test/wsman","cancelTimeoutMilliseconds":-1}""")]
    [InlineData("""{"endpointUri":"https://server.example.test/wsman","kdcProxyName":""}""")]
    [InlineData("""{"endpointUri":"https://server.example.test/wsman","unknown":true}""")]
    public void Parse_InvalidOptions_RejectsConfiguration(string optionsJson)
    {
        Assert.ThrowsAny<ArgumentException>(() => DevolutionsWsmanOptions.Parse(optionsJson));
    }

    [Fact]
    public void Parse_OverlongConnectionInfoText_RejectsConfiguration()
    {
        string overlongDomain = new('d', DevolutionsWsmanOptions.MaxDomainLength + 1);
        string overlongKdcProxyName = new('k', DevolutionsWsmanOptions.MaxKdcProxyNameLength + 1);

        Assert.Throws<ArgumentException>(() => DevolutionsWsmanOptions.Parse(
            $$"""{"endpointUri":"https://server.example.test/wsman","domain":"{{overlongDomain}}"}"""));
        Assert.Throws<ArgumentException>(() => DevolutionsWsmanOptions.Parse(
            $$"""{"endpointUri":"https://server.example.test/wsman","kdcProxyName":"{{overlongKdcProxyName}}"}"""));
    }

    private static void AssertStaticStringProperty(Type adapterType, string propertyName)
    {
        PropertyInfo property = Assert.IsAssignableFrom<PropertyInfo>(
            adapterType.GetProperty(propertyName, BindingFlags.Public | BindingFlags.Static));
        Assert.Equal(typeof(string), property.PropertyType);
    }
}
