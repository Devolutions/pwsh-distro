using System.Management.Automation;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using PsPowerShell = System.Management.Automation.PowerShell;

namespace Devolutions.PowerShell.WorkerBridge;

/// <summary>Managed exports loaded only inside the selected PowerShell worker runtime.</summary>
public static class BridgeExports
{
    private const int Success = 0;
    private const int InvalidArgument = 1;
    private const int OutputTooLarge = 2;
    private const int InvocationFailed = 3;
    private const int Cancelled = 4;
    private const int UnsupportedType = 5;
    private const int MaximumFrameEventBytes = (64 * 1024) - 10;

    private static readonly Type PowerShellType = typeof(PsPowerShell);
    private static readonly object ActiveInvocationLock = new();
    private static ActiveInvocation? s_activeInvocation;

    /// <summary>Returns the WorkerBridge ABI version.</summary>
    [UnmanagedCallersOnly(EntryPoint = "dps_worker_bridge_get_abi_version")]
    public static int GetAbiVersion() => PowerShellType == typeof(PsPowerShell) ? 2 : 0;

    /// <summary>
    /// Executes a bounded, binary structured-command DTO and writes an ordered
    /// sequence of stream records to caller-owned memory.
    /// </summary>
    [UnmanagedCallersOnly(EntryPoint = "dps_worker_bridge_execute_invocation_utf8")]
    public static unsafe int ExecuteInvocationUtf8(
        byte* request,
        int requestLength,
        uint executionTimeoutMilliseconds,
        byte* output,
        int outputCapacity,
        int* outputLength)
    {
        if (request is null || requestLength <= 0 || output is null || outputCapacity < 0 || outputLength is null)
        {
            return InvalidArgument;
        }

        *outputLength = 0;
        if (!CommandRequest.TryParse(new ReadOnlySpan<byte>(request, requestLength), out CommandRequest? commandRequest)
            || commandRequest is null)
        {
            return InvalidArgument;
        }

        var writer = new BridgeResponseWriter(outputCapacity);
        var active = new ActiveInvocation();
        lock (ActiveInvocationLock)
        {
            if (s_activeInvocation is not null)
            {
                return InvocationFailed;
            }

            s_activeInvocation = active;
        }

        int result;
        try
        {
            result = Execute(commandRequest, executionTimeoutMilliseconds, active, writer);
        }
        finally
        {
            lock (ActiveInvocationLock)
            {
                if (ReferenceEquals(s_activeInvocation, active))
                {
                    s_activeInvocation = null;
                }
            }
        }

        if (writer.IsTooLarge)
        {
            return OutputTooLarge;
        }

        int written = writer.WriteTo(new Span<byte>(output, outputCapacity));
        if (written < 0)
        {
            return OutputTooLarge;
        }

        *outputLength = written;
        return result;
    }

    /// <summary>Requests a cooperative stop of the invocation currently owned by this worker.</summary>
    [UnmanagedCallersOnly(EntryPoint = "dps_worker_bridge_stop_current_invocation")]
    public static int StopCurrentInvocation()
    {
        lock (ActiveInvocationLock)
        {
            s_activeInvocation?.Stop();
        }

        return Success;
    }

    private static int Execute(
        CommandRequest request,
        uint executionTimeoutMilliseconds,
        ActiveInvocation active,
        BridgeResponseWriter writer)
    {
        using var powerShell = PsPowerShell.Create();
        active.SetPowerShell(powerShell);
        using var timeout = executionTimeoutMilliseconds == 0
            ? null
            : new Timer(static state => ((ActiveInvocation)state!).Stop(), active, executionTimeoutMilliseconds, Timeout.Infinite);

        var capture = new StreamCapture(writer, active);
        using var output = new PSDataCollection<PSObject>();
        output.DataAdded += (_, eventArgs) => capture.Output(output[eventArgs.Index]);
        powerShell.Streams.Error.DataAdded += (_, eventArgs) => capture.Error(powerShell.Streams.Error[eventArgs.Index]);
        powerShell.Streams.Warning.DataAdded += (_, eventArgs) => capture.Text(StreamEventKind.Warning, powerShell.Streams.Warning[eventArgs.Index].Message);
        powerShell.Streams.Verbose.DataAdded += (_, eventArgs) => capture.Text(StreamEventKind.Verbose, powerShell.Streams.Verbose[eventArgs.Index].Message);
        powerShell.Streams.Debug.DataAdded += (_, eventArgs) => capture.Text(StreamEventKind.Debug, powerShell.Streams.Debug[eventArgs.Index].Message);
        powerShell.Streams.Information.DataAdded += (_, eventArgs) => capture.Information(powerShell.Streams.Information[eventArgs.Index]);
        powerShell.Streams.Progress.DataAdded += (_, eventArgs) => capture.Progress(powerShell.Streams.Progress[eventArgs.Index]);

        try
        {
            foreach (CommandOperation operation in request.Operations)
            {
                operation.Apply(powerShell);
            }

            powerShell.Invoke<PSObject>(null, output);
        }
        catch (RuntimeException exception)
        {
            if (!active.StopRequested)
            {
                capture.Error(exception.ErrorRecord ?? CreateErrorRecord(exception), isTerminating: true);
            }
        }
        catch (Exception exception)
        {
            if (!active.StopRequested)
            {
                capture.Error(CreateErrorRecord(exception), isTerminating: true);
            }
        }

        if (writer.IsTooLarge)
        {
            return OutputTooLarge;
        }

        if (capture.UnsupportedType is not null)
        {
            capture.Error(CreateUnsupportedTypeError(capture.UnsupportedType));
            return UnsupportedType;
        }

        if (active.StopRequested)
        {
            return Cancelled;
        }

        return powerShell.HadErrors && capture.TerminatingErrorSeen ? InvocationFailed : Success;
    }

    private static ErrorRecord CreateErrorRecord(Exception exception) =>
        new(exception, "NativeAotWorkerBridgeFailure", ErrorCategory.NotSpecified, null);

    private static ErrorRecord CreateUnsupportedTypeError(string typeName) =>
        new(
            new NotSupportedException($"PowerShell output type '{typeName}' is not supported by the NativeAOT DTO contract."),
            "NativeAotUnsupportedOutputType",
            ErrorCategory.InvalidType,
            typeName);

    private sealed class ActiveInvocation
    {
        private PsPowerShell? _powerShell;
        private int _stopRequested;
        private int _stopIssued;

        public bool StopRequested => Volatile.Read(ref _stopRequested) != 0;

        public void SetPowerShell(PsPowerShell powerShell)
        {
            Volatile.Write(ref _powerShell, powerShell);
            if (StopRequested)
            {
                TryStopOnce(powerShell);
            }
        }

        public void Stop()
        {
            Interlocked.Exchange(ref _stopRequested, 1);
            PsPowerShell? powerShell = Volatile.Read(ref _powerShell);
            if (powerShell is not null)
            {
                TryStopOnce(powerShell);
            }
        }

        private void TryStopOnce(PsPowerShell powerShell)
        {
            if (Interlocked.Exchange(ref _stopIssued, 1) != 0)
            {
                return;
            }

            try
            {
                powerShell.Stop();
            }
            catch (InvalidPowerShellStateException)
            {
                // The pipeline already completed between cancellation and Stop.
            }
            catch (ObjectDisposedException)
            {
                // A late timer or pipe cancellation can race PowerShell disposal.
            }
        }
    }

    private sealed class StreamCapture
    {
        private readonly BridgeResponseWriter _writer;
        private readonly ActiveInvocation _active;

        public StreamCapture(BridgeResponseWriter writer, ActiveInvocation active)
        {
            _writer = writer;
            _active = active;
        }

        public string? UnsupportedType { get; private set; }

        public bool TerminatingErrorSeen { get; private set; }

        public void Output(PSObject value)
        {
            if (!PowerShellValue.TryEncode(value.BaseObject, out byte[]? encoded, out string? unsupportedType))
            {
                UnsupportedType ??= unsupportedType;
                ThreadPool.UnsafeQueueUserWorkItem(
                    static state => ((ActiveInvocation)state!).Stop(),
                    _active);
                return;
            }

            _writer.AddEvent(StreamEventKind.Output, encoded!);
        }

        public void Error(ErrorRecord error, bool isTerminating = false)
        {
            TerminatingErrorSeen |= isTerminating;
            _writer.AddEvent(StreamEventKind.Error, SerializeError(error));
        }

        public void Text(StreamEventKind kind, string? message) =>
            _writer.AddEvent(kind, Encoding.UTF8.GetBytes(message ?? string.Empty));

        public void Information(InformationRecord information)
        {
            _writer.AddEvent(
                StreamEventKind.Information,
                SerializeJson(new
                {
                    message = information.MessageData?.ToString() ?? string.Empty,
                    source = information.Source ?? string.Empty,
                    tags = information.Tags?.ToArray() ?? [],
                    timeGenerated = information.TimeGenerated.ToString("O"),
                }));
        }

        public void Progress(ProgressRecord progress)
        {
            _writer.AddEvent(
                StreamEventKind.Progress,
                SerializeJson(new
                {
                    activityId = progress.ActivityId,
                    parentActivityId = progress.ParentActivityId,
                    activity = progress.Activity ?? string.Empty,
                    statusDescription = progress.StatusDescription ?? string.Empty,
                    currentOperation = progress.CurrentOperation ?? string.Empty,
                    percentComplete = progress.PercentComplete,
                    secondsRemaining = progress.SecondsRemaining,
                    recordType = progress.RecordType.ToString(),
                }));
        }
    }

    private sealed class BridgeResponseWriter
    {
        private readonly object _sync = new();
        private readonly int _capacity;
        private readonly List<BridgeEvent> _events = [];
        private int _encodedLength = 3;
        private bool _isTooLarge;

        public BridgeResponseWriter(int capacity)
        {
            _capacity = capacity;
        }

        public bool IsTooLarge
        {
            get
            {
                lock (_sync)
                {
                    return _isTooLarge;
                }
            }
        }

        public void AddEvent(StreamEventKind kind, byte[] body)
        {
            lock (_sync)
            {
                if (_isTooLarge)
                {
                    return;
                }

                if (body.Length > MaximumFrameEventBytes)
                {
                    _isTooLarge = true;
                    return;
                }

                int recordLength;
                try
                {
                    recordLength = checked(6 + body.Length);
                }
                catch (OverflowException)
                {
                    _isTooLarge = true;
                    return;
                }

                if (_events.Count == ushort.MaxValue || recordLength > _capacity - _encodedLength)
                {
                    _isTooLarge = true;
                    return;
                }

                _events.Add(new BridgeEvent(kind, body));
                _encodedLength += recordLength;
            }
        }

        public int WriteTo(Span<byte> destination)
        {
            lock (_sync)
            {
                if (_isTooLarge || destination.Length < _encodedLength)
                {
                    return -1;
                }

                destination[0] = 1;
                BitConverter.TryWriteBytes(destination[1..3], checked((ushort)_events.Count));
                int offset = 3;
                foreach (BridgeEvent bridgeEvent in _events)
                {
                    BitConverter.TryWriteBytes(destination.Slice(offset, 2), (ushort)bridgeEvent.Kind);
                    offset += 2;
                    BitConverter.TryWriteBytes(destination.Slice(offset, 4), checked((uint)bridgeEvent.Body.Length));
                    offset += 4;
                    bridgeEvent.Body.CopyTo(destination[offset..]);
                    offset += bridgeEvent.Body.Length;
                }

                return offset;
            }
        }
    }

    private readonly record struct BridgeEvent(StreamEventKind Kind, byte[] Body);

    private enum StreamEventKind : ushort
    {
        Output = 1,
        Error = 2,
        Warning = 3,
        Verbose = 4,
        Debug = 5,
        Information = 6,
        Progress = 7,
    }

    private static byte[] SerializeError(ErrorRecord error) =>
        SerializeJson(new
        {
            message = Truncate(error.Exception?.Message ?? error.ToString(), 1_024),
            fullyQualifiedErrorId = Truncate(error.FullyQualifiedErrorId, 512),
            category = error.CategoryInfo.Category.ToString(),
            categoryReason = Truncate(error.CategoryInfo.Reason, 512),
            targetObject = Truncate(error.TargetObject?.ToString(), 512),
            scriptStackTrace = Truncate(error.ScriptStackTrace, 1_024),
            exceptionType = error.Exception?.GetType().FullName ?? string.Empty,
            invocationName = Truncate(error.InvocationInfo?.InvocationName, 512),
            scriptName = Truncate(error.InvocationInfo?.ScriptName, 1_024),
            scriptLineNumber = error.InvocationInfo?.ScriptLineNumber ?? 0,
            offsetInLine = error.InvocationInfo?.OffsetInLine ?? 0,
            pipelineLength = error.InvocationInfo?.PipelineLength ?? 0,
            pipelinePosition = error.InvocationInfo?.PipelinePosition ?? 0,
        });

    private static byte[] SerializeJson<T>(T value)
    {
        byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(value);
        if (bytes.Length <= MaximumFrameEventBytes)
        {
            return bytes;
        }

        return Encoding.UTF8.GetBytes("""{"message":"PowerShell stream record exceeded the configured event limit."}""");
    }

    private static string Truncate(string? value, int maximumLength)
    {
        if (string.IsNullOrEmpty(value) || value.Length <= maximumLength)
        {
            return value ?? string.Empty;
        }

        return value[..maximumLength];
    }

    private sealed class CommandRequest
    {
        private CommandRequest(List<CommandOperation> operations)
        {
            Operations = operations;
        }

        public List<CommandOperation> Operations { get; }

        public static bool TryParse(ReadOnlySpan<byte> source, out CommandRequest? request)
        {
            request = null;
            var reader = new BinaryReader(source);
            if (!reader.TryReadByte(out byte version) || version != 1 || !reader.TryReadUInt16(out ushort count) || count == 0)
            {
                return false;
            }

            var operations = new List<CommandOperation>(count);
            for (int index = 0; index < count; index++)
            {
                if (!reader.TryReadByte(out byte opcode) || !CommandOperation.TryRead(opcode, ref reader, out CommandOperation? operation))
                {
                    return false;
                }

                operations.Add(operation!);
            }

            if (!reader.AtEnd)
            {
                return false;
            }

            request = new CommandRequest(operations);
            return true;
        }
    }

    private sealed class CommandOperation
    {
        private CommandOperation(byte opcode, string? text, PowerShellValue value)
        {
            Opcode = opcode;
            Text = text;
            Value = value;
        }

        private byte Opcode { get; }

        private string? Text { get; }

        private PowerShellValue Value { get; }

        public static bool TryRead(byte opcode, ref BinaryReader reader, out CommandOperation? operation)
        {
            operation = null;
            switch (opcode)
            {
                case 1:
                case 2:
                    if (!reader.TryReadString(out string? text) || string.IsNullOrEmpty(text))
                    {
                        return false;
                    }

                    operation = new CommandOperation(opcode, text, default);
                    return true;
                case 3:
                    if (!PowerShellValue.TryRead(ref reader, out PowerShellValue argument))
                    {
                        return false;
                    }

                    operation = new CommandOperation(opcode, null, argument);
                    return true;
                case 4:
                    if (!reader.TryReadString(out string? parameterName)
                        || string.IsNullOrEmpty(parameterName)
                        || !PowerShellValue.TryRead(ref reader, out PowerShellValue parameterValue))
                    {
                        return false;
                    }

                    operation = new CommandOperation(opcode, parameterName, parameterValue);
                    return true;
                case 5:
                case 6:
                    operation = new CommandOperation(opcode, null, default);
                    return true;
                default:
                    return false;
            }
        }

        public void Apply(PsPowerShell powerShell)
        {
            switch (Opcode)
            {
                case 1:
                    powerShell.AddCommand(Text!);
                    break;
                case 2:
                    powerShell.AddScript(Text!);
                    break;
                case 3:
                    powerShell.AddArgument(Value.ToObject());
                    break;
                case 4:
                    powerShell.AddParameter(Text!, Value.ToObject());
                    break;
                case 5:
                    powerShell.AddStatement();
                    break;
                case 6:
                    powerShell.Commands.Clear();
                    break;
                default:
                    throw new InvalidOperationException("The command DTO contained an invalid operation.");
            }
        }
    }

    private readonly struct PowerShellValue
    {
        private readonly byte _kind;
        private readonly object? _value;

        private PowerShellValue(byte kind, object? value)
        {
            _kind = kind;
            _value = value;
        }

        public static bool TryRead(ref BinaryReader reader, out PowerShellValue value)
        {
            value = default;
            if (!reader.TryReadByte(out byte kind))
            {
                return false;
            }

            switch (kind)
            {
                case 0:
                    value = new PowerShellValue(kind, null);
                    return true;
                case 1:
                    if (!reader.TryReadByte(out byte boolean) || boolean > 1)
                    {
                        return false;
                    }

                    value = new PowerShellValue(kind, boolean != 0);
                    return true;
                case 2:
                    if (!reader.TryReadInt64(out long integer))
                    {
                        return false;
                    }

                    value = new PowerShellValue(kind, integer);
                    return true;
                case 3:
                    if (!reader.TryReadDouble(out double number) || double.IsNaN(number) || double.IsInfinity(number))
                    {
                        return false;
                    }

                    value = new PowerShellValue(kind, number);
                    return true;
                case 4:
                    if (!reader.TryReadString(out string? text))
                    {
                        return false;
                    }

                    value = new PowerShellValue(kind, text);
                    return true;
                default:
                    return false;
            }
        }

        public object? ToObject() => _value;

        public static bool TryEncode(object? value, out byte[]? encoded, out string? unsupportedType)
        {
            unsupportedType = null;
            var destination = new List<byte>(16);
            switch (value)
            {
                case null:
                    destination.Add(0);
                    break;
                case bool boolean:
                    destination.Add(1);
                    destination.Add(boolean ? (byte)1 : (byte)0);
                    break;
                case sbyte integer:
                    AddInt64(destination, integer);
                    break;
                case byte integer:
                    AddInt64(destination, integer);
                    break;
                case short integer:
                    AddInt64(destination, integer);
                    break;
                case ushort integer:
                    AddInt64(destination, integer);
                    break;
                case int integer:
                    AddInt64(destination, integer);
                    break;
                case uint integer:
                    AddInt64(destination, integer);
                    break;
                case long integer:
                    AddInt64(destination, integer);
                    break;
                case ulong integer when integer <= long.MaxValue:
                    AddInt64(destination, checked((long)integer));
                    break;
                case float number when float.IsFinite(number):
                    AddDouble(destination, number);
                    break;
                case double number when double.IsFinite(number):
                    AddDouble(destination, number);
                    break;
                case char character:
                    AddString(destination, character.ToString());
                    break;
                case string text:
                    AddString(destination, text);
                    break;
                default:
                    encoded = null;
                    unsupportedType = value.GetType().FullName ?? value.GetType().Name;
                    return false;
            }

            encoded = destination.ToArray();
            return true;
        }

        private static void AddInt64(List<byte> destination, long value)
        {
            destination.Add(2);
            destination.AddRange(BitConverter.GetBytes(value));
        }

        private static void AddDouble(List<byte> destination, double value)
        {
            destination.Add(3);
            destination.AddRange(BitConverter.GetBytes(value));
        }

        private static void AddString(List<byte> destination, string value)
        {
            byte[] bytes = Encoding.UTF8.GetBytes(value);
            destination.Add(4);
            destination.AddRange(BitConverter.GetBytes(checked((uint)bytes.Length)));
            destination.AddRange(bytes);
        }
    }

    private ref struct BinaryReader
    {
        private readonly ReadOnlySpan<byte> _source;
        private int _offset;

        public BinaryReader(ReadOnlySpan<byte> source)
        {
            _source = source;
        }

        public bool AtEnd => _offset == _source.Length;

        public bool TryReadByte(out byte value)
        {
            value = 0;
            if (_offset >= _source.Length)
            {
                return false;
            }

            value = _source[_offset++];
            return true;
        }

        public bool TryReadUInt16(out ushort value) =>
            TryReadUnmanaged(out value);

        public bool TryReadInt64(out long value) =>
            TryReadUnmanaged(out value);

        public bool TryReadDouble(out double value) =>
            TryReadUnmanaged(out value);

        public bool TryReadString(out string? value)
        {
            value = null;
            if (!TryReadUnmanaged(out uint length)
                || length > int.MaxValue
                || length > _source.Length - _offset)
            {
                return false;
            }

            try
            {
                value = new UTF8Encoding(false, true).GetString(_source.Slice(_offset, checked((int)length)));
            }
            catch (DecoderFallbackException)
            {
                return false;
            }

            _offset += checked((int)length);
            return true;
        }

        private bool TryReadUnmanaged<T>(out T value)
            where T : unmanaged
        {
            value = default;
            int length = Unsafe.SizeOf<T>();
            if (length > _source.Length - _offset)
            {
                return false;
            }

            value = MemoryMarshal.Read<T>(_source[_offset..]);
            _offset += length;
            return true;
        }
    }
}
