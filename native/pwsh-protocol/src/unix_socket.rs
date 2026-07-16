use crate::{Frame, FrameHeader, MAX_BUFFERED_BYTES, ProtocolError};
use std::fs;
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, RwLock};
use std::time::{Duration, Instant};

#[derive(Debug, Eq, PartialEq)]
pub enum UnixSocketError {
    PeerClosed,
    Protocol(ProtocolError),
    TimedOut,
    Unix(i32),
}

impl From<ProtocolError> for UnixSocketError {
    fn from(error: ProtocolError) -> Self {
        Self::Protocol(error)
    }
}

pub struct UnixSocketServer {
    listener: UnixListener,
    endpoint: Option<EndpointCleanup>,
}

impl UnixSocketServer {
    pub fn create_owner_only(endpoint: &str, _: u32) -> Result<Self, UnixSocketError> {
        let endpoint = PathBuf::from(endpoint);
        validate_private_parent(&endpoint)?;
        if fs::symlink_metadata(&endpoint).is_ok() {
            return Err(UnixSocketError::Unix(libc::EEXIST));
        }
        let listener = UnixListener::bind(&endpoint).map_err(map_io_error)?;
        fs::set_permissions(&endpoint, fs::Permissions::from_mode(0o600)).map_err(map_io_error)?;
        Ok(Self {
            listener,
            endpoint: Some(EndpointCleanup::new(endpoint)),
        })
    }

    pub fn accept(mut self, timeout_ms: u32) -> Result<UnixSocketConnection, UnixSocketError> {
        self.listener.set_nonblocking(true).map_err(map_io_error)?;
        let deadline = Deadline::new(timeout_ms);
        loop {
            match self.listener.accept() {
                Ok((stream, _)) => {
                    verify_same_user(&stream)?;
                    let endpoint = self.endpoint.take();
                    return Ok(UnixSocketConnection::new(stream, endpoint));
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    deadline.sleep_until_retry()?;
                }
                Err(error) => return Err(map_io_error(error)),
            }
        }
    }
}

impl Drop for UnixSocketServer {
    fn drop(&mut self) {
        if let Some(endpoint) = &self.endpoint {
            endpoint.cleanup();
        }
    }
}

pub struct UnixSocketClient;

impl UnixSocketClient {
    pub fn connect(
        endpoint: &str,
        timeout_ms: u32,
    ) -> Result<UnixSocketConnection, UnixSocketError> {
        let deadline = Deadline::new(timeout_ms);
        loop {
            match UnixStream::connect(endpoint) {
                Ok(stream) => {
                    verify_same_user(&stream)?;
                    return Ok(UnixSocketConnection::new(stream, None));
                }
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::NotFound
                            | std::io::ErrorKind::ConnectionRefused
                            | std::io::ErrorKind::WouldBlock
                    ) =>
                {
                    deadline.sleep_until_retry()?;
                }
                Err(error) => return Err(map_io_error(error)),
            }
        }
    }
}

pub struct UnixSocketConnection {
    stream: RwLock<Option<UnixStream>>,
    read_lock: Mutex<()>,
    read_buffer: Mutex<Vec<u8>>,
    write_lock: Mutex<()>,
    cleanup: Option<EndpointCleanup>,
}

impl UnixSocketConnection {
    fn new(stream: UnixStream, cleanup: Option<EndpointCleanup>) -> Self {
        Self {
            stream: RwLock::new(Some(stream)),
            read_lock: Mutex::new(()),
            read_buffer: Mutex::new(Vec::new()),
            write_lock: Mutex::new(()),
            cleanup,
        }
    }

    pub fn write_frame(&self, frame: &Frame, timeout_ms: u32) -> Result<(), UnixSocketError> {
        let encoded = frame.encode()?;
        self.write_all(&encoded, &Deadline::new(timeout_ms))
    }

    pub fn read_frame(&self, timeout_ms: u32) -> Result<Frame, UnixSocketError> {
        let deadline = Deadline::new(timeout_ms);
        let _read_lock = self
            .read_lock
            .lock()
            .map_err(|_| UnixSocketError::PeerClosed)?;
        let mut buffer = self
            .read_buffer
            .lock()
            .map_err(|_| UnixSocketError::PeerClosed)?;
        let mut stream = self.stream_clone()?;
        loop {
            if buffer.len() >= FrameHeader::ENCODED_LENGTH {
                let frame_length =
                    FrameHeader::frame_length_from_header(&buffer[..FrameHeader::ENCODED_LENGTH])?;
                if buffer.len() >= frame_length {
                    let encoded: Vec<u8> = buffer.drain(..frame_length).collect();
                    return Ok(Frame::decode(&encoded)?);
                }
            }
            if buffer.len() >= MAX_BUFFERED_BYTES {
                return Err(UnixSocketError::Protocol(
                    ProtocolError::BufferedDataTooLarge,
                ));
            }

            stream
                .set_read_timeout(Some(deadline.remaining_duration()?))
                .map_err(map_io_error)?;
            let mut chunk = [0_u8; 8 * 1024];
            match stream.read(&mut chunk) {
                Ok(0) => return Err(UnixSocketError::PeerClosed),
                Ok(read) => buffer.extend_from_slice(&chunk[..read]),
                Err(error) => return Err(map_io_error(error)),
            }
        }
    }

    pub fn wait_for_peer_close(&self) -> Result<(), UnixSocketError> {
        let mut byte = [0_u8; 1];
        match self.read_exact(&mut byte, &Deadline::new(u32::MAX)) {
            Err(UnixSocketError::PeerClosed) => Ok(()),
            Err(error) => Err(error),
            Ok(()) => Err(UnixSocketError::Protocol(ProtocolError::InvalidPayload)),
        }
    }

    #[cfg(test)]
    pub(crate) fn write_test_bytes(
        &self,
        bytes: &[u8],
        timeout_ms: u32,
    ) -> Result<(), UnixSocketError> {
        self.write_all(bytes, &Deadline::new(timeout_ms))
    }

    pub fn close(&self) {
        let stream = self
            .stream
            .write()
            .ok()
            .and_then(|mut stream| stream.take());
        if let Some(stream) = stream {
            let _ = stream.shutdown(std::net::Shutdown::Both);
        }
        if let Some(cleanup) = &self.cleanup {
            cleanup.cleanup();
        }
    }

    fn write_all(&self, bytes: &[u8], deadline: &Deadline) -> Result<(), UnixSocketError> {
        let _write_lock = self
            .write_lock
            .lock()
            .map_err(|_| UnixSocketError::PeerClosed)?;
        let mut stream = self.stream_clone()?;
        let mut offset = 0;
        while offset < bytes.len() {
            stream
                .set_write_timeout(Some(deadline.remaining_duration()?))
                .map_err(map_io_error)?;
            match stream.write(&bytes[offset..]) {
                Ok(0) => return Err(UnixSocketError::PeerClosed),
                Ok(written) => offset += written,
                Err(error) => return Err(map_io_error(error)),
            }
        }
        Ok(())
    }

    fn read_exact(&self, bytes: &mut [u8], deadline: &Deadline) -> Result<(), UnixSocketError> {
        let _read_lock = self
            .read_lock
            .lock()
            .map_err(|_| UnixSocketError::PeerClosed)?;
        let mut stream = self.stream_clone()?;
        let mut offset = 0;
        while offset < bytes.len() {
            stream
                .set_read_timeout(Some(deadline.remaining_duration()?))
                .map_err(map_io_error)?;
            match stream.read(&mut bytes[offset..]) {
                Ok(0) => return Err(UnixSocketError::PeerClosed),
                Ok(read) => offset += read,
                Err(error) => return Err(map_io_error(error)),
            }
        }
        Ok(())
    }

    fn stream_clone(&self) -> Result<UnixStream, UnixSocketError> {
        self.stream
            .read()
            .map_err(|_| UnixSocketError::PeerClosed)?
            .as_ref()
            .ok_or(UnixSocketError::PeerClosed)?
            .try_clone()
            .map_err(map_io_error)
    }
}

impl Drop for UnixSocketConnection {
    fn drop(&mut self) {
        self.close();
    }
}

struct EndpointCleanup {
    socket_path: PathBuf,
    parent: PathBuf,
}

impl EndpointCleanup {
    fn new(socket_path: PathBuf) -> Self {
        Self {
            parent: socket_path.parent().unwrap_or(Path::new("")).to_path_buf(),
            socket_path,
        }
    }

    fn cleanup(&self) {
        let _ = fs::remove_file(&self.socket_path);
        let metadata = match fs::symlink_metadata(&self.parent) {
            Ok(metadata) => metadata,
            Err(_) => return,
        };
        if metadata.is_dir()
            && !metadata.file_type().is_symlink()
            && metadata.permissions().mode() & 0o077 == 0
        {
            let _ = fs::remove_dir_all(&self.parent);
        }
    }
}

fn validate_private_parent(endpoint: &Path) -> Result<(), UnixSocketError> {
    let parent = endpoint
        .parent()
        .ok_or(UnixSocketError::Unix(libc::EINVAL))?;
    let metadata = fs::symlink_metadata(parent).map_err(map_io_error)?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        return Err(UnixSocketError::Unix(libc::EINVAL));
    }
    if metadata.permissions().mode() & 0o077 != 0 {
        return Err(UnixSocketError::Unix(libc::EACCES));
    }
    Ok(())
}

fn verify_same_user(stream: &UnixStream) -> Result<(), UnixSocketError> {
    let mut credentials = libc::ucred {
        pid: 0,
        uid: 0,
        gid: 0,
    };
    let mut length = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    let result = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut credentials as *mut libc::ucred).cast(),
            &mut length,
        )
    };
    if result != 0 || length != std::mem::size_of::<libc::ucred>() as libc::socklen_t {
        return Err(UnixSocketError::Unix(last_errno()));
    }
    if credentials.uid != unsafe { libc::geteuid() } {
        return Err(UnixSocketError::Unix(libc::EACCES));
    }
    Ok(())
}

struct Deadline {
    deadline: Instant,
}

impl Deadline {
    fn new(timeout_ms: u32) -> Self {
        Self {
            deadline: Instant::now() + Duration::from_millis(u64::from(timeout_ms)),
        }
    }

    fn remaining_duration(&self) -> Result<Duration, UnixSocketError> {
        self.deadline
            .checked_duration_since(Instant::now())
            .filter(|remaining| !remaining.is_zero())
            .ok_or(UnixSocketError::TimedOut)
    }

    fn sleep_until_retry(&self) -> Result<(), UnixSocketError> {
        let remaining = self.remaining_duration()?;
        std::thread::sleep(remaining.min(Duration::from_millis(5)));
        Ok(())
    }
}

fn map_io_error(error: std::io::Error) -> UnixSocketError {
    match error.kind() {
        std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock => UnixSocketError::TimedOut,
        std::io::ErrorKind::BrokenPipe
        | std::io::ErrorKind::ConnectionAborted
        | std::io::ErrorKind::ConnectionReset
        | std::io::ErrorKind::NotConnected
        | std::io::ErrorKind::UnexpectedEof => UnixSocketError::PeerClosed,
        _ => UnixSocketError::Unix(error.raw_os_error().unwrap_or(libc::EIO)),
    }
}

fn last_errno() -> i32 {
    std::io::Error::last_os_error()
        .raw_os_error()
        .unwrap_or(libc::EIO)
}

#[cfg(test)]
mod tests {
    use super::{UnixSocketClient, UnixSocketError, UnixSocketServer};
    use crate::{FeatureSet, RequestIdentifiers, execute_script_frame};
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::time::{Duration, SystemTime, UNIX_EPOCH};

    fn endpoint() -> String {
        let suffix = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock")
            .as_nanos();
        let parent = std::env::temp_dir().join(format!("devolutions-pwsh-test-{suffix}"));
        fs::create_dir(&parent).expect("private directory");
        fs::set_permissions(&parent, fs::Permissions::from_mode(0o700)).expect("private mode");
        parent.join("worker.sock").to_string_lossy().into_owned()
    }

    #[test]
    fn creates_owner_only_socket_and_authenticates_same_user() {
        let endpoint = endpoint();
        let server = UnixSocketServer::create_owner_only(&endpoint, 4096).expect("server");
        assert_eq!(
            fs::metadata(&endpoint)
                .expect("socket metadata")
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        let client_endpoint = endpoint.clone();
        let client = std::thread::spawn(move || UnixSocketClient::connect(&client_endpoint, 1_000));
        let server_connection = server.accept(1_000).expect("same user accepted");
        let client_connection = client.join().expect("client thread").expect("client");
        drop(client_connection);
        drop(server_connection);
        assert!(!std::path::Path::new(&endpoint).exists());
        assert!(
            !std::path::Path::new(&endpoint)
                .parent()
                .expect("parent")
                .exists()
        );
    }

    #[test]
    fn cleanup_removes_worker_private_state() {
        let endpoint = endpoint();
        let parent = std::path::Path::new(&endpoint)
            .parent()
            .expect("parent")
            .to_path_buf();
        let server = UnixSocketServer::create_owner_only(&endpoint, 4096).expect("server");
        let client_endpoint = endpoint.clone();
        let client = std::thread::spawn(move || UnixSocketClient::connect(&client_endpoint, 1_000));
        let server_connection = server.accept(1_000).expect("same user accepted");
        let client_connection = client.join().expect("client thread").expect("client");
        fs::write(parent.join("worker-state"), "private state").expect("worker state");
        drop(client_connection);
        drop(server_connection);
        assert!(!parent.exists());
    }

    #[test]
    fn complete_frame_deadline_applies_to_partial_reads() {
        let endpoint = endpoint();
        let server = UnixSocketServer::create_owner_only(&endpoint, 4096).expect("server");
        let client_endpoint = endpoint.clone();
        let client = std::thread::spawn(move || {
            let client = UnixSocketClient::connect(&client_endpoint, 1_000).expect("client");
            let frame = execute_script_frame(
                FeatureSet::SUPPORTED,
                RequestIdentifiers::new(1, 1, 1),
                "partial",
            )
            .expect("frame")
            .encode()
            .expect("bytes");
            for byte in frame {
                if client.write_test_bytes(&[byte], 1_000).is_err() {
                    break;
                }
                std::thread::sleep(Duration::from_millis(5));
            }
        });
        let connection = server.accept(1_000).expect("accept");
        assert_eq!(connection.read_frame(20), Err(UnixSocketError::TimedOut));
        client.join().expect("client");
    }

    #[test]
    fn partial_frame_is_preserved_across_deadlines() {
        let endpoint = endpoint();
        let server = UnixSocketServer::create_owner_only(&endpoint, 4096).expect("server");
        let client_endpoint = endpoint.clone();
        let client = std::thread::spawn(move || {
            let client = UnixSocketClient::connect(&client_endpoint, 1_000).expect("client");
            let frame = execute_script_frame(
                FeatureSet::SUPPORTED,
                RequestIdentifiers::new(1, 1, 1),
                "preserved",
            )
            .expect("frame")
            .encode()
            .expect("bytes");
            client
                .write_test_bytes(&frame[..10], 1_000)
                .expect("partial frame");
            std::thread::sleep(Duration::from_millis(30));
            client
                .write_test_bytes(&frame[10..], 1_000)
                .expect("remaining frame");
        });
        let connection = server.accept(1_000).expect("accept");
        assert_eq!(connection.read_frame(20), Err(UnixSocketError::TimedOut));
        assert_eq!(
            connection
                .read_frame(1_000)
                .expect("completed frame")
                .script_request_payload()
                .expect("script payload"),
            "preserved"
        );
        client.join().expect("client");
    }
}
