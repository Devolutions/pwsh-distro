namespace Devolutions.PowerShell.NativeAot;

/// <summary>Fixed broker status values shared with the Rust ABI.</summary>
public enum NativeStatus
{
    Success = 0,
    InvalidArgument = 1,
    PayloadNotFound = 2,
    HostfxrNotFound = 3,
    WorkerNotFound = 4,
    WorkerFailed = 5,
    UnsupportedPlatform = 6,
    InvalidPayload = 7,
    BridgeNotFound = 8,
    BridgeLoadFailed = 9,
    BridgeAbiMismatch = 10,
    StartupTimeout = 11,
    HandshakeRejected = 12,
    WorkerExited = 13,
    ConnectionSetupFailed = 14,
    RequestTimeout = 15,
    OutputBufferTooSmall = 16,
    ProtocolViolation = 17,
    PayloadManifestMissing = 18,
    PayloadManifestInvalid = 19,
    IntegrityMismatch = 20,
    ArchitectureMismatch = 21,
}
