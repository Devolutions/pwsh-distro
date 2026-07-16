using System.Buffers.Binary;
using System.Text;
using System.Text.Json;

namespace Devolutions.PowerShell.NativeAot;

/// <summary>PowerShell stream kinds emitted in arrival order by one invocation.</summary>
public enum PowerShellStreamKind : ushort
{
    Output = 1,
    Error = 2,
    Warning = 3,
    Verbose = 4,
    Debug = 5,
    Information = 6,
    Progress = 7,
}

/// <summary>The exactly-one terminal state emitted by a completed invocation.</summary>
public enum PowerShellTerminalStatus : ushort
{
    Succeeded = 0,
    Cancelled = 1,
    Failed = 2,
}

/// <summary>A transport-safe structured PowerShell error record.</summary>
public sealed record PowerShellErrorRecord(
    string Message,
    string FullyQualifiedErrorId,
    string Category,
    string CategoryReason,
    string TargetObject,
    string ScriptStackTrace,
    string ExceptionType)
{
    /// <summary>Gets the bounded PowerShell invocation name when diagnostics were negotiated.</summary>
    public string InvocationName { get; init; } = string.Empty;

    /// <summary>Gets the bounded source script path when diagnostics were negotiated.</summary>
    public string ScriptName { get; init; } = string.Empty;

    /// <summary>Gets the one-based source line reported by PowerShell, or zero when unavailable.</summary>
    public int ScriptLineNumber { get; init; }

    /// <summary>Gets the one-based source offset reported by PowerShell, or zero when unavailable.</summary>
    public int OffsetInLine { get; init; }

    /// <summary>Gets the reported pipeline length, or zero when unavailable.</summary>
    public int PipelineLength { get; init; }

    /// <summary>Gets the reported pipeline position, or zero when unavailable.</summary>
    public int PipelinePosition { get; init; }
}

/// <summary>A transport-safe progress record.</summary>
public sealed record PowerShellProgressRecord(
    int ActivityId,
    int ParentActivityId,
    string Activity,
    string StatusDescription,
    string CurrentOperation,
    int PercentComplete,
    int SecondsRemaining,
    string RecordType)
{
    /// <summary>Gets whether the record closes a PowerShell progress activity.</summary>
    public bool IsCompleted { get; init; }
}

/// <summary>A transport-safe information record.</summary>
public sealed record PowerShellInformationRecord(
    string Message,
    string Source,
    IReadOnlyList<string> Tags,
    string TimeGenerated);

/// <summary>One ordered event emitted by a PowerShell invocation.</summary>
public sealed class PowerShellStreamEvent
{
    internal PowerShellStreamEvent(
        ulong sequence,
        PowerShellStreamKind kind,
        PowerShellValue? value = null,
        string? text = null,
        PowerShellErrorRecord? error = null,
        PowerShellInformationRecord? information = null,
        PowerShellProgressRecord? progress = null)
    {
        Sequence = sequence;
        Kind = kind;
        Value = value;
        Text = text;
        Error = error;
        Information = information;
        Progress = progress;
    }

    /// <summary>Gets the zero-based, contiguous stream sequence number.</summary>
    public ulong Sequence { get; }

    /// <summary>Gets the event stream kind.</summary>
    public PowerShellStreamKind Kind { get; }

    /// <summary>Gets an output primitive, when <see cref="Kind"/> is Output.</summary>
    public PowerShellValue? Value { get; }

    /// <summary>Gets text for warning, verbose, or debug records.</summary>
    public string? Text { get; }

    /// <summary>Gets a structured error record, when <see cref="Kind"/> is Error.</summary>
    public PowerShellErrorRecord? Error { get; }

    /// <summary>Gets a structured information record, when <see cref="Kind"/> is Information.</summary>
    public PowerShellInformationRecord? Information { get; }

    /// <summary>Gets a structured progress record, when <see cref="Kind"/> is Progress.</summary>
    public PowerShellProgressRecord? Progress { get; }
}

/// <summary>The complete bounded response stream and exactly one terminal result.</summary>
public sealed class PowerShellInvocationResult
{
    internal PowerShellInvocationResult(
        IReadOnlyList<PowerShellStreamEvent> events,
        PowerShellTerminalStatus terminalStatus,
        PowerShellErrorRecord? failure)
    {
        Events = events;
        TerminalStatus = terminalStatus;
        Failure = failure;
    }

    /// <summary>Gets events in worker-observed stream order.</summary>
    public IReadOnlyList<PowerShellStreamEvent> Events { get; }

    /// <summary>Gets the terminal status emitted exactly once by the worker.</summary>
    public PowerShellTerminalStatus TerminalStatus { get; }

    /// <summary>Gets the protocol failure summary for a failed terminal result.</summary>
    public PowerShellErrorRecord? Failure { get; }
}

internal static class PowerShellProtocolResponseParser
{
    private const int HeaderLength = 40;
    private const int MaximumFramePayloadBytes = 64 * 1024;
    private const int MaximumInvocationResponseBytes = 256 * 1024;
    private const uint MaximumInvocationFrames = (MaximumInvocationResponseBytes - sizeof(uint)) / 54;
    private const uint StructuredDiagnosticsFeature = 1u << 5;
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);

    internal static bool TryParse(ReadOnlySpan<byte> response, out PowerShellInvocationResult? result)
    {
        result = null;
        if (response.Length < sizeof(uint) || response.Length > MaximumInvocationResponseBytes)
        {
            return false;
        }

        uint frameCount = BinaryPrimitives.ReadUInt32LittleEndian(response);
        if (frameCount == 0 || frameCount > MaximumInvocationFrames)
        {
            return false;
        }
        int offset = sizeof(uint);
        ulong? expectedCorrelation = null;
        ulong? expectedSession = null;
        ulong? expectedRequest = null;
        uint? negotiatedFeatures = null;
        ulong nextSequence = 0;
        bool terminalSeen = false;
        bool failureSeen = false;
        var events = new List<PowerShellStreamEvent>();
        PowerShellErrorRecord? failure = null;
        PowerShellTerminalStatus terminalStatus = default;

        for (uint index = 0; index < frameCount; index++)
        {
            if (terminalSeen || response.Length - offset < sizeof(uint))
            {
                return false;
            }

            uint frameLength = BinaryPrimitives.ReadUInt32LittleEndian(response[offset..]);
            offset += sizeof(uint);
            if (frameLength < HeaderLength
                || frameLength > HeaderLength + MaximumFramePayloadBytes
                || frameLength > response.Length - offset)
            {
                return false;
            }

            ReadOnlySpan<byte> frame = response.Slice(offset, checked((int)frameLength));
            offset += checked((int)frameLength);
            if (!TryReadHeader(
                    frame,
                    out ushort kind,
                    out uint features,
                    out uint payloadLength,
                    out ulong correlation,
                    out ulong session,
                    out ulong request)
                || payloadLength != frame.Length - HeaderLength
                || correlation == 0
                || session == 0
                || request == 0)
            {
                return false;
            }

            if (expectedCorrelation is null)
            {
                expectedCorrelation = correlation;
                expectedSession = session;
                expectedRequest = request;
                negotiatedFeatures = features;
            }
            else if (expectedCorrelation != correlation
                || expectedSession != session
                || expectedRequest != request
                || negotiatedFeatures != features)
            {
                return false;
            }

            ReadOnlySpan<byte> payload = frame[HeaderLength..];
            switch (kind)
            {
                case 4:
                    if (!TryReadEvent(payload, nextSequence, negotiatedFeatures!.Value, out PowerShellStreamEvent? streamEvent))
                    {
                        return false;
                    }

                    events.Add(streamEvent!);
                    nextSequence++;
                    break;
                case 5:
                    if (failureSeen || !TryReadFailure(payload, nextSequence, out failure))
                    {
                        return false;
                    }

                    failureSeen = true;
                    nextSequence++;
                    break;
                case 6:
                    if (!TryReadTerminal(payload, nextSequence, out terminalStatus))
                    {
                        return false;
                    }

                    nextSequence++;
                    terminalSeen = true;
                    break;
                default:
                    return false;
            }
        }

        if (!terminalSeen
            || offset != response.Length
            || (terminalStatus == PowerShellTerminalStatus.Failed) != failureSeen)
        {
            return false;
        }

        result = new PowerShellInvocationResult(events, terminalStatus, failure);
        return true;
    }

    private static bool TryReadHeader(
        ReadOnlySpan<byte> frame,
        out ushort kind,
        out uint features,
        out uint payloadLength,
        out ulong correlation,
        out ulong session,
        out ulong request)
    {
        kind = default;
        features = default;
        payloadLength = default;
        correlation = default;
        session = default;
        request = default;
        if (frame.Length < HeaderLength
            || !frame[..4].SequenceEqual("DPSI"u8)
            || BinaryPrimitives.ReadUInt16LittleEndian(frame[4..]) != 1)
        {
            return false;
        }

        features = BinaryPrimitives.ReadUInt32LittleEndian(frame[8..]);
        if ((features & ~0x3Fu) != 0)
        {
            return false;
        }

        kind = BinaryPrimitives.ReadUInt16LittleEndian(frame[6..]);
        payloadLength = BinaryPrimitives.ReadUInt32LittleEndian(frame[12..]);
        correlation = BinaryPrimitives.ReadUInt64LittleEndian(frame[16..]);
        session = BinaryPrimitives.ReadUInt64LittleEndian(frame[24..]);
        request = BinaryPrimitives.ReadUInt64LittleEndian(frame[32..]);
        return true;
    }

    private static bool TryReadEvent(
        ReadOnlySpan<byte> payload,
        ulong expectedSequence,
        uint negotiatedFeatures,
        out PowerShellStreamEvent? streamEvent)
    {
        streamEvent = null;
        if (payload.Length < 10 || BinaryPrimitives.ReadUInt64LittleEndian(payload) != expectedSequence)
        {
            return false;
        }

        PowerShellStreamKind kind = (PowerShellStreamKind)BinaryPrimitives.ReadUInt16LittleEndian(payload[8..]);
        ReadOnlySpan<byte> body = payload[10..];
        switch (kind)
        {
            case PowerShellStreamKind.Output:
                int valueOffset = 0;
                if (!PowerShellValue.TryRead(body, ref valueOffset, out PowerShellValue value) || valueOffset != body.Length)
                {
                    return false;
                }

                streamEvent = new PowerShellStreamEvent(expectedSequence, kind, value: value);
                return true;
            case PowerShellStreamKind.Error:
                if (!TryReadError(
                    body,
                    (negotiatedFeatures & StructuredDiagnosticsFeature) != 0,
                    out PowerShellErrorRecord? error))
                {
                    return false;
                }

                streamEvent = new PowerShellStreamEvent(expectedSequence, kind, error: error);
                return true;
            case PowerShellStreamKind.Warning:
            case PowerShellStreamKind.Verbose:
            case PowerShellStreamKind.Debug:
                if (!TryReadUtf8(body, out string? text))
                {
                    return false;
                }

                streamEvent = new PowerShellStreamEvent(expectedSequence, kind, text: text);
                return true;
            case PowerShellStreamKind.Information:
                if (!TryReadInformation(body, out PowerShellInformationRecord? information))
                {
                    return false;
                }

                streamEvent = new PowerShellStreamEvent(expectedSequence, kind, information: information);
                return true;
            case PowerShellStreamKind.Progress:
                if (!TryReadProgress(
                    body,
                    (negotiatedFeatures & StructuredDiagnosticsFeature) != 0,
                    out PowerShellProgressRecord? progress))
                {
                    return false;
                }

                streamEvent = new PowerShellStreamEvent(expectedSequence, kind, progress: progress);
                return true;
            default:
                return false;
        }
    }

    private static bool TryReadFailure(ReadOnlySpan<byte> payload, ulong expectedSequence, out PowerShellErrorRecord? failure)
    {
        failure = null;
        if (payload.Length < 12 || BinaryPrimitives.ReadUInt64LittleEndian(payload) != expectedSequence)
        {
            return false;
        }

        ushort messageLength = BinaryPrimitives.ReadUInt16LittleEndian(payload[10..]);
        if (messageLength > 4 * 1024 || messageLength != payload.Length - 12 || !TryReadUtf8(payload[12..], out string? message))
        {
            return false;
        }

        failure = new PowerShellErrorRecord(message!, string.Empty, "Protocol", string.Empty, string.Empty, string.Empty, string.Empty);
        return true;
    }

    private static bool TryReadTerminal(ReadOnlySpan<byte> payload, ulong expectedSequence, out PowerShellTerminalStatus terminalStatus)
    {
        terminalStatus = default;
        if (payload.Length != 10 || BinaryPrimitives.ReadUInt64LittleEndian(payload) != expectedSequence)
        {
            return false;
        }

        terminalStatus = (PowerShellTerminalStatus)BinaryPrimitives.ReadUInt16LittleEndian(payload[8..]);
        return terminalStatus is PowerShellTerminalStatus.Succeeded
            or PowerShellTerminalStatus.Cancelled
            or PowerShellTerminalStatus.Failed;
    }

    private static bool TryReadError(
        ReadOnlySpan<byte> body,
        bool structuredDiagnostics,
        out PowerShellErrorRecord? error)
    {
        if (structuredDiagnostics)
        {
            return TryReadStructuredError(body, out error);
        }

        error = null;
        try
        {
            using JsonDocument document = JsonDocument.Parse(body.ToArray());
            JsonElement root = document.RootElement;
            error = new PowerShellErrorRecord(
                GetString(root, "message"),
                GetString(root, "fullyQualifiedErrorId"),
                GetString(root, "category"),
                GetString(root, "categoryReason"),
                GetString(root, "targetObject"),
                GetString(root, "scriptStackTrace"),
                GetString(root, "exceptionType"))
            {
                InvocationName = GetString(root, "invocationName"),
                ScriptName = GetString(root, "scriptName"),
                ScriptLineNumber = GetInt32(root, "scriptLineNumber"),
                OffsetInLine = GetInt32(root, "offsetInLine"),
                PipelineLength = GetInt32(root, "pipelineLength"),
                PipelinePosition = GetInt32(root, "pipelinePosition"),
            };
            return true;
        }
        catch (JsonException)
        {
            return false;
        }
    }

    private static bool TryReadInformation(ReadOnlySpan<byte> body, out PowerShellInformationRecord? information)
    {
        information = null;
        try
        {
            using JsonDocument document = JsonDocument.Parse(body.ToArray());
            JsonElement root = document.RootElement;
            var tags = new List<string>();
            if (root.TryGetProperty("tags", out JsonElement tagsElement) && tagsElement.ValueKind == JsonValueKind.Array)
            {
                foreach (JsonElement tag in tagsElement.EnumerateArray())
                {
                    if (tag.ValueKind == JsonValueKind.String)
                    {
                        tags.Add(tag.GetString() ?? string.Empty);
                    }
                }
            }

            information = new PowerShellInformationRecord(
                GetString(root, "message"),
                GetString(root, "source"),
                tags,
                GetString(root, "timeGenerated"));
            return true;
        }
        catch (JsonException)
        {
            return false;
        }
    }

    private static bool TryReadProgress(
        ReadOnlySpan<byte> body,
        bool structuredDiagnostics,
        out PowerShellProgressRecord? progress)
    {
        if (structuredDiagnostics)
        {
            return TryReadStructuredProgress(body, out progress);
        }

        progress = null;
        try
        {
            using JsonDocument document = JsonDocument.Parse(body.ToArray());
            JsonElement root = document.RootElement;
            progress = new PowerShellProgressRecord(
                GetInt32(root, "activityId"),
                GetInt32(root, "parentActivityId"),
                GetString(root, "activity"),
                GetString(root, "statusDescription"),
                GetString(root, "currentOperation"),
                GetInt32(root, "percentComplete"),
                GetInt32(root, "secondsRemaining"),
                GetString(root, "recordType"));
            return true;
        }
        catch (JsonException)
        {
            return false;
        }
    }

    private static bool TryReadStructuredError(ReadOnlySpan<byte> body, out PowerShellErrorRecord? error)
        {
            error = null;
            int offset = 0;
            if (!TryReadByte(body, ref offset, out byte version)
                || version != 1
                || !TryReadBoundedUtf8(body, ref offset, 1_024, out string? message)
                || !TryReadBoundedUtf8(body, ref offset, 512, out string? fullyQualifiedErrorId)
                || !TryReadBoundedUtf8(body, ref offset, 256, out string? category)
                || !TryReadBoundedUtf8(body, ref offset, 512, out string? categoryReason)
                || !TryReadBoundedUtf8(body, ref offset, 512, out string? targetObject)
                || !TryReadBoundedUtf8(body, ref offset, 1_024, out string? scriptStackTrace)
                || !TryReadBoundedUtf8(body, ref offset, 512, out string? exceptionType)
                || !TryReadBoundedUtf8(body, ref offset, 512, out string? invocationName)
                || !TryReadBoundedUtf8(body, ref offset, 1_024, out string? scriptName)
                || !TryReadInt32(body, ref offset, out int scriptLineNumber)
                || !TryReadInt32(body, ref offset, out int offsetInLine)
                || !TryReadInt32(body, ref offset, out int pipelineLength)
                || !TryReadInt32(body, ref offset, out int pipelinePosition)
                || offset != body.Length)
            {
                return false;
            }

            error = new PowerShellErrorRecord(
                message!,
                fullyQualifiedErrorId!,
                category!,
                categoryReason!,
                targetObject!,
                scriptStackTrace!,
                exceptionType!)
            {
                InvocationName = invocationName!,
                ScriptName = scriptName!,
                ScriptLineNumber = scriptLineNumber,
                OffsetInLine = offsetInLine,
                PipelineLength = pipelineLength,
                PipelinePosition = pipelinePosition,
            };
            return true;
        }

    private static bool TryReadStructuredProgress(ReadOnlySpan<byte> body, out PowerShellProgressRecord? progress)
        {
            progress = null;
            int offset = 0;
            if (!TryReadByte(body, ref offset, out byte version)
                || version != 1
                || !TryReadInt32(body, ref offset, out int activityId)
                || !TryReadInt32(body, ref offset, out int parentActivityId)
                || !TryReadInt32(body, ref offset, out int percentComplete)
                || !TryReadInt32(body, ref offset, out int secondsRemaining)
                || !TryReadByte(body, ref offset, out byte recordType)
                || recordType > 1
                || !TryReadBoundedUtf8(body, ref offset, 1_024, out string? activity)
                || !TryReadBoundedUtf8(body, ref offset, 1_024, out string? statusDescription)
                || !TryReadBoundedUtf8(body, ref offset, 1_024, out string? currentOperation)
                || offset != body.Length)
            {
                return false;
            }

            progress = new PowerShellProgressRecord(
                activityId,
                parentActivityId,
                activity!,
                statusDescription!,
                currentOperation!,
                percentComplete,
                secondsRemaining,
                recordType == 0 ? "Processing" : "Completed")
            {
                IsCompleted = recordType == 1,
            };
            return true;
        }

    private static bool TryReadByte(ReadOnlySpan<byte> source, ref int offset, out byte value)
        {
            value = default;
            if ((uint)offset >= (uint)source.Length)
            {
                return false;
            }

            value = source[offset++];
            return true;
        }

    private static bool TryReadInt32(ReadOnlySpan<byte> source, ref int offset, out int value)
        {
            value = default;
            if (source.Length - offset < sizeof(int))
            {
                return false;
            }

            value = BinaryPrimitives.ReadInt32LittleEndian(source[offset..]);
            offset += sizeof(int);
            return true;
        }

    private static bool TryReadBoundedUtf8(
            ReadOnlySpan<byte> source,
            ref int offset,
            int maximumLength,
            out string? value)
        {
            value = null;
            if (source.Length - offset < sizeof(ushort))
            {
                return false;
            }

            ushort length = BinaryPrimitives.ReadUInt16LittleEndian(source[offset..]);
            offset += sizeof(ushort);
            if (length > maximumLength || source.Length - offset < length)
            {
                return false;
            }

            bool result = TryReadUtf8(source.Slice(offset, length), out value);
            offset += length;
            return result;
    }

    private static bool TryReadUtf8(ReadOnlySpan<byte> source, out string? value)
    {
        try
        {
            value = StrictUtf8.GetString(source);
            return true;
        }
        catch (DecoderFallbackException)
        {
            value = null;
            return false;
        }
    }

    private static string GetString(JsonElement root, string propertyName) =>
        root.TryGetProperty(propertyName, out JsonElement property) && property.ValueKind == JsonValueKind.String
            ? property.GetString() ?? string.Empty
            : string.Empty;

    private static int GetInt32(JsonElement root, string propertyName) =>
        root.TryGetProperty(propertyName, out JsonElement property) && property.TryGetInt32(out int value)
            ? value
            : 0;
}
