using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;

namespace Devolutions.PowerShell.NativeAot;

internal static partial class NativeMethods
{
    private const string LibraryName = "devolutions_pwsh_broker";

    [LibraryImport(LibraryName, EntryPoint = "dps_broker_get_abi_version")]
    internal static partial uint GetAbiVersion();

    [LibraryImport(LibraryName, EntryPoint = "dps_broker_probe_payload_utf8")]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    private static partial int ProbePayload(
        ReadOnlySpan<byte> payloadPath,
        nuint payloadPathLength,
        ReadOnlySpan<byte> workerPath,
        nuint workerPathLength);

    [LibraryImport(LibraryName, EntryPoint = "dps_broker_connection_start_utf8")]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    private static partial int StartWorkerConnection(
        ReadOnlySpan<byte> workerPath,
        nuint workerPathLength,
        ReadOnlySpan<byte> payloadPath,
        nuint payloadPathLength,
        ReadOnlySpan<byte> workerBridgePath,
        nuint workerBridgePathLength,
        uint startupTimeoutMilliseconds,
        out nint connection);

    [LibraryImport(LibraryName, EntryPoint = "dps_broker_connection_execute_script_utf8")]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    private static partial int ExecuteScript(
        PowerShellWorkerConnection connection,
        ReadOnlySpan<byte> script,
        nuint scriptLength,
        uint executionTimeoutMilliseconds,
        Span<byte> output,
        nuint outputCapacity,
        out nuint outputLength);

    [LibraryImport(LibraryName, EntryPoint = "dps_broker_connection_shutdown")]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    private static partial int ShutdownWorkerConnectionNative(nint connection);

    [LibraryImport(LibraryName, EntryPoint = "dps_broker_connection_abort")]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    private static partial int AbortWorkerConnectionNative(nint connection);

    [LibraryImport(LibraryName, EntryPoint = "dps_broker_connection_execute_command_utf8")]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    private static partial int ExecuteCommand(
        PowerShellWorkerConnection connection,
        ReadOnlySpan<byte> request,
        nuint requestLength,
        uint executionTimeoutMilliseconds,
        Span<byte> output,
        nuint outputCapacity,
        out nuint outputLength);

    [LibraryImport(LibraryName, EntryPoint = "dps_broker_connection_cancel")]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    private static partial int CancelWorkerConnectionNative(nint connection);

    internal static NativeStatus ProbePayload(string payloadPath, string workerPath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(payloadPath);
        ArgumentException.ThrowIfNullOrWhiteSpace(workerPath);

        byte[] payloadBytes = GetUtf8Text(payloadPath, nameof(payloadPath));
        byte[] workerBytes = GetUtf8Text(workerPath, nameof(workerPath));
        return (NativeStatus)ProbePayload(
            payloadBytes,
            (nuint)payloadBytes.Length,
            workerBytes,
            (nuint)workerBytes.Length);
    }

    internal static NativeStatus StartWorkerConnection(
        string workerPath,
        string payloadPath,
        string workerBridgePath,
        uint startupTimeoutMilliseconds,
        out nint connection)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(workerPath);
        ArgumentException.ThrowIfNullOrWhiteSpace(payloadPath);
        ArgumentException.ThrowIfNullOrWhiteSpace(workerBridgePath);

        byte[] workerBytes = GetUtf8Text(workerPath, nameof(workerPath));
        byte[] payloadBytes = GetUtf8Text(payloadPath, nameof(payloadPath));
        byte[] workerBridgeBytes = GetUtf8Text(workerBridgePath, nameof(workerBridgePath));
        return (NativeStatus)StartWorkerConnection(
            workerBytes,
            (nuint)workerBytes.Length,
            payloadBytes,
            (nuint)payloadBytes.Length,
            workerBridgeBytes,
            (nuint)workerBridgeBytes.Length,
            startupTimeoutMilliseconds,
            out connection);
    }

    internal static NativeStatus ExecuteScript(
        PowerShellWorkerConnection connection,
        string script,
        uint executionTimeoutMilliseconds,
        Span<byte> output,
        out nuint outputLength)
    {
        ArgumentNullException.ThrowIfNull(connection);
        ArgumentException.ThrowIfNullOrWhiteSpace(script);

        byte[] scriptBytes = GetUtf8Text(script, nameof(script));
        return (NativeStatus)ExecuteScript(
            connection,
            scriptBytes,
            (nuint)scriptBytes.Length,
            executionTimeoutMilliseconds,
            output,
            (nuint)output.Length,
            out outputLength);
    }

    internal static NativeStatus ShutdownWorkerConnection(nint connection) =>
        (NativeStatus)ShutdownWorkerConnectionNative(connection);

    internal static NativeStatus AbortWorkerConnection(nint connection) =>
        (NativeStatus)AbortWorkerConnectionNative(connection);

    internal static NativeStatus ExecuteCommand(
        PowerShellWorkerConnection connection,
        ReadOnlySpan<byte> request,
        uint executionTimeoutMilliseconds,
        Span<byte> output,
        out nuint outputLength) =>
        (NativeStatus)ExecuteCommand(
            connection,
            request,
            (nuint)request.Length,
            executionTimeoutMilliseconds,
            output,
            (nuint)output.Length,
            out outputLength);

    internal static NativeStatus CancelWorkerConnection(nint connection) =>
        (NativeStatus)CancelWorkerConnectionNative(connection);

    private static byte[] GetUtf8Text(string value, string parameterName)
    {
        if (value.IndexOf('\0') >= 0)
        {
            throw new ArgumentException("UTF-8 ABI inputs cannot contain NUL characters.", parameterName);
        }

        return Encoding.UTF8.GetBytes(value);
    }
}
