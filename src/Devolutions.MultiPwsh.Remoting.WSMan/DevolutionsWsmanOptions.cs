using System.Text.Json;
using System.Text.Json.Serialization;

namespace Devolutions.MultiPwsh.Remoting.WSMan;

public sealed record DevolutionsWsmanOptions
{
    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        AllowTrailingCommas = false,
        PropertyNameCaseInsensitive = false,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
    };

    [JsonPropertyName("endpointUri")]
    public required Uri EndpointUri { get; init; }

    [JsonPropertyName("authentication")]
    [JsonConverter(typeof(JsonStringEnumConverter<DevolutionsWsmanAuthentication>))]
    public DevolutionsWsmanAuthentication Authentication { get; init; } = DevolutionsWsmanAuthentication.Negotiate;

    [JsonPropertyName("shellUri")]
    public string ShellUri { get; init; } = "http://schemas.microsoft.com/powershell/Microsoft.PowerShell";

    [JsonPropertyName("minRunspaces")]
    public int MinRunspaces { get; init; } = 1;

    [JsonPropertyName("maxRunspaces")]
    public int MaxRunspaces { get; init; } = 1;

    [JsonPropertyName("openTimeoutMilliseconds")]
    public int OpenTimeoutMilliseconds { get; init; } = 180_000;

    [JsonPropertyName("operationTimeoutMilliseconds")]
    public int OperationTimeoutMilliseconds { get; init; } = 180_000;

    [JsonPropertyName("maxEnvelopeSizeKilobytes")]
    public int MaxEnvelopeSizeKilobytes { get; init; } = 500;

    [JsonPropertyName("skipCertificateCheck")]
    public bool SkipCertificateCheck { get; init; }

    [JsonPropertyName("kdcProxyUri")]
    public Uri? KdcProxyUri { get; init; }

    [JsonPropertyName("spn")]
    public string? Spn { get; init; }

    public static DevolutionsWsmanOptions Parse(string optionsJson)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(optionsJson);

        DevolutionsWsmanOptions options;
        try
        {
            options = JsonSerializer.Deserialize<DevolutionsWsmanOptions>(optionsJson, SerializerOptions)
                ?? throw new ArgumentException("The options JSON must contain an object.", nameof(optionsJson));
        }
        catch (JsonException exception)
        {
            throw new ArgumentException("The options JSON does not match the devolutions.wsman schema.", nameof(optionsJson), exception);
        }

        options.Validate();
        return options;
    }

    private void Validate()
    {
        if (!EndpointUri.IsAbsoluteUri ||
            (EndpointUri.Scheme != Uri.UriSchemeHttp && EndpointUri.Scheme != Uri.UriSchemeHttps))
        {
            throw new ArgumentException("endpointUri must be an absolute HTTP or HTTPS URI.");
        }

        if (string.IsNullOrWhiteSpace(ShellUri))
        {
            throw new ArgumentException("shellUri must not be empty.");
        }

        if (MinRunspaces < 1)
        {
            throw new ArgumentOutOfRangeException(nameof(MinRunspaces), "minRunspaces must be at least 1.");
        }

        if (MaxRunspaces < MinRunspaces)
        {
            throw new ArgumentOutOfRangeException(nameof(MaxRunspaces), "maxRunspaces must be greater than or equal to minRunspaces.");
        }

        if (OpenTimeoutMilliseconds < 1)
        {
            throw new ArgumentOutOfRangeException(nameof(OpenTimeoutMilliseconds), "openTimeoutMilliseconds must be at least 1.");
        }

        if (OperationTimeoutMilliseconds < 1)
        {
            throw new ArgumentOutOfRangeException(nameof(OperationTimeoutMilliseconds), "operationTimeoutMilliseconds must be at least 1.");
        }

        if (MaxEnvelopeSizeKilobytes < 1)
        {
            throw new ArgumentOutOfRangeException(nameof(MaxEnvelopeSizeKilobytes), "maxEnvelopeSizeKilobytes must be at least 1.");
        }

        if (KdcProxyUri is not null &&
            (!KdcProxyUri.IsAbsoluteUri || KdcProxyUri.Scheme != Uri.UriSchemeHttps))
        {
            throw new ArgumentException("kdcProxyUri must be an absolute HTTPS URI.");
        }

        if (Spn is not null && string.IsNullOrWhiteSpace(Spn))
        {
            throw new ArgumentException("spn must be null or a non-empty string.");
        }
    }
}

[JsonConverter(typeof(JsonStringEnumConverter<DevolutionsWsmanAuthentication>))]
public enum DevolutionsWsmanAuthentication
{
    Negotiate,
    Kerberos,
    Ntlm,
}
