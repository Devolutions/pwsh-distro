using Microsoft.Win32.SafeHandles;
using System.Text;

namespace Devolutions.PowerShell.NativeAot;

/// <summary>Owns the broker connection and its isolated worker process.</summary>
public sealed class PowerShellWorkerConnection : SafeHandleZeroOrMinusOneIsInvalid
{
    private const int MaximumScriptOutputBytes = (64 * 1024) - 8;
    private const int MaximumInvocationResponseBytes = 256 * 1024;
    private const int CancellationRetryCount = 10;
    private readonly object _invocationLock = new();
    private int _invocationActive;

    internal PowerShellWorkerConnection(nint handle)
        : base(ownsHandle: true)
    {
        SetHandle(handle);
    }

    /// <inheritdoc />
    protected override bool ReleaseHandle()
    {
        _ = NativeMethods.ShutdownWorkerConnection(handle);
        return true;
    }

    /// <inheritdoc />
    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            CancelActiveInvocation();
            AbortConnection();
        }

        base.Dispose(disposing);
    }

    /// <summary>
    /// Executes the one DTO-only script request supported by the architecture gate.
    /// </summary>
    public NativeStatus ExecuteScript(string script, TimeSpan executionTimeout, out string? output)
    {
        if (executionTimeout <= TimeSpan.Zero || executionTimeout > TimeSpan.FromMinutes(1))
        {
            throw new ArgumentOutOfRangeException(
                nameof(executionTimeout),
                "The execution timeout must be between one millisecond and one minute.");
        }

        lock (_invocationLock)
        {
            if (IsClosed || IsInvalid)
            {
                output = null;
                return NativeStatus.WorkerExited;
            }

            byte[] outputBytes = new byte[MaximumScriptOutputBytes];
            NativeStatus status;
            nuint outputLength;
            try
            {
                status = NativeMethods.ExecuteScript(
                    this,
                    script,
                    (uint)Math.Ceiling(executionTimeout.TotalMilliseconds),
                    outputBytes,
                    out outputLength);
            }
            catch (ObjectDisposedException)
            {
                output = null;
                return NativeStatus.WorkerExited;
            }
            if (status != NativeStatus.Success)
            {
                output = null;
                return status;
            }
            if (outputLength > (nuint)outputBytes.Length)
            {
                output = null;
                return NativeStatus.ProtocolViolation;
            }

            try
            {
                output = new UTF8Encoding(false, true).GetString(outputBytes, 0, checked((int)outputLength));
                return NativeStatus.Success;
            }
            catch (DecoderFallbackException)
            {
                output = null;
                return NativeStatus.ProtocolViolation;
            }
        }
    }

    /// <summary>
    /// Executes an atomic structured command DTO and returns all ordered stream
    /// events followed by exactly one terminal result.
    /// </summary>
    public NativeStatus Invoke(
        PowerShellCommand command,
        TimeSpan executionTimeout,
        CancellationToken cancellationToken,
        out PowerShellInvocationResult? result)
    {
        ArgumentNullException.ThrowIfNull(command);
        uint timeoutMilliseconds = GetExecutionTimeoutMilliseconds(executionTimeout);
        result = null;

        if (cancellationToken.IsCancellationRequested)
        {
            result = new PowerShellInvocationResult([], PowerShellTerminalStatus.Cancelled, null);
            return NativeStatus.Success;
        }

        byte[] commandPayload = command.ToPayload();
        lock (_invocationLock)
        {
            if (IsClosed || IsInvalid)
            {
                return NativeStatus.WorkerExited;
            }
            if (cancellationToken.IsCancellationRequested)
            {
                result = new PowerShellInvocationResult([], PowerShellTerminalStatus.Cancelled, null);
                return NativeStatus.Success;
            }

            byte[] response = new byte[MaximumInvocationResponseBytes];
            using CancellationTokenRegistration cancellationRegistration = cancellationToken.Register(
                static state => ((PowerShellWorkerConnection)state!).CancelActiveInvocation(),
                this);
            if (cancellationToken.IsCancellationRequested)
            {
                result = new PowerShellInvocationResult([], PowerShellTerminalStatus.Cancelled, null);
                return NativeStatus.Success;
            }
            NativeStatus status;
            nuint responseLength;
            try
            {
                Volatile.Write(ref _invocationActive, 1);
                status = NativeMethods.ExecuteCommand(
                    this,
                    commandPayload,
                    timeoutMilliseconds,
                    response,
                    out responseLength);
            }
            catch (ObjectDisposedException)
            {
                return NativeStatus.WorkerExited;
            }
            finally
            {
                Volatile.Write(ref _invocationActive, 0);
            }
            if (status != NativeStatus.Success)
            {
                return status;
            }
            if (responseLength > (nuint)response.Length
                || !PowerShellProtocolResponseParser.TryParse(response.AsSpan(0, checked((int)responseLength)), out result))
            {
                result = null;
                return NativeStatus.ProtocolViolation;
            }

            return NativeStatus.Success;
        }
    }

    /// <summary>Executes an atomic structured command DTO without cancellation.</summary>
    public NativeStatus Invoke(
        PowerShellCommand command,
        TimeSpan executionTimeout,
        out PowerShellInvocationResult? result) =>
        Invoke(command, executionTimeout, CancellationToken.None, out result);

    private void CancelActiveInvocation()
    {
        bool addRef = false;
        try
        {
            DangerousAddRef(ref addRef);
            nint connection = DangerousGetHandle();
            for (int attempt = 0; attempt < CancellationRetryCount; attempt++)
            {
                _ = NativeMethods.CancelWorkerConnection(connection);
                if (Volatile.Read(ref _invocationActive) == 0)
                {
                    break;
                }

                Thread.Sleep(10);
            }
        }
        catch (ObjectDisposedException)
        {
            // Disposal winning a cancellation race has the same observable outcome.
        }
        finally
        {
            if (addRef)
            {
                DangerousRelease();
            }
        }
    }

    private void AbortConnection()
    {
        bool addRef = false;
        try
        {
            DangerousAddRef(ref addRef);
            _ = NativeMethods.AbortWorkerConnection(DangerousGetHandle());
        }
        catch (ObjectDisposedException)
        {
            // SafeHandle disposal already retired the native connection.
        }
        finally
        {
            if (addRef)
            {
                DangerousRelease();
            }
        }
    }

    private static uint GetExecutionTimeoutMilliseconds(TimeSpan executionTimeout)
    {
        if (executionTimeout <= TimeSpan.Zero || executionTimeout > TimeSpan.FromMinutes(1))
        {
            throw new ArgumentOutOfRangeException(
                nameof(executionTimeout),
                "The execution timeout must be between one millisecond and one minute.");
        }

        return checked((uint)Math.Ceiling(executionTimeout.TotalMilliseconds));
    }
}
