use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::Rc;
use std::sync::{Arc, Mutex};

use anyhow::Context as _;
use niri_config::{Config, OutputName};
use smithay::backend::drm::DrmNode;
use smithay::backend::renderer::element::RenderElementStates;
use smithay::backend::renderer::gles::GlesRenderer;
use smithay::backend::winit::{self, WinitEvent};
use smithay::output::{Mode, Output, PhysicalProperties, Subpixel};
use smithay::reexports::calloop::LoopHandle;
use smithay::reexports::wayland_protocols::wp::presentation_time::server::wp_presentation_feedback;
use smithay::reexports::winit::dpi::LogicalSize;
use smithay::reexports::winit::raw_window_handle::{HasDisplayHandle, HasWindowHandle};
use smithay::reexports::winit::window::{Window as WinitWindow, WindowAttributes};
use smithay::wayland::presentation::Refresh;

use super::{IpcOutputMap, OutputId, RenderResult};
use crate::niri::{Niri, RedrawState, State};
use crate::utils::{get_monotonic_time, logical_output, WinitScale};

pub struct Metal {
    _config: Rc<RefCell<Config>>,
    pub output: Output,
    window: Arc<dyn WinitWindow>,
    _instance: wgpu::Instance,
    surface: wgpu::Surface<'static>,
    _adapter: wgpu::Adapter,
    device: wgpu::Device,
    queue: wgpu::Queue,
    surface_config: wgpu::SurfaceConfiguration,
    debug_tint: bool,
    ipc_outputs: Arc<Mutex<IpcOutputMap>>,
}

impl Metal {
    pub fn new(
        config: Rc<RefCell<Config>>,
        event_loop: LoopHandle<State>,
    ) -> anyhow::Result<Self> {
        let _span = tracy_client::span!("Metal::new");

        let builder = WindowAttributes::default()
            .with_surface_size(LogicalSize::new(1280.0, 800.0))
            .with_title("niri");

        let (window, winit_event_loop) = winit::init_window_and_event_loop(builder)
            .map_err(|err| anyhow::anyhow!("error initializing winit window: {err:?}"))?;

        let output = Output::new(
            "metal".to_string(),
            PhysicalProperties {
                size: (0, 0).into(),
                subpixel: Subpixel::Unknown,
                make: "Apple".into(),
                model: "Metal".into(),
                serial_number: "Unknown".into(),
            },
        );

        let window_size = window.surface_size();
        let mode = Mode {
            size: (window_size.width as i32, window_size.height as i32).into(),
            refresh: 60_000,
        };
        output.change_current_state(Some(mode), None, None, None);
        output.set_preferred(mode);

        output.user_data().insert_if_missing(|| OutputName {
            connector: "metal".to_string(),
            make: Some("Apple".to_string()),
            model: Some("Metal".to_string()),
            serial: None,
        });

        output
            .user_data()
            .insert_if_missing(|| WinitScale(Cell::new(window.scale_factor())));

        let physical_properties = output.physical_properties();
        let ipc_outputs = Arc::new(Mutex::new(HashMap::from([(
            OutputId::next(),
            niri_ipc::Output {
                name: output.name(),
                make: physical_properties.make,
                model: physical_properties.model,
                serial: None,
                physical_size: None,
                modes: vec![niri_ipc::Mode {
                    width: window_size.width.clamp(0, u16::MAX as u32) as u16,
                    height: window_size.height.clamp(0, u16::MAX as u32) as u16,
                    refresh_rate: 60_000,
                    is_preferred: true,
                }],
                current_mode: Some(0),
                is_custom_mode: true,
                vrr_supported: false,
                vrr_enabled: false,
                logical: Some(logical_output(&output)),
                max_bpc: None,
            },
        )])));

        // Create wgpu instance using Apple Metal backend
        let instance = wgpu::Instance::new(&wgpu::InstanceDescriptor {
            backends: wgpu::Backends::METAL,
            flags: wgpu::InstanceFlags::default(),
            backend_options: wgpu::BackendOptions::default(),
        });

        let raw_display_handle = window
            .display_handle()
            .map_err(|err| anyhow::anyhow!("display handle error: {err:?}"))?
            .as_raw();
        let raw_window_handle = window
            .window_handle()
            .map_err(|err| anyhow::anyhow!("window handle error: {err:?}"))?
            .as_raw();

        let surface = unsafe {
            instance.create_surface_unsafe(wgpu::SurfaceTargetUnsafe::RawHandle {
                raw_display_handle,
                raw_window_handle,
            })
        }?;

        let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            compatible_surface: Some(&surface),
            force_fallback_adapter: false,
        }))
        .context("no suitable Metal graphics adapter found")?;

        let (device, queue) = pollster::block_on(adapter.request_device(
            &wgpu::DeviceDescriptor {
                label: Some("niri-metal-device"),
                required_features: wgpu::Features::empty(),
                required_limits: wgpu::Limits::default(),
                memory_hints: wgpu::MemoryHints::default(),
            },
            None,
        ))
        .context("failed to create Metal logical device and queue")?;

        let surface_caps = surface.get_capabilities(&adapter);
        let surface_format = surface_caps
            .formats
            .iter()
            .copied()
            .find(|f| f.is_srgb())
            .unwrap_or(surface_caps.formats[0]);

        let surface_config = wgpu::SurfaceConfiguration {
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            format: surface_format,
            width: window_size.width.max(1),
            height: window_size.height.max(1),
            present_mode: wgpu::PresentMode::AutoVsync,
            alpha_mode: surface_caps.alpha_modes[0],
            view_formats: vec![],
            desired_maximum_frame_latency: 2,
        };
        surface.configure(&device, &surface_config);

        event_loop
            .insert_source(winit_event_loop, move |event, _, state| match event {
                WinitEvent::Resized { size, scale_factor } => {
                    let metal = state.backend.metal();
                    let output = metal.output.clone();
                    metal.resize(size.w.max(1) as u32, size.h.max(1) as u32);
                    output.change_current_state(
                        Some(Mode {
                            size,
                            refresh: 60_000,
                        }),
                        None,
                        None,
                        None,
                    );

                    {
                        let scale = output.user_data().get_or_insert(WinitScale::default);
                        scale.0.set(scale_factor);
                    }

                    {
                        let mut ipc_outputs = metal.ipc_outputs.lock().unwrap();
                        if let Some(output) = ipc_outputs.values_mut().next() {
                            let mode = &mut output.modes[0];
                            mode.width = size.w.clamp(0, u16::MAX as i32) as u16;
                            mode.height = size.h.clamp(0, u16::MAX as i32) as u16;
                            state.niri.ipc_outputs_changed = true;
                        }
                    }

                    state.reload_output_config();
                    state.niri.output_resized(&output);
                }
                WinitEvent::Input(event) => state.process_input_event(event),
                WinitEvent::Focus(_) => (),
                WinitEvent::Redraw => state.niri.queue_redraw(&state.backend.metal().output),
                WinitEvent::CloseRequested => state.niri.stop_signal.stop(),
            })
            .map_err(|err| anyhow::anyhow!("failed to register winit event source in calloop: {err:?}"))?;

        Ok(Self {
            _config: config,
            output,
            window,
            _instance: instance,
            surface,
            _adapter: adapter,
            device,
            queue,
            surface_config,
            debug_tint: false,
            ipc_outputs,
        })
    }

    pub fn resize(&mut self, width: u32, height: u32) {
        if width > 0 && height > 0 {
            self.surface_config.width = width;
            self.surface_config.height = height;
            self.surface.configure(&self.device, &self.surface_config);
        }
    }

    pub fn init(&mut self, niri: &mut Niri) {
        niri.add_output(self.output.clone(), None, false);
    }

    pub fn seat_name(&self) -> String {
        "metal".to_owned()
    }

    pub fn with_primary_renderer<T>(
        &mut self,
        _f: impl FnOnce(&mut GlesRenderer) -> T,
    ) -> Option<T> {
        None
    }

    pub fn primary_render_node(&mut self) -> Option<DrmNode> {
        None
    }

    pub fn render(&mut self, niri: &mut Niri, output: &Output) -> RenderResult {
        let _span = tracy_client::span!("Metal::render");

        let frame = match self.surface.get_current_texture() {
            Ok(frame) => frame,
            Err(wgpu::SurfaceError::Timeout) => {
                return RenderResult::Skipped;
            }
            Err(wgpu::SurfaceError::Outdated | wgpu::SurfaceError::Lost) => {
                self.surface.configure(&self.device, &self.surface_config);
                return RenderResult::Skipped;
            }
            Err(err) => {
                error!("Metal surface error: {err:?}");
                return RenderResult::Skipped;
            }
        };

        let view = frame.texture.create_view(&wgpu::TextureViewDescriptor::default());
        let mut encoder = self.device.create_command_encoder(&wgpu::CommandEncoderDescriptor {
            label: Some("niri-metal-encoder"),
        });

        let clear_color = if self.debug_tint {
            wgpu::Color {
                r: 0.12,
                g: 0.25,
                b: 0.45,
                a: 1.0,
            }
        } else {
            // Elegant modern dark wallpaper / canvas
            wgpu::Color {
                r: 0.08,
                g: 0.09,
                b: 0.12,
                a: 1.0,
            }
        };

        {
            let _rpass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("niri-metal-clear-pass"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &view,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(clear_color),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
            });
        }

        self.queue.submit(Some(encoder.finish()));
        frame.present();

        let states = RenderElementStates::default();
        let mut presentation_feedbacks = niri.take_presentation_feedbacks(output, &states);
        presentation_feedbacks.presented::<_, smithay::utils::Monotonic>(
            get_monotonic_time(),
            Refresh::Unknown,
            0,
            wp_presentation_feedback::Kind::empty(),
        );

        let output_state = niri.output_state.get_mut(output).unwrap();
        output_state.redraw_state = RedrawState::Idle;
        output_state.frame_callback_sequence = output_state.frame_callback_sequence.wrapping_add(1);

        if output_state.unfinished_animations_remain {
            self.window.request_redraw();
        }

        RenderResult::Submitted
    }

    pub fn toggle_debug_tint(&mut self) {
        self.debug_tint = !self.debug_tint;
    }

    pub fn ipc_outputs(&self) -> Arc<Mutex<IpcOutputMap>> {
        self.ipc_outputs.clone()
    }
}
