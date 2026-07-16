namespace Devolutions.PowerShell.NativeAot;

/// <summary>Builds one atomic, typed PowerShell command DTO without referencing SMA.</summary>
public sealed class PowerShellCommand
{
    private const int MaximumPayloadBytes = (64 * 1024) - 4;
    private readonly object _sync = new();
    private readonly List<CommandOperation> _operations = [];

    /// <summary>Adds a command name to the current statement.</summary>
    public PowerShellCommand AddCommand(string command)
    {
        AddTextOperation(CommandOpcode.AddCommand, command, nameof(command));
        return this;
    }

    /// <summary>Adds a script fragment to the current statement.</summary>
    public PowerShellCommand AddScript(string script)
    {
        AddTextOperation(CommandOpcode.AddScript, script, nameof(script));
        return this;
    }

    /// <summary>Adds a typed argument to the current command.</summary>
    public PowerShellCommand AddArgument(PowerShellValue value)
    {
        lock (_sync)
        {
            _operations.Add(new(CommandOpcode.AddArgument, null, value));
        }

        return this;
    }

    /// <summary>Adds a supported primitive argument to the current command.</summary>
    public PowerShellCommand AddArgument(object? value) => AddArgument(PowerShellValue.FromObject(value));

    /// <summary>Adds a typed parameter to the current command.</summary>
    public PowerShellCommand AddParameter(string name, PowerShellValue value)
    {
        ValidateText(name, nameof(name));
        lock (_sync)
        {
            _operations.Add(new(CommandOpcode.AddParameter, name, value));
        }

        return this;
    }

    /// <summary>Adds a supported primitive parameter to the current command.</summary>
    public PowerShellCommand AddParameter(string name, object? value) =>
        AddParameter(name, PowerShellValue.FromObject(value));

    /// <summary>Ends the current pipeline statement.</summary>
    public PowerShellCommand AddStatement()
    {
        lock (_sync)
        {
            _operations.Add(new(CommandOpcode.AddStatement, null, default));
        }

        return this;
    }

    /// <summary>Clears commands accumulated before this point in the remote invocation.</summary>
    public PowerShellCommand Clear()
    {
        lock (_sync)
        {
            _operations.Add(new(CommandOpcode.Clear, null, default));
        }

        return this;
    }

    internal byte[] ToPayload()
    {
        CommandOperation[] operations;
        lock (_sync)
        {
            if (_operations.Count == 0)
            {
                throw new InvalidOperationException("At least one command operation is required.");
            }

            operations = _operations.ToArray();
        }

        if (operations.Length > ushort.MaxValue)
        {
            throw new InvalidOperationException("Too many command operations were supplied.");
        }

        var payload = new List<byte>(64)
        {
            1,
        };
        payload.AddRange(BitConverter.GetBytes(checked((ushort)operations.Length)));
        foreach (CommandOperation operation in operations)
        {
            payload.Add((byte)operation.Opcode);
            switch (operation.Opcode)
            {
                case CommandOpcode.AddCommand:
                case CommandOpcode.AddScript:
                    PowerShellValue.WriteText(payload, operation.Text!);
                    break;
                case CommandOpcode.AddArgument:
                    operation.Value.WriteTo(payload);
                    break;
                case CommandOpcode.AddParameter:
                    PowerShellValue.WriteText(payload, operation.Text!);
                    operation.Value.WriteTo(payload);
                    break;
            }

            if (payload.Count > MaximumPayloadBytes)
            {
                throw new InvalidOperationException("The structured command exceeds the 64 KiB protocol frame limit.");
            }
        }

        return payload.ToArray();
    }

    private void AddTextOperation(CommandOpcode opcode, string value, string parameterName)
    {
        ValidateText(value, parameterName);
        lock (_sync)
        {
            _operations.Add(new(opcode, value, default));
        }
    }

    private static void ValidateText(string value, string parameterName)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(value, parameterName);
        if (value.IndexOf('\0') >= 0)
        {
            throw new ArgumentException("Command text cannot contain NUL characters.", parameterName);
        }
    }

    private readonly record struct CommandOperation(CommandOpcode Opcode, string? Text, PowerShellValue Value);

    private enum CommandOpcode : byte
    {
        AddCommand = 1,
        AddScript = 2,
        AddArgument = 3,
        AddParameter = 4,
        AddStatement = 5,
        Clear = 6,
    }
}
