namespace Devolutions.PowerShell.NativeAot;

/// <summary>Explicit locations used by the Phase 0/1 worker probe.</summary>
public sealed class PowerShellSessionOptions
{
    /// <summary>Gets or sets the selected PowerShell distribution directory.</summary>
    public required string PayloadDirectory { get; init; }

    /// <summary>Gets or sets the worker executable that owns the selected payload.</summary>
    public required string WorkerPath { get; init; }

    /// <summary>Gets or sets the managed WorkerBridge assembly injected into the worker payload.</summary>
    public required string WorkerBridgePath { get; init; }
}
