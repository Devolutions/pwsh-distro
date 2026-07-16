use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::fs;
use std::path::{Component, Path, PathBuf};

#[cfg(target_os = "linux")]
pub mod unix_socket;
#[cfg(windows)]
pub mod windows_pipe;

#[cfg(target_os = "linux")]
pub mod transport {
    pub use crate::unix_socket::{
        UnixSocketClient as NamedPipeClient, UnixSocketConnection as PipeConnection,
        UnixSocketError as PipeError, UnixSocketServer as NamedPipeServer,
    };
}
#[cfg(windows)]
pub mod transport {
    pub use crate::windows_pipe::{NamedPipeClient, NamedPipeServer, PipeConnection, PipeError};
}

pub const BROKER_ABI_VERSION: u32 = 1;
pub const PROTOCOL_VERSION: u16 = 1;
pub const CAPABILITY_TOKEN_LENGTH: usize = 32;
pub const MAX_FRAME_PAYLOAD_BYTES: usize = 64 * 1024;
pub const MAX_FAILURE_MESSAGE_BYTES: usize = 4 * 1024;
pub const MAX_BUFFERED_BYTES: usize = 2 * (FrameHeader::ENCODED_LENGTH + MAX_FRAME_PAYLOAD_BYTES);
pub const MAX_INVOCATION_RESPONSE_BYTES: usize = 256 * 1024;
pub const PAYLOAD_MANIFEST_FILE: &str = "devolutions-pwsh-payload.json";

const FRAME_MAGIC: [u8; 4] = *b"DPSI";

#[repr(i32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Status {
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

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct FeatureSet(u32);

impl FeatureSet {
    pub const EMPTY: Self = Self(0);
    pub const CANCELLATION: Self = Self(1 << 0);
    pub const ORDERED_EVENTS: Self = Self(1 << 1);
    pub const STRUCTURED_FAILURES: Self = Self(1 << 2);
    pub const STRUCTURED_COMMANDS: Self = Self(1 << 3);
    pub const TYPED_VALUES: Self = Self(1 << 4);
    /// Enables fixed-schema error coordinates and progress payloads.
    pub const STRUCTURED_DIAGNOSTICS: Self = Self(1 << 5);
    pub const SUPPORTED: Self = Self(
        Self::CANCELLATION.0
            | Self::ORDERED_EVENTS.0
            | Self::STRUCTURED_FAILURES.0
            | Self::STRUCTURED_COMMANDS.0
            | Self::TYPED_VALUES.0
            | Self::STRUCTURED_DIAGNOSTICS.0,
    );

    pub const fn from_bits(bits: u32) -> Self {
        Self(bits)
    }

    pub const fn bits(self) -> u32 {
        self.0
    }

    pub const fn contains(self, feature: Self) -> bool {
        self.0 & feature.0 == feature.0
    }

    pub const fn intersection(self, other: Self) -> Self {
        Self(self.0 & other.0)
    }

    const fn has_unknown_bits(self) -> bool {
        self.0 & !Self::SUPPORTED.0 != 0
    }
}

#[repr(u16)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FrameKind {
    Hello = 1,
    Welcome = 2,
    Cancel = 3,
    Event = 4,
    Failure = 5,
    Terminal = 6,
    ExecuteScript = 7,
    ExecuteCommand = 8,
    ScriptOutput = 9,
}

impl TryFrom<u16> for FrameKind {
    type Error = ProtocolError;

    fn try_from(value: u16) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::Hello),
            2 => Ok(Self::Welcome),
            3 => Ok(Self::Cancel),
            4 => Ok(Self::Event),
            5 => Ok(Self::Failure),
            6 => Ok(Self::Terminal),
            7 => Ok(Self::ExecuteScript),
            8 => Ok(Self::ExecuteCommand),
            9 => Ok(Self::ScriptOutput),
            _ => Err(ProtocolError::UnknownFrameKind(value)),
        }
    }
}

#[repr(u16)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TerminalStatus {
    Succeeded = 0,
    Cancelled = 1,
    Failed = 2,
}

impl TryFrom<u16> for TerminalStatus {
    type Error = ProtocolError;

    fn try_from(value: u16) -> Result<Self, Self::Error> {
        match value {
            0 => Ok(Self::Succeeded),
            1 => Ok(Self::Cancelled),
            2 => Ok(Self::Failed),
            _ => Err(ProtocolError::InvalidPayload),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RequestIdentifiers {
    pub correlation_id: u64,
    pub session_id: u64,
    pub request_id: u64,
}

impl RequestIdentifiers {
    pub const fn new(correlation_id: u64, session_id: u64, request_id: u64) -> Self {
        Self {
            correlation_id,
            session_id,
            request_id,
        }
    }

    fn is_valid(self) -> bool {
        self.correlation_id != 0 && self.session_id != 0 && self.request_id != 0
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct FrameHeader {
    pub protocol_version: u16,
    pub kind: FrameKind,
    pub features: FeatureSet,
    pub payload_length: u32,
    pub identifiers: RequestIdentifiers,
}

impl FrameHeader {
    pub const ENCODED_LENGTH: usize = 40;

    fn encode(self, destination: &mut Vec<u8>) {
        destination.extend_from_slice(&FRAME_MAGIC);
        destination.extend_from_slice(&self.protocol_version.to_le_bytes());
        destination.extend_from_slice(&(self.kind as u16).to_le_bytes());
        destination.extend_from_slice(&self.features.bits().to_le_bytes());
        destination.extend_from_slice(&self.payload_length.to_le_bytes());
        destination.extend_from_slice(&self.identifiers.correlation_id.to_le_bytes());
        destination.extend_from_slice(&self.identifiers.session_id.to_le_bytes());
        destination.extend_from_slice(&self.identifiers.request_id.to_le_bytes());
    }

    pub fn frame_length_from_header(encoded_header: &[u8]) -> Result<usize, ProtocolError> {
        let header = FrameHeader::decode(encoded_header)?;
        Ok(FrameHeader::ENCODED_LENGTH + header.payload_length as usize)
    }

    fn decode(source: &[u8]) -> Result<Self, ProtocolError> {
        if source.len() != Self::ENCODED_LENGTH {
            return Err(ProtocolError::InvalidLength);
        }
        if source[..4] != FRAME_MAGIC {
            return Err(ProtocolError::InvalidMagic);
        }

        let protocol_version = u16::from_le_bytes([source[4], source[5]]);
        if protocol_version != PROTOCOL_VERSION {
            return Err(ProtocolError::UnsupportedProtocolVersion(protocol_version));
        }

        let kind = FrameKind::try_from(u16::from_le_bytes([source[6], source[7]]))?;
        let features = FeatureSet::from_bits(u32::from_le_bytes([
            source[8], source[9], source[10], source[11],
        ]));
        if features.has_unknown_bits() {
            return Err(ProtocolError::UnsupportedFeatureBits(features.bits()));
        }

        let payload_length = u32::from_le_bytes([source[12], source[13], source[14], source[15]]);
        if payload_length as usize > MAX_FRAME_PAYLOAD_BYTES {
            return Err(ProtocolError::FrameTooLarge);
        }

        let identifiers = RequestIdentifiers::new(
            u64::from_le_bytes([
                source[16], source[17], source[18], source[19], source[20], source[21], source[22],
                source[23],
            ]),
            u64::from_le_bytes([
                source[24], source[25], source[26], source[27], source[28], source[29], source[30],
                source[31],
            ]),
            u64::from_le_bytes([
                source[32], source[33], source[34], source[35], source[36], source[37], source[38],
                source[39],
            ]),
        );

        if matches!(kind, FrameKind::Hello | FrameKind::Welcome) {
            if identifiers != RequestIdentifiers::new(0, 0, 0) {
                return Err(ProtocolError::InvalidIdentifiers);
            }
        } else if !identifiers.is_valid() {
            return Err(ProtocolError::InvalidIdentifiers);
        }

        Ok(Self {
            protocol_version,
            kind,
            features,
            payload_length,
            identifiers,
        })
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Frame {
    pub header: FrameHeader,
    pub payload: Vec<u8>,
}

impl Frame {
    pub fn new(
        kind: FrameKind,
        features: FeatureSet,
        identifiers: RequestIdentifiers,
        payload: Vec<u8>,
    ) -> Result<Self, ProtocolError> {
        if payload.len() > MAX_FRAME_PAYLOAD_BYTES {
            return Err(ProtocolError::FrameTooLarge);
        }
        if features.has_unknown_bits() {
            return Err(ProtocolError::UnsupportedFeatureBits(features.bits()));
        }
        if matches!(kind, FrameKind::Hello | FrameKind::Welcome) {
            if identifiers != RequestIdentifiers::new(0, 0, 0) {
                return Err(ProtocolError::InvalidIdentifiers);
            }
        } else if !identifiers.is_valid() {
            return Err(ProtocolError::InvalidIdentifiers);
        }

        let frame = Self {
            header: FrameHeader {
                protocol_version: PROTOCOL_VERSION,
                kind,
                features,
                payload_length: payload.len() as u32,
                identifiers,
            },
            payload,
        };
        frame.validate_payload()?;
        Ok(frame)
    }

    pub fn encode(&self) -> Result<Vec<u8>, ProtocolError> {
        if self.header.payload_length != self.payload.len() as u32 {
            return Err(ProtocolError::InvalidLength);
        }

        let mut encoded = Vec::with_capacity(FrameHeader::ENCODED_LENGTH + self.payload.len());
        self.header.encode(&mut encoded);
        encoded.extend_from_slice(&self.payload);
        Ok(encoded)
    }

    pub fn decode(encoded: &[u8]) -> Result<Self, ProtocolError> {
        if encoded.len() < FrameHeader::ENCODED_LENGTH {
            return Err(ProtocolError::TruncatedFrame);
        }

        let header = FrameHeader::decode(&encoded[..FrameHeader::ENCODED_LENGTH])?;
        let expected_length = FrameHeader::ENCODED_LENGTH + header.payload_length as usize;
        if encoded.len() < expected_length {
            return Err(ProtocolError::TruncatedFrame);
        }
        if encoded.len() != expected_length {
            return Err(ProtocolError::TrailingData);
        }

        let frame = Self {
            header,
            payload: encoded[FrameHeader::ENCODED_LENGTH..].to_vec(),
        };
        frame.validate_payload()?;
        Ok(frame)
    }

    pub fn event_payload(&self) -> Result<EventPayload<'_>, ProtocolError> {
        if self.header.kind != FrameKind::Event || self.payload.len() < 10 {
            return Err(ProtocolError::InvalidPayload);
        }

        Ok(EventPayload {
            sequence: u64::from_le_bytes(
                self.payload[..8]
                    .try_into()
                    .map_err(|_| ProtocolError::InvalidPayload)?,
            ),
            event_kind: u16::from_le_bytes(
                self.payload[8..10]
                    .try_into()
                    .map_err(|_| ProtocolError::InvalidPayload)?,
            ),
            body: &self.payload[10..],
        })
    }

    pub fn failure_payload(&self) -> Result<FailurePayload<'_>, ProtocolError> {
        if self.header.kind != FrameKind::Failure || self.payload.len() < 12 {
            return Err(ProtocolError::InvalidPayload);
        }

        let message_length = u16::from_le_bytes(
            self.payload[10..12]
                .try_into()
                .map_err(|_| ProtocolError::InvalidPayload)?,
        ) as usize;
        if message_length > MAX_FAILURE_MESSAGE_BYTES || self.payload.len() != 12 + message_length {
            return Err(ProtocolError::InvalidPayload);
        }

        Ok(FailurePayload {
            sequence: u64::from_le_bytes(
                self.payload[..8]
                    .try_into()
                    .map_err(|_| ProtocolError::InvalidPayload)?,
            ),
            failure_code: u16::from_le_bytes(
                self.payload[8..10]
                    .try_into()
                    .map_err(|_| ProtocolError::InvalidPayload)?,
            ),
            message: std::str::from_utf8(&self.payload[12..])
                .map_err(|_| ProtocolError::InvalidPayload)?,
        })
    }

    pub fn terminal_payload(&self) -> Result<TerminalPayload, ProtocolError> {
        if self.header.kind != FrameKind::Terminal || self.payload.len() != 10 {
            return Err(ProtocolError::InvalidPayload);
        }

        Ok(TerminalPayload {
            sequence: u64::from_le_bytes(
                self.payload[..8]
                    .try_into()
                    .map_err(|_| ProtocolError::InvalidPayload)?,
            ),
            status: TerminalStatus::try_from(u16::from_le_bytes(
                self.payload[8..10]
                    .try_into()
                    .map_err(|_| ProtocolError::InvalidPayload)?,
            ))?,
        })
    }

    pub fn script_request_payload(&self) -> Result<&str, ProtocolError> {
        if self.header.kind != FrameKind::ExecuteScript || self.payload.is_empty() {
            return Err(ProtocolError::InvalidPayload);
        }

        std::str::from_utf8(&self.payload).map_err(|_| ProtocolError::InvalidPayload)
    }

    pub fn command_request_payload(&self) -> Result<&[u8], ProtocolError> {
        if self.header.kind != FrameKind::ExecuteCommand || self.payload.is_empty() {
            return Err(ProtocolError::InvalidPayload);
        }

        Ok(&self.payload)
    }

    pub fn script_output_payload(&self) -> Result<ScriptOutputPayload<'_>, ProtocolError> {
        if self.header.kind != FrameKind::ScriptOutput || self.payload.len() < 8 {
            return Err(ProtocolError::InvalidPayload);
        }

        Ok(ScriptOutputPayload {
            sequence: u64::from_le_bytes(
                self.payload[..8]
                    .try_into()
                    .map_err(|_| ProtocolError::InvalidPayload)?,
            ),
            output: std::str::from_utf8(&self.payload[8..])
                .map_err(|_| ProtocolError::InvalidPayload)?,
        })
    }

    fn validate_payload(&self) -> Result<(), ProtocolError> {
        match self.header.kind {
            FrameKind::Hello => {
                Hello::from_frame(self)?;
            }
            FrameKind::Welcome => {
                Welcome::from_frame(self)?;
            }
            FrameKind::Cancel if self.payload.is_empty() => {}
            FrameKind::Cancel => return Err(ProtocolError::InvalidPayload),
            FrameKind::Event => {
                self.event_payload()?;
            }
            FrameKind::Failure => {
                self.failure_payload()?;
            }
            FrameKind::Terminal => {
                self.terminal_payload()?;
            }
            FrameKind::ExecuteScript => {
                self.script_request_payload()?;
            }
            FrameKind::ExecuteCommand => {
                self.command_request_payload()?;
            }
            FrameKind::ScriptOutput => {
                self.script_output_payload()?;
            }
        }

        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct EventPayload<'a> {
    pub sequence: u64,
    pub event_kind: u16,
    pub body: &'a [u8],
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct FailurePayload<'a> {
    pub sequence: u64,
    pub failure_code: u16,
    pub message: &'a str,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TerminalPayload {
    pub sequence: u64,
    pub status: TerminalStatus,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ScriptOutputPayload<'a> {
    pub sequence: u64,
    pub output: &'a str,
}

#[derive(Default)]
pub struct FrameDecoder {
    buffered: Vec<u8>,
}

impl FrameDecoder {
    pub fn push(&mut self, bytes: &[u8]) -> Result<Vec<Frame>, ProtocolError> {
        if self.buffered.len().saturating_add(bytes.len()) > MAX_BUFFERED_BYTES {
            return Err(ProtocolError::BufferedDataTooLarge);
        }
        self.buffered.extend_from_slice(bytes);

        let mut frames = Vec::new();
        while self.buffered.len() >= FrameHeader::ENCODED_LENGTH {
            let header = FrameHeader::decode(&self.buffered[..FrameHeader::ENCODED_LENGTH])?;
            let frame_length = FrameHeader::ENCODED_LENGTH + header.payload_length as usize;
            if self.buffered.len() < frame_length {
                break;
            }

            let encoded = self.buffered.drain(..frame_length).collect::<Vec<_>>();
            frames.push(Frame::decode(&encoded)?);
        }

        Ok(frames)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Hello {
    pub minimum_version: u16,
    pub maximum_version: u16,
    pub offered_features: FeatureSet,
    pub capability_token: [u8; CAPABILITY_TOKEN_LENGTH],
}

impl Hello {
    const ENCODED_LENGTH: usize = 40;

    pub fn to_frame(&self) -> Result<Frame, ProtocolError> {
        if self.minimum_version > self.maximum_version {
            return Err(ProtocolError::InvalidVersionRange);
        }

        let mut payload = Vec::with_capacity(Self::ENCODED_LENGTH);
        payload.extend_from_slice(&self.minimum_version.to_le_bytes());
        payload.extend_from_slice(&self.maximum_version.to_le_bytes());
        payload.extend_from_slice(&self.offered_features.bits().to_le_bytes());
        payload.extend_from_slice(&self.capability_token);
        Frame::new(
            FrameKind::Hello,
            FeatureSet::EMPTY,
            RequestIdentifiers::new(0, 0, 0),
            payload,
        )
    }

    pub fn from_frame(frame: &Frame) -> Result<Self, ProtocolError> {
        if frame.header.kind != FrameKind::Hello || frame.payload.len() != Self::ENCODED_LENGTH {
            return Err(ProtocolError::InvalidHandshake);
        }

        let offered_features = FeatureSet::from_bits(u32::from_le_bytes([
            frame.payload[4],
            frame.payload[5],
            frame.payload[6],
            frame.payload[7],
        ]));
        let mut capability_token = [0_u8; CAPABILITY_TOKEN_LENGTH];
        capability_token.copy_from_slice(&frame.payload[8..]);
        let hello = Self {
            minimum_version: u16::from_le_bytes([frame.payload[0], frame.payload[1]]),
            maximum_version: u16::from_le_bytes([frame.payload[2], frame.payload[3]]),
            offered_features,
            capability_token,
        };
        if hello.minimum_version > hello.maximum_version {
            return Err(ProtocolError::InvalidVersionRange);
        }

        Ok(hello)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Welcome {
    pub selected_version: u16,
    pub selected_features: FeatureSet,
}

impl Welcome {
    const ENCODED_LENGTH: usize = 6;

    pub fn to_frame(self) -> Result<Frame, ProtocolError> {
        let mut payload = Vec::with_capacity(Self::ENCODED_LENGTH);
        payload.extend_from_slice(&self.selected_version.to_le_bytes());
        payload.extend_from_slice(&self.selected_features.bits().to_le_bytes());
        Frame::new(
            FrameKind::Welcome,
            self.selected_features,
            RequestIdentifiers::new(0, 0, 0),
            payload,
        )
    }

    pub fn from_frame(frame: &Frame) -> Result<Self, ProtocolError> {
        if frame.header.kind != FrameKind::Welcome || frame.payload.len() != Self::ENCODED_LENGTH {
            return Err(ProtocolError::InvalidHandshake);
        }

        let selected_features = FeatureSet::from_bits(u32::from_le_bytes([
            frame.payload[2],
            frame.payload[3],
            frame.payload[4],
            frame.payload[5],
        ]));
        if selected_features.has_unknown_bits() || frame.header.features != selected_features {
            return Err(ProtocolError::InvalidHandshake);
        }
        let selected_version = u16::from_le_bytes([frame.payload[0], frame.payload[1]]);
        if selected_version != PROTOCOL_VERSION {
            return Err(ProtocolError::UnsupportedProtocolVersion(selected_version));
        }

        Ok(Self {
            selected_version,
            selected_features,
        })
    }
}

pub fn negotiate(
    hello: &Hello,
    expected_capability_token: &[u8; CAPABILITY_TOKEN_LENGTH],
) -> Result<Welcome, ProtocolError> {
    if !tokens_match(&hello.capability_token, expected_capability_token) {
        return Err(ProtocolError::AuthenticationFailed);
    }
    if hello.minimum_version > PROTOCOL_VERSION || hello.maximum_version < PROTOCOL_VERSION {
        return Err(ProtocolError::IncompatibleProtocolVersion);
    }

    Ok(Welcome {
        selected_version: PROTOCOL_VERSION,
        selected_features: hello.offered_features.intersection(FeatureSet::SUPPORTED),
    })
}

pub fn cancellation_frame(
    features: FeatureSet,
    identifiers: RequestIdentifiers,
) -> Result<Frame, ProtocolError> {
    if !features.contains(FeatureSet::CANCELLATION) {
        return Err(ProtocolError::MissingRequiredFeature);
    }

    Frame::new(FrameKind::Cancel, features, identifiers, Vec::new())
}

pub fn execute_script_frame(
    features: FeatureSet,
    identifiers: RequestIdentifiers,
    script: &str,
) -> Result<Frame, ProtocolError> {
    request_frame(FrameKind::ExecuteScript, features, identifiers, script)
}

pub fn execute_command_frame(
    features: FeatureSet,
    identifiers: RequestIdentifiers,
    command: impl AsRef<[u8]>,
) -> Result<Frame, ProtocolError> {
    request_bytes_frame(
        FrameKind::ExecuteCommand,
        features,
        identifiers,
        command.as_ref(),
    )
}

fn request_frame(
    kind: FrameKind,
    features: FeatureSet,
    identifiers: RequestIdentifiers,
    text: &str,
) -> Result<Frame, ProtocolError> {
    if text.is_empty() {
        return Err(ProtocolError::InvalidPayload);
    }

    Frame::new(kind, features, identifiers, text.as_bytes().to_vec())
}

fn request_bytes_frame(
    kind: FrameKind,
    features: FeatureSet,
    identifiers: RequestIdentifiers,
    payload: &[u8],
) -> Result<Frame, ProtocolError> {
    if payload.is_empty() {
        return Err(ProtocolError::InvalidPayload);
    }

    Frame::new(kind, features, identifiers, payload.to_vec())
}

pub struct RequestStream {
    features: FeatureSet,
    identifiers: RequestIdentifiers,
    next_sequence: u64,
    terminal_sent: bool,
}

impl RequestStream {
    pub fn new(
        features: FeatureSet,
        identifiers: RequestIdentifiers,
    ) -> Result<Self, ProtocolError> {
        if !identifiers.is_valid() {
            return Err(ProtocolError::InvalidIdentifiers);
        }
        if !features.contains(FeatureSet::ORDERED_EVENTS)
            || !features.contains(FeatureSet::STRUCTURED_FAILURES)
        {
            return Err(ProtocolError::MissingRequiredFeature);
        }

        Ok(Self {
            features,
            identifiers,
            next_sequence: 0,
            terminal_sent: false,
        })
    }

    pub fn event(&mut self, event_kind: u16, body: &[u8]) -> Result<Frame, ProtocolError> {
        let sequence = self.next_sequence()?;
        let mut payload = Vec::with_capacity(10 + body.len());
        payload.extend_from_slice(&sequence.to_le_bytes());
        payload.extend_from_slice(&event_kind.to_le_bytes());
        payload.extend_from_slice(body);
        Frame::new(FrameKind::Event, self.features, self.identifiers, payload)
    }

    pub fn failure(&mut self, failure_code: u16, message: &str) -> Result<Frame, ProtocolError> {
        let message = message.as_bytes();
        if message.len() > MAX_FAILURE_MESSAGE_BYTES || message.len() > u16::MAX as usize {
            return Err(ProtocolError::FailureMessageTooLarge);
        }

        let sequence = self.next_sequence()?;
        let mut payload = Vec::with_capacity(12 + message.len());
        payload.extend_from_slice(&sequence.to_le_bytes());
        payload.extend_from_slice(&failure_code.to_le_bytes());
        payload.extend_from_slice(&(message.len() as u16).to_le_bytes());
        payload.extend_from_slice(message);
        Frame::new(FrameKind::Failure, self.features, self.identifiers, payload)
    }

    pub fn script_output(&mut self, output: &[u8]) -> Result<Frame, ProtocolError> {
        std::str::from_utf8(output).map_err(|_| ProtocolError::InvalidPayload)?;
        let sequence = self.next_sequence()?;
        let mut payload = Vec::with_capacity(8 + output.len());
        payload.extend_from_slice(&sequence.to_le_bytes());
        payload.extend_from_slice(output);
        Frame::new(
            FrameKind::ScriptOutput,
            self.features,
            self.identifiers,
            payload,
        )
    }

    pub fn terminal(&mut self, status: TerminalStatus) -> Result<Frame, ProtocolError> {
        if self.terminal_sent {
            return Err(ProtocolError::DuplicateTerminal);
        }

        let sequence = self.next_sequence()?;
        let mut payload = Vec::with_capacity(10);
        payload.extend_from_slice(&sequence.to_le_bytes());
        payload.extend_from_slice(&(status as u16).to_le_bytes());
        let frame = Frame::new(
            FrameKind::Terminal,
            self.features,
            self.identifiers,
            payload,
        )?;
        self.terminal_sent = true;
        Ok(frame)
    }

    fn next_sequence(&mut self) -> Result<u64, ProtocolError> {
        if self.terminal_sent {
            return Err(ProtocolError::RequestAlreadyTerminal);
        }

        let sequence = self.next_sequence;
        self.next_sequence = self
            .next_sequence
            .checked_add(1)
            .ok_or(ProtocolError::SequenceOverflow)?;
        Ok(sequence)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ProtocolError {
    AuthenticationFailed,
    BufferedDataTooLarge,
    DuplicateTerminal,
    FailureMessageTooLarge,
    FrameTooLarge,
    IncompatibleProtocolVersion,
    InvalidHandshake,
    InvalidIdentifiers,
    InvalidLength,
    InvalidMagic,
    InvalidPayload,
    InvalidVersionRange,
    MissingRequiredFeature,
    RequestAlreadyTerminal,
    SequenceOverflow,
    TrailingData,
    TruncatedFrame,
    UnknownFrameKind(u16),
    UnsupportedFeatureBits(u32),
    UnsupportedProtocolVersion(u16),
}

fn tokens_match(
    left: &[u8; CAPABILITY_TOKEN_LENGTH],
    right: &[u8; CAPABILITY_TOKEN_LENGTH],
) -> bool {
    let mut difference = 0_u8;
    for (left, right) in left.iter().zip(right.iter()) {
        difference |= left ^ right;
    }
    difference == 0
}

pub fn payload_files(payload_directory: &Path) -> (PathBuf, PathBuf, PathBuf) {
    let hostfxr_name = if cfg!(windows) {
        "hostfxr.dll"
    } else if cfg!(target_os = "macos") {
        "libhostfxr.dylib"
    } else {
        "libhostfxr.so"
    };

    (
        payload_directory.join("pwsh.dll"),
        payload_directory.join("pwsh.runtimeconfig.json"),
        payload_directory.join(hostfxr_name),
    )
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ValidatedPayload {
    pub root: PathBuf,
    pub pwsh_dll: PathBuf,
    pub runtime_config: PathBuf,
    pub hostfxr: PathBuf,
    pub worker_bridge: Option<PathBuf>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PayloadManifest {
    schema_version: u32,
    rid: String,
    architecture: String,
    files: Vec<ManifestFile>,
    #[serde(default)]
    worker_bridge_sha256: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ManifestFile {
    path: String,
    sha256: String,
}

pub fn validate_payload(payload_directory: &Path) -> Status {
    validate_payload_with_bridge(payload_directory, None)
        .map(|_| Status::Success)
        .unwrap_or_else(|status| status)
}

pub fn validate_payload_with_bridge(
    payload_directory: &Path,
    worker_bridge: Option<&Path>,
) -> Result<ValidatedPayload, Status> {
    let root = canonical_payload_root(payload_directory)?;
    let manifest_path = root.join(PAYLOAD_MANIFEST_FILE);
    let manifest_bytes = fs::read(&manifest_path).map_err(|error| {
        if error.kind() == std::io::ErrorKind::NotFound {
            Status::PayloadManifestMissing
        } else {
            Status::PayloadManifestInvalid
        }
    })?;
    let manifest: PayloadManifest =
        serde_json::from_slice(&manifest_bytes).map_err(|_| Status::PayloadManifestInvalid)?;
    validate_manifest_metadata(&manifest)?;

    let (pwsh_dll, runtime_config, hostfxr) = payload_files(&root);
    let required_files = [
        ("pwsh.dll", &pwsh_dll),
        ("pwsh.runtimeconfig.json", &runtime_config),
        (
            hostfxr
                .file_name()
                .and_then(|name| name.to_str())
                .unwrap_or_default(),
            &hostfxr,
        ),
    ];
    let mut manifest_paths = HashSet::new();
    for entry in &manifest.files {
        let relative_path = manifest_relative_path(&entry.path)?;
        if !manifest_paths.insert(relative_path.clone()) {
            return Err(Status::PayloadManifestInvalid);
        }
        let file = canonical_payload_file(&root, &relative_path)?;
        verify_sha256(&file, &entry.sha256)?;
    }
    if manifest_paths != collect_payload_files(&root)? {
        return Err(Status::PayloadManifestInvalid);
    }
    for (required_name, required_path) in required_files {
        if !manifest_paths.contains(Path::new(required_name)) {
            return Err(Status::PayloadManifestInvalid);
        }
        canonical_payload_file(&root, Path::new(required_name)).map(|file| {
            if file != *required_path {
                Err(Status::InvalidPayload)
            } else {
                Ok(())
            }
        })??;
    }
    verify_payload_architecture(&pwsh_dll, &hostfxr)?;

    let worker_bridge = match (worker_bridge, manifest.worker_bridge_sha256.as_deref()) {
        (Some(bridge), Some(expected_hash)) => {
            let bridge = canonical_external_file(bridge, Status::BridgeNotFound)?;
            verify_sha256(&bridge, expected_hash)?;
            Some(bridge)
        }
        (Some(_), None) => return Err(Status::PayloadManifestInvalid),
        (None, _) => None,
    };

    Ok(ValidatedPayload {
        root,
        pwsh_dll,
        runtime_config,
        hostfxr,
        worker_bridge,
    })
}

fn canonical_payload_root(payload_directory: &Path) -> Result<PathBuf, Status> {
    let metadata = fs::symlink_metadata(payload_directory).map_err(|error| {
        if error.kind() == std::io::ErrorKind::NotFound {
            Status::PayloadNotFound
        } else {
            Status::InvalidPayload
        }
    })?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        return Err(Status::InvalidPayload);
    }
    fs::canonicalize(payload_directory).map_err(|_| Status::InvalidPayload)
}

fn manifest_relative_path(value: &str) -> Result<PathBuf, Status> {
    let path = Path::new(value);
    if path.as_os_str().is_empty()
        || path.is_absolute()
        || path.components().any(|component| {
            matches!(
                component,
                Component::ParentDir | Component::RootDir | Component::Prefix(_)
            )
        })
    {
        return Err(Status::PayloadManifestInvalid);
    }
    Ok(path.to_path_buf())
}

fn canonical_payload_file(root: &Path, relative_path: &Path) -> Result<PathBuf, Status> {
    let path = root.join(relative_path);
    let metadata = fs::symlink_metadata(&path).map_err(|_| Status::InvalidPayload)?;
    if !metadata.is_file() || metadata.file_type().is_symlink() {
        return Err(Status::InvalidPayload);
    }
    let canonical = fs::canonicalize(&path).map_err(|_| Status::InvalidPayload)?;
    if !canonical.starts_with(root) {
        return Err(Status::InvalidPayload);
    }
    Ok(canonical)
}

fn collect_payload_files(root: &Path) -> Result<HashSet<PathBuf>, Status> {
    let mut files = HashSet::new();
    collect_payload_files_recursive(root, root, &mut files)?;
    Ok(files)
}

fn collect_payload_files_recursive(
    root: &Path,
    directory: &Path,
    files: &mut HashSet<PathBuf>,
) -> Result<(), Status> {
    for entry in fs::read_dir(directory).map_err(|_| Status::InvalidPayload)? {
        let entry = entry.map_err(|_| Status::InvalidPayload)?;
        let path = entry.path();
        let metadata = fs::symlink_metadata(&path).map_err(|_| Status::InvalidPayload)?;
        if metadata.file_type().is_symlink() {
            return Err(Status::InvalidPayload);
        }
        if metadata.is_dir() {
            collect_payload_files_recursive(root, &path, files)?;
            continue;
        }
        if !metadata.is_file() {
            return Err(Status::InvalidPayload);
        }
        let relative_path = path
            .strip_prefix(root)
            .map_err(|_| Status::InvalidPayload)?
            .to_path_buf();
        if relative_path != Path::new(PAYLOAD_MANIFEST_FILE) {
            files.insert(relative_path);
        }
    }
    Ok(())
}

fn canonical_external_file(path: &Path, missing_status: Status) -> Result<PathBuf, Status> {
    let metadata = fs::symlink_metadata(path).map_err(|error| {
        if error.kind() == std::io::ErrorKind::NotFound {
            missing_status
        } else {
            Status::InvalidPayload
        }
    })?;
    if !metadata.is_file() || metadata.file_type().is_symlink() {
        return Err(Status::InvalidPayload);
    }
    fs::canonicalize(path).map_err(|_| Status::InvalidPayload)
}

fn validate_manifest_metadata(manifest: &PayloadManifest) -> Result<(), Status> {
    let (rid, architecture) = match () {
        _ if cfg!(all(windows, target_arch = "x86_64")) => ("win-x64", "x64"),
        _ if cfg!(all(windows, target_arch = "aarch64")) => ("win-arm64", "arm64"),
        _ if cfg!(all(target_os = "linux", target_arch = "x86_64")) => ("linux-x64", "x64"),
        _ => return Err(Status::UnsupportedPlatform),
    };
    if manifest.schema_version != 1 || manifest.rid != rid || manifest.architecture != architecture
    {
        return Err(Status::ArchitectureMismatch);
    }
    Ok(())
}

fn verify_sha256(path: &Path, expected: &str) -> Result<(), Status> {
    if expected.len() != 64 || !expected.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(Status::PayloadManifestInvalid);
    }
    let content = fs::read(path).map_err(|_| Status::InvalidPayload)?;
    let actual = format!("{:x}", Sha256::digest(content));
    if !actual.eq_ignore_ascii_case(expected) {
        return Err(Status::IntegrityMismatch);
    }
    Ok(())
}

fn verify_payload_architecture(pwsh_dll: &Path, hostfxr: &Path) -> Result<(), Status> {
    if cfg!(windows) {
        let machine = if cfg!(target_arch = "x86_64") {
            0x8664
        } else if cfg!(target_arch = "aarch64") {
            0xAA64
        } else {
            return Err(Status::UnsupportedPlatform);
        };
        verify_windows_pe(pwsh_dll, machine)?;
        verify_windows_pe(hostfxr, machine)?;
    } else if cfg!(target_os = "linux") {
        verify_managed_x64_pe(pwsh_dll)?;
        verify_linux_x64_elf(hostfxr)?;
    }
    Ok(())
}

fn verify_windows_pe(path: &Path, machine: u16) -> Result<(), Status> {
    verify_pe_machine(path, machine)
}

fn verify_managed_x64_pe(path: &Path) -> Result<(), Status> {
    let content = fs::read(path).map_err(|_| Status::InvalidPayload)?;
    let pe_offset = pe_header_offset(&content)?;
    let optional_header = pe_offset
        .checked_add(24)
        .ok_or(Status::ArchitectureMismatch)?;
    let optional_magic = content
        .get(optional_header..optional_header + 2)
        .ok_or(Status::ArchitectureMismatch)?;
    let data_directory_offset = match optional_magic {
        [0x0B, 0x01] => optional_header
            .checked_add(96)
            .ok_or(Status::ArchitectureMismatch)?,
        [0x0B, 0x02] => optional_header
            .checked_add(112)
            .ok_or(Status::ArchitectureMismatch)?,
        _ => return Err(Status::ArchitectureMismatch),
    };
    let cli_directory = data_directory_offset
        .checked_add(14 * 8)
        .ok_or(Status::ArchitectureMismatch)?;
    let cli_rva = content
        .get(cli_directory..cli_directory + 4)
        .ok_or(Status::ArchitectureMismatch)?;
    let cli_size = content
        .get(cli_directory + 4..cli_directory + 8)
        .ok_or(Status::ArchitectureMismatch)?;
    if cli_rva == [0; 4] || cli_size == [0; 4] {
        return Err(Status::ArchitectureMismatch);
    }
    Ok(())
}

fn verify_pe_machine(path: &Path, machine: u16) -> Result<(), Status> {
    let content = fs::read(path).map_err(|_| Status::InvalidPayload)?;
    let offset = pe_header_offset(&content)?;
    let machine_offset = offset.checked_add(4).ok_or(Status::ArchitectureMismatch)?;
    if content.get(machine_offset..machine_offset + 2) != Some(&machine.to_le_bytes()) {
        return Err(Status::ArchitectureMismatch);
    }
    Ok(())
}

fn pe_header_offset(content: &[u8]) -> Result<usize, Status> {
    if content.len() < 0x40 || content[..2] != *b"MZ" {
        return Err(Status::ArchitectureMismatch);
    }
    let offset = u32::from_le_bytes(
        content[0x3C..0x40]
            .try_into()
            .map_err(|_| Status::ArchitectureMismatch)?,
    ) as usize;
    let machine_offset = offset.checked_add(4).ok_or(Status::ArchitectureMismatch)?;
    if content.get(offset..machine_offset) != Some(b"PE\0\0") {
        return Err(Status::ArchitectureMismatch);
    }
    Ok(offset)
}

fn verify_linux_x64_elf(path: &Path) -> Result<(), Status> {
    let content = fs::read(path).map_err(|_| Status::InvalidPayload)?;
    if content.len() < 20
        || content[..4] != *b"\x7FELF"
        || content[4] != 2
        || content[5] != 1
        || content.get(18..20) != Some(&0x3E_u16.to_le_bytes())
    {
        return Err(Status::ArchitectureMismatch);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{
        CAPABILITY_TOKEN_LENGTH, FeatureSet, Frame, FrameDecoder, FrameHeader, FrameKind, Hello,
        MAX_BUFFERED_BYTES, MAX_FRAME_PAYLOAD_BYTES, PAYLOAD_MANIFEST_FILE, PROTOCOL_VERSION,
        ProtocolError, RequestIdentifiers, RequestStream, Status, TerminalStatus, Welcome,
        cancellation_frame, execute_command_frame, execute_script_frame, negotiate, payload_files,
        validate_payload, validate_payload_with_bridge, verify_pe_machine,
    };
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::time::{SystemTime, UNIX_EPOCH};

    const TOKEN: [u8; CAPABILITY_TOKEN_LENGTH] = [0xA5; CAPABILITY_TOKEN_LENGTH];

    fn temporary_directory() -> std::path::PathBuf {
        let suffix = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock is before the Unix epoch")
            .as_nanos();
        std::env::current_dir()
            .expect("test working directory")
            .join(format!(".devolutions-pwsh-protocol-{suffix}"))
    }

    fn identifiers() -> RequestIdentifiers {
        RequestIdentifiers::new(1, 2, 3)
    }

    #[test]
    fn hello_frame_has_a_stable_golden_encoding() {
        let hello = Hello {
            minimum_version: 1,
            maximum_version: 1,
            offered_features: FeatureSet::CANCELLATION,
            capability_token: TOKEN,
        };

        let encoded = hello
            .to_frame()
            .expect("encode hello")
            .encode()
            .expect("frame bytes");
        let expected = [
            b'D', b'P', b'S', b'I', 1, 0, 1, 0, 0, 0, 0, 0, 40, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 1, 0, 0, 0, 0xA5, 0xA5, 0xA5,
            0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5,
            0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5,
            0xA5,
        ];

        assert_eq!(encoded, expected);
        assert_eq!(
            Hello::from_frame(&Frame::decode(&expected).expect("decode golden hello"))
                .expect("hello"),
            hello
        );
    }

    #[test]
    fn handshake_negotiates_features_and_requires_the_capability_token() {
        let hello = Hello {
            minimum_version: PROTOCOL_VERSION,
            maximum_version: PROTOCOL_VERSION,
            offered_features: FeatureSet::from_bits(FeatureSet::SUPPORTED.bits() | (1 << 31)),
            capability_token: TOKEN,
        };

        let welcome = negotiate(&hello, &TOKEN).expect("negotiate");
        assert_eq!(welcome.selected_version, PROTOCOL_VERSION);
        assert_eq!(welcome.selected_features, FeatureSet::SUPPORTED);
        assert_eq!(
            Welcome::from_frame(&welcome.to_frame().expect("encode welcome"))
                .expect("decode welcome"),
            welcome
        );

        let older_features = FeatureSet::from_bits(
            FeatureSet::SUPPORTED.bits() & !FeatureSet::STRUCTURED_DIAGNOSTICS.bits(),
        );
        let older_hello = Hello {
            offered_features: older_features,
            ..hello
        };
        assert_eq!(
            negotiate(&older_hello, &TOKEN)
                .expect("negotiate older peer")
                .selected_features,
            older_features
        );

        let mut invalid_token = TOKEN;
        invalid_token[0] ^= 1;
        assert_eq!(
            negotiate(&hello, &invalid_token),
            Err(ProtocolError::AuthenticationFailed)
        );
    }

    #[test]
    fn framed_decoder_handles_partial_and_multiple_frames() {
        let hello = Hello {
            minimum_version: PROTOCOL_VERSION,
            maximum_version: PROTOCOL_VERSION,
            offered_features: FeatureSet::EMPTY,
            capability_token: TOKEN,
        }
        .to_frame()
        .expect("hello frame")
        .encode()
        .expect("hello bytes");
        let welcome = Welcome {
            selected_version: PROTOCOL_VERSION,
            selected_features: FeatureSet::EMPTY,
        }
        .to_frame()
        .expect("welcome frame")
        .encode()
        .expect("welcome bytes");

        let mut decoder = FrameDecoder::default();
        assert!(
            decoder
                .push(&hello[..9])
                .expect("partial header")
                .is_empty()
        );
        let mut remainder = hello[9..].to_vec();
        remainder.extend_from_slice(&welcome);
        let frames = decoder.push(&remainder).expect("complete frames");

        assert_eq!(frames.len(), 2);
        assert_eq!(frames[0].header.kind, FrameKind::Hello);
        assert_eq!(frames[1].header.kind, FrameKind::Welcome);
    }

    #[test]
    fn malformed_frames_are_rejected_before_dispatch() {
        let hello = Hello {
            minimum_version: PROTOCOL_VERSION,
            maximum_version: PROTOCOL_VERSION,
            offered_features: FeatureSet::EMPTY,
            capability_token: TOKEN,
        }
        .to_frame()
        .expect("hello frame")
        .encode()
        .expect("hello bytes");

        let mut invalid_magic = hello.clone();
        invalid_magic[0] = b'X';
        assert_eq!(
            Frame::decode(&invalid_magic),
            Err(ProtocolError::InvalidMagic)
        );

        let mut oversized_payload = hello.clone();
        oversized_payload[12..16]
            .copy_from_slice(&((MAX_FRAME_PAYLOAD_BYTES as u32) + 1).to_le_bytes());
        assert_eq!(
            Frame::decode(&oversized_payload),
            Err(ProtocolError::FrameTooLarge)
        );

        let mut truncated = hello.clone();
        truncated.pop();
        assert_eq!(
            Frame::decode(&truncated),
            Err(ProtocolError::TruncatedFrame)
        );

        let mut decoder = FrameDecoder::default();
        assert_eq!(
            decoder.push(&vec![0; MAX_BUFFERED_BYTES + 1]),
            Err(ProtocolError::BufferedDataTooLarge)
        );
    }

    #[test]
    fn malformed_structured_payloads_are_rejected() {
        let features = FeatureSet::SUPPORTED;
        let mut stream = RequestStream::new(features, identifiers()).expect("request stream");
        let failure = stream.failure(42, "message").expect("failure");
        let mut malformed = failure.encode().expect("failure bytes");
        malformed[FrameHeader::ENCODED_LENGTH + 10..FrameHeader::ENCODED_LENGTH + 12]
            .copy_from_slice(&99_u16.to_le_bytes());

        assert_eq!(
            Frame::decode(&malformed),
            Err(ProtocolError::InvalidPayload)
        );
    }

    #[test]
    fn script_and_command_requests_are_distinct_and_script_output_is_ordered() {
        let features = FeatureSet::SUPPORTED;
        let script =
            execute_script_frame(features, identifiers(), "'script'").expect("script request");
        let command =
            execute_command_frame(features, identifiers(), "Get-Process").expect("command request");
        assert_eq!(script.header.kind, FrameKind::ExecuteScript);
        assert_eq!(script.script_request_payload(), Ok("'script'"));
        assert_eq!(command.header.kind, FrameKind::ExecuteCommand);
        assert_eq!(command.command_request_payload(), Ok(&b"Get-Process"[..]));

        let mut stream = RequestStream::new(features, identifiers()).expect("request stream");
        let output = stream.script_output(b"script").expect("script output");
        assert_eq!(output.header.kind, FrameKind::ScriptOutput);
        assert_eq!(
            output
                .script_output_payload()
                .expect("output payload")
                .sequence,
            0
        );
        assert_eq!(
            output
                .script_output_payload()
                .expect("output payload")
                .output,
            "script"
        );
        let terminal = stream
            .terminal(TerminalStatus::Succeeded)
            .expect("terminal");
        assert_eq!(
            terminal
                .terminal_payload()
                .expect("terminal payload")
                .sequence,
            1
        );
    }

    #[test]
    fn request_stream_orders_frames_and_allows_exactly_one_terminal() {
        let features = FeatureSet::SUPPORTED;
        let mut stream = RequestStream::new(features, identifiers()).expect("request stream");
        let event = stream.event(7, b"first").expect("event");
        let failure = stream.failure(42, "bounded error").expect("failure");
        let terminal = stream.terminal(TerminalStatus::Failed).expect("terminal");

        assert_eq!(event.header.kind, FrameKind::Event);
        assert_eq!(
            u64::from_le_bytes(event.payload[..8].try_into().expect("sequence")),
            0
        );
        assert_eq!(failure.header.kind, FrameKind::Failure);
        assert_eq!(
            u64::from_le_bytes(failure.payload[..8].try_into().expect("sequence")),
            1
        );
        assert_eq!(terminal.header.kind, FrameKind::Terminal);
        assert_eq!(
            u64::from_le_bytes(terminal.payload[..8].try_into().expect("sequence")),
            2
        );
        assert_eq!(
            stream.terminal(TerminalStatus::Failed),
            Err(ProtocolError::DuplicateTerminal)
        );
        assert_eq!(
            stream.event(8, b"after"),
            Err(ProtocolError::RequestAlreadyTerminal)
        );
    }

    #[test]
    fn structured_command_payload_is_binary_and_bounded() {
        let command = [
            1_u8, 1, 0, 1, 11, 0, 0, 0, b'W', b'r', b'i', b't', b'e', b'-', b'O', b'u', b't', b'p',
            b'u', b't',
        ];
        let frame = execute_command_frame(FeatureSet::SUPPORTED, identifiers(), command)
            .expect("binary command frame");

        assert_eq!(frame.header.kind, FrameKind::ExecuteCommand);
        assert_eq!(frame.command_request_payload(), Ok(&command[..]));
    }

    #[test]
    fn event_stream_rejects_frames_after_its_terminal() {
        let features = FeatureSet::SUPPORTED;
        let mut stream = RequestStream::new(features, identifiers()).expect("request stream");
        let terminal = stream
            .terminal(TerminalStatus::Succeeded)
            .expect("terminal");

        assert_eq!(
            stream.event(1, b"after terminal"),
            Err(ProtocolError::RequestAlreadyTerminal)
        );
        assert_eq!(
            terminal
                .terminal_payload()
                .expect("terminal payload")
                .status,
            TerminalStatus::Succeeded
        );
    }

    #[test]
    fn cancellation_requires_the_negotiated_feature() {
        assert_eq!(
            cancellation_frame(FeatureSet::EMPTY, identifiers()),
            Err(ProtocolError::MissingRequiredFeature)
        );
        assert_eq!(
            cancellation_frame(FeatureSet::CANCELLATION, identifiers())
                .expect("cancel frame")
                .header
                .kind,
            FrameKind::Cancel
        );
    }

    #[test]
    fn validates_a_complete_explicit_payload() {
        let directory = temporary_directory();
        fs::create_dir_all(&directory).expect("create test directory");
        let bridge = write_valid_payload_manifest(&directory);

        assert_eq!(validate_payload(&directory), Status::Success);
        assert!(validate_payload_with_bridge(&directory, Some(&bridge)).is_ok());

        fs::remove_dir_all(directory).expect("remove test directory");
        fs::remove_file(bridge).expect("remove test bridge");
    }

    #[test]
    fn rejects_a_payload_without_a_manifest() {
        let directory = temporary_directory();
        fs::create_dir_all(&directory).expect("create test directory");

        assert_eq!(validate_payload(&directory), Status::PayloadManifestMissing);

        fs::remove_dir_all(directory).expect("remove test directory");
    }

    #[test]
    fn rejects_tampered_or_architecture_mismatched_payloads() {
        let directory = temporary_directory();
        fs::create_dir_all(&directory).expect("create test directory");
        let bridge = write_valid_payload_manifest(&directory);
        fs::write(directory.join("unlisted.dll"), b"unlisted")
            .expect("write unlisted payload file");
        assert_eq!(validate_payload(&directory), Status::PayloadManifestInvalid);
        fs::remove_file(directory.join("unlisted.dll")).expect("remove unlisted payload file");

        write_valid_payload_manifest(&directory);
        let (_, runtime_config, _) = payload_files(&directory);
        fs::write(&runtime_config, b"{\"tampered\":true}").expect("tamper runtimeconfig");
        assert_eq!(validate_payload(&directory), Status::IntegrityMismatch);

        write_valid_payload_manifest(&directory);
        fs::write(&bridge, b"tampered bridge").expect("tamper bridge");
        assert_eq!(
            validate_payload_with_bridge(&directory, Some(&bridge)),
            Err(Status::IntegrityMismatch)
        );

        write_valid_payload_manifest(&directory);
        let manifest = directory.join(PAYLOAD_MANIFEST_FILE);
        let text = fs::read_to_string(&manifest).expect("read manifest");
        fs::write(
            manifest,
            text.replace("\"architecture\":\"x64\"", "\"architecture\":\"arm64\""),
        )
        .expect("write architecture mismatch");
        assert_eq!(validate_payload(&directory), Status::ArchitectureMismatch);

        fs::remove_dir_all(directory).expect("remove test directory");
        fs::remove_file(bridge).expect("remove test bridge");
    }

    #[test]
    fn pe_machine_validation_distinguishes_arm64_from_x64() {
        let path = temporary_directory().with_extension("dll");
        write_pe(&path, 0xAA64);
        assert!(verify_pe_machine(&path, 0xAA64).is_ok());
        assert_eq!(
            verify_pe_machine(&path, 0x8664),
            Err(Status::ArchitectureMismatch)
        );
        fs::remove_file(path).expect("remove test PE");
    }

    fn write_valid_payload_manifest(directory: &Path) -> PathBuf {
        let (pwsh_dll, runtime_config, hostfxr) = payload_files(directory);
        write_x64_pe(&pwsh_dll);
        fs::write(&runtime_config, b"{\"runtimeOptions\":{}}").expect("write runtimeconfig");
        if cfg!(target_os = "linux") {
            write_x64_elf(&hostfxr);
        } else {
            write_x64_pe(&hostfxr);
        }
        let bridge = directory.with_extension("worker-bridge.dll");
        fs::write(&bridge, b"test bridge").expect("write bridge");

        let hostfxr_name = hostfxr
            .file_name()
            .and_then(|value| value.to_str())
            .expect("hostfxr name");
        let manifest = format!(
            concat!(
                "{{\"schema_version\":1,\"rid\":\"{}\",\"architecture\":\"x64\",",
                "\"files\":[",
                "{{\"path\":\"pwsh.dll\",\"sha256\":\"{}\"}},",
                "{{\"path\":\"pwsh.runtimeconfig.json\",\"sha256\":\"{}\"}},",
                "{{\"path\":\"{}\",\"sha256\":\"{}\"}}],",
                "\"worker_bridge_sha256\":\"{}\"}}"
            ),
            if cfg!(target_os = "linux") {
                "linux-x64"
            } else {
                "win-x64"
            },
            sha256(&pwsh_dll),
            sha256(&runtime_config),
            hostfxr_name,
            sha256(&hostfxr),
            sha256(&bridge),
        );
        fs::write(directory.join(PAYLOAD_MANIFEST_FILE), manifest).expect("write manifest");
        bridge
    }

    fn write_x64_pe(path: &Path) {
        write_pe(path, 0x8664);
    }

    fn write_pe(path: &Path, machine: u16) {
        let mut content = vec![0_u8; 0x180];
        content[..2].copy_from_slice(b"MZ");
        content[0x3C..0x40].copy_from_slice(&0x40_u32.to_le_bytes());
        content[0x40..0x44].copy_from_slice(b"PE\0\0");
        content[0x44..0x46].copy_from_slice(&machine.to_le_bytes());
        content[0x54..0x56].copy_from_slice(&0xF0_u16.to_le_bytes());
        content[0x58..0x5A].copy_from_slice(&0x20B_u16.to_le_bytes());
        content[0x138..0x13C].copy_from_slice(&1_u32.to_le_bytes());
        content[0x13C..0x140].copy_from_slice(&72_u32.to_le_bytes());
        fs::write(path, content).expect("write x64 PE");
    }

    fn write_x64_elf(path: &Path) {
        let mut content = vec![0_u8; 64];
        content[..4].copy_from_slice(b"\x7FELF");
        content[4] = 2;
        content[5] = 1;
        content[18..20].copy_from_slice(&0x3E_u16.to_le_bytes());
        fs::write(path, content).expect("write x64 ELF");
    }

    fn sha256(path: &Path) -> String {
        use sha2::{Digest, Sha256};

        format!(
            "{:x}",
            Sha256::digest(fs::read(path).expect("read test payload file"))
        )
    }
}
