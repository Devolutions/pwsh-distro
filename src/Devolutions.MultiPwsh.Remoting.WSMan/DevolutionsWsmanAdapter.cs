using System.Management.Automation;
using System.Management.Automation.Runspaces;

namespace Devolutions.MultiPwsh.Remoting.WSMan;

public sealed class DevolutionsWsmanAdapter
{
    public static string ProviderId => "devolutions.wsman";

    public static string ContractHash => "836ea45ab6a3169cc786392cf9db644ac2e6fe59494f514e6a4f94f2a5cd20f9";

    public static string ProviderVersion => "0.1.0";

    public static ulong Capabilities => 0;

    public RunspacePool CreateRunspacePool(
        string optionsJson,
        PSCredential credential,
        Func<string, int, bool, CancellationToken, Task<Stream>> connector)
    {
        ArgumentNullException.ThrowIfNull(credential);
        ArgumentNullException.ThrowIfNull(connector);
        _ = DevolutionsWsmanOptions.Parse(optionsJson);

        throw new NotSupportedException(
            "The devolutions.wsman provider contract is staged, but the managed WSMan transport is not yet included. " +
            "RDM transport extraction and patched-SMA integration must be completed before this provider can create runspace pools.");
    }
}

[Flags]
public enum DevolutionsWsmanCapabilities : ulong
{
    None = 0,
    CustomClientTransport = 1UL << 0,
    RemoteRunspacePool = 1UL << 1,
    HostStreamRelay = 1UL << 2,
    Negotiate = 1UL << 3,
    Kerberos = 1UL << 4,
    Ntlm = 1UL << 5,
    KdcProxy = 1UL << 6,
}
