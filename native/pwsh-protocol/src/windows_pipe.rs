use crate::{Frame, FrameHeader, ProtocolError};
use std::ffi::c_void;
use std::os::windows::ffi::OsStrExt;
use std::ptr;
use std::sync::RwLock;
use std::time::{Duration, Instant};

const INVALID_HANDLE_VALUE: isize = -1;
const GENERIC_READ: u32 = 0x8000_0000;
const GENERIC_WRITE: u32 = 0x4000_0000;
const OPEN_EXISTING: u32 = 3;
const FILE_FLAG_OVERLAPPED: u32 = 0x4000_0000;
const PIPE_ACCESS_DUPLEX: u32 = 0x0000_0003;
const PIPE_TYPE_BYTE: u32 = 0x0000_0000;
const PIPE_READMODE_BYTE: u32 = 0x0000_0000;
const PIPE_WAIT: u32 = 0x0000_0000;
const ERROR_BROKEN_PIPE: u32 = 109;
const ERROR_NO_DATA: u32 = 232;
const ERROR_PIPE_NOT_CONNECTED: u32 = 233;
const ERROR_IO_PENDING: u32 = 997;
const ERROR_OPERATION_ABORTED: u32 = 995;
const ERROR_PIPE_BUSY: u32 = 231;
const ERROR_PIPE_CONNECTED: u32 = 535;
const ERROR_SEM_TIMEOUT: u32 = 121;
const INFINITE: u32 = u32::MAX;
const WAIT_OBJECT_0: u32 = 0;
const WAIT_TIMEOUT: u32 = 258;
const SDDL_REVISION_1: u32 = 1;

#[repr(C)]
struct SecurityAttributes {
    length: u32,
    security_descriptor: *mut c_void,
    inherit_handle: i32,
}

#[repr(C)]
struct Overlapped {
    internal: usize,
    internal_high: usize,
    offset: u32,
    offset_high: u32,
    event: isize,
}

#[derive(Debug, Eq, PartialEq)]
pub enum PipeError {
    PeerClosed,
    Protocol(ProtocolError),
    TimedOut,
    Windows(u32),
}

impl From<ProtocolError> for PipeError {
    fn from(error: ProtocolError) -> Self {
        Self::Protocol(error)
    }
}

pub struct NamedPipeServer {
    handle: isize,
}

impl NamedPipeServer {
    pub fn create_owner_only(endpoint: &str, buffer_size: u32) -> Result<Self, PipeError> {
        let security_descriptor = owner_only_security_descriptor()?;
        let attributes = SecurityAttributes {
            length: std::mem::size_of::<SecurityAttributes>() as u32,
            security_descriptor,
            inherit_handle: 0,
        };
        let endpoint = to_wide(endpoint);
        let handle = unsafe {
            CreateNamedPipeW(
                endpoint.as_ptr(),
                PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED,
                PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
                1,
                buffer_size,
                buffer_size,
                0,
                &attributes,
            )
        };
        unsafe {
            LocalFree(security_descriptor as isize);
        }
        if handle == INVALID_HANDLE_VALUE {
            return Err(PipeError::Windows(unsafe { GetLastError() }));
        }

        Ok(Self { handle })
    }

    pub fn accept(self, timeout_ms: u32) -> Result<PipeConnection, PipeError> {
        let event = unsafe { CreateEventW(ptr::null(), 1, 0, ptr::null()) };
        if event == 0 {
            return Err(PipeError::Windows(unsafe { GetLastError() }));
        }
        let mut overlapped = Overlapped {
            internal: 0,
            internal_high: 0,
            offset: 0,
            offset_high: 0,
            event,
        };
        let connected = unsafe { ConnectNamedPipe(self.handle, &mut overlapped) };
        let result = if connected != 0 {
            Ok(())
        } else {
            match unsafe { GetLastError() } {
                ERROR_PIPE_CONNECTED => Ok(()),
                ERROR_IO_PENDING => unsafe {
                    wait_for_overlapped(self.handle, &mut overlapped, timeout_ms)
                },
                error => Err(PipeError::Windows(error)),
            }
        };
        unsafe {
            CloseHandle(event);
        }
        result?;

        let handle = self.handle;
        std::mem::forget(self);
        Ok(PipeConnection {
            state: RwLock::new(PipeState {
                handle,
                server: true,
            }),
            close_lock: RwLock::new(()),
        })
    }
}

impl Drop for NamedPipeServer {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.handle);
        }
    }
}

pub struct NamedPipeClient;

impl NamedPipeClient {
    pub fn connect(endpoint: &str, timeout_ms: u32) -> Result<PipeConnection, PipeError> {
        let endpoint = to_wide(endpoint);
        let handle = unsafe {
            CreateFileW(
                endpoint.as_ptr(),
                GENERIC_READ | GENERIC_WRITE,
                0,
                ptr::null(),
                OPEN_EXISTING,
                FILE_FLAG_OVERLAPPED,
                0,
            )
        };
        if handle != INVALID_HANDLE_VALUE {
            return Ok(PipeConnection {
                state: RwLock::new(PipeState {
                    handle,
                    server: false,
                }),
                close_lock: RwLock::new(()),
            });
        }

        let error = unsafe { GetLastError() };
        if error != ERROR_PIPE_BUSY {
            return Err(PipeError::Windows(error));
        }
        if unsafe { WaitNamedPipeW(endpoint.as_ptr(), timeout_ms) } == 0 {
            return Err(match unsafe { GetLastError() } {
                WAIT_TIMEOUT | ERROR_SEM_TIMEOUT => PipeError::TimedOut,
                error => PipeError::Windows(error),
            });
        }

        let handle = unsafe {
            CreateFileW(
                endpoint.as_ptr(),
                GENERIC_READ | GENERIC_WRITE,
                0,
                ptr::null(),
                OPEN_EXISTING,
                FILE_FLAG_OVERLAPPED,
                0,
            )
        };
        if handle == INVALID_HANDLE_VALUE {
            return Err(PipeError::Windows(unsafe { GetLastError() }));
        }

        Ok(PipeConnection {
            state: RwLock::new(PipeState {
                handle,
                server: false,
            }),
            close_lock: RwLock::new(()),
        })
    }
}

pub struct PipeConnection {
    state: RwLock<PipeState>,
    close_lock: RwLock<()>,
}

struct PipeState {
    handle: isize,
    server: bool,
}

impl PipeConnection {
    pub fn write_frame(&self, frame: &Frame, timeout_ms: u32) -> Result<(), PipeError> {
        let encoded = frame.encode()?;
        self.write_all(&encoded, &IoDeadline::new(timeout_ms))
    }

    pub fn read_frame(&self, timeout_ms: u32) -> Result<Frame, PipeError> {
        let deadline = IoDeadline::new(timeout_ms);
        let mut header = [0_u8; FrameHeader::ENCODED_LENGTH];
        self.read_exact(&mut header, &deadline)?;
        let frame_length = FrameHeader::frame_length_from_header(&header)?;
        let mut encoded = Vec::with_capacity(frame_length);
        encoded.extend_from_slice(&header);
        encoded.resize(frame_length, 0);
        self.read_exact(&mut encoded[FrameHeader::ENCODED_LENGTH..], &deadline)?;
        Ok(Frame::decode(&encoded)?)
    }

    pub fn wait_for_peer_close(&self) -> Result<(), PipeError> {
        let mut byte = [0_u8; 1];
        match self.read_exact(&mut byte, &IoDeadline::new(u32::MAX)) {
            Err(PipeError::PeerClosed) => Ok(()),
            Err(error) => Err(error),
            Ok(()) => Err(PipeError::Protocol(ProtocolError::InvalidPayload)),
        }
    }

    #[cfg(test)]
    pub(crate) fn write_test_bytes(&self, bytes: &[u8], timeout_ms: u32) -> Result<(), PipeError> {
        self.write_all(bytes, &IoDeadline::new(timeout_ms))
    }

    pub fn close(&self) {
        let Ok(_close_lock) = self.close_lock.write() else {
            return;
        };
        let handle = match self.state.read() {
            Ok(state) => state.handle,
            Err(_) => return,
        };
        if handle != INVALID_HANDLE_VALUE {
            unsafe {
                CancelIoEx(handle, ptr::null_mut());
            }
        }

        let Ok(mut state) = self.state.write() else {
            return;
        };
        if state.handle == INVALID_HANDLE_VALUE {
            return;
        }
        unsafe {
            if state.server {
                DisconnectNamedPipe(state.handle);
            }
            CloseHandle(state.handle);
        }
        state.handle = INVALID_HANDLE_VALUE;
    }

    fn write_all(&self, bytes: &[u8], deadline: &IoDeadline) -> Result<(), PipeError> {
        let mut offset = 0;
        while offset < bytes.len() {
            let written = self.write_once(&bytes[offset..], deadline.remaining()?)?;
            if written == 0 {
                return Err(PipeError::PeerClosed);
            }
            offset += written;
        }
        Ok(())
    }

    fn read_exact(&self, bytes: &mut [u8], deadline: &IoDeadline) -> Result<(), PipeError> {
        let mut offset = 0;
        while offset < bytes.len() {
            let read = self.read_once(&mut bytes[offset..], deadline.remaining()?)?;
            if read == 0 {
                return Err(PipeError::PeerClosed);
            }
            offset += read;
        }
        Ok(())
    }

    fn write_once(&self, bytes: &[u8], timeout_ms: u32) -> Result<usize, PipeError> {
        unsafe {
            self.io_once(
                |handle, transferred, overlapped| {
                    WriteFile(
                        handle,
                        bytes.as_ptr().cast(),
                        bytes.len() as u32,
                        transferred,
                        overlapped,
                    )
                },
                timeout_ms,
            )
        }
    }

    fn read_once(&self, bytes: &mut [u8], timeout_ms: u32) -> Result<usize, PipeError> {
        unsafe {
            self.io_once(
                |handle, transferred, overlapped| {
                    ReadFile(
                        handle,
                        bytes.as_mut_ptr().cast(),
                        bytes.len() as u32,
                        transferred,
                        overlapped,
                    )
                },
                timeout_ms,
            )
        }
    }

    unsafe fn io_once(
        &self,
        operation: impl FnOnce(isize, *mut u32, *mut Overlapped) -> i32,
        timeout_ms: u32,
    ) -> Result<usize, PipeError> {
        let state = self.state.read().map_err(|_| PipeError::PeerClosed)?;
        if state.handle == INVALID_HANDLE_VALUE {
            return Err(PipeError::PeerClosed);
        }
        let handle = state.handle;
        let event = unsafe { CreateEventW(ptr::null(), 1, 0, ptr::null()) };
        if event == 0 {
            return Err(PipeError::Windows(unsafe { GetLastError() }));
        }
        let mut overlapped = Overlapped {
            internal: 0,
            internal_high: 0,
            offset: 0,
            offset_high: 0,
            event,
        };
        let mut transferred = 0_u32;
        let completed = operation(handle, &mut transferred, &mut overlapped);
        let result = if completed != 0 {
            Ok(transferred as usize)
        } else {
            match unsafe { GetLastError() } {
                ERROR_IO_PENDING => {
                    unsafe { wait_for_overlapped(handle, &mut overlapped, timeout_ms) }?;
                    let completed = unsafe {
                        GetOverlappedResult(handle, &mut overlapped, &mut transferred, 0)
                    };
                    if completed == 0 {
                        Err(map_io_error(unsafe { GetLastError() }))
                    } else {
                        Ok(transferred as usize)
                    }
                }
                error => Err(map_io_error(error)),
            }
        };
        unsafe {
            CloseHandle(event);
        }
        result
    }
}

impl Drop for PipeConnection {
    fn drop(&mut self) {
        self.close();
    }
}

struct IoDeadline {
    deadline: Instant,
}

impl IoDeadline {
    fn new(timeout_ms: u32) -> Self {
        Self {
            deadline: Instant::now() + Duration::from_millis(timeout_ms as u64),
        }
    }

    fn remaining(&self) -> Result<u32, PipeError> {
        let remaining = self
            .deadline
            .checked_duration_since(Instant::now())
            .ok_or(PipeError::TimedOut)?;
        u32::try_from(remaining.as_millis().max(1)).map_err(|_| PipeError::TimedOut)
    }
}

unsafe fn wait_for_overlapped(
    handle: isize,
    overlapped: &mut Overlapped,
    timeout_ms: u32,
) -> Result<(), PipeError> {
    match unsafe { WaitForSingleObject(overlapped.event, timeout_ms) } {
        WAIT_OBJECT_0 => Ok(()),
        WAIT_TIMEOUT => {
            unsafe {
                CancelIoEx(handle, overlapped);
            }
            // Cancellation is asynchronous. Wait for its completion before
            // dropping the event and stack-backed OVERLAPPED structure.
            match unsafe { WaitForSingleObject(overlapped.event, INFINITE) } {
                WAIT_OBJECT_0 => Err(PipeError::TimedOut),
                _ => Err(PipeError::Windows(unsafe { GetLastError() })),
            }
        }
        _ => Err(PipeError::Windows(unsafe { GetLastError() })),
    }
}

fn owner_only_security_descriptor() -> Result<*mut c_void, PipeError> {
    let sddl = to_wide("D:P(A;;GA;;;OW)");
    let mut security_descriptor = ptr::null_mut();
    let converted = unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl.as_ptr(),
            SDDL_REVISION_1,
            &mut security_descriptor,
            ptr::null_mut(),
        )
    };
    if converted == 0 {
        return Err(PipeError::Windows(unsafe { GetLastError() }));
    }
    Ok(security_descriptor)
}

fn map_io_error(error: u32) -> PipeError {
    if matches!(
        error,
        ERROR_BROKEN_PIPE | ERROR_NO_DATA | ERROR_PIPE_NOT_CONNECTED | ERROR_OPERATION_ABORTED
    ) {
        PipeError::PeerClosed
    } else {
        PipeError::Windows(error)
    }
}

fn to_wide(value: impl AsRef<std::ffi::OsStr>) -> Vec<u16> {
    value.as_ref().encode_wide().chain(Some(0)).collect()
}

#[cfg(test)]
mod tests {
    use super::{NamedPipeClient, NamedPipeServer, PipeError};
    use crate::{FeatureSet, RequestIdentifiers, execute_script_frame};
    use std::sync::Arc;
    use std::sync::atomic::{AtomicU32, Ordering};
    use std::time::Duration;

    static NEXT_ENDPOINT: AtomicU32 = AtomicU32::new(0);

    fn endpoint() -> String {
        format!(
            r"\\.\pipe\devolutions-pwsh-protocol-pipe-test-{}-{}",
            std::process::id(),
            NEXT_ENDPOINT.fetch_add(1, Ordering::Relaxed)
        )
    }

    fn server(endpoint: &str) -> NamedPipeServer {
        NamedPipeServer::create_owner_only(endpoint, 4096).expect("test pipe must be created")
    }

    #[test]
    fn read_frame_timeout_cancels_the_pending_overlapped_io() {
        let endpoint = endpoint();
        let server = server(&endpoint);
        let client_endpoint = endpoint.clone();
        let client = std::thread::spawn(move || {
            let pipe =
                NamedPipeClient::connect(&client_endpoint, 1_000).expect("client must connect");
            std::thread::sleep(Duration::from_millis(100));
            pipe.wait_for_peer_close()
        });

        let pipe = server.accept(1_000).expect("server must accept");
        assert_eq!(pipe.read_frame(20), Err(PipeError::TimedOut));
        drop(pipe);
        assert_eq!(client.join().expect("client must finish"), Ok(()));
    }

    #[test]
    fn close_interrupts_an_indefinite_read_without_reusing_the_handle() {
        let endpoint = endpoint();
        let server = server(&endpoint);
        let client_endpoint = endpoint.clone();
        let client = std::thread::spawn(move || {
            let pipe =
                NamedPipeClient::connect(&client_endpoint, 1_000).expect("client must connect");
            pipe.wait_for_peer_close()
        });

        let pipe = Arc::new(server.accept(1_000).expect("server must accept"));
        let reader = {
            let pipe = Arc::clone(&pipe);
            std::thread::spawn(move || pipe.read_frame(u32::MAX))
        };
        std::thread::sleep(Duration::from_millis(20));
        pipe.close();

        assert_eq!(
            reader.join().expect("reader must finish"),
            Err(PipeError::PeerClosed)
        );
        assert_eq!(client.join().expect("client must finish"), Ok(()));
    }

    #[test]
    fn frame_deadline_covers_the_complete_frame_not_each_partial_read() {
        let endpoint = endpoint();
        let server = server(&endpoint);
        let client_endpoint = endpoint.clone();
        let client = std::thread::spawn(move || {
            let pipe =
                NamedPipeClient::connect(&client_endpoint, 1_000).expect("client must connect");
            let frame = execute_script_frame(
                FeatureSet::SUPPORTED,
                RequestIdentifiers::new(1, 1, 1),
                "partial",
            )
            .expect("frame must encode")
            .encode()
            .expect("frame bytes");
            for byte in frame {
                if pipe.write_test_bytes(&[byte], 1_000).is_err() {
                    break;
                }
                std::thread::sleep(Duration::from_millis(5));
            }
            drop(pipe);
        });

        let pipe = server.accept(1_000).expect("server must accept");
        assert_eq!(pipe.read_frame(20), Err(PipeError::TimedOut));
        client.join().expect("client must finish");
    }
}

#[link(name = "advapi32")]
unsafe extern "system" {
    fn ConvertStringSecurityDescriptorToSecurityDescriptorW(
        string_security_descriptor: *const u16,
        string_sd_revision: u32,
        security_descriptor: *mut *mut c_void,
        security_descriptor_size: *mut u32,
    ) -> i32;
}

#[link(name = "kernel32")]
unsafe extern "system" {
    fn CancelIoEx(file: isize, overlapped: *mut Overlapped) -> i32;
    fn CloseHandle(handle: isize) -> i32;
    fn ConnectNamedPipe(named_pipe: isize, overlapped: *mut Overlapped) -> i32;
    fn CreateEventW(
        attributes: *const c_void,
        manual_reset: i32,
        initial_state: i32,
        name: *const u16,
    ) -> isize;
    fn CreateFileW(
        file_name: *const u16,
        desired_access: u32,
        share_mode: u32,
        security_attributes: *const c_void,
        creation_disposition: u32,
        flags_and_attributes: u32,
        template_file: isize,
    ) -> isize;
    fn CreateNamedPipeW(
        name: *const u16,
        open_mode: u32,
        pipe_mode: u32,
        max_instances: u32,
        out_buffer_size: u32,
        in_buffer_size: u32,
        default_timeout: u32,
        security_attributes: *const SecurityAttributes,
    ) -> isize;
    fn DisconnectNamedPipe(named_pipe: isize) -> i32;
    fn GetLastError() -> u32;
    fn GetOverlappedResult(
        file: isize,
        overlapped: *mut Overlapped,
        bytes_transferred: *mut u32,
        wait: i32,
    ) -> i32;
    fn LocalFree(memory: isize) -> isize;
    fn ReadFile(
        file: isize,
        buffer: *mut c_void,
        bytes_to_read: u32,
        bytes_read: *mut u32,
        overlapped: *mut Overlapped,
    ) -> i32;
    fn WaitForSingleObject(handle: isize, milliseconds: u32) -> u32;
    fn WaitNamedPipeW(name: *const u16, timeout: u32) -> i32;
    fn WriteFile(
        file: isize,
        buffer: *const c_void,
        bytes_to_write: u32,
        bytes_written: *mut u32,
        overlapped: *mut Overlapped,
    ) -> i32;
}
