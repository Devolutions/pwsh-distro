namespace Devolutions.PowerShell.NativeAot;

/// <summary>
/// NativeAOT-safe entry point for the process-isolated PowerShell worker.
/// </summary>
public static class PowerShellSession
{
    /// <summary>Gets the broker ABI version without loading PowerShell in this process.</summary>
    public static uint GetBrokerAbiVersion() => NativeMethods.GetAbiVersion();

    /// <summary>
    /// Verifies that a worker can initialize the selected payload-local hostfxr.
    /// </summary>
    public static NativeStatus ProbePayload(PowerShellSessionOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        return NativeMethods.ProbePayload(options.PayloadDirectory, options.WorkerPath);
    }

    /// <summary>
    /// Starts a private broker-to-worker connection without loading PowerShell
    /// or the CLR into the NativeAOT client process.
    /// </summary>
    public static NativeStatus TryStartWorkerConnection(
        PowerShellSessionOptions options,
        TimeSpan startupTimeout,
        out PowerShellWorkerConnection? connection)
    {
        ArgumentNullException.ThrowIfNull(options);
        if (startupTimeout <= TimeSpan.Zero || startupTimeout > TimeSpan.FromMinutes(1))
        {
            throw new ArgumentOutOfRangeException(
                nameof(startupTimeout),
                "The startup timeout must be between one millisecond and one minute.");
        }

        double milliseconds = Math.Ceiling(startupTimeout.TotalMilliseconds);
        if (milliseconds > uint.MaxValue)
        {
            throw new ArgumentOutOfRangeException(nameof(startupTimeout));
        }

        NativeStatus status = NativeMethods.StartWorkerConnection(
            options.WorkerPath,
            options.PayloadDirectory,
            options.WorkerBridgePath,
            (uint)milliseconds,
            out nint handle);
        connection = status == NativeStatus.Success
            ? new PowerShellWorkerConnection(handle)
            : null;
        return status;
    }
}
