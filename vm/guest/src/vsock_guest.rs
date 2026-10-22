//! `vm/guest/src/vsock_guest.rs`
//!
//! Lightweight Wayland socket proxy daemon for Linux MicroVM guests.
//! Exposes `/run/user/1000/wayland-0` and bridges Wayland wire protocol bytes
//! across virtio-vsock (host CID 2, port 1024).

use std::fs;
use std::io::{Read, Write};
use std::net::Shutdown;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::io::{FromRawFd, RawFd};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;

const DEFAULT_SOCKET_PATH: &str = "/run/user/1000/wayland-0";
const VMADDR_CID_HOST: u32 = 2;
const DEFAULT_PORT: u32 = 1024;
const AF_VSOCK: i32 = 40;

#[repr(C)]
#[derive(Copy, Clone)]
struct SockaddrVm {
    svm_family: libc::sa_family_t,
    svm_reserved1: u16,
    svm_port: u32,
    svm_cid: u32,
    svm_zero: [u8; 4],
}

fn connect_vsock(cid: u32, port: u32) -> Option<RawFd> {
    unsafe {
        for attempt in 0..30 {
            let fd = libc::socket(AF_VSOCK, libc::SOCK_STREAM, 0);
            if fd < 0 {
                let err = std::io::Error::last_os_error();
                eprintln!("[GUEST PROXY] socket(AF_VSOCK) failed: {err}");
                return None;
            }

            let mut addr: SockaddrVm = std::mem::zeroed();
            addr.svm_family = AF_VSOCK as libc::sa_family_t;
            addr.svm_cid = cid;
            addr.svm_port = port;

            let res = libc::connect(
                fd,
                &addr as *const _ as *const libc::sockaddr,
                std::mem::size_of::<SockaddrVm>() as libc::socklen_t,
            );

            if res == 0 {
                return Some(fd);
            }

            let err = std::io::Error::last_os_error();
            eprintln!("[GUEST PROXY] attempt {attempt}: connect(cid={cid}, port={port}) failed: {err}");
            libc::close(fd);
            if attempt < 29 {
                std::thread::sleep(std::time::Duration::from_millis(100));
            }
        }
        eprintln!("[GUEST PROXY] connect(AF_VSOCK, cid={cid}, port={port}) timed out after retries");
        None
    }
}

fn handle_connection(mut client_stream: UnixStream, host_fd: RawFd, session_id: u32) {
    let mut host_stream = unsafe { UnixStream::from_raw_fd(host_fd) };
    let mut client_read = match client_stream.try_clone() {
        Ok(s) => s,
        Err(_) => return,
    };
    let mut host_read = match host_stream.try_clone() {
        Ok(s) => s,
        Err(_) => return,
    };

    let running = Arc::new(AtomicBool::new(true));

    // Client -> Host
    let r1 = running.clone();
    let t1 = thread::spawn(move || {
        let mut buf = [0u8; 32768];
        while r1.load(Ordering::Relaxed) {
            match client_read.read(&mut buf) {
                Ok(0) => {
                    println!("[GUEST PROXY] client_read EOF");
                    break;
                }
                Ok(n) => {
                    println!("[GUEST PROXY] Read {n} bytes from client, sending to vsock");
                    if let Err(e) = host_stream.write_all(&buf[..n]) {
                        println!("[GUEST PROXY] host_stream.write_all error: {e:?}");
                        break;
                    }
                }
                Err(e) => {
                    println!("[GUEST PROXY] client_read error: {e:?}");
                    break;
                }
            }
        }
        r1.store(false, Ordering::Relaxed);
        let _ = host_stream.shutdown(Shutdown::Both);
    });

    // Host -> Client
    let r2 = running.clone();
    let t2 = thread::spawn(move || {
        let mut buf = [0u8; 32768];
        while r2.load(Ordering::Relaxed) {
            match host_read.read(&mut buf) {
                Ok(0) => {
                    println!("[GUEST PROXY] host_read EOF");
                    break;
                }
                Ok(n) => {
                    if let Err(e) = client_stream.write_all(&buf[..n]) {
                        println!("[GUEST PROXY] client_stream.write_all error: {e:?}");
                        break;
                    }
                }
                Err(e) => {
                    println!("[GUEST PROXY] host_read error: {e:?}");
                    break;
                }
            }
        }
        r2.store(false, Ordering::Relaxed);
        let _ = client_stream.shutdown(Shutdown::Both);
    });

    let _ = t1.join();
    let _ = t2.join();
    println!("[GUEST PROXY] Session #{session_id} finished");
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let socket_path = std::env::var("WAYLAND_SOCKET_PATH")
        .unwrap_or_else(|_| DEFAULT_SOCKET_PATH.to_string());

    if let Some(parent) = Path::new(&socket_path).parent() {
        fs::create_dir_all(parent)?;
        let _ = fs::set_permissions(parent, fs::Permissions::from_mode(0o777));
    }

    if Path::new(&socket_path).exists() {
        let _ = fs::remove_file(&socket_path);
    }

    println!("============================================================");
    println!("Niri Linux Guest Wayland Proxy Daemon");
    println!("Socket: /run/user/1000/wayland-0");
    println!("Target: virtio-vsock CID 2, Port 1024");
    println!("============================================================");

    let listener = UnixListener::bind(&socket_path)?;
    let _ = fs::set_permissions(&socket_path, fs::Permissions::from_mode(0o666));

    let mut session_counter = 0u32;

    for stream in listener.incoming() {
        match stream {
            Ok(client_stream) => {
                session_counter += 1;
                let sid = session_counter;
                println!("[GUEST PROXY] New client connection accepted, session #{sid}");

                // Connect to host via vsock
                if let Some(host_fd) = connect_vsock(VMADDR_CID_HOST, DEFAULT_PORT) {
                    thread::spawn(move || {
                        handle_connection(client_stream, host_fd, sid);
                    });
                } else {
                    eprintln!("[GUEST PROXY] Failed to connect to host vsock port 1024");
                }
            }
            Err(e) => eprintln!("[GUEST PROXY] Incoming connection error: {e}"),
        }
    }

    Ok(())
}
