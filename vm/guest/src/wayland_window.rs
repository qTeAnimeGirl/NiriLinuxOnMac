//! `vm/guest/src/wayland_window.rs`
//!
//! Minimal standalone Wayland client for Linux MicroVM on Niri macOS.
//! Maps an xdg_toplevel window titled "MicroVM Linux Wayland Client"
//! with a 640x480 indigo-to-cyan gradient buffer.

use std::fs::File;
use std::io::Write;
use std::os::unix::io::AsFd;
#[cfg(target_os = "linux")]
use std::os::unix::io::FromRawFd;
use wayland_client::protocol::{
    wl_buffer, wl_compositor, wl_registry, wl_shm, wl_shm_pool, wl_surface,
};
use wayland_client::{Connection, Dispatch, QueueHandle};
use wayland_protocols::xdg::shell::client::{
    xdg_surface, xdg_toplevel, xdg_wm_base,
};

struct AppState {
    compositor: Option<wl_compositor::WlCompositor>,
    shm: Option<wl_shm::WlShm>,
    wm_base: Option<xdg_wm_base::XdgWmBase>,
    surface: Option<wl_surface::WlSurface>,
    configured: bool,
    running: bool,
}

impl Dispatch<wl_registry::WlRegistry, ()> for AppState {
    fn event(
        state: &mut Self,
        registry: &wl_registry::WlRegistry,
        event: wl_registry::Event,
        _: &(),
        _: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        if let wl_registry::Event::Global { name, interface, version } = event {
            match interface.as_str() {
                "wl_compositor" => {
                    let comp = registry.bind::<wl_compositor::WlCompositor, _, _>(
                        name,
                        version.min(4),
                        qh,
                        (),
                    );
                    state.compositor = Some(comp);
                }
                "wl_shm" => {
                    let shm = registry.bind::<wl_shm::WlShm, _, _>(name, 1, qh, ());
                    state.shm = Some(shm);
                }
                "xdg_wm_base" => {
                    let wm = registry.bind::<xdg_wm_base::XdgWmBase, _, _>(
                        name,
                        version.min(4),
                        qh,
                        (),
                    );
                    state.wm_base = Some(wm);
                }
                _ => {}
            }
        }
    }
}

impl Dispatch<wl_compositor::WlCompositor, ()> for AppState {
    fn event(_: &mut Self, _: &wl_compositor::WlCompositor, _: wl_compositor::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}

impl Dispatch<wl_shm::WlShm, ()> for AppState {
    fn event(_: &mut Self, _: &wl_shm::WlShm, _: wl_shm::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}

impl Dispatch<wl_shm_pool::WlShmPool, ()> for AppState {
    fn event(_: &mut Self, _: &wl_shm_pool::WlShmPool, _: wl_shm_pool::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}

impl Dispatch<wl_buffer::WlBuffer, ()> for AppState {
    fn event(_: &mut Self, _: &wl_buffer::WlBuffer, _: wl_buffer::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}

impl Dispatch<wl_surface::WlSurface, ()> for AppState {
    fn event(_: &mut Self, _: &wl_surface::WlSurface, _: wl_surface::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}

impl Dispatch<xdg_wm_base::XdgWmBase, ()> for AppState {
    fn event(
        _: &mut Self,
        wm: &xdg_wm_base::XdgWmBase,
        event: xdg_wm_base::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if let xdg_wm_base::Event::Ping { serial } = event {
            wm.pong(serial);
        }
    }
}

impl Dispatch<xdg_surface::XdgSurface, ()> for AppState {
    fn event(
        state: &mut Self,
        xdg_surface: &xdg_surface::XdgSurface,
        event: xdg_surface::Event,
        _: &(),
        conn: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        if let xdg_surface::Event::Configure { serial } = event {
            xdg_surface.ack_configure(serial);
            if !state.configured {
                state.configured = true;
                state.draw_and_commit(qh);
                match conn.flush() {
                    Ok(_) => println!("[CLIENT] Flush succeeded!"),
                    Err(e) => println!("[CLIENT] Flush failed: {:?}", e),
                }
            }
        }
    }
}

impl Dispatch<xdg_toplevel::XdgToplevel, ()> for AppState {
    fn event(
        state: &mut Self,
        _: &xdg_toplevel::XdgToplevel,
        event: xdg_toplevel::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if let xdg_toplevel::Event::Close = event {
            state.running = false;
        }
    }
}

impl AppState {
    fn draw_and_commit(&self, qh: &QueueHandle<Self>) {
        let (Some(surface), Some(shm)) = (&self.surface, &self.shm) else { return; };

        let width = 640;
        let height = 480;
        let stride = width * 4;
        let size = stride * height;

        let mut file = tempfile_shm(size).expect("Failed to create temporary SHM file");
        let mut pixels = vec![0u8; size as usize];
        for y in 0..height {
            for x in 0..width {
                let idx = ((y * stride) + (x * 4)) as usize;
                let r = ((x * 180) / width) as u8;
                let g = 80u8;
                let b = ((y * 220) / height + 35) as u8;
                pixels[idx] = b;
                pixels[idx + 1] = g;
                pixels[idx + 2] = r;
                pixels[idx + 3] = 255;
            }
        }
        file.write_all(&pixels).expect("Failed to write pixels");

        let pool = shm.create_pool(file.as_fd(), size, qh, ());
        let buffer = pool.create_buffer(0, width, height, stride, wl_shm::Format::Argb8888, qh, ());

        surface.attach(Some(&buffer), 0, 0);
        surface.damage(0, 0, width, height);
        surface.commit();
        println!("[CLIENT] Committed 640x480 surface to Niri compositor!");
    }
}

fn tempfile_shm(size: i32) -> std::io::Result<File> {
    // 1. Try memfd_create on Linux
    #[cfg(target_os = "linux")]
    unsafe {
        let name = std::ffi::CStr::from_bytes_with_nul(b"niri_shm\0").unwrap();
        let fd = libc::memfd_create(name.as_ptr(), libc::MFD_CLOEXEC);
        if fd >= 0 {
            let file = File::from_raw_fd(fd);
            file.set_len(size as u64)?;
            return Ok(file);
        }
    }

    // 2. Fallback to temporary directory
    let temp_dir = std::env::temp_dir();
    let path = temp_dir.join(format!("niri_client_{}", std::process::id()));
    let file = File::options().read(true).write(true).create(true).truncate(true).open(&path)?;
    file.set_len(size as u64)?;
    let _ = std::fs::remove_file(&path);
    Ok(file)
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("[CLIENT] Connecting to Wayland socket...");
    let mut attempts = 0;
    let conn = loop {
        match Connection::connect_to_env() {
            Ok(c) => break c,
            Err(e) => {
                attempts += 1;
                if attempts > 50 {
                    return Err(format!("Failed to connect to wayland after retries: {e:?}").into());
                }
                std::thread::sleep(std::time::Duration::from_millis(150));
            }
        }
    };
    let mut event_queue = conn.new_event_queue();
    let qh = event_queue.handle();

    let mut state = AppState {
        compositor: None,
        shm: None,
        wm_base: None,
        surface: None,
        configured: false,
        running: true,
    };

    let display = conn.display();
    let _registry = display.get_registry(&qh, ());

    event_queue.roundtrip(&mut state)?;

    let compositor = state.compositor.as_ref().expect("Missing wl_compositor");
    let wm_base = state.wm_base.as_ref().expect("Missing xdg_wm_base");

    let surface = compositor.create_surface(&qh, ());
    let xdg_surface = wm_base.get_xdg_surface(&surface, &qh, ());
    let xdg_toplevel = xdg_surface.get_toplevel(&qh, ());

    xdg_toplevel.set_title("MicroVM Linux Wayland Client".to_string());
    xdg_toplevel.set_app_id("org.niri.microvm.client".to_string());

    surface.commit();
    state.surface = Some(surface);
    let _ = conn.flush();

    println!("[CLIENT] Entering event loop...");
    while state.running {
        let _ = conn.flush();
        event_queue.blocking_dispatch(&mut state)?;
    }

    Ok(())
}
