#[cfg(any(windows, target_os = "linux"))]
use devolutions_pwsh_protocol::{
    CAPABILITY_TOKEN_LENGTH, FeatureSet, Frame, FrameKind, Hello, MAX_FRAME_PAYLOAD_BYTES,
    MAX_INVOCATION_RESPONSE_BYTES, PROTOCOL_VERSION, RequestIdentifiers, RequestStream,
    TerminalStatus,
    transport::{NamedPipeClient, PipeError},
};
use devolutions_pwsh_protocol::{
    Status, payload_files, validate_payload, validate_payload_with_bridge,
};
use std::env;
use std::path::Path;

#[cfg(any(windows, target_os = "linux"))]
use std::time::{Duration, Instant};

#[cfg(any(windows, target_os = "linux"))]
const MAX_STARTUP_TIMEOUT_MS: u32 = 60_000;
#[cfg(any(windows, target_os = "linux"))]
const CANCELLATION_GRACE_TIMEOUT_MS: u32 = 1_000;

fn main() {
    let mut arguments = env::args_os();
    let _program = arguments.next();
    let command = arguments.next();
    match command.as_deref() {
        Some(command) if command == "--probe-payload" => {
            let payload = match arguments.next() {
                Some(payload) if arguments.next().is_none() => payload,
                _ => std::process::exit(Status::InvalidArgument as i32),
            };
            std::process::exit(probe_payload(Path::new(&payload)) as i32);
        }
        Some(command) if command == "--probe-bridge" => {
            let payload = match arguments.next() {
                Some(payload) => payload,
                None => std::process::exit(Status::InvalidArgument as i32),
            };
            let bridge = match arguments.next() {
                Some(bridge) if arguments.next().is_none() => bridge,
                _ => std::process::exit(Status::InvalidArgument as i32),
            };
            std::process::exit(probe_bridge(Path::new(&payload), Path::new(&bridge)) as i32);
        }
        Some(command) if command == "--ipc-session" => {
            let endpoint = match arguments.next() {
                Some(endpoint) => endpoint,
                _ => std::process::exit(Status::InvalidArgument as i32),
            };
            let payload = match arguments.next() {
                Some(payload) => payload,
                None => std::process::exit(Status::InvalidArgument as i32),
            };
            let bridge = match arguments.next() {
                Some(bridge) if arguments.next().is_none() => bridge,
                _ => std::process::exit(Status::InvalidArgument as i32),
            };
            std::process::exit(
                ipc_session(&endpoint, Path::new(&payload), Path::new(&bridge)) as i32,
            );
        }
        _ => std::process::exit(Status::InvalidArgument as i32),
    }
}

#[cfg(any(windows, target_os = "linux"))]
fn ipc_session(endpoint: &std::ffi::OsStr, payload_directory: &Path, bridge_path: &Path) -> Status {
    let (pipe, negotiated_features, payload) = match authenticate_pipe(endpoint, || {
        validate_payload_with_bridge(payload_directory, Some(bridge_path))
    }) {
        Ok(connection) => connection,
        Err(status) => return status,
    };
    let bridge_path = match payload.worker_bridge.as_deref() {
        Some(bridge_path) => bridge_path,
        None => return Status::BridgeNotFound,
    };
    initialize_payload_hostfxr(
        &payload.hostfxr,
        &payload.pwsh_dll,
        |get_function_pointer| unsafe {
            let bridge = match load_bridge_exports(get_function_pointer, bridge_path) {
                Ok(bridge) => bridge,
                Err(status) => return status,
            };
            serve_session(&pipe, negotiated_features, bridge)
        },
    )
}

#[cfg(any(windows, target_os = "linux"))]
fn authenticate_pipe<T>(
    endpoint: &std::ffi::OsStr,
    validate_payload: impl FnOnce() -> Result<T, Status>,
) -> Result<
    (
        devolutions_pwsh_protocol::transport::PipeConnection,
        FeatureSet,
        T,
    ),
    Status,
> {
    let capability_token = capability_token_from_environment()?;
    let endpoint = match endpoint.to_str() {
        Some(endpoint) if !endpoint.is_empty() => endpoint,
        _ => return Err(Status::InvalidArgument),
    };
    let pipe = match NamedPipeClient::connect(endpoint, MAX_STARTUP_TIMEOUT_MS) {
        Ok(pipe) => pipe,
        Err(PipeError::TimedOut) => return Err(Status::StartupTimeout),
        Err(_) => return Err(Status::ConnectionSetupFailed),
    };
    let worker_hello = Hello {
        minimum_version: PROTOCOL_VERSION,
        maximum_version: PROTOCOL_VERSION,
        offered_features: FeatureSet::SUPPORTED,
        capability_token,
    };
    if pipe
        .write_frame(
            &match worker_hello.to_frame() {
                Ok(frame) => frame,
                Err(_) => return Err(Status::HandshakeRejected),
            },
            MAX_STARTUP_TIMEOUT_MS,
        )
        .is_err()
    {
        return Err(Status::HandshakeRejected);
    }
    let payload = validate_payload()?;
    let broker_hello = match pipe.read_frame(MAX_STARTUP_TIMEOUT_MS) {
        Ok(frame) => match Hello::from_frame(&frame) {
            Ok(hello) => hello,
            Err(_) => return Err(Status::HandshakeRejected),
        },
        Err(PipeError::TimedOut) => return Err(Status::StartupTimeout),
        Err(_) => return Err(Status::HandshakeRejected),
    };
    let welcome = match devolutions_pwsh_protocol::negotiate(&broker_hello, &capability_token) {
        Ok(welcome) => welcome,
        Err(_) => return Err(Status::HandshakeRejected),
    };
    let negotiated_features = welcome.selected_features;
    let welcome = match welcome.to_frame() {
        Ok(frame) => frame,
        Err(_) => return Err(Status::HandshakeRejected),
    };
    if pipe.write_frame(&welcome, MAX_STARTUP_TIMEOUT_MS).is_err() {
        return Err(Status::HandshakeRejected);
    }

    Ok((pipe, negotiated_features, payload))
}

#[cfg(not(any(windows, target_os = "linux")))]
fn ipc_session(_: &std::ffi::OsStr, _: &Path, _: &Path) -> Status {
    Status::UnsupportedPlatform
}

#[cfg(any(windows, target_os = "linux"))]
fn serve_session(
    pipe: &devolutions_pwsh_protocol::transport::PipeConnection,
    negotiated_features: FeatureSet,
    bridge: BridgeExports,
) -> Status {
    loop {
        let request = match pipe.read_frame(u32::MAX) {
            Ok(request) => request,
            Err(PipeError::PeerClosed) => return Status::Success,
            Err(PipeError::TimedOut) => return Status::RequestTimeout,
            Err(_) => return Status::WorkerFailed,
        };
        if request.header.features != negotiated_features {
            if respond_failed_request(
                pipe,
                negotiated_features,
                request,
                "Request feature negotiation mismatch.",
            )
            .is_err()
            {
                return Status::WorkerFailed;
            }
            continue;
        }

        match request.header.kind {
            FrameKind::ExecuteScript | FrameKind::ExecuteCommand => {
                if serve_invocation(pipe, negotiated_features, request, &bridge) != Status::Success
                {
                    return Status::WorkerFailed;
                }
            }
            FrameKind::Cancel => {
                // A cancellation can race the prior terminal response. It is
                // generation-tagged by request identifiers and has no effect
                // once no invocation owns those identifiers.
                continue;
            }
            _ => {
                if respond_failed_request(
                    pipe,
                    negotiated_features,
                    request,
                    "Unexpected request frame.",
                )
                .is_err()
                {
                    return Status::WorkerFailed;
                }
            }
        }
    }
}

#[cfg(any(windows, target_os = "linux"))]
fn respond_failed_request(
    pipe: &devolutions_pwsh_protocol::transport::PipeConnection,
    negotiated_features: FeatureSet,
    request: Frame,
    message: &str,
) -> Result<(), Status> {
    let mut stream = match RequestStream::new(negotiated_features, request.header.identifiers) {
        Ok(stream) => stream,
        Err(_) => return Err(Status::WorkerFailed),
    };
    let failure = match stream.failure(1, message) {
        Ok(frame) => frame,
        Err(_) => return Err(Status::WorkerFailed),
    };
    let terminal = match stream.terminal(TerminalStatus::Failed) {
        Ok(frame) => frame,
        Err(_) => return Err(Status::WorkerFailed),
    };
    if pipe.write_frame(&failure, 5_000).is_err() || pipe.write_frame(&terminal, 5_000).is_err() {
        return Err(Status::WorkerFailed);
    }
    Ok(())
}

#[cfg(any(windows, target_os = "linux"))]
fn serve_invocation(
    pipe: &devolutions_pwsh_protocol::transport::PipeConnection,
    negotiated_features: FeatureSet,
    request: Frame,
    bridge: &BridgeExports,
) -> Status {
    let payload = match bridge_request_payload(&request) {
        Ok(payload) => payload,
        Err(_) => {
            return respond_failed_request(
                pipe,
                negotiated_features,
                request,
                "Invalid structured command request payload.",
            )
            .map_or(Status::WorkerFailed, |_| Status::Success);
        }
    };
    let mut output = vec![0_u8; MAX_INVOCATION_RESPONSE_BYTES];
    let mut output_length = 0_i32;
    let mut protocol_error = false;
    let mut peer_closed = false;
    let mut cancellation_requested = false;
    let bridge_result = std::thread::scope(|scope| {
        let handle = scope.spawn(|| unsafe {
            (bridge.execute_invocation)(
                payload.command.as_ptr(),
                payload.command.len() as i32,
                payload.execution_timeout_ms,
                output.as_mut_ptr(),
                output.len() as i32,
                &mut output_length,
            )
        });

        while !handle.is_finished() {
            if peer_closed || protocol_error {
                std::thread::sleep(std::time::Duration::from_millis(1));
                continue;
            }
            match pipe.read_frame(25) {
                Ok(cancel)
                    if cancel.header.kind == FrameKind::Cancel
                        && cancel.header.features == negotiated_features
                        && cancel.header.identifiers == request.header.identifiers =>
                {
                    if !cancellation_requested {
                        cancellation_requested = true;
                        unsafe {
                            (bridge.stop_current_invocation)();
                        }
                    }
                }
                Ok(cancel) if cancel.header.kind == FrameKind::Cancel => {
                    // A stale cancellation from a completed request must not
                    // interrupt the invocation currently owning the pipe.
                }
                Ok(_) => {
                    protocol_error = true;
                    unsafe {
                        (bridge.stop_current_invocation)();
                    }
                }
                Err(PipeError::TimedOut) => {}
                Err(PipeError::PeerClosed) => {
                    peer_closed = true;
                    unsafe {
                        (bridge.stop_current_invocation)();
                    }
                }
                Err(_) => {
                    protocol_error = true;
                    unsafe {
                        (bridge.stop_current_invocation)();
                    }
                }
            }
        }

        handle.join().unwrap_or(BRIDGE_INVOCATION_FAILED)
    });
    if peer_closed || protocol_error || output_length < 0 || output_length as usize > output.len() {
        return Status::WorkerFailed;
    }

    let response_deadline = InvocationDeadline::new(CANCELLATION_GRACE_TIMEOUT_MS);
    emit_bridge_response(
        pipe,
        negotiated_features,
        request.header.identifiers,
        bridge_result,
        &output[..output_length as usize],
        &response_deadline,
    )
}

#[cfg(any(windows, target_os = "linux"))]
struct BridgeInvocation {
    command: Vec<u8>,
    execution_timeout_ms: u32,
}

#[cfg(any(windows, target_os = "linux"))]
fn bridge_request_payload(request: &Frame) -> Result<BridgeInvocation, ()> {
    match request.header.kind {
        FrameKind::ExecuteCommand => {
            let payload = request.command_request_payload().map_err(|_| ())?;
            if payload.len() < 5 {
                return Err(());
            }
            let execution_timeout_ms = u32::from_le_bytes(payload[..4].try_into().map_err(|_| ())?);
            if execution_timeout_ms == 0 {
                return Err(());
            }
            Ok(BridgeInvocation {
                command: payload[4..].to_vec(),
                execution_timeout_ms,
            })
        }
        FrameKind::ExecuteScript => {
            let script = request.script_request_payload().map_err(|_| ())?;
            let script = script.as_bytes();
            let mut payload = Vec::with_capacity(8 + script.len());
            payload.push(1);
            payload.extend_from_slice(&1_u16.to_le_bytes());
            payload.push(2);
            payload.extend_from_slice(&(script.len() as u32).to_le_bytes());
            payload.extend_from_slice(script);
            Ok(BridgeInvocation {
                command: payload,
                execution_timeout_ms: 5_000,
            })
        }
        _ => Err(()),
    }
}

#[cfg(any(windows, target_os = "linux"))]
fn emit_bridge_response(
    pipe: &devolutions_pwsh_protocol::transport::PipeConnection,
    negotiated_features: FeatureSet,
    identifiers: RequestIdentifiers,
    bridge_result: i32,
    response: &[u8],
    deadline: &InvocationDeadline,
) -> Status {
    let frames =
        match prepare_bridge_response(negotiated_features, identifiers, bridge_result, response) {
            Ok(frames) => frames,
            Err(status) => return status,
        };
    for frame in frames {
        let timeout = match deadline.remaining() {
            Ok(timeout) => timeout,
            Err(status) => return status,
        };
        if pipe.write_frame(&frame, timeout).is_err() {
            return Status::WorkerFailed;
        }
    }

    Status::Success
}

#[cfg(any(windows, target_os = "linux"))]
fn prepare_bridge_response(
    negotiated_features: FeatureSet,
    identifiers: RequestIdentifiers,
    bridge_result: i32,
    response: &[u8],
) -> Result<Vec<Frame>, Status> {
    let bridge_failed = matches!(
        bridge_result,
        BRIDGE_INVALID_ARGUMENT
            | BRIDGE_OUTPUT_TOO_LARGE
            | BRIDGE_INVOCATION_FAILED
            | BRIDGE_UNSUPPORTED_TYPE
    );
    let events = match decode_bridge_events(response) {
        Ok(events) => events,
        Err(_) if bridge_failed && response.is_empty() => Vec::new(),
        Err(_) => return Err(Status::WorkerFailed),
    };
    let mut stream =
        RequestStream::new(negotiated_features, identifiers).map_err(|_| Status::WorkerFailed)?;

    let mut frames = Vec::with_capacity(events.len() + 2);
    let mut total_encoded_bytes = 4_usize;
    for (kind, body) in events {
        let body = encode_diagnostic_event(negotiated_features, kind, body)?;
        let event = stream
            .event(kind, &body)
            .map_err(|_| Status::WorkerFailed)?;
        total_encoded_bytes =
            match total_encoded_bytes.checked_add(event.header.payload_length as usize + 44) {
                Some(total) => total,
                None => return Err(Status::WorkerFailed),
            };
        if total_encoded_bytes > MAX_INVOCATION_RESPONSE_BYTES {
            return response_limit_failure_frames(negotiated_features, identifiers);
        }
        frames.push(event);
    }

    let terminal_status = match bridge_result {
        BRIDGE_SUCCESS => TerminalStatus::Succeeded,
        BRIDGE_CANCELLED => TerminalStatus::Cancelled,
        BRIDGE_INVALID_ARGUMENT
        | BRIDGE_OUTPUT_TOO_LARGE
        | BRIDGE_INVOCATION_FAILED
        | BRIDGE_UNSUPPORTED_TYPE => {
            let message = match bridge_result {
                BRIDGE_INVALID_ARGUMENT => "WorkerBridge rejected the structured command DTO.",
                BRIDGE_OUTPUT_TOO_LARGE => {
                    "Invocation stream output exceeded the configured limit."
                }
                BRIDGE_UNSUPPORTED_TYPE => "PowerShell produced a type outside the DTO contract.",
                _ => "PowerShell invocation failed.",
            };
            let failure = stream
                .failure(bridge_result as u16, message)
                .map_err(|_| Status::WorkerFailed)?;
            frames.push(failure);
            TerminalStatus::Failed
        }
        _ => return Err(Status::WorkerFailed),
    };
    let terminal = stream
        .terminal(terminal_status)
        .map_err(|_| Status::WorkerFailed)?;
    frames.push(terminal);
    let response_size = frames.iter().try_fold(4_usize, |total, frame| {
        total.checked_add(frame.header.payload_length as usize + 44)
    });
    if response_size.is_none_or(|size| size > MAX_INVOCATION_RESPONSE_BYTES) {
        return response_limit_failure_frames(negotiated_features, identifiers);
    }

    Ok(frames)
}

#[cfg(any(windows, target_os = "linux"))]
fn encode_diagnostic_event(
    features: FeatureSet,
    kind: u16,
    body: &[u8],
) -> Result<Vec<u8>, Status> {
    if !features.contains(FeatureSet::STRUCTURED_DIAGNOSTICS) || !(kind == 2 || kind == 7) {
        return Ok(body.to_vec());
    }

    let source: serde_json::Value =
        serde_json::from_slice(body).map_err(|_| Status::WorkerFailed)?;
    let source = source.as_object().ok_or(Status::WorkerFailed)?;
    let mut encoded = Vec::with_capacity(body.len());
    encoded.push(1);
    match kind {
        2 => {
            write_json_string(&mut encoded, source, "message", 1_024)?;
            write_json_string(&mut encoded, source, "fullyQualifiedErrorId", 512)?;
            write_json_string(&mut encoded, source, "category", 256)?;
            write_json_string(&mut encoded, source, "categoryReason", 512)?;
            write_json_string(&mut encoded, source, "targetObject", 512)?;
            write_json_string(&mut encoded, source, "scriptStackTrace", 1_024)?;
            write_json_string(&mut encoded, source, "exceptionType", 512)?;
            write_json_optional_string(&mut encoded, source, "invocationName", 512)?;
            write_json_optional_string(&mut encoded, source, "scriptName", 1_024)?;
            write_json_optional_i32(&mut encoded, source, "scriptLineNumber");
            write_json_optional_i32(&mut encoded, source, "offsetInLine");
            write_json_optional_i32(&mut encoded, source, "pipelineLength");
            write_json_optional_i32(&mut encoded, source, "pipelinePosition");
        }
        7 => {
            write_json_i32(&mut encoded, source, "activityId")?;
            write_json_i32(&mut encoded, source, "parentActivityId")?;
            write_json_i32(&mut encoded, source, "percentComplete")?;
            write_json_i32(&mut encoded, source, "secondsRemaining")?;
            let record_type = match source.get("recordType").and_then(serde_json::Value::as_str) {
                Some("Processing") => 0,
                Some("Completed") => 1,
                _ => return Err(Status::WorkerFailed),
            };
            encoded.push(record_type);
            write_json_string(&mut encoded, source, "activity", 1_024)?;
            write_json_string(&mut encoded, source, "statusDescription", 1_024)?;
            write_json_string(&mut encoded, source, "currentOperation", 1_024)?;
        }
        _ => return Err(Status::WorkerFailed),
    }
    Ok(encoded)
}

#[cfg(any(windows, target_os = "linux"))]
fn write_json_string(
    destination: &mut Vec<u8>,
    source: &serde_json::Map<String, serde_json::Value>,
    name: &str,
    maximum_bytes: usize,
) -> Result<(), Status> {
    let value = source
        .get(name)
        .and_then(serde_json::Value::as_str)
        .ok_or(Status::WorkerFailed)?;
    write_utf8_prefix(destination, value, maximum_bytes)
}

#[cfg(any(windows, target_os = "linux"))]
fn write_json_optional_string(
    destination: &mut Vec<u8>,
    source: &serde_json::Map<String, serde_json::Value>,
    name: &str,
    maximum_bytes: usize,
) -> Result<(), Status> {
    match source.get(name) {
        Some(value) => write_utf8_prefix(
            destination,
            value.as_str().ok_or(Status::WorkerFailed)?,
            maximum_bytes,
        ),
        None => write_utf8_prefix(destination, "", maximum_bytes),
    }
}

#[cfg(any(windows, target_os = "linux"))]
fn write_json_i32(
    destination: &mut Vec<u8>,
    source: &serde_json::Map<String, serde_json::Value>,
    name: &str,
) -> Result<(), Status> {
    let value = source
        .get(name)
        .and_then(serde_json::Value::as_i64)
        .and_then(|value| i32::try_from(value).ok())
        .ok_or(Status::WorkerFailed)?;
    destination.extend_from_slice(&value.to_le_bytes());
    Ok(())
}

#[cfg(any(windows, target_os = "linux"))]
fn write_json_optional_i32(
    destination: &mut Vec<u8>,
    source: &serde_json::Map<String, serde_json::Value>,
    name: &str,
) {
    let value = source
        .get(name)
        .and_then(serde_json::Value::as_i64)
        .and_then(|value| i32::try_from(value).ok())
        .unwrap_or_default();
    destination.extend_from_slice(&value.to_le_bytes());
}

#[cfg(any(windows, target_os = "linux"))]
fn write_utf8_prefix(
    destination: &mut Vec<u8>,
    value: &str,
    maximum_bytes: usize,
) -> Result<(), Status> {
    let mut length = value.len().min(maximum_bytes);
    while !value.is_char_boundary(length) {
        length -= 1;
    }
    let value = &value[..length];
    let length = u16::try_from(value.len()).map_err(|_| Status::WorkerFailed)?;
    destination.extend_from_slice(&length.to_le_bytes());
    destination.extend_from_slice(value.as_bytes());
    Ok(())
}

#[cfg(any(windows, target_os = "linux"))]
fn response_limit_failure_frames(
    negotiated_features: FeatureSet,
    identifiers: RequestIdentifiers,
) -> Result<Vec<Frame>, Status> {
    let mut stream =
        RequestStream::new(negotiated_features, identifiers).map_err(|_| Status::WorkerFailed)?;
    let failure = stream
        .failure(
            BRIDGE_OUTPUT_TOO_LARGE as u16,
            "Invocation response exceeded the configured transport limit.",
        )
        .map_err(|_| Status::WorkerFailed)?;
    let terminal = stream
        .terminal(TerminalStatus::Failed)
        .map_err(|_| Status::WorkerFailed)?;
    Ok(vec![failure, terminal])
}

#[cfg(any(windows, target_os = "linux"))]
fn decode_bridge_events(response: &[u8]) -> Result<Vec<(u16, &[u8])>, ()> {
    if response.len() < 3 || response[0] != 1 {
        return Err(());
    }
    let count = u16::from_le_bytes([response[1], response[2]]) as usize;
    let mut offset = 3;
    let mut events = Vec::with_capacity(count);
    for _ in 0..count {
        if response.len().saturating_sub(offset) < 6 {
            return Err(());
        }
        let kind = u16::from_le_bytes([response[offset], response[offset + 1]]);
        let length = u32::from_le_bytes([
            response[offset + 2],
            response[offset + 3],
            response[offset + 4],
            response[offset + 5],
        ]) as usize;
        offset += 6;
        if !(1..=7).contains(&kind)
            || length > MAX_FRAME_PAYLOAD_BYTES - 10
            || length > response.len().saturating_sub(offset)
        {
            return Err(());
        }
        events.push((kind, &response[offset..offset + length]));
        offset += length;
    }

    if offset != response.len() {
        return Err(());
    }
    Ok(events)
}

#[cfg(any(windows, target_os = "linux"))]
struct InvocationDeadline {
    deadline: Instant,
}

#[cfg(any(windows, target_os = "linux"))]
impl InvocationDeadline {
    fn new(timeout_ms: u32) -> Self {
        Self {
            deadline: Instant::now() + Duration::from_millis(timeout_ms as u64),
        }
    }

    fn remaining(&self) -> Result<u32, Status> {
        let remaining = self
            .deadline
            .checked_duration_since(Instant::now())
            .ok_or(Status::RequestTimeout)?;
        u32::try_from(remaining.as_millis().max(1)).map_err(|_| Status::RequestTimeout)
    }
}

#[cfg(any(windows, target_os = "linux"))]
fn capability_token_from_environment() -> Result<[u8; CAPABILITY_TOKEN_LENGTH], Status> {
    let encoded =
        env::var_os("DEVOLUTIONS_PWSH_CAPABILITY_TOKEN").ok_or(Status::HandshakeRejected)?;
    unsafe {
        env::remove_var("DEVOLUTIONS_PWSH_CAPABILITY_TOKEN");
    }
    let encoded = encoded.to_str().ok_or(Status::HandshakeRejected)?;
    decode_hex_token(encoded)
}

#[cfg(any(windows, target_os = "linux"))]
fn decode_hex_token(encoded: &str) -> Result<[u8; CAPABILITY_TOKEN_LENGTH], Status> {
    if encoded.len() != CAPABILITY_TOKEN_LENGTH * 2 {
        return Err(Status::HandshakeRejected);
    }
    let mut token = [0_u8; CAPABILITY_TOKEN_LENGTH];
    for (index, pair) in encoded.as_bytes().chunks_exact(2).enumerate() {
        let high = hex_nibble(pair[0]).ok_or(Status::HandshakeRejected)?;
        let low = hex_nibble(pair[1]).ok_or(Status::HandshakeRejected)?;
        token[index] = (high << 4) | low;
    }
    Ok(token)
}

#[cfg(any(windows, target_os = "linux"))]
fn hex_nibble(value: u8) -> Option<u8> {
    match value {
        b'0'..=b'9' => Some(value - b'0'),
        b'a'..=b'f' => Some(value - b'a' + 10),
        b'A'..=b'F' => Some(value - b'A' + 10),
        _ => None,
    }
}

fn probe_payload(payload_directory: &Path) -> Status {
    let validation = validate_payload(payload_directory);
    if validation != Status::Success {
        return validation;
    }

    let (_, _, hostfxr_path) = payload_files(payload_directory);
    probe_payload_local_hostfxr(&hostfxr_path, &payload_directory.join("pwsh.dll"))
}

fn probe_bridge(payload_directory: &Path, bridge_path: &Path) -> Status {
    let payload = match validate_payload_with_bridge(payload_directory, Some(bridge_path)) {
        Ok(payload) => payload,
        Err(status) => return status,
    };
    probe_payload_local_hostfxr_bridge(
        &payload.hostfxr,
        &payload.pwsh_dll,
        payload.worker_bridge.as_deref().unwrap_or(bridge_path),
    )
}

#[cfg(any(windows, target_os = "linux"))]
fn probe_payload_local_hostfxr(hostfxr_path: &Path, pwsh_dll_path: &Path) -> Status {
    initialize_payload_hostfxr(hostfxr_path, pwsh_dll_path, |_| Status::Success)
}

#[cfg(any(windows, target_os = "linux"))]
fn probe_payload_local_hostfxr_bridge(
    hostfxr_path: &Path,
    pwsh_dll_path: &Path,
    bridge_path: &Path,
) -> Status {
    initialize_payload_hostfxr(hostfxr_path, pwsh_dll_path, |get_function_pointer| unsafe {
        match load_bridge_exports(get_function_pointer, bridge_path) {
            Ok(_) => {
                println!("WorkerBridge ABI: 2");
                Status::Success
            }
            Err(status) => status,
        }
    })
}

#[cfg(any(windows, target_os = "linux"))]
unsafe fn load_bridge_exports(
    get_function_pointer: GetFunctionPointer,
    bridge_path: &Path,
) -> Result<BridgeExports, Status> {
    let bridge_bytes = match std::fs::read(bridge_path) {
        Ok(bytes) if !bytes.is_empty() && bytes.len() <= i32::MAX as usize => bytes,
        _ => return Err(Status::BridgeLoadFailed),
    };
    let load_assembly = unsafe {
        get_unmanaged_function(
            get_function_pointer,
            "System.Management.Automation.PowerShellUnsafeAssemblyLoad, System.Management.Automation",
            "LoadAssemblyFromNativeMemory",
        )
    };
    let load_assembly = unsafe {
        std::mem::transmute::<*mut std::ffi::c_void, LoadAssemblyFromNativeMemory>(load_assembly?)
    };
    if unsafe { load_assembly(bridge_bytes.as_ptr(), bridge_bytes.len() as i32) } != 0 {
        return Err(Status::BridgeLoadFailed);
    }

    let get_abi_version = unsafe {
        get_unmanaged_function(
            get_function_pointer,
            "Devolutions.PowerShell.WorkerBridge.BridgeExports, Devolutions.PowerShell.WorkerBridge",
            "GetAbiVersion",
        )
    };
    let get_abi_version = unsafe {
        std::mem::transmute::<*mut std::ffi::c_void, GetBridgeAbiVersion>(get_abi_version?)
    };
    if unsafe { get_abi_version() } != 2 {
        return Err(Status::BridgeAbiMismatch);
    }

    let execute_invocation = unsafe {
        get_unmanaged_function(
            get_function_pointer,
            "Devolutions.PowerShell.WorkerBridge.BridgeExports, Devolutions.PowerShell.WorkerBridge",
            "ExecuteInvocationUtf8",
        )
    }?;
    let stop_current_invocation = unsafe {
        get_unmanaged_function(
            get_function_pointer,
            "Devolutions.PowerShell.WorkerBridge.BridgeExports, Devolutions.PowerShell.WorkerBridge",
            "StopCurrentInvocation",
        )
    }?;
    Ok(BridgeExports {
        execute_invocation: unsafe {
            std::mem::transmute::<*mut std::ffi::c_void, ExecuteInvocationUtf8>(execute_invocation)
        },
        stop_current_invocation: unsafe {
            std::mem::transmute::<*mut std::ffi::c_void, StopCurrentInvocation>(
                stop_current_invocation,
            )
        },
    })
}

#[cfg(windows)]
fn initialize_payload_hostfxr(
    hostfxr_path: &Path,
    pwsh_dll_path: &Path,
    action: impl FnOnce(GetFunctionPointer) -> Status,
) -> Status {
    use std::ffi::c_void;
    use std::ptr;

    type HostfxrInitializeForDotnetCommandLine =
        unsafe extern "system" fn(i32, *const *const u16, *const c_void, *mut *mut c_void) -> i32;
    type HostfxrClose = unsafe extern "system" fn(*mut c_void) -> i32;
    type HostfxrGetRuntimeDelegate =
        unsafe extern "system" fn(*mut c_void, i32, *mut *mut c_void) -> i32;

    let library = unsafe { LoadLibraryW(to_wide(hostfxr_path).as_ptr()) };
    if library == 0 {
        return Status::HostfxrNotFound;
    }

    let initialize = unsafe {
        GetProcAddress(
            library,
            c"hostfxr_initialize_for_dotnet_command_line".as_ptr(),
        )
    };
    let close = unsafe { GetProcAddress(library, c"hostfxr_close".as_ptr()) };
    let get_runtime_delegate =
        unsafe { GetProcAddress(library, c"hostfxr_get_runtime_delegate".as_ptr()) };
    if initialize.is_null() || close.is_null() || get_runtime_delegate.is_null() {
        unsafe {
            FreeLibrary(library);
        }
        return Status::InvalidPayload;
    }

    let initialize: HostfxrInitializeForDotnetCommandLine =
        unsafe { std::mem::transmute(initialize) };
    let close: HostfxrClose = unsafe { std::mem::transmute(close) };
    let get_runtime_delegate: HostfxrGetRuntimeDelegate =
        unsafe { std::mem::transmute(get_runtime_delegate) };
    let pwsh_dll = to_wide(pwsh_dll_path);
    let arguments = [pwsh_dll.as_ptr()];
    let mut context = ptr::null_mut();
    let result = unsafe { initialize(1, arguments.as_ptr(), ptr::null(), &mut context) };

    let status = if result < 0 || context.is_null() {
        Status::WorkerFailed
    } else {
        let mut function = ptr::null_mut();
        let result = unsafe { get_runtime_delegate(context, 6, &mut function) };
        if result < 0 || function.is_null() {
            Status::WorkerFailed
        } else {
            let get_function_pointer: GetFunctionPointer = unsafe { std::mem::transmute(function) };
            action(get_function_pointer)
        }
    };

    if !context.is_null() {
        unsafe {
            close(context);
        }
    }
    unsafe {
        FreeLibrary(library);
    }

    status
}

#[cfg(windows)]
type GetFunctionPointer = unsafe extern "system" fn(
    *const u16,
    *const u16,
    *const u16,
    *const std::ffi::c_void,
    *const std::ffi::c_void,
    *mut *mut std::ffi::c_void,
) -> i32;

#[cfg(windows)]
type LoadAssemblyFromNativeMemory = unsafe extern "system" fn(*const u8, i32) -> i32;
#[cfg(target_os = "linux")]
type LoadAssemblyFromNativeMemory = unsafe extern "C" fn(*const u8, i32) -> i32;
#[cfg(target_os = "linux")]
type GetFunctionPointer = unsafe extern "C" fn(
    *const std::ffi::c_char,
    *const std::ffi::c_char,
    *const std::ffi::c_char,
    *const std::ffi::c_void,
    *const std::ffi::c_void,
    *mut *mut std::ffi::c_void,
) -> i32;
#[cfg(any(windows, target_os = "linux"))]
type GetBridgeAbiVersion = unsafe extern "C" fn() -> i32;

#[cfg(any(windows, target_os = "linux"))]
struct BridgeExports {
    execute_invocation: ExecuteInvocationUtf8,
    stop_current_invocation: StopCurrentInvocation,
}

#[cfg(any(windows, target_os = "linux"))]
type ExecuteInvocationUtf8 =
    unsafe extern "C" fn(*const u8, i32, u32, *mut u8, i32, *mut i32) -> i32;

#[cfg(any(windows, target_os = "linux"))]
type StopCurrentInvocation = unsafe extern "C" fn() -> i32;

#[cfg(any(windows, target_os = "linux"))]
const BRIDGE_SUCCESS: i32 = 0;
#[cfg(any(windows, target_os = "linux"))]
const BRIDGE_INVALID_ARGUMENT: i32 = 1;
#[cfg(any(windows, target_os = "linux"))]
const BRIDGE_OUTPUT_TOO_LARGE: i32 = 2;
#[cfg(any(windows, target_os = "linux"))]
const BRIDGE_INVOCATION_FAILED: i32 = 3;
#[cfg(any(windows, target_os = "linux"))]
const BRIDGE_CANCELLED: i32 = 4;
#[cfg(any(windows, target_os = "linux"))]
const BRIDGE_UNSUPPORTED_TYPE: i32 = 5;

#[cfg(windows)]
unsafe fn get_unmanaged_function(
    get_function_pointer: GetFunctionPointer,
    type_name: &str,
    method_name: &str,
) -> Result<*mut std::ffi::c_void, Status> {
    let type_name = to_wide_str(type_name);
    let method_name = to_wide_str(method_name);
    let mut function = std::ptr::null_mut();
    let result = unsafe {
        get_function_pointer(
            type_name.as_ptr(),
            method_name.as_ptr(),
            usize::MAX as *const u16,
            std::ptr::null(),
            std::ptr::null(),
            &mut function,
        )
    };

    if result < 0 || function.is_null() {
        return Err(Status::BridgeLoadFailed);
    }

    Ok(function)
}

#[cfg(target_os = "linux")]
unsafe fn get_unmanaged_function(
    get_function_pointer: GetFunctionPointer,
    type_name: &str,
    method_name: &str,
) -> Result<*mut std::ffi::c_void, Status> {
    let type_name = std::ffi::CString::new(type_name).map_err(|_| Status::BridgeLoadFailed)?;
    let method_name = std::ffi::CString::new(method_name).map_err(|_| Status::BridgeLoadFailed)?;
    let mut function = std::ptr::null_mut();
    let result = unsafe {
        get_function_pointer(
            type_name.as_ptr(),
            method_name.as_ptr(),
            usize::MAX as *const std::ffi::c_char,
            std::ptr::null(),
            std::ptr::null(),
            &mut function,
        )
    };
    if result < 0 || function.is_null() {
        return Err(Status::BridgeLoadFailed);
    }
    Ok(function)
}

#[cfg(windows)]
fn to_wide(path: &Path) -> Vec<u16> {
    use std::os::windows::ffi::OsStrExt;

    path.as_os_str().encode_wide().chain(Some(0)).collect()
}

#[cfg(windows)]
fn to_wide_str(value: &str) -> Vec<u16> {
    use std::os::windows::ffi::OsStrExt;

    std::ffi::OsStr::new(value)
        .encode_wide()
        .chain(Some(0))
        .collect()
}

#[cfg(windows)]
#[link(name = "kernel32")]
unsafe extern "system" {
    fn LoadLibraryW(file_name: *const u16) -> isize;
    fn FreeLibrary(module: isize) -> i32;
    fn GetProcAddress(module: isize, name: *const i8) -> *mut std::ffi::c_void;
}

#[cfg(target_os = "linux")]
fn initialize_payload_hostfxr(
    hostfxr_path: &Path,
    pwsh_dll_path: &Path,
    action: impl FnOnce(GetFunctionPointer) -> Status,
) -> Status {
    use std::ffi::{CString, c_void};
    use std::ptr;

    type HostfxrInitializeForDotnetCommandLine =
        unsafe extern "C" fn(i32, *const *const i8, *const c_void, *mut *mut c_void) -> i32;
    type HostfxrClose = unsafe extern "C" fn(*mut c_void) -> i32;
    type HostfxrGetRuntimeDelegate =
        unsafe extern "C" fn(*mut c_void, i32, *mut *mut c_void) -> i32;

    let library_path = match CString::new(hostfxr_path.as_os_str().as_encoded_bytes()) {
        Ok(path) => path,
        Err(_) => return Status::InvalidPayload,
    };
    let library = unsafe { dlopen(library_path.as_ptr(), libc::RTLD_NOW | libc::RTLD_LOCAL) };
    if library.is_null() {
        return Status::HostfxrNotFound;
    }
    let initialize = unsafe {
        dlsym(
            library,
            c"hostfxr_initialize_for_dotnet_command_line".as_ptr(),
        )
    };
    let close = unsafe { dlsym(library, c"hostfxr_close".as_ptr()) };
    let get_runtime_delegate = unsafe { dlsym(library, c"hostfxr_get_runtime_delegate".as_ptr()) };
    if initialize.is_null() || close.is_null() || get_runtime_delegate.is_null() {
        unsafe { dlclose(library) };
        return Status::InvalidPayload;
    }
    let initialize: HostfxrInitializeForDotnetCommandLine =
        unsafe { std::mem::transmute(initialize) };
    let close: HostfxrClose = unsafe { std::mem::transmute(close) };
    let get_runtime_delegate: HostfxrGetRuntimeDelegate =
        unsafe { std::mem::transmute(get_runtime_delegate) };
    let pwsh_dll = match CString::new(pwsh_dll_path.as_os_str().as_encoded_bytes()) {
        Ok(path) => path,
        Err(_) => return Status::InvalidPayload,
    };
    let arguments = [pwsh_dll.as_ptr()];
    let mut context = ptr::null_mut();
    let result = unsafe { initialize(1, arguments.as_ptr(), ptr::null(), &mut context) };
    let status = if result < 0 || context.is_null() {
        Status::WorkerFailed
    } else {
        let mut function = ptr::null_mut();
        let result = unsafe { get_runtime_delegate(context, 6, &mut function) };
        if result < 0 || function.is_null() {
            Status::WorkerFailed
        } else {
            let get_function_pointer =
                unsafe { std::mem::transmute::<*mut c_void, GetFunctionPointer>(function) };
            action(get_function_pointer)
        }
    };
    if !context.is_null() {
        unsafe { close(context) };
    }
    unsafe { dlclose(library) };
    status
}

#[cfg(target_os = "linux")]
#[link(name = "dl")]
unsafe extern "C" {
    fn dlopen(filename: *const i8, flags: i32) -> *mut std::ffi::c_void;
    fn dlclose(handle: *mut std::ffi::c_void) -> i32;
    fn dlsym(handle: *mut std::ffi::c_void, symbol: *const i8) -> *mut std::ffi::c_void;
}

#[cfg(not(any(windows, target_os = "linux")))]
fn probe_payload_local_hostfxr(_hostfxr_path: &Path, _pwsh_dll_path: &Path) -> Status {
    Status::UnsupportedPlatform
}

#[cfg(not(any(windows, target_os = "linux")))]
fn probe_payload_local_hostfxr_bridge(
    _hostfxr_path: &Path,
    _pwsh_dll_path: &Path,
    _bridge_path: &Path,
) -> Status {
    Status::UnsupportedPlatform
}

#[cfg(test)]
#[cfg(any(windows, target_os = "linux"))]
mod tests {
    use super::*;

    fn identifiers() -> RequestIdentifiers {
        RequestIdentifiers::new(1, 1, 1)
    }

    fn bridge_response(kind: u16, body: &[u8]) -> Vec<u8> {
        let mut response = vec![1, 1, 0];
        response.extend_from_slice(&kind.to_le_bytes());
        response.extend_from_slice(&(body.len() as u32).to_le_bytes());
        response.extend_from_slice(body);
        response
    }

    #[test]
    fn structured_diagnostics_are_negotiated_and_legacy_events_remain_json() {
        let error = br#"{"message":"failure","fullyQualifiedErrorId":"FQID","category":"InvalidOperation","categoryReason":"InvalidOperationException","targetObject":"","scriptStackTrace":"","exceptionType":"System.InvalidOperationException","invocationName":"Invoke-Test","scriptName":"sample.ps1","scriptLineNumber":4,"offsetInLine":2,"pipelineLength":1,"pipelinePosition":1}"#;
        let response = bridge_response(2, error);
        let legacy_features = FeatureSet::from_bits(
            FeatureSet::SUPPORTED.bits() & !FeatureSet::STRUCTURED_DIAGNOSTICS.bits(),
        );
        let legacy =
            prepare_bridge_response(legacy_features, identifiers(), BRIDGE_SUCCESS, &response)
                .expect("legacy response");
        assert_eq!(&legacy[0].payload[10..], error);

        let enriched = prepare_bridge_response(
            FeatureSet::SUPPORTED,
            identifiers(),
            BRIDGE_SUCCESS,
            &response,
        )
        .expect("structured response");
        assert_eq!(enriched[0].payload[10], 1);
        assert_ne!(&enriched[0].payload[10..], error);

        assert_eq!(
            prepare_bridge_response(
                FeatureSet::SUPPORTED,
                identifiers(),
                BRIDGE_SUCCESS,
                &bridge_response(2, br#"{}"#),
            ),
            Err(Status::WorkerFailed)
        );
    }

    #[test]
    fn empty_bridge_failure_becomes_a_bounded_diagnostic_terminal() {
        let frames = prepare_bridge_response(
            FeatureSet::SUPPORTED,
            identifiers(),
            BRIDGE_OUTPUT_TOO_LARGE,
            &[],
        )
        .expect("failure response must be generated");

        assert_eq!(frames.len(), 2);
        assert_eq!(frames[0].header.kind, FrameKind::Failure);
        assert_eq!(
            frames[0].failure_payload().expect("failure").failure_code,
            2
        );
        assert_eq!(
            frames[1].terminal_payload().expect("terminal").status,
            TerminalStatus::Failed
        );
    }

    #[test]
    fn response_backpressure_replaces_an_oversized_frame_set_with_a_failure() {
        let count = 5_000_u16;
        let mut response = Vec::with_capacity(3 + usize::from(count) * 6);
        response.push(1);
        response.extend_from_slice(&count.to_le_bytes());
        for _ in 0..count {
            response.extend_from_slice(&1_u16.to_le_bytes());
            response.extend_from_slice(&0_u32.to_le_bytes());
        }

        let frames = prepare_bridge_response(
            FeatureSet::SUPPORTED,
            identifiers(),
            BRIDGE_SUCCESS,
            &response,
        )
        .expect("bounded replacement response must be generated");
        assert_eq!(frames.len(), 2);
        assert_eq!(
            frames[0].failure_payload().expect("failure").failure_code,
            2
        );
        assert_eq!(
            frames[1].terminal_payload().expect("terminal").status,
            TerminalStatus::Failed
        );
    }

    #[test]
    fn bridge_event_decoder_rejects_trailing_and_oversized_records() {
        assert!(decode_bridge_events(&[1, 0, 0, 0]).is_err());

        let mut oversized = vec![1, 1, 0];
        oversized.extend_from_slice(&1_u16.to_le_bytes());
        oversized.extend_from_slice(&((MAX_FRAME_PAYLOAD_BYTES - 9) as u32).to_le_bytes());
        assert!(decode_bridge_events(&oversized).is_err());
    }
}
