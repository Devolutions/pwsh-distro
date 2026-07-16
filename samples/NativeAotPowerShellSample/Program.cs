using Devolutions.PowerShell.NativeAot;

if (args.Length != 3)
{
    Console.Error.WriteLine("Usage: NativeAotPowerShellSample <payload-directory> <worker-path> <worker-bridge-path>");
    return 64;
}

var options = new PowerShellSessionOptions
{
    PayloadDirectory = args[0],
    WorkerPath = args[1],
    WorkerBridgePath = args[2],
};

Console.WriteLine($"Broker ABI: {PowerShellSession.GetBrokerAbiVersion()}");
NativeStatus status = PowerShellSession.ProbePayload(options);
Console.WriteLine($"Payload probe: {status}");
if (status != NativeStatus.Success)
{
    return (int)status;
}

status = PowerShellSession.TryStartWorkerConnection(options, TimeSpan.FromSeconds(30), out PowerShellWorkerConnection? connection);
using (connection)
{
    Console.WriteLine($"Worker connection: {status}");
    if (status != NativeStatus.Success || connection is null)
    {
        return (int)status;
    }

    status = connection.ExecuteScript("'nativeaot-script-architecture-gate'", TimeSpan.FromSeconds(5), out string? output);
    Console.WriteLine($"Script execution: {status}");
    Console.WriteLine($"Script output: {output}");
    if (status != NativeStatus.Success || output != "nativeaot-script-architecture-gate")
    {
        return (int)(status == NativeStatus.Success ? NativeStatus.ProtocolViolation : status);
    }

    status = connection.Invoke(
        new PowerShellCommand()
            .AddScript("""
                $VerbosePreference = 'Continue'
                $DebugPreference = 'Continue'
                Write-Output 'héllo-世界'
                Write-Warning 'warning-stream'
                Write-Verbose 'verbose-stream'
                Write-Debug 'debug-stream'
                Write-Information 'information-stream' -Tags 'nativeaot'
                Write-Progress -Activity 'progress-stream' -Status 'working' -PercentComplete 50
                """),
        TimeSpan.FromSeconds(5),
        out PowerShellInvocationResult? streamResult);
    Console.WriteLine($"Stream invocation: {status}");
    Console.WriteLine($"Stream terminal: {streamResult?.TerminalStatus}");
    if (status != NativeStatus.Success
        || streamResult?.TerminalStatus != PowerShellTerminalStatus.Succeeded
        || !streamResult.Events.Any(static streamEvent => streamEvent.Kind == PowerShellStreamKind.Output
            && streamEvent.Value?.ToObject() is string value
            && value == "héllo-世界")
        || !streamResult.Events.Any(static streamEvent => streamEvent.Kind == PowerShellStreamKind.Warning)
        || !streamResult.Events.Any(static streamEvent => streamEvent.Kind == PowerShellStreamKind.Verbose)
        || !streamResult.Events.Any(static streamEvent => streamEvent.Kind == PowerShellStreamKind.Debug)
        || !streamResult.Events.Any(static streamEvent => streamEvent.Kind == PowerShellStreamKind.Information)
        || !streamResult.Events.Any(static streamEvent => streamEvent.Kind == PowerShellStreamKind.Progress)
        || !streamResult.Events.Any(static streamEvent => streamEvent.Progress?.RecordType == "Processing"
            && !streamEvent.Progress.IsCompleted)
        || streamResult.Events.Select(static (streamEvent, index) => streamEvent.Sequence == (ulong)index).Contains(false))
    {
        return (int)NativeStatus.ProtocolViolation;
    }

    status = connection.Invoke(
        new PowerShellCommand().AddScript("Write-Error 'nonterminating-stream-error'; 'after-nonterminating-error'"),
        TimeSpan.FromSeconds(5),
        out PowerShellInvocationResult? nonterminatingResult);
    Console.WriteLine($"Nonterminating invocation: {status} ({nonterminatingResult?.TerminalStatus})");
    if (status != NativeStatus.Success
        || nonterminatingResult?.TerminalStatus != PowerShellTerminalStatus.Succeeded
        || !nonterminatingResult.Events.Any(static streamEvent => streamEvent.Kind == PowerShellStreamKind.Error
            && streamEvent.Error?.Message.Contains("nonterminating-stream-error", StringComparison.Ordinal) == true))
    {
        return (int)NativeStatus.ProtocolViolation;
    }

    status = connection.Invoke(
        new PowerShellCommand().AddScript("throw 'terminating-stream-error'"),
        TimeSpan.FromSeconds(5),
        out PowerShellInvocationResult? terminatingResult);
    Console.WriteLine($"Terminating invocation: {status} ({terminatingResult?.TerminalStatus})");
    PowerShellErrorRecord? terminatingError = terminatingResult?.Events
        .Select(static streamEvent => streamEvent.Error)
        .FirstOrDefault(static error => error is not null);
    Console.WriteLine(
        $"Terminating error coordinates: {terminatingError?.ScriptLineNumber}/{terminatingError?.OffsetInLine}/"
        + $"{terminatingError?.PipelineLength}/{terminatingError?.PipelinePosition}");
    if (status != NativeStatus.Success
        || terminatingResult?.TerminalStatus != PowerShellTerminalStatus.Failed
        || !terminatingResult.Events.Any(static streamEvent => streamEvent.Kind == PowerShellStreamKind.Error
           && streamEvent.Error?.Message.Contains("terminating-stream-error", StringComparison.Ordinal) == true)
        || terminatingError?.ScriptLineNumber <= 0
        || terminatingResult.Failure is null)
    {
        return (int)NativeStatus.ProtocolViolation;
    }

    using var cancellation = new CancellationTokenSource(TimeSpan.FromMilliseconds(250));
    status = connection.Invoke(
        new PowerShellCommand().AddScript("Start-Sleep -Seconds 30; 'unexpected-output'"),
        TimeSpan.FromSeconds(10),
        cancellation.Token,
        out PowerShellInvocationResult? cancellationResult);
    Console.WriteLine($"Cancelled invocation: {status} ({cancellationResult?.TerminalStatus})");
    if (status != NativeStatus.Success || cancellationResult?.TerminalStatus != PowerShellTerminalStatus.Cancelled)
    {
        return (int)NativeStatus.ProtocolViolation;
    }

    status = connection.Invoke(
        new PowerShellCommand().AddScript("Start-Sleep -Seconds 30; 'unexpected-deadline-output'"),
        TimeSpan.FromMilliseconds(250),
        out PowerShellInvocationResult? deadlineResult);
    Console.WriteLine($"Deadline invocation: {status} ({deadlineResult?.TerminalStatus})");
    if (status != NativeStatus.Success || deadlineResult?.TerminalStatus != PowerShellTerminalStatus.Cancelled)
    {
        return (int)NativeStatus.ProtocolViolation;
    }

    status = connection.Invoke(
        new PowerShellCommand()
            .AddCommand("Write-Output")
            .AddArgument("discarded-by-clear")
            .Clear()
            .AddCommand("Write-Output")
            .AddParameter("InputObject", PowerShellValue.FromString("sequential-✓"))
            .AddStatement()
            .AddScript("'second-statement'")
            .AddStatement()
            .AddCommand("Write-Output")
            .AddArgument(PowerShellValue.FromInt64(42))
            .AddStatement()
            .AddCommand("Write-Output")
            .AddArgument(PowerShellValue.FromBoolean(true))
            .AddStatement()
            .AddCommand("Write-Output")
            .AddArgument(PowerShellValue.FromDouble(3.5)),
        TimeSpan.FromSeconds(5),
        out PowerShellInvocationResult? sequentialResult);
    Console.WriteLine($"Sequential invocation: {status} ({sequentialResult?.TerminalStatus})");
    if (status != NativeStatus.Success
        || sequentialResult?.TerminalStatus != PowerShellTerminalStatus.Succeeded
        || sequentialResult.Events.Count(static streamEvent => streamEvent.Kind == PowerShellStreamKind.Output) != 5
        || !sequentialResult.Events.Any(static streamEvent => Equals(streamEvent.Value?.ToObject(), 42L))
        || !sequentialResult.Events.Any(static streamEvent => Equals(streamEvent.Value?.ToObject(), true))
        || !sequentialResult.Events.Any(static streamEvent => Equals(streamEvent.Value?.ToObject(), 3.5)))
    {
        return (int)NativeStatus.ProtocolViolation;
    }

    status = connection.Invoke(
        new PowerShellCommand().AddScript("[pscustomobject]@{ Unsupported = 'type' }"),
        TimeSpan.FromSeconds(5),
        out PowerShellInvocationResult? unsupportedResult);
    Console.WriteLine($"Unsupported invocation: {status} ({unsupportedResult?.TerminalStatus})");
    if (status != NativeStatus.Success
        || unsupportedResult?.TerminalStatus != PowerShellTerminalStatus.Failed
        || unsupportedResult.Failure is null)
    {
        return (int)NativeStatus.ProtocolViolation;
    }

    connection.Dispose();
    connection.Dispose();
    Console.WriteLine("Connection disposal: Success");
}

status = PowerShellSession.TryStartWorkerConnection(options, TimeSpan.FromSeconds(30), out PowerShellWorkerConnection? firstConnection);
if (status != NativeStatus.Success || firstConnection is null)
{
    Console.WriteLine($"Concurrent sessions: {status}");
    return (int)status;
}

using (firstConnection)
{
    status = PowerShellSession.TryStartWorkerConnection(options, TimeSpan.FromSeconds(30), out PowerShellWorkerConnection? secondConnection);
    if (status != NativeStatus.Success || secondConnection is null)
    {
        Console.WriteLine($"Concurrent sessions: {status}");
        return (int)status;
    }

    using (secondConnection)
    {
        var stopwatch = System.Diagnostics.Stopwatch.StartNew();
        Task<(NativeStatus Status, PowerShellInvocationResult? Result)> firstInvocation = Task.Run(() =>
        {
            NativeStatus invocationStatus = firstConnection.Invoke(
                new PowerShellCommand().AddScript("Start-Sleep -Milliseconds 350; 'first-session'"),
                TimeSpan.FromSeconds(5),
                out PowerShellInvocationResult? invocationResult);
            return (invocationStatus, invocationResult);
        });
        Task<(NativeStatus Status, PowerShellInvocationResult? Result)> secondInvocation = Task.Run(() =>
        {
            NativeStatus invocationStatus = secondConnection.Invoke(
                new PowerShellCommand().AddScript("Start-Sleep -Milliseconds 350; 'second-session'"),
                TimeSpan.FromSeconds(5),
                out PowerShellInvocationResult? invocationResult);
            return (invocationStatus, invocationResult);
        });
        Task.WaitAll(firstInvocation, secondInvocation);
        stopwatch.Stop();

        bool concurrentSuccess = firstInvocation.Result.Status == NativeStatus.Success
            && firstInvocation.Result.Result?.TerminalStatus == PowerShellTerminalStatus.Succeeded
            && secondInvocation.Result.Status == NativeStatus.Success
            && secondInvocation.Result.Result?.TerminalStatus == PowerShellTerminalStatus.Succeeded
            && stopwatch.Elapsed < TimeSpan.FromSeconds(2);
        Console.WriteLine($"Concurrent sessions: {(concurrentSuccess ? "Success" : "Failed")}");
        if (!concurrentSuccess)
        {
            return (int)NativeStatus.ProtocolViolation;
        }
    }
}

status = PowerShellSession.TryStartWorkerConnection(options, TimeSpan.FromSeconds(30), out PowerShellWorkerConnection? disposalConnection);
if (status != NativeStatus.Success || disposalConnection is null)
{
    Console.WriteLine($"Disposal race: {status}");
    return (int)status;
}

Task<(NativeStatus Status, PowerShellInvocationResult? Result)> disposalInvocation = Task.Run(() =>
{
    NativeStatus invocationStatus = disposalConnection.Invoke(
        new PowerShellCommand().AddScript("Start-Sleep -Seconds 30; 'unexpected-disposal-output'"),
        TimeSpan.FromSeconds(10),
        out PowerShellInvocationResult? invocationResult);
    return (invocationStatus, invocationResult);
});
Thread.Sleep(100);
var disposalStopwatch = System.Diagnostics.Stopwatch.StartNew();
disposalConnection.Dispose();
bool disposalCompleted = disposalInvocation.Wait(TimeSpan.FromSeconds(5));
disposalStopwatch.Stop();
bool disposalRaceSuccess = disposalCompleted
    && disposalStopwatch.Elapsed < TimeSpan.FromSeconds(5)
    && (disposalInvocation.Result.Status == NativeStatus.WorkerExited
        || (disposalInvocation.Result.Status == NativeStatus.Success
            && disposalInvocation.Result.Result?.TerminalStatus == PowerShellTerminalStatus.Cancelled));
Console.WriteLine(
    $"Disposal race: {(disposalRaceSuccess ? "Success" : "Failed")} "
    + $"({(disposalCompleted ? disposalInvocation.Result.Status : NativeStatus.RequestTimeout)})");
if (!disposalRaceSuccess)
{
    return (int)NativeStatus.ProtocolViolation;
}

return 0;
