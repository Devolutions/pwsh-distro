using System.Buffers.Binary;
using System.Text;

namespace Devolutions.PowerShell.NativeAot;

/// <summary>Primitive values supported by the process-isolated PowerShell DTO contract.</summary>
public enum PowerShellValueKind : byte
{
    Null = 0,
    Boolean = 1,
    Int64 = 2,
    Double = 3,
    String = 4,
}

/// <summary>A typed primitive that can safely cross the NativeAOT worker boundary.</summary>
public readonly struct PowerShellValue
{
    private readonly object? _value;

    private PowerShellValue(PowerShellValueKind kind, object? value)
    {
        Kind = kind;
        _value = value;
    }

    /// <summary>Gets the DTO primitive kind.</summary>
    public PowerShellValueKind Kind { get; }

    /// <summary>Creates a null value.</summary>
    public static PowerShellValue Null() => new(PowerShellValueKind.Null, null);

    /// <summary>Creates a Boolean value.</summary>
    public static PowerShellValue FromBoolean(bool value) => new(PowerShellValueKind.Boolean, value);

    /// <summary>Creates an Int64 value.</summary>
    public static PowerShellValue FromInt64(long value) => new(PowerShellValueKind.Int64, value);

    /// <summary>Creates a finite double-precision value.</summary>
    public static PowerShellValue FromDouble(double value)
    {
        if (!double.IsFinite(value))
        {
            throw new ArgumentOutOfRangeException(nameof(value), "Only finite floating-point values are supported.");
        }

        return new(PowerShellValueKind.Double, value);
    }

    /// <summary>Creates a UTF-8 string value.</summary>
    public static PowerShellValue FromString(string? value) =>
        value is null ? Null() : new(PowerShellValueKind.String, ValidateText(value, nameof(value)));

    /// <summary>Creates a supported primitive value or rejects an object graph that cannot cross the boundary.</summary>
    public static PowerShellValue FromObject(object? value) => value switch
    {
        null => Null(),
        bool boolean => FromBoolean(boolean),
        sbyte integer => FromInt64(integer),
        byte integer => FromInt64(integer),
        short integer => FromInt64(integer),
        ushort integer => FromInt64(integer),
        int integer => FromInt64(integer),
        uint integer => FromInt64(integer),
        long integer => FromInt64(integer),
        ulong integer when integer <= long.MaxValue => FromInt64((long)integer),
        float number when float.IsFinite(number) => FromDouble(number),
        double number => FromDouble(number),
        char character => FromString(character.ToString()),
        string text => FromString(text),
        _ => throw new NotSupportedException(
            $"Values of type '{value.GetType().FullName}' are not supported by the NativeAOT PowerShell DTO contract."),
    };

    /// <summary>Returns the primitive value represented by this DTO.</summary>
    public object? ToObject() => _value;

    internal void WriteTo(List<byte> destination)
    {
        destination.Add((byte)Kind);
        switch (Kind)
        {
            case PowerShellValueKind.Null:
                return;
            case PowerShellValueKind.Boolean:
                destination.Add((bool)_value! ? (byte)1 : (byte)0);
                return;
            case PowerShellValueKind.Int64:
                WriteInt64(destination, (long)_value!);
                return;
            case PowerShellValueKind.Double:
                WriteInt64(destination, BitConverter.DoubleToInt64Bits((double)_value!));
                return;
            case PowerShellValueKind.String:
                WriteText(destination, (string)_value!);
                return;
            default:
                throw new InvalidOperationException("The PowerShell value kind is invalid.");
        }
    }

    internal static bool TryRead(ReadOnlySpan<byte> source, ref int offset, out PowerShellValue value)
    {
        value = default;
        if (offset >= source.Length)
        {
            return false;
        }

        PowerShellValueKind kind = (PowerShellValueKind)source[offset++];
        switch (kind)
        {
            case PowerShellValueKind.Null:
                value = Null();
                return true;
            case PowerShellValueKind.Boolean:
                if (source.Length - offset < 1 || source[offset] > 1)
                {
                    return false;
                }

                value = FromBoolean(source[offset++] != 0);
                return true;
            case PowerShellValueKind.Int64:
                if (!TryReadInt64(source, ref offset, out long integer))
                {
                    return false;
                }

                value = FromInt64(integer);
                return true;
            case PowerShellValueKind.Double:
                if (!TryReadInt64(source, ref offset, out long bits))
                {
                    return false;
                }

                double number = BitConverter.Int64BitsToDouble(bits);
                if (!double.IsFinite(number))
                {
                    return false;
                }

                value = FromDouble(number);
                return true;
            case PowerShellValueKind.String:
                if (!TryReadText(source, ref offset, out string? text))
                {
                    return false;
                }

                value = FromString(text);
                return true;
            default:
                return false;
        }
    }

    internal static void WriteText(List<byte> destination, string value)
    {
        byte[] bytes = Encoding.UTF8.GetBytes(ValidateText(value, nameof(value)));
        destination.AddRange(BitConverter.GetBytes(checked((uint)bytes.Length)));
        destination.AddRange(bytes);
    }

    internal static bool TryReadText(ReadOnlySpan<byte> source, ref int offset, out string? value)
    {
        value = null;
        if (source.Length - offset < sizeof(uint))
        {
            return false;
        }

        uint length = BinaryPrimitives.ReadUInt32LittleEndian(source[offset..]);
        offset += sizeof(uint);
        if (length > int.MaxValue || length > source.Length - offset)
        {
            return false;
        }

        try
        {
            value = new UTF8Encoding(false, true).GetString(source.Slice(offset, checked((int)length)));
        }
        catch (DecoderFallbackException)
        {
            return false;
        }

        offset += checked((int)length);
        return true;
    }

    private static void WriteInt64(List<byte> destination, long value) =>
        destination.AddRange(BitConverter.GetBytes(value));

    private static bool TryReadInt64(ReadOnlySpan<byte> source, ref int offset, out long value)
    {
        value = default;
        if (source.Length - offset < sizeof(long))
        {
            return false;
        }

        value = BinaryPrimitives.ReadInt64LittleEndian(source[offset..]);
        offset += sizeof(long);
        return true;
    }

    private static string ValidateText(string value, string parameterName)
    {
        if (value.IndexOf('\0') >= 0)
        {
            throw new ArgumentException("DTO strings cannot contain NUL characters.", parameterName);
        }

        return value;
    }
}
