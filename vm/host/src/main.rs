//! `vm/host/src/main.rs`
//!
//! virtio-vsock Wayland Protocol Host Bridge for Niri on macOS (aarch64-apple-darwin).
//! Bridges guest Wayland client connections arriving over vsock to Niri's host Wayland socket.
//! Handles out-of-band file descriptor passing (SCM_RIGHTS), bounds checking, and framing.

#[path = "../../proto/mod.rs"]
mod proto;

use clap::Parser;
use proto::{NiriIpcPacketHeader, NiriMsgType, NIRI_VSOCK_WAYLAND_PORT};
use std::fs::File;
use std::io::{self, Read, Write};
use std::os::unix::io::{AsRawFd, FromRawFd, IntoRawFd, RawFd};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::Arc;
use std::thread;
use tracing::{debug, error, info, warn};

#[derive(Parser, Debug)]
#[command(name = "niri-vsock-host")]
#[command(about = "virtio-vsock to Wayland UNIX socket bridge for Niri on macOS")]
struct Args {
    /// Path to Niri's host Wayland socket ($XDG_RUNTIME_DIR/wayland-1 or wayland-0)
    #[arg(short = 'w', long = "wayland-socket")]
    wayland_socket: Option<PathBuf>,

    /// Path to listen for hypervisor / vsock connections
    #[arg(short = 'l', long = "listen-socket", default_value = "/tmp/niri-vsock-1024.sock")]
    listen_socket: PathBuf,

    /// Directory shared with the VM for zero-copy SHM
    #[arg(short = 's', long = "shared-dir", default_value = "/tmp/niri-shm")]
    shared_dir: PathBuf,

    /// virtio-vsock port
    #[arg(short = 'p', long = "port", default_value_t = NIRI_VSOCK_WAYLAND_PORT)]
    port: u32,
}

/// Helper to resolve Niri's Wayland socket path on macOS
fn resolve_niri_socket(override_path: Option<PathBuf>) -> io::Result<PathBuf> {
    if let Some(p) = override_path {
        if p.exists() {
            return Ok(p);
        }
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!("Specified Wayland socket does not exist: {}", p.display()),
        ));
    }

    if let Ok(runtime_dir) = std::env::var("XDG_RUNTIME_DIR") {
        let p1 = Path::new(&runtime_dir).join("wayland-1");
        if p1.exists() {
            return Ok(p1);
        }
        let p0 = Path::new(&runtime_dir).join("wayland-0");
        if p0.exists() {
            return Ok(p0);
        }
    }

    let temp_sock = std::env::temp_dir().join("niri-wayland.sock");
    if temp_sock.exists() {
        return Ok(temp_sock);
    }

    // Default fallback
    let default_path = std::env::temp_dir().join("wayland-1");
    Ok(default_path)
}

/// Sends raw data along with an optional file descriptor via sendmsg (SCM_RIGHTS)
fn send_with_fd(sock_fd: RawFd, data: &[u8], fd: Option<RawFd>) -> io::Result<usize> {
    // SAFETY: iov and msghdr point to valid memory buffers with matching lengths.
    // When an FD is provided, cmsg_buffer is aligned and allocated with CMSG_SPACE for a single int FD.
    unsafe {
        let mut iov = libc::iovec {
            iov_base: data.as_ptr() as *mut libc::c_void,
            iov_len: data.len(),
        };

        let mut msg: libc::msghdr = std::mem::zeroed();
        msg.msg_iov = &mut iov;
        msg.msg_iovlen = 1;

        let mut cmsg_buffer = [0u8; unsafe { libc::CMSG_SPACE(std::mem::size_of::<libc::c_int>() as u32) } as usize];

        if let Some(pass_fd) = fd {
            msg.msg_control = cmsg_buffer.as_mut_ptr() as *mut libc::c_void;
            msg.msg_controllen = cmsg_buffer.len() as _;

            let cmsg = libc::CMSG_FIRSTHDR(&msg);
            if !cmsg.is_null() {
                (*cmsg).cmsg_level = libc::SOL_SOCKET;
                (*cmsg).cmsg_type = libc::SCM_RIGHTS;
                (*cmsg).cmsg_len = libc::CMSG_LEN(std::mem::size_of::<libc::c_int>() as u32) as _;
                let data_ptr = libc::CMSG_DATA(cmsg) as *mut libc::c_int;
                *data_ptr = pass_fd;
            }
        }

        let res = libc::sendmsg(sock_fd, &msg, 0);
        if res < 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(res as usize)
        }
    }
}

/// Receives raw data and any ancillary file descriptors via recvmsg (SCM_RIGHTS)
fn recv_with_fd(sock_fd: RawFd, buf: &mut [u8]) -> io::Result<(usize, Option<RawFd>)> {
    // SAFETY: buf points to valid writable memory. cmsg_buffer is allocated with CMSG_SPACE
    // for ancillary socket data and safely navigated using POSIX CMSG_FIRSTHDR/CMSG_NXTHDR macros.
    unsafe {
        let mut iov = libc::iovec {
            iov_base: buf.as_mut_ptr() as *mut libc::c_void,
            iov_len: buf.len(),
        };

        let mut cmsg_buffer = [0u8; unsafe { libc::CMSG_SPACE(std::mem::size_of::<libc::c_int>() as u32) } as usize];
        let mut msg: libc::msghdr = std::mem::zeroed();
        msg.msg_iov = &mut iov;
        msg.msg_iovlen = 1;
        msg.msg_control = cmsg_buffer.as_mut_ptr() as *mut libc::c_void;
        msg.msg_controllen = cmsg_buffer.len() as _;

        let res = libc::recvmsg(sock_fd, &mut msg, 0);
        if res < 0 {
            return Err(io::Error::last_os_error());
        }
        let bytes_read = res as usize;

        let mut received_fd = None;
        let mut cmsg = libc::CMSG_FIRSTHDR(&msg);
        while !cmsg.is_null() {
            if (*cmsg).cmsg_level == libc::SOL_SOCKET && (*cmsg).cmsg_type == libc::SCM_RIGHTS {
                let data_ptr = libc::CMSG_DATA(cmsg) as *const libc::c_int;
                received_fd = Some(*data_ptr);
                break;
            }
            cmsg = libc::CMSG_NXTHDR(&msg, cmsg);
        }

        Ok((bytes_read, received_fd))
    }
}

/// Handles an active client session bridged between vsock stream and Niri's Wayland socket
fn handle_session(
    mut vsock_stream: UnixStream,
    niri_socket_path: PathBuf,
    shared_dir: PathBuf,
    session_id: u32,
) -> io::Result<()> {
    info!(session_id, "Connecting to Niri Wayland socket: {}", niri_socket_path.display());
    let niri_stream = UnixStream::connect(&niri_socket_path)?;
    let niri_fd = niri_stream.as_raw_fd();

    let running = Arc::new(AtomicBool::new(true));
    let seq_counter = Arc::new(AtomicU32::new(1));

    // Thread 1: vsock stream -> Niri Wayland socket
    let running_in = running.clone();
    let shared_dir_clone = shared_dir.clone();
    let mut vsock_reader = vsock_stream.try_clone()?;
    let t_in = thread::spawn(move || -> io::Result<()> {
        let mut header_buf = [0u8; NiriIpcPacketHeader::SIZE];

        while running_in.load(Ordering::Relaxed) {
            // Read packet header
            match vsock_reader.read_exact(&mut header_buf) {
                Ok(()) => {}
                Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => break,
                Err(e) => return Err(e),
            }

            // SAFETY: header_buf is a 16-byte array matching NiriIpcPacketHeader #[repr(C, packed)]
            // containing only primitive integers; .validate() immediately validates fields.
            let header: NiriIpcPacketHeader = unsafe { std::mem::transmute_copy(&header_buf) };
            let msg_type = match header.validate() {
                Ok(t) => t,
                Err(e) => {
                    warn!(session_id, "Discarding malformed packet: {e}");
                    break;
                }
            };

            let payload_len = header.payload_size as usize;
            let mut payload = vec![0u8; payload_len];
            vsock_reader.read_exact(&mut payload)?;

            match msg_type {
                NiriMsgType::RawWire => {
                    // Forward directly to Niri Wayland socket
                    niri_fd_write_all(niri_fd, &payload)?;
                }
                NiriMsgType::ShmPoolCreate => {
                    // Create local host FD and pass via SCM_RIGHTS to Niri
                    let fd = create_host_shm_fd(&shared_dir_clone, &payload)?;
                    debug!(session_id, "Reconstructed host SHM FD: {fd}");
                    send_with_fd(niri_fd, &[], Some(fd))?;
                    // SAFETY: fd is an open descriptor created by create_host_shm_fd and successfully sent.
                    unsafe { libc::close(fd) };
                }
                NiriMsgType::FrameCommit => {
                    debug!(session_id, "Received FrameCommit descriptor from guest");
                }
                NiriMsgType::ControlPing => {
                    // Respond with Pong
                    let pong = NiriIpcPacketHeader::new(NiriMsgType::ControlPong, 0, header.sequence_id);
                    let _ = pong.write_to(&mut vsock_reader);
                }
                NiriMsgType::ControlPong => {}
            }
        }
        running_in.store(false, Ordering::Relaxed);
        Ok(())
    });

    // Thread 2: Niri Wayland socket -> vsock stream
    let running_out = running.clone();
    let t_out = thread::spawn(move || -> io::Result<()> {
        let mut buf = vec![0u8; 65536];

        while running_out.load(Ordering::Relaxed) {
            let (n, maybe_fd) = match recv_with_fd(niri_fd, &mut buf) {
                Ok((bytes, fd)) => {
                    if bytes == 0 {
                        break;
                    }
                    (bytes, fd)
                }
                Err(e) => {
                    if running_out.load(Ordering::Relaxed) {
                        warn!(session_id, "Error reading from Niri socket: {e}");
                    }
                    break;
                }
            };

            if let Some(fd) = maybe_fd {
                // Out-of-band FD from host to guest (e.g. XKB keymap)
                debug!(session_id, "Intercepted host FD ({fd}) destined for guest");
                let fd_data = read_fd_content(fd)?;
                // SAFETY: fd is an intercepted descriptor from SCM_RIGHTS; closed here after read_fd_content completes.
                unsafe { libc::close(fd) };

                let seq = seq_counter.fetch_add(1, Ordering::Relaxed);
                let header = NiriIpcPacketHeader::new(
                    NiriMsgType::ShmPoolCreate,
                    fd_data.len() as u32,
                    seq,
                );
                header.write_to(&mut vsock_stream)?;
                vsock_stream.write_all(&fd_data)?;
                vsock_stream.flush()?;
            } else {
                // Raw Wayland wire message
                let seq = seq_counter.fetch_add(1, Ordering::Relaxed);
                let header = NiriIpcPacketHeader::new(NiriMsgType::RawWire, n as u32, seq);
                header.write_to(&mut vsock_stream)?;
                vsock_stream.write_all(&buf[..n])?;
                vsock_stream.flush()?;
            }
        }
        running_out.store(false, Ordering::Relaxed);
        Ok(())
    });

    let _ = t_in.join();
    let _ = t_out.join();

    info!(session_id, "Session terminated cleanly");
    Ok(())
}

fn niri_fd_write_all(fd: RawFd, mut data: &[u8]) -> io::Result<()> {
    while !data.is_empty() {
        // SAFETY: data points to valid memory buffer of data.len() bytes; libc::write safely handles partial writes.
        let written = unsafe { libc::write(fd, data.as_ptr() as *const libc::c_void, data.len()) };
        if written <= 0 {
            return Err(io::Error::last_os_error());
        }
        data = &data[written as usize..];
    }
    Ok(())
}

fn read_fd_content(fd: RawFd) -> io::Result<Vec<u8>> {
    // SAFETY: fd is an open, valid file descriptor intercepted from host SCM_RIGHTS.
    // File takes ownership temporarily; std::mem::forget prevents double close upon drop.
    let mut file = unsafe { File::from_raw_fd(fd) };
    let mut data = Vec::new();
    file.read_to_end(&mut data)?;
    // Prevent double close since from_raw_fd takes ownership
    std::mem::forget(file);
    Ok(data)
}

fn create_host_shm_fd(shared_dir: &Path, payload: &[u8]) -> io::Result<RawFd> {
    // If payload contains shared filename string, open directly in shared_dir with path traversal defense
    if !payload.is_empty() && payload[0] == b'/' {
        let path_str = String::from_utf8_lossy(payload).trim_end_matches('\0').to_string();
        let rel_path = Path::new(path_str.trim_start_matches('/'));
        // Reject path traversal components
        if !rel_path.components().any(|c| matches!(c, std::path::Component::ParentDir)) {
            let target = shared_dir.join(rel_path);
            if let Ok(canon_target) = target.canonicalize() {
                if let Ok(canon_shared) = shared_dir.canonicalize() {
                    if canon_target.starts_with(canon_shared) && canon_target.is_file() {
                        let file = File::open(&canon_target)?;
                        return Ok(file.into_raw_fd());
                    }
                }
            }
        }
    }

    // Otherwise create temporary file in shared_dir
    let template = shared_dir.join("niri_shm_XXXXXX\0");
    let mut template_bytes = template.to_string_lossy().as_bytes().to_vec();
    // SAFETY: template_bytes contains a valid null-terminated POSIX template string in writable memory.
    // libc::mkstemp creates an exclusive temporary file descriptor mode 0600.
    // libc::unlink immediately removes directory visibility, making the inode anonymous.
    unsafe {
        let fd = libc::mkstemp(template_bytes.as_mut_ptr() as *mut libc::c_char);
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // Immediately unlink so it remains an anonymous memory buffer
        libc::unlink(template_bytes.as_ptr() as *const libc::c_char);

        if !payload.is_empty() {
            libc::write(fd, payload.as_ptr() as *const libc::c_void, payload.len());
            libc::lseek(fd, 0, libc::SEEK_SET);
        }
        Ok(fd)
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let args = Args::parse();

    let niri_socket = resolve_niri_socket(args.wayland_socket)?;
    info!("Target Niri Wayland socket: {}", niri_socket.display());

    // Ensure shared directory exists
    std::fs::create_dir_all(&args.shared_dir)?;
    info!("virtio-fs shared directory: {}", args.shared_dir.display());

    // Clean up old listen socket if it exists
    if args.listen_socket.exists() {
        let _ = std::fs::remove_file(&args.listen_socket);
    }

    info!("Starting virtio-vsock Wayland listener on: {}", args.listen_socket.display());
    let listener = UnixListener::bind(&args.listen_socket)?;

    let mut session_counter = 0u32;

    for stream in listener.incoming() {
        match stream {
            Ok(vsock_stream) => {
                session_counter += 1;
                let niri_path = niri_socket.clone();
                let shm_dir = args.shared_dir.clone();
                let sid = session_counter;

                info!(session_id = sid, "New VM client connection accepted");
                thread::spawn(move || {
                    if let Err(e) = handle_session(vsock_stream, niri_path, shm_dir, sid) {
                        warn!(session_id = sid, "Session closed with error: {e}");
                    }
                });
            }
            Err(e) => {
                error!("Listener incoming connection error: {e}");
            }
        }
    }

    Ok(())
}
