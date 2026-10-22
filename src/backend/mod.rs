use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use niri_config::{Config, ModKey};
use smithay::backend::allocator::dmabuf::Dmabuf;
use smithay::backend::drm::DrmNode;
use smithay::backend::renderer::gles::GlesRenderer;
use smithay::output::Output;
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;

use crate::niri::Niri;
use crate::utils::id::IdCounter;

#[cfg(target_os = "linux")]
pub mod tty;
#[cfg(target_os = "linux")]
pub use tty::Tty;

pub mod winit;
pub use winit::Winit;

pub mod headless;
pub use headless::Headless;

#[cfg(target_os = "macos")]
pub mod metal;
#[cfg(target_os = "macos")]
pub use metal::Metal;

#[allow(clippy::large_enum_variant)]
pub enum Backend {
    #[cfg(target_os = "linux")]
    Tty(Tty),
    Winit(Winit),
    Headless(Headless),
    #[cfg(target_os = "macos")]
    Metal(Metal),
}

#[derive(PartialEq, Eq)]
pub enum RenderResult {
    /// The frame was submitted to the backend for presentation.
    Submitted,
    /// Rendering succeeded, but there was no damage.
    NoDamage,
    /// The frame was not rendered and submitted, due to an error or otherwise.
    Skipped,
}

pub type IpcOutputMap = HashMap<OutputId, niri_ipc::Output>;

static OUTPUT_ID_COUNTER: IdCounter = IdCounter::new();

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct OutputId(u64);

impl OutputId {
    fn next() -> OutputId {
        OutputId(OUTPUT_ID_COUNTER.next())
    }

    pub fn get(self) -> u64 {
        self.0
    }
}

impl Backend {
    pub fn init(&mut self, niri: &mut Niri) {
        let _span = tracy_client::span!("Backend::init");
        match self {
            #[cfg(target_os = "linux")]
            Backend::Tty(tty) => tty.init(niri),
            Backend::Winit(winit) => winit.init(niri),
            Backend::Headless(headless) => headless.init(niri),
            #[cfg(target_os = "macos")]
            Backend::Metal(metal) => metal.init(niri),
        }
    }

    pub fn seat_name(&self) -> String {
        match self {
            #[cfg(target_os = "linux")]
            Backend::Tty(tty) => tty.seat_name(),
            Backend::Winit(winit) => winit.seat_name(),
            Backend::Headless(headless) => headless.seat_name(),
            #[cfg(target_os = "macos")]
            Backend::Metal(metal) => metal.seat_name(),
        }
    }

    pub fn with_primary_renderer<T>(
        &mut self,
        f: impl FnOnce(&mut GlesRenderer) -> T,
    ) -> Option<T> {
        match self {
            #[cfg(target_os = "linux")]
            Backend::Tty(tty) => tty.with_primary_renderer(f),
            Backend::Winit(winit) => winit.with_primary_renderer(f),
            Backend::Headless(headless) => headless.with_primary_renderer(f),
            #[cfg(target_os = "macos")]
            Backend::Metal(metal) => metal.with_primary_renderer(f),
        }
    }

    /// DRM render node of the primary renderer, if it has one.
    ///
    /// This is the node clients should allocate dma-bufs on for the primary renderer to import
    /// and render into them directly.
    pub fn primary_render_node(&mut self) -> Option<DrmNode> {
        match self {
            #[cfg(target_os = "linux")]
            Backend::Tty(tty) => tty.primary_render_node(),
            Backend::Winit(winit) => winit.primary_render_node(),
            Backend::Headless(headless) => headless.primary_render_node(),
            #[cfg(target_os = "macos")]
            Backend::Metal(metal) => metal.primary_render_node(),
        }
    }

    pub fn render(
        &mut self,
        niri: &mut Niri,
        output: &Output,
        target_presentation_time: Duration,
    ) -> RenderResult {
        match self {
            #[cfg(target_os = "linux")]
            Backend::Tty(tty) => tty.render(niri, output, target_presentation_time),
            Backend::Winit(winit) => {
                let _ = target_presentation_time;
                winit.render(niri, output)
            }
            Backend::Headless(headless) => {
                let _ = target_presentation_time;
                headless.render(niri, output)
            }
            #[cfg(target_os = "macos")]
            Backend::Metal(metal) => {
                let _ = target_presentation_time;
                metal.render(niri, output)
            }
        }
    }

    pub fn mod_key(&self, config: &Config) -> ModKey {
        match self {
            Backend::Winit(_) => config.input.mod_key_nested.unwrap_or({
                if let Some(ModKey::Alt) = config.input.mod_key {
                    ModKey::Super
                } else {
                    ModKey::Alt
                }
            }),
            #[cfg(target_os = "macos")]
            Backend::Metal(_) => config.input.mod_key_nested.unwrap_or({
                if let Some(ModKey::Alt) = config.input.mod_key {
                    ModKey::Super
                } else {
                    ModKey::Alt
                }
            }),
            #[cfg(target_os = "linux")]
            Backend::Tty(_) => config.input.mod_key.unwrap_or(ModKey::Super),
            Backend::Headless(_) => config.input.mod_key.unwrap_or(ModKey::Super),
        }
    }

    pub fn change_vt(&mut self, vt: i32) {
        match self {
            #[cfg(target_os = "linux")]
            Backend::Tty(tty) => tty.change_vt(vt),
            _ => {
                let _ = vt;
            }
        }
    }

    pub fn suspend(&mut self) {
        match self {
            #[cfg(target_os = "linux")]
            Backend::Tty(tty) => tty.suspend(),
            _ => (),
        }
    }

    pub fn toggle_debug_tint(&mut self) {
        match self {
            #[cfg(target_os = "linux")]
            Backend::Tty(tty) => tty.toggle_debug_tint(),
            Backend::Winit(winit) => winit.toggle_debug_tint(),
            Backend::Headless(_) => (),
            #[cfg(target_os = "macos")]
            Backend::Metal(metal) => metal.toggle_debug_tint(),
        }
    }

    pub fn import_dmabuf(&mut self, dmabuf: &Dmabuf) -> bool {
        match self {
            #[cfg(target_os = "linux")]
            Backend::Tty(tty) => tty.import_dmabuf(dmabuf),
            Backend::Winit(winit) => winit.import_dmabuf(dmabuf),
            Backend::Headless(headless) => headless.import_dmabuf(dmabuf),
            #[cfg(target_os = "macos")]
            Backend::Metal(_) => false,
        }
    }

    pub fn early_import(&mut self, _surface: &WlSurface) {
        match self {
            #[cfg(target_os = "linux")]
            Backend::Tty(tty) => tty.early_import(_surface),
            Backend::Winit(_) => (),
            Backend::Headless(_) => (),
            #[cfg(target_os = "macos")]
            Backend::Metal(_) => (),
        }
    }

    pub fn ipc_outputs(&self) -> Arc<Mutex<IpcOutputMap>> {
        match self {
            #[cfg(target_os = "linux")]
            Backend::Tty(tty) => tty.ipc_outputs(),
            Backend::Winit(winit) => winit.ipc_outputs(),
            Backend::Headless(headless) => headless.ipc_outputs(),
            #[cfg(target_os = "macos")]
            Backend::Metal(metal) => metal.ipc_outputs(),
        }
    }

    #[cfg(feature = "xdp-gnome-screencast")]
    pub fn gbm_device(
        &self,
    ) -> Option<smithay::backend::allocator::gbm::GbmDevice<smithay::utils::DeviceFd>> {
        match self {
            #[cfg(target_os = "linux")]
            Backend::Tty(tty) => tty.primary_gbm_device(),
            Backend::Winit(winit) => winit.gbm_device(),
            Backend::Headless(_) => None,
            #[cfg(target_os = "macos")]
            Backend::Metal(_) => None,
        }
    }

    pub fn set_monitors_active(&mut self, active: bool) {
        match self {
            #[cfg(target_os = "linux")]
            Backend::Tty(tty) => tty.set_monitors_active(active),
            _ => {
                let _ = active;
            }
        }
    }

    pub fn set_output_on_demand_vrr(&mut self, niri: &mut Niri, output: &Output, enable_vrr: bool) {
        match self {
            #[cfg(target_os = "linux")]
            Backend::Tty(tty) => tty.set_output_on_demand_vrr(niri, output, enable_vrr),
            _ => {
                let _ = (niri, output, enable_vrr);
            }
        }
    }

    pub fn update_ignored_nodes_config(&mut self, niri: &mut Niri) {
        match self {
            #[cfg(target_os = "linux")]
            Backend::Tty(tty) => tty.update_ignored_nodes_config(niri),
            _ => {
                let _ = niri;
            }
        }
    }

    pub fn on_output_config_changed(&mut self, niri: &mut Niri) {
        match self {
            #[cfg(target_os = "linux")]
            Backend::Tty(tty) => tty.on_output_config_changed(niri),
            _ => {
                let _ = niri;
            }
        }
    }

    #[cfg(target_os = "linux")]
    pub fn tty_checked(&mut self) -> Option<&mut Tty> {
        if let Self::Tty(v) = self {
            Some(v)
        } else {
            None
        }
    }

    #[cfg(target_os = "linux")]
    pub fn tty(&mut self) -> &mut Tty {
        if let Self::Tty(v) = self {
            v
        } else {
            panic!("backend is not Tty");
        }
    }

    pub fn winit(&mut self) -> &mut Winit {
        if let Self::Winit(v) = self {
            v
        } else {
            panic!("backend is not Winit")
        }
    }

    pub fn headless(&mut self) -> &mut Headless {
        if let Self::Headless(v) = self {
            v
        } else {
            panic!("backend is not Headless")
        }
    }

    #[cfg(target_os = "macos")]
    pub fn metal(&mut self) -> &mut Metal {
        if let Self::Metal(v) = self {
            v
        } else {
            panic!("backend is not Metal")
        }
    }
}
