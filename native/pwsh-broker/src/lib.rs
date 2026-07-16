use devolutions_pwsh_protocol::{BROKER_ABI_VERSION, Status};
#[cfg(any(windows, target_os = "linux"))]
use std::collections::{HashMap, HashSet, VecDeque};
use std::ffi::OsString;
use std::path::PathBuf;
use std::process::Command;
use std::slice;
#[cfg(any(windows, target_os = "linux"))]
use std::sync::atomic::{AtomicBool, Ordering};
#[cfg(any(windows, target_os = "linux"))]
use std::sync::{Arc, Mutex, OnceLock};

#[cfg(any(windows, target_os = "linux"))]
use devolutions_pwsh_protocol::{
    CAPABILITY_TOKEN_LENGTH, FeatureSet, Frame, FrameHeader, FrameKind, Hello,
    MAX_INVOCATION_RESPONSE_BYTES, RequestIdentifiers, TerminalStatus, Welcome, cancellation_frame,
    execute_command_frame, execute_script_frame,
    transport::{NamedPipeServer, PipeConnection, PipeError},
    validate_payload_with_bridge,
};
#[cfg(any(windows, target_os = "linux"))]
use std::process::{Child, Stdio};
#[cfg(any(windows, target_os = "linux"))]
use std::time::{Duration, Instant};

const MAX_STARTUP_TIMEOUT_MS: u32 = 60_000;
#[cfg(any(windows, target_os = "linux"))]
const CANCELLATION_GRACE_TIMEOUT_MS: u32 = 1_000;

/// Opaque ABI token. Its pointer value is never dereferenced; it is a
/// generation-tagged registry key so stale native handles cannot alias a new
/// worker session.
#[repr(C)]
pub struct BrokerConnection {
    _private: [u8; 0],
}

#[cfg(any(windows, target_os = "linux"))]
struct SessionConnection {
    #[cfg(any(windows, target_os = "linux"))]
    pipe: Arc<PipeConnection>,
    child: Mutex<Option<Child>>,
    negotiated_features: FeatureSet,
    state: Mutex<ConnectionState>,
    write_lock: Mutex<()>,
    request_lock: Mutex<()>,
    closed: AtomicBool,
}

#[cfg(any(windows, target_os = "linux"))]
struct ConnectionState {
    next_request_id: u64,
    active_request: Option<ActiveRequest>,
}

#[cfg(any(windows, target_os = "linux"))]
struct ActiveRequest {
    identifiers: RequestIdentifiers,
    request_sent: bool,
    cancellation_requested: bool,
    cancellation_sent: bool,
}

struct HandleRegistry {
    next_handle: u64,
    live: HashMap<u64, Arc<SessionConnection>>,
    retired: VecDeque<u64>,
    retired_lookup: HashSet<u64>,
}

const MAX_RETIRED_HANDLES: usize = 1_024;

fn handle_registry() -> &'static Mutex<HandleRegistry> {
    static REGISTRY: OnceLock<Mutex<HandleRegistry>> = OnceLock::new();
    REGISTRY.get_or_init(|| {
        Mutex::new(HandleRegistry {
            next_handle: 1,
            live: HashMap::new(),
            retired: VecDeque::new(),
            retired_lookup: HashSet::new(),
        })
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn dps_broker_get_abi_version() -> u32 {
    BROKER_ABI_VERSION
}

/// Starts the isolated worker to probe an explicit payload. The broker copies
/// both UTF-8 path buffers before creating the child process.
///
/// # Safety
///
/// Both pointer/length pairs must identify readable byte ranges for the
/// duration of this call. Each range must be non-empty UTF-8 without NUL
/// bytes. The broker copies both ranges before it starts the worker.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dps_broker_probe_payload_utf8(
    payload_path: *const u8,
    payload_path_length: usize,
    worker_path: *const u8,
    worker_path_length: usize,
) -> i32 {
    let payload_path = match unsafe { copy_utf8_path(payload_path, payload_path_length) } {
        Ok(path) => path,
        Err(status) => return status as i32,
    };
    let worker_path = match unsafe { copy_utf8_path(worker_path, worker_path_length) } {
        Ok(path) => path,
        Err(status) => return status as i32,
    };

    if !worker_path.is_file() {
        return Status::WorkerNotFound as i32;
    }

    match Command::new(worker_path)
        .arg("--probe-payload")
        .arg(payload_path)
        .status()
    {
        Ok(status) if status.success() => Status::Success as i32,
        Ok(status) => status.code().unwrap_or(Status::WorkerFailed as i32),
        Err(_) => Status::WorkerFailed as i32,
    }
}

/// Starts a broker-owned private worker connection.
///
/// # Safety
///
/// The worker, payload, and bridge paths must each identify readable UTF-8
/// byte ranges for the duration of this call. `connection` must identify
/// writable storage for one pointer. On success, the caller owns the returned
/// opaque handle and must pass it exactly once to
/// `dps_broker_connection_shutdown`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dps_broker_connection_start_utf8(
    worker_path: *const u8,
    worker_path_length: usize,
    payload_path: *const u8,
    payload_path_length: usize,
    bridge_path: *const u8,
    bridge_path_length: usize,
    startup_timeout_ms: u32,
    connection: *mut *mut BrokerConnection,
) -> i32 {
    if connection.is_null()
        || startup_timeout_ms == 0
        || startup_timeout_ms > MAX_STARTUP_TIMEOUT_MS
    {
        return Status::InvalidArgument as i32;
    }
    unsafe {
        *connection = std::ptr::null_mut();
    }

    let worker_path = match unsafe { copy_utf8_path(worker_path, worker_path_length) } {
        Ok(path) => path,
        Err(status) => return status as i32,
    };
    let payload_path = match unsafe { copy_utf8_path(payload_path, payload_path_length) } {
        Ok(path) => path,
        Err(status) => return status as i32,
    };
    let bridge_path = match unsafe { copy_utf8_path(bridge_path, bridge_path_length) } {
        Ok(path) => path,
        Err(status) => return status as i32,
    };
    if !worker_path.is_file() {
        return Status::WorkerNotFound as i32;
    }

    #[cfg(any(windows, target_os = "linux"))]
    {
        match start_connection(worker_path, payload_path, bridge_path, startup_timeout_ms) {
            Ok(connection_value) => {
                let connection_value = Arc::new(connection_value);
                match register_connection(Arc::clone(&connection_value)) {
                    Ok(handle) => {
                        unsafe {
                            *connection = handle;
                        }
                        Status::Success as i32
                    }
                    Err(status) => {
                        let _ = shutdown_connection(&connection_value);
                        status as i32
                    }
                }
            }
            Err(status) => status as i32,
        }
    }

    #[cfg(not(any(windows, target_os = "linux")))]
    {
        let _ = worker_path;
        let _ = payload_path;
        let _ = bridge_path;
        Status::UnsupportedPlatform as i32
    }
}

/// Executes one bounded UTF-8 script through an authenticated worker session.
///
/// This Phase 2 compatibility entry point projects Phase 3 output events back
/// to text. New callers should use `dps_broker_connection_execute_command_utf8`.
///
/// # Safety
///
/// `connection` must be a live opaque connection handle. `script` and
/// `output` must identify readable and writable buffers, respectively, for
/// the duration of this call. `output_length` must identify writable storage.
/// All buffers remain caller-owned; the broker retains none after returning.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dps_broker_connection_execute_script_utf8(
    connection: *mut BrokerConnection,
    script: *const u8,
    script_length: usize,
    execution_timeout_ms: u32,
    output: *mut u8,
    output_capacity: usize,
    output_length: *mut usize,
) -> i32 {
    if connection.is_null()
        || script.is_null()
        || script_length == 0
        || output.is_null()
        || output_length.is_null()
        || execution_timeout_ms == 0
        || execution_timeout_ms > MAX_STARTUP_TIMEOUT_MS
    {
        return Status::InvalidArgument as i32;
    }
    unsafe {
        *output_length = 0;
    }
    let script = match unsafe { copy_utf8_string(script, script_length) } {
        Ok(script) => script,
        Err(status) => return status as i32,
    };

    #[cfg(any(windows, target_os = "linux"))]
    {
        let connection = match get_live_connection(connection) {
            Ok(connection) => connection,
            Err(status) => return status as i32,
        };
        let status = execute_script(&connection, &script, execution_timeout_ms);
        match status {
            Ok(script_output) => {
                unsafe {
                    *output_length = script_output.len();
                }
                if script_output.len() > output_capacity {
                    return Status::OutputBufferTooSmall as i32;
                }
                unsafe {
                    std::ptr::copy_nonoverlapping(
                        script_output.as_ptr(),
                        output,
                        script_output.len(),
                    );
                }
                Status::Success as i32
            }
            Err(status) => status as i32,
        }
    }

    #[cfg(not(any(windows, target_os = "linux")))]
    {
        let _ = script;
        let _ = output_capacity;
        Status::UnsupportedPlatform as i32
    }
}

/// Executes one binary structured-command DTO and returns its complete,
/// bounded protocol response frames in caller-owned storage.
///
/// # Safety
///
/// `connection` must be a live opaque connection. `request` identifies a
/// non-empty caller-owned DTO and `output` identifies caller-owned storage.
/// The output format is little-endian `u32 frame_count`, followed by one
/// `u32 encoded_frame_length` and encoded protocol frame per response frame.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dps_broker_connection_execute_command_utf8(
    connection: *mut BrokerConnection,
    request: *const u8,
    request_length: usize,
    execution_timeout_ms: u32,
    output: *mut u8,
    output_capacity: usize,
    output_length: *mut usize,
) -> i32 {
    if connection.is_null()
        || request.is_null()
        || request_length == 0
        || output.is_null()
        || output_length.is_null()
        || execution_timeout_ms == 0
        || execution_timeout_ms > MAX_STARTUP_TIMEOUT_MS
    {
        return Status::InvalidArgument as i32;
    }
    unsafe {
        *output_length = 0;
    }
    let request = match unsafe { copy_bytes(request, request_length) } {
        Ok(request) => request,
        Err(status) => return status as i32,
    };

    #[cfg(any(windows, target_os = "linux"))]
    {
        let connection = match get_live_connection(connection) {
            Ok(connection) => connection,
            Err(status) => return status as i32,
        };
        let mut payload = Vec::with_capacity(4 + request.len());
        payload.extend_from_slice(&execution_timeout_ms.to_le_bytes());
        payload.extend_from_slice(&request);
        let frames = match execute_request(
            &connection,
            FrameKind::ExecuteCommand,
            &payload,
            execution_timeout_ms,
        ) {
            Ok(frames) => frames,
            Err(status) => return status as i32,
        };
        let encoded = match encode_response_frames(&frames) {
            Ok(encoded) => encoded,
            Err(status) => return status as i32,
        };
        unsafe {
            *output_length = encoded.len();
        }
        if encoded.len() > output_capacity {
            return Status::OutputBufferTooSmall as i32;
        }
        unsafe {
            std::ptr::copy_nonoverlapping(encoded.as_ptr(), output, encoded.len());
        }
        Status::Success as i32
    }

    #[cfg(not(any(windows, target_os = "linux")))]
    {
        let _ = request;
        let _ = output_capacity;
        Status::UnsupportedPlatform as i32
    }
}

/// Requests cooperative cancellation of the active invocation. The request is
/// idempotent while an invocation is active and never terminates the session.
///
/// # Safety
///
/// `connection` must be a live opaque connection handle returned by
/// `dps_broker_connection_start_utf8`. It remains owned by the caller.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dps_broker_connection_cancel(connection: *mut BrokerConnection) -> i32 {
    if connection.is_null() {
        return Status::InvalidArgument as i32;
    }

    #[cfg(any(windows, target_os = "linux"))]
    {
        match get_live_connection(connection) {
            Ok(connection) => cancel_active_request(&connection) as i32,
            Err(status) => status as i32,
        }
    }

    #[cfg(not(any(windows, target_os = "linux")))]
    {
        Status::UnsupportedPlatform as i32
    }
}

/// Shuts down a broker-owned worker connection and releases its opaque handle.
///
/// # Safety
///
/// `connection` must be a non-null handle returned by
/// `dps_broker_connection_start_utf8`. Repeated shutdown of a retired opaque
/// token is safe and idempotent; unknown tokens are rejected without
/// dereferencing them.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dps_broker_connection_shutdown(connection: *mut BrokerConnection) -> i32 {
    if connection.is_null() {
        return Status::InvalidArgument as i32;
    }

    /// Immediately tears down a broker-owned worker connection and releases its
    /// opaque handle. This is reserved for SafeHandle disposal while a request may
    /// still be blocked in the execute ABI; callers must treat that request as
    /// worker termination rather than cooperative cancellation.
    ///
    /// # Safety
    ///
    /// `connection` must be a non-null handle returned by
    /// `dps_broker_connection_start_utf8`. Repeated aborts of a retired opaque
    /// token are safe and idempotent; unknown tokens are rejected without
    /// dereferencing them.
    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn dps_broker_connection_abort(connection: *mut BrokerConnection) -> i32 {
        if connection.is_null() {
            return Status::InvalidArgument as i32;
        }

        #[cfg(any(windows, target_os = "linux"))]
        {
            abort_registered_connection(connection) as i32
        }

        #[cfg(not(any(windows, target_os = "linux")))]
        {
            Status::UnsupportedPlatform as i32
        }
    }

    #[cfg(any(windows, target_os = "linux"))]
    {
        shutdown_registered_connection(connection) as i32
    }

    #[cfg(not(any(windows, target_os = "linux")))]
    {
        Status::UnsupportedPlatform as i32
    }
}

unsafe fn copy_utf8_path(pointer: *const u8, length: usize) -> Result<PathBuf, Status> {
    if pointer.is_null() || length == 0 {
        return Err(Status::InvalidArgument);
    }

    // The ABI contract requires the caller to keep the input alive only for
    // this call; the buffer is copied before the worker is created.
    let bytes = unsafe { slice::from_raw_parts(pointer, length) };
    if bytes.contains(&0) {
        return Err(Status::InvalidArgument);
    }
    let value = std::str::from_utf8(bytes).map_err(|_| Status::InvalidArgument)?;
    Ok(PathBuf::from(OsString::from(value)))
}

unsafe fn copy_utf8_string(pointer: *const u8, length: usize) -> Result<String, Status> {
    if pointer.is_null() || length == 0 {
        return Err(Status::InvalidArgument);
    }

    let bytes = unsafe { slice::from_raw_parts(pointer, length) };
    if bytes.contains(&0) {
        return Err(Status::InvalidArgument);
    }
    std::str::from_utf8(bytes)
        .map(str::to_owned)
        .map_err(|_| Status::InvalidArgument)
}

unsafe fn copy_bytes(pointer: *const u8, length: usize) -> Result<Vec<u8>, Status> {
    if pointer.is_null() || length == 0 {
        return Err(Status::InvalidArgument);
    }

    Ok(unsafe { slice::from_raw_parts(pointer, length) }.to_vec())
}

fn register_connection(
    connection: Arc<SessionConnection>,
) -> Result<*mut BrokerConnection, Status> {
    let mut registry = match handle_registry().lock() {
        Ok(registry) => registry,
        Err(_) => return Err(Status::WorkerFailed),
    };
    let handle = registry.next_handle;
    let Some(next_handle) = registry.next_handle.checked_add(1) else {
        return Err(Status::ConnectionSetupFailed);
    };
    registry.next_handle = next_handle;
    registry.live.insert(handle, connection);
    Ok(handle as usize as *mut BrokerConnection)
}

fn connection_handle(connection: *mut BrokerConnection) -> Result<u64, Status> {
    if connection.is_null() {
        return Err(Status::InvalidArgument);
    }
    u64::try_from(connection as usize).map_err(|_| Status::InvalidArgument)
}

fn get_live_connection(
    connection: *mut BrokerConnection,
) -> Result<Arc<SessionConnection>, Status> {
    let handle = connection_handle(connection)?;
    let registry = handle_registry().lock().map_err(|_| Status::WorkerFailed)?;
    match registry.live.get(&handle) {
        Some(connection) => Ok(Arc::clone(connection)),
        None if registry.retired_lookup.contains(&handle) => Err(Status::WorkerExited),
        None => Err(Status::InvalidArgument),
    }
}

fn retire_handle(registry: &mut HandleRegistry, handle: u64) {
    registry.retired.push_back(handle);
    registry.retired_lookup.insert(handle);
    if registry.retired.len() > MAX_RETIRED_HANDLES
        && let Some(expired) = registry.retired.pop_front()
    {
        registry.retired_lookup.remove(&expired);
    }
}

fn shutdown_registered_connection(connection: *mut BrokerConnection) -> Status {
    let handle = match connection_handle(connection) {
        Ok(handle) => handle,
        Err(status) => return status,
    };
    let connection = {
        let mut registry = match handle_registry().lock() {
            Ok(registry) => registry,
            Err(_) => return Status::WorkerFailed,
        };
        match registry.live.remove(&handle) {
            Some(connection) => {
                retire_handle(&mut registry, handle);
                connection
            }
            None if registry.retired_lookup.contains(&handle) => return Status::Success,
            None => return Status::InvalidArgument,
        }
    };
    shutdown_connection(&connection)
}

fn abort_registered_connection(connection: *mut BrokerConnection) -> Status {
    let handle = match connection_handle(connection) {
        Ok(handle) => handle,
        Err(status) => return status,
    };
    let connection = {
        let mut registry = match handle_registry().lock() {
            Ok(registry) => registry,
            Err(_) => return Status::WorkerFailed,
        };
        match registry.live.remove(&handle) {
            Some(connection) => {
                retire_handle(&mut registry, handle);
                connection
            }
            None if registry.retired_lookup.contains(&handle) => return Status::Success,
            None => return Status::InvalidArgument,
        }
    };
    abort_connection(&connection);
    Status::Success
}

fn start_connection(
    worker_path: PathBuf,
    payload_path: PathBuf,
    bridge_path: PathBuf,
    startup_timeout_ms: u32,
) -> Result<SessionConnection, Status> {
    let payload = validate_payload_with_bridge(&payload_path, Some(&bridge_path))?;
    let worker_path = canonical_worker_path(&worker_path)?;
    let worker_directory = worker_path
        .parent()
        .ok_or(Status::WorkerNotFound)?
        .to_path_buf();
    let bridge_path = payload.worker_bridge.ok_or(Status::BridgeNotFound)?;
    let deadline = StartupDeadline::new(startup_timeout_ms);
    let capability_token = random_bytes::<CAPABILITY_TOKEN_LENGTH>()?;
    let endpoint_nonce = random_bytes::<16>()?;
    let (endpoint, server) = create_private_endpoint(&endpoint_nonce)?;

    let mut command = Command::new(worker_path);
    command
        .env_clear()
        .arg("--ipc-session")
        .arg(&endpoint)
        .arg(&payload.root)
        .arg(bridge_path)
        .env(
            "DEVOLUTIONS_PWSH_CAPABILITY_TOKEN",
            encode_hex(&capability_token),
        )
        .current_dir(&payload.root)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    configure_worker_environment(&mut command, &worker_directory, &payload.root, &endpoint)?;
    let mut child = command.spawn().map_err(|_| Status::WorkerFailed)?;

    let accept_timeout = match deadline.remaining() {
        Ok(timeout) => timeout,
        Err(status) => {
            terminate_child(child);
            return Err(status);
        }
    };
    let pipe = match server.accept(accept_timeout) {
        Ok(pipe) => validate_worker_handshake(&pipe, &capability_token, &deadline)
            .map(|negotiated_features| (pipe, negotiated_features)),
        Err(PipeError::TimedOut) if child.try_wait().ok().flatten().is_some() => {
            Err(Status::WorkerExited)
        }
        Err(error) => Err(map_pipe_startup_error(error)),
    };

    match pipe {
        Ok((pipe, negotiated_features)) => Ok(SessionConnection {
            pipe: Arc::new(pipe),
            child: Mutex::new(Some(child)),
            negotiated_features,
            state: Mutex::new(ConnectionState {
                next_request_id: 1,
                active_request: None,
            }),
            write_lock: Mutex::new(()),
            request_lock: Mutex::new(()),
            closed: AtomicBool::new(false),
        }),
        Err(status) => {
            terminate_child(child);
            Err(status)
        }
    }
}

#[cfg(windows)]
fn create_private_endpoint(endpoint_nonce: &[u8; 16]) -> Result<(String, NamedPipeServer), Status> {
    let endpoint = format!(r"\\.\pipe\devolutions-pwsh-{}", encode_hex(endpoint_nonce));
    let server = NamedPipeServer::create_owner_only(
        &endpoint,
        (devolutions_pwsh_protocol::FrameHeader::ENCODED_LENGTH
            + devolutions_pwsh_protocol::MAX_FRAME_PAYLOAD_BYTES) as u32,
    )
    .map_err(map_pipe_startup_error)?;
    Ok((endpoint, server))
}

#[cfg(target_os = "linux")]
fn create_private_endpoint(endpoint_nonce: &[u8; 16]) -> Result<(String, NamedPipeServer), Status> {
    use std::os::unix::fs::PermissionsExt;

    let directory =
        std::env::temp_dir().join(format!("devolutions-pwsh-{}", encode_hex(endpoint_nonce)));
    std::fs::create_dir(&directory).map_err(|_| Status::ConnectionSetupFailed)?;
    std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700))
        .map_err(|_| Status::ConnectionSetupFailed)?;
    let endpoint = directory.join("worker.sock");
    let endpoint = endpoint
        .to_str()
        .ok_or(Status::ConnectionSetupFailed)?
        .to_owned();
    let server = NamedPipeServer::create_owner_only(
        &endpoint,
        (devolutions_pwsh_protocol::FrameHeader::ENCODED_LENGTH
            + devolutions_pwsh_protocol::MAX_FRAME_PAYLOAD_BYTES) as u32,
    )
    .map_err(map_pipe_startup_error)?;
    Ok((endpoint, server))
}

#[cfg(windows)]
fn configure_worker_environment(
    command: &mut Command,
    worker_directory: &std::path::Path,
    payload_root: &std::path::Path,
    _: &str,
) -> Result<(), Status> {
    command
        .env("SystemRoot", required_environment_variable("SystemRoot")?)
        .env("WINDIR", required_environment_variable("WINDIR")?)
        .env(
            "PATH",
            format!("{};{}", worker_directory.display(), payload_root.display()),
        );
    if let Some(value) = std::env::var_os("TEMP") {
        command.env("TEMP", value);
    }
    if let Some(value) = std::env::var_os("TMP") {
        command.env("TMP", value);
    }
    Ok(())
}

#[cfg(target_os = "linux")]
fn configure_worker_environment(
    command: &mut Command,
    worker_directory: &std::path::Path,
    payload_root: &std::path::Path,
    endpoint: &str,
) -> Result<(), Status> {
    let private_directory = std::path::Path::new(endpoint)
        .parent()
        .ok_or(Status::ConnectionSetupFailed)?;
    command
        .env(
            "PATH",
            format!("{}:{}", worker_directory.display(), payload_root.display()),
        )
        .env("HOME", private_directory)
        .env("TMPDIR", private_directory);
    if let Some(value) = std::env::var_os("LANG") {
        command.env("LANG", value);
    }
    Ok(())
}

fn canonical_worker_path(worker_path: &std::path::Path) -> Result<PathBuf, Status> {
    let metadata = std::fs::symlink_metadata(worker_path).map_err(|_| Status::WorkerNotFound)?;
    if !metadata.is_file() || metadata.file_type().is_symlink() {
        return Err(Status::WorkerNotFound);
    }
    std::fs::canonicalize(worker_path).map_err(|_| Status::WorkerNotFound)
}

#[cfg(windows)]
fn required_environment_variable(name: &str) -> Result<std::ffi::OsString, Status> {
    std::env::var_os(name).ok_or(Status::ConnectionSetupFailed)
}

fn validate_worker_handshake(
    pipe: &PipeConnection,
    capability_token: &[u8; CAPABILITY_TOKEN_LENGTH],
    deadline: &StartupDeadline,
) -> Result<FeatureSet, Status> {
    let worker_hello = pipe
        .read_frame(deadline.remaining()?)
        .map_err(map_pipe_handshake_error)?;
    let worker_hello = Hello::from_frame(&worker_hello).map_err(|_| Status::HandshakeRejected)?;
    let worker_negotiation = devolutions_pwsh_protocol::negotiate(&worker_hello, capability_token)
        .map_err(|_| Status::HandshakeRejected)?;

    let broker_hello = Hello {
        minimum_version: devolutions_pwsh_protocol::PROTOCOL_VERSION,
        maximum_version: devolutions_pwsh_protocol::PROTOCOL_VERSION,
        offered_features: FeatureSet::SUPPORTED,
        capability_token: *capability_token,
    };
    pipe.write_frame(
        &broker_hello
            .to_frame()
            .map_err(|_| Status::HandshakeRejected)?,
        deadline.remaining()?,
    )
    .map_err(map_pipe_handshake_error)?;

    let worker_welcome = pipe
        .read_frame(deadline.remaining()?)
        .map_err(map_pipe_handshake_error)?;
    let worker_welcome =
        Welcome::from_frame(&worker_welcome).map_err(|_| Status::HandshakeRejected)?;
    let expected_welcome = devolutions_pwsh_protocol::negotiate(&broker_hello, capability_token)
        .map_err(|_| Status::HandshakeRejected)?;
    if worker_welcome != expected_welcome {
        return Err(Status::HandshakeRejected);
    }

    Ok(worker_negotiation.selected_features)
}

fn execute_script(
    connection: &SessionConnection,
    script: &str,
    execution_timeout_ms: u32,
) -> Result<Vec<u8>, Status> {
    let frames = execute_request(
        connection,
        FrameKind::ExecuteScript,
        script.as_bytes(),
        execution_timeout_ms,
    )?;
    let terminal = frames
        .last()
        .ok_or(Status::ProtocolViolation)?
        .terminal_payload()
        .map_err(|_| Status::ProtocolViolation)?;
    match terminal.status {
        TerminalStatus::Succeeded => legacy_script_output(&frames),
        TerminalStatus::Cancelled => Err(Status::RequestTimeout),
        TerminalStatus::Failed => Err(Status::WorkerFailed),
    }
}

fn execute_request(
    connection: &SessionConnection,
    kind: FrameKind,
    payload: &[u8],
    execution_timeout_ms: u32,
) -> Result<Vec<Frame>, Status> {
    let _request_lock = connection
        .request_lock
        .lock()
        .map_err(|_| Status::WorkerFailed)?;
    if connection.closed.load(Ordering::Acquire) {
        return Err(Status::WorkerExited);
    }
    let deadline = StartupDeadline::new(execution_timeout_ms);
    let identifiers = begin_request(connection)?;
    let request = match kind {
        FrameKind::ExecuteScript => {
            let script = std::str::from_utf8(payload).map_err(|_| Status::InvalidArgument)?;
            execute_script_frame(connection.negotiated_features, identifiers, script)
                .map_err(|_| Status::InvalidArgument)?
        }
        FrameKind::ExecuteCommand => {
            execute_command_frame(connection.negotiated_features, identifiers, payload)
                .map_err(|_| Status::InvalidArgument)?
        }
        _ => return Err(Status::InvalidArgument),
    };
    let mut result = (|| {
        write_request_frame(connection, &request, deadline.remaining_request()?)?;
        mark_request_sent(connection, identifiers, &deadline)?;
        collect_response_frames(connection, identifiers, &deadline)
    })();
    if matches!(result.as_ref(), Err(Status::RequestTimeout)) {
        let _ = cancel_active_request(connection);
        result = collect_response_frames(
            connection,
            identifiers,
            &StartupDeadline::new(CANCELLATION_GRACE_TIMEOUT_MS),
        );
    }
    if result.is_err() {
        abort_connection(connection);
    }
    clear_active_request(connection, identifiers);
    result
}

fn begin_request(connection: &SessionConnection) -> Result<RequestIdentifiers, Status> {
    let mut state = connection.state.lock().map_err(|_| Status::WorkerFailed)?;
    debug_assert!(state.active_request.is_none());
    let request_id = state.next_request_id;
    state.next_request_id = state
        .next_request_id
        .checked_add(1)
        .ok_or(Status::ProtocolViolation)?;
    let identifiers = RequestIdentifiers::new(1, 1, request_id);
    state.active_request = Some(ActiveRequest {
        identifiers,
        request_sent: false,
        cancellation_requested: false,
        cancellation_sent: false,
    });
    Ok(identifiers)
}

fn clear_active_request(connection: &SessionConnection, identifiers: RequestIdentifiers) {
    if let Ok(mut state) = connection.state.lock()
        && state
            .active_request
            .as_ref()
            .is_some_and(|active| active.identifiers == identifiers)
    {
        state.active_request = None;
    }
}

fn write_request_frame(
    connection: &SessionConnection,
    frame: &Frame,
    timeout_ms: u32,
) -> Result<(), Status> {
    let _write_lock = connection
        .write_lock
        .lock()
        .map_err(|_| Status::WorkerFailed)?;
    if connection.closed.load(Ordering::Acquire) {
        return Err(Status::WorkerExited);
    }
    connection
        .pipe
        .write_frame(frame, timeout_ms)
        .map_err(map_pipe_request_error)
}

fn mark_request_sent(
    connection: &SessionConnection,
    identifiers: RequestIdentifiers,
    deadline: &StartupDeadline,
) -> Result<(), Status> {
    let should_send_cancel = {
        let mut state = connection.state.lock().map_err(|_| Status::WorkerFailed)?;
        mark_request_sent_state(&mut state, identifiers)?
    };
    if should_send_cancel {
        send_cancellation_frame(connection, identifiers, deadline.remaining_request()?)?;
    }
    Ok(())
}

fn cancel_active_request(connection: &SessionConnection) -> Status {
    if connection.closed.load(Ordering::Acquire) {
        return Status::WorkerExited;
    }
    let identifiers = match connection.state.lock() {
        Ok(mut state) => match request_active_cancellation(&mut state) {
            Some(identifiers) => identifiers,
            None => return Status::Success,
        },
        Err(_) => return Status::WorkerFailed,
    };
    send_cancellation_frame(connection, identifiers, CANCELLATION_GRACE_TIMEOUT_MS)
        .map_or_else(|status| status, |_| Status::Success)
}

fn mark_request_sent_state(
    state: &mut ConnectionState,
    identifiers: RequestIdentifiers,
) -> Result<bool, Status> {
    let active = state.active_request.as_mut().ok_or(Status::WorkerExited)?;
    if active.identifiers != identifiers {
        return Err(Status::WorkerExited);
    }
    active.request_sent = true;
    if active.cancellation_requested && !active.cancellation_sent {
        active.cancellation_sent = true;
        Ok(true)
    } else {
        Ok(false)
    }
}

fn request_active_cancellation(state: &mut ConnectionState) -> Option<RequestIdentifiers> {
    let active = state.active_request.as_mut()?;
    active.cancellation_requested = true;
    if !active.request_sent || active.cancellation_sent {
        return None;
    }
    active.cancellation_sent = true;
    Some(active.identifiers)
}

fn send_cancellation_frame(
    connection: &SessionConnection,
    identifiers: RequestIdentifiers,
    timeout_ms: u32,
) -> Result<(), Status> {
    let cancel = match cancellation_frame(connection.negotiated_features, identifiers) {
        Ok(cancel) => cancel,
        Err(_) => return Err(Status::ProtocolViolation),
    };
    write_request_frame(connection, &cancel, timeout_ms)
}

fn collect_response_frames(
    connection: &SessionConnection,
    identifiers: RequestIdentifiers,
    deadline: &StartupDeadline,
) -> Result<Vec<Frame>, Status> {
    let pipe = &connection.pipe;
    let mut frames = Vec::new();
    let mut sequence = 0_u64;
    let mut total_encoded_bytes = 4_usize;
    loop {
        let frame = pipe
            .read_frame(deadline.remaining_request()?)
            .map_err(map_pipe_request_error)?;
        validate_response_header(&frame, connection.negotiated_features, identifiers)?;
        let frame_sequence = match frame.header.kind {
            FrameKind::Event => {
                frame
                    .event_payload()
                    .map_err(|_| Status::ProtocolViolation)?
                    .sequence
            }
            FrameKind::Failure => {
                frame
                    .failure_payload()
                    .map_err(|_| Status::ProtocolViolation)?
                    .sequence
            }
            FrameKind::ScriptOutput => {
                frame
                    .script_output_payload()
                    .map_err(|_| Status::ProtocolViolation)?
                    .sequence
            }
            FrameKind::Terminal => {
                frame
                    .terminal_payload()
                    .map_err(|_| Status::ProtocolViolation)?
                    .sequence
            }
            _ => return Err(Status::ProtocolViolation),
        };
        if frame_sequence != sequence {
            return Err(Status::ProtocolViolation);
        }
        sequence = sequence.checked_add(1).ok_or(Status::ProtocolViolation)?;
        total_encoded_bytes = total_encoded_bytes
            .checked_add(FrameHeader::ENCODED_LENGTH + frame.payload.len() + 4)
            .ok_or(Status::ProtocolViolation)?;
        if total_encoded_bytes > MAX_INVOCATION_RESPONSE_BYTES {
            return Err(Status::OutputBufferTooSmall);
        }
        let terminal = frame.header.kind == FrameKind::Terminal;
        frames.push(frame);
        if terminal {
            clear_active_request(connection, identifiers);
            return Ok(frames);
        }
    }
}

fn legacy_script_output(frames: &[Frame]) -> Result<Vec<u8>, Status> {
    let mut output = String::new();
    for frame in frames {
        match frame.header.kind {
            FrameKind::ScriptOutput => {
                let value = frame
                    .script_output_payload()
                    .map_err(|_| Status::ProtocolViolation)?
                    .output;
                if !output.is_empty() {
                    output.push('\n');
                }
                output.push_str(value);
            }
            FrameKind::Event => {
                let event = frame
                    .event_payload()
                    .map_err(|_| Status::ProtocolViolation)?;
                if event.event_kind == 1 {
                    let value = legacy_value_text(event.body)?;
                    if !output.is_empty() {
                        output.push('\n');
                    }
                    output.push_str(&value);
                }
            }
            FrameKind::Failure | FrameKind::Terminal => {}
            _ => return Err(Status::ProtocolViolation),
        }
    }
    Ok(output.into_bytes())
}

fn legacy_value_text(value: &[u8]) -> Result<String, Status> {
    let kind = *value.first().ok_or(Status::ProtocolViolation)?;
    match kind {
        0 => Ok(String::new()),
        1 if value.len() == 2 && value[1] <= 1 => Ok((value[1] != 0).to_string()),
        2 if value.len() == 9 => Ok(i64::from_le_bytes(
            value[1..9]
                .try_into()
                .map_err(|_| Status::ProtocolViolation)?,
        )
        .to_string()),
        3 if value.len() == 9 => Ok(f64::from_le_bytes(
            value[1..9]
                .try_into()
                .map_err(|_| Status::ProtocolViolation)?,
        )
        .to_string()),
        4 if value.len() >= 5 => {
            let length = u32::from_le_bytes(
                value[1..5]
                    .try_into()
                    .map_err(|_| Status::ProtocolViolation)?,
            ) as usize;
            if length != value.len() - 5 {
                return Err(Status::ProtocolViolation);
            }
            std::str::from_utf8(&value[5..])
                .map(str::to_owned)
                .map_err(|_| Status::ProtocolViolation)
        }
        _ => Err(Status::ProtocolViolation),
    }
}

fn encode_response_frames(frames: &[Frame]) -> Result<Vec<u8>, Status> {
    let mut encoded = Vec::with_capacity(4);
    encoded.extend_from_slice(
        &(u32::try_from(frames.len()).map_err(|_| Status::OutputBufferTooSmall)?).to_le_bytes(),
    );
    for frame in frames {
        let frame = frame.encode().map_err(|_| Status::ProtocolViolation)?;
        let length = u32::try_from(frame.len()).map_err(|_| Status::OutputBufferTooSmall)?;
        encoded.extend_from_slice(&length.to_le_bytes());
        encoded.extend_from_slice(&frame);
        if encoded.len() > MAX_INVOCATION_RESPONSE_BYTES {
            return Err(Status::OutputBufferTooSmall);
        }
    }
    Ok(encoded)
}

fn validate_response_header(
    frame: &Frame,
    features: FeatureSet,
    identifiers: RequestIdentifiers,
) -> Result<(), Status> {
    if frame.header.features != features || frame.header.identifiers != identifiers {
        return Err(Status::ProtocolViolation);
    }
    Ok(())
}

fn shutdown_connection(connection: &SessionConnection) -> Status {
    let was_closed = connection.closed.swap(true, Ordering::AcqRel);
    connection.pipe.close();
    let child = match connection.child.lock() {
        Ok(mut child) => child.take(),
        Err(_) => return Status::WorkerFailed,
    };
    let Some(mut child) = child else {
        return if was_closed {
            Status::Success
        } else {
            Status::WorkerExited
        };
    };
    let worker_exited = child.try_wait().ok().flatten().is_some();
    if worker_exited {
        return Status::WorkerExited;
    }

    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        match child.try_wait() {
            Ok(Some(_)) => return Status::Success,
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(10)),
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                return Status::Success;
            }
            Err(_) => return Status::WorkerExited,
        }
    }
}

fn abort_connection(connection: &SessionConnection) {
    if connection.closed.swap(true, Ordering::AcqRel) {
        return;
    }
    connection.pipe.close();
    if let Ok(mut child) = connection.child.lock()
        && let Some(child) = child.take()
    {
        terminate_child(child);
    }
}

fn terminate_child(mut child: Child) {
    let _ = child.kill();
    let _ = child.wait();
}

fn map_pipe_startup_error(error: PipeError) -> Status {
    match error {
        PipeError::TimedOut => Status::StartupTimeout,
        PipeError::PeerClosed => Status::WorkerExited,
        PipeError::Protocol(_) => Status::HandshakeRejected,
        _ => Status::ConnectionSetupFailed,
    }
}

fn map_pipe_handshake_error(error: PipeError) -> Status {
    match error {
        PipeError::TimedOut => Status::StartupTimeout,
        PipeError::PeerClosed => Status::WorkerExited,
        _ => Status::HandshakeRejected,
    }
}

fn map_pipe_request_error(error: PipeError) -> Status {
    match error {
        PipeError::TimedOut => Status::RequestTimeout,
        PipeError::PeerClosed => Status::WorkerExited,
        _ => Status::ProtocolViolation,
    }
}

struct StartupDeadline {
    deadline: Instant,
}

impl StartupDeadline {
    fn new(timeout_ms: u32) -> Self {
        Self {
            deadline: Instant::now() + Duration::from_millis(timeout_ms as u64),
        }
    }

    fn remaining(&self) -> Result<u32, Status> {
        self.remaining_as(Status::StartupTimeout)
    }

    fn remaining_request(&self) -> Result<u32, Status> {
        self.remaining_as(Status::RequestTimeout)
    }

    fn remaining_as(&self, timeout_status: Status) -> Result<u32, Status> {
        let remaining = self
            .deadline
            .checked_duration_since(Instant::now())
            .ok_or(timeout_status)?;
        u32::try_from(remaining.as_millis().max(1)).map_err(|_| timeout_status)
    }
}

#[cfg(windows)]
fn random_bytes<const LENGTH: usize>() -> Result<[u8; LENGTH], Status> {
    let mut bytes = [0_u8; LENGTH];
    if unsafe { SystemFunction036(bytes.as_mut_ptr().cast(), LENGTH as u32) } == 0 {
        return Err(Status::ConnectionSetupFailed);
    }
    Ok(bytes)
}

#[cfg(target_os = "linux")]
fn random_bytes<const LENGTH: usize>() -> Result<[u8; LENGTH], Status> {
    use std::io::Read;

    let mut bytes = [0_u8; LENGTH];
    std::fs::File::open("/dev/urandom")
        .map_err(|_| Status::ConnectionSetupFailed)?
        .read_exact(&mut bytes)
        .map_err(|_| Status::ConnectionSetupFailed)?;
    Ok(bytes)
}

#[cfg(any(windows, target_os = "linux"))]
fn encode_hex(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut value = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        value.push(HEX[(byte >> 4) as usize] as char);
        value.push(HEX[(byte & 0x0F) as usize] as char);
    }
    value
}

#[cfg(windows)]
#[link(name = "advapi32")]
unsafe extern "system" {
    fn SystemFunction036(random_buffer: *mut std::ffi::c_void, random_buffer_length: u32) -> i32;
}

#[cfg(test)]
#[cfg(windows)]
mod tests {
    use super::*;
    use devolutions_pwsh_protocol::{
        CAPABILITY_TOKEN_LENGTH, PROTOCOL_VERSION, windows_pipe::NamedPipeClient,
    };
    use std::sync::atomic::{AtomicU32, Ordering};

    const TOKEN: [u8; CAPABILITY_TOKEN_LENGTH] = [0x5A; CAPABILITY_TOKEN_LENGTH];
    static NEXT_ENDPOINT: AtomicU32 = AtomicU32::new(0);

    #[test]
    fn broker_pipe_rejects_wrong_token_and_unsupported_version_before_dispatch() {
        for hello in [
            Hello {
                minimum_version: PROTOCOL_VERSION,
                maximum_version: PROTOCOL_VERSION,
                offered_features: FeatureSet::SUPPORTED,
                capability_token: [0xA5; CAPABILITY_TOKEN_LENGTH],
            },
            Hello {
                minimum_version: PROTOCOL_VERSION + 1,
                maximum_version: PROTOCOL_VERSION + 1,
                offered_features: FeatureSet::SUPPORTED,
                capability_token: TOKEN,
            },
        ] {
            assert_handshake_rejected(hello);
        }
    }

    #[test]
    fn endpoint_nonce_does_not_include_the_capability_token() {
        let nonce = [0x11; 16];
        assert_ne!(encode_hex(&nonce), encode_hex(&TOKEN));
    }

    #[test]
    fn cancellation_is_latched_until_the_request_frame_is_written_and_is_idempotent() {
        let identifiers = RequestIdentifiers::new(1, 1, 7);
        let mut state = ConnectionState {
            next_request_id: 8,
            active_request: Some(ActiveRequest {
                identifiers,
                request_sent: false,
                cancellation_requested: false,
                cancellation_sent: false,
            }),
        };

        assert_eq!(request_active_cancellation(&mut state), None);
        assert!(mark_request_sent_state(&mut state, identifiers).expect("request state"));
        assert_eq!(request_active_cancellation(&mut state), None);
        assert!(!mark_request_sent_state(&mut state, identifiers).expect("request state"));
    }

    #[test]
    fn request_deadlines_and_pipe_failures_keep_their_diagnostic_status() {
        let deadline = StartupDeadline::new(1);
        std::thread::sleep(Duration::from_millis(5));
        assert_eq!(deadline.remaining_request(), Err(Status::RequestTimeout));
        assert_eq!(
            map_pipe_startup_error(PipeError::PeerClosed),
            Status::WorkerExited
        );
        assert_eq!(
            map_pipe_handshake_error(PipeError::TimedOut),
            Status::StartupTimeout
        );
        assert_eq!(
            map_pipe_request_error(PipeError::PeerClosed),
            Status::WorkerExited
        );
    }

    #[test]
    fn stale_generation_tagged_handles_are_not_dereferenced_or_reused() {
        let handle = (usize::MAX - 7) as *mut BrokerConnection;
        assert!(matches!(
            get_live_connection(handle),
            Err(Status::InvalidArgument)
        ));

        let handle_id = connection_handle(handle).expect("opaque handle value");
        {
            let mut registry = handle_registry().lock().expect("test registry");
            retire_handle(&mut registry, handle_id);
        }
        assert!(matches!(
            get_live_connection(handle),
            Err(Status::WorkerExited)
        ));
        assert_eq!(shutdown_registered_connection(handle), Status::Success);
        assert_eq!(abort_registered_connection(handle), Status::Success);
    }

    fn assert_handshake_rejected(hello: Hello) {
        let endpoint = format!(
            r"\\.\pipe\devolutions-pwsh-broker-test-{}-{}",
            std::process::id(),
            NEXT_ENDPOINT.fetch_add(1, Ordering::Relaxed)
        );
        let server = NamedPipeServer::create_owner_only(
            &endpoint,
            (devolutions_pwsh_protocol::FrameHeader::ENCODED_LENGTH
                + devolutions_pwsh_protocol::MAX_FRAME_PAYLOAD_BYTES) as u32,
        )
        .expect("test pipe must be created");
        let client = std::thread::spawn(move || {
            let pipe = NamedPipeClient::connect(&endpoint, 1_000).expect("client must connect");
            pipe.write_frame(&hello.to_frame().expect("hello must encode"), 1_000)
                .expect("client must write hello");
        });
        let pipe = server.accept(1_000).expect("server must accept");
        assert_eq!(
            validate_worker_handshake(&pipe, &TOKEN, &StartupDeadline::new(1_000)),
            Err(Status::HandshakeRejected)
        );
        client.join().expect("client must finish");
    }
}
