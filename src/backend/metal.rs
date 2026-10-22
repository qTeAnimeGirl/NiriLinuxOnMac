use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::ffi::{c_char, c_void};
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
use smithay::reexports::winit::window::{CursorGrabMode, Window as WinitWindow, WindowAttributes};
use smithay::wayland::presentation::Refresh;

use super::{IpcOutputMap, OutputId, RenderResult};
use crate::niri::{Niri, RedrawState, State};
use crate::utils::{get_monotonic_time, logical_output, WinitScale};

#[repr(C)]
#[derive(Copy, Clone, Debug, bytemuck::Pod, bytemuck::Zeroable)]
struct CursorUniforms {
    viewport_size: [f32; 2],
    cursor_pos: [f32; 2],
    cursor_size: [f32; 2],
    hotspot: [f32; 2],
}

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
    cursor_pipeline: wgpu::RenderPipeline,
    cursor_bind_group: wgpu::BindGroup,
    cursor_uniform_buffer: wgpu::Buffer,
    debug_tint: bool,
    ipc_outputs: Arc<Mutex<IpcOutputMap>>,
}

impl Metal {
    pub fn new(
        config: Rc<RefCell<Config>>,
        event_loop: LoopHandle<State>,
    ) -> anyhow::Result<Self> {
        let _span = tracy_client::span!("Metal::new");

        let is_windowed = std::env::var("NIRI_WINDOWED")
            .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
            .unwrap_or(false);
        let notch_bypass = !is_windowed
            && std::env::var("NIRI_NOTCH_BYPASS")
                .map(|v| v != "0" && !v.eq_ignore_ascii_case("false"))
                .unwrap_or(true);

        let default_width = if notch_bypass { 1280.0 } else { 1920.0 };
        let default_height = if notch_bypass { 800.0 } else { 1080.0 };
        let width: f64 = std::env::var("NIRI_WIDTH")
            .ok()
            .and_then(|w| w.parse().ok())
            .unwrap_or(default_width);
        let height: f64 = std::env::var("NIRI_HEIGHT")
            .ok()
            .and_then(|h| h.parse().ok())
            .unwrap_or(default_height);

        // Request borderless fullscreen by default unless windowed mode requested
        let builder = WindowAttributes::default()
            .with_surface_size(LogicalSize::new(width, height))
            .with_title("niri")
            .with_decorations(!notch_bypass);

        let (window, winit_event_loop) = winit::init_window_and_event_loop(builder)
            .map_err(|err| anyhow::anyhow!("error initializing winit window: {err:?}"))?;

        if notch_bypass {
            // Capture mouse and trackpad: hide system cursor and confine to window
            window.set_cursor_visible(false);
            let _ = window.set_cursor_grab(CursorGrabMode::Confined);
        } else {
            // In windowed mode, hide OS cursor over canvas so Niri's hardware-accelerated cursor is drawn
            let hide_cursor = std::env::var("NIRI_HIDE_CURSOR")
                .map(|v| v != "0" && !v.eq_ignore_ascii_case("false"))
                .unwrap_or(true);
            if hide_cursor {
                window.set_cursor_visible(false);
            }
        }

        // Bypass macOS camera notch: expand window frame across the full physical screen
        let raw_window_handle = window
            .window_handle()
            .map_err(|err| anyhow::anyhow!("window handle error: {err:?}"))?
            .as_raw();
        let raw_display_handle = window
            .display_handle()
            .map_err(|err| anyhow::anyhow!("display handle error: {err:?}"))?
            .as_raw();

        if notch_bypass {
            if let smithay::reexports::winit::raw_window_handle::RawWindowHandle::AppKit(handle) = raw_window_handle {
                // SAFETY: handle.ns_view is a valid NonNull pointer to the window's NSView provided by winit,
                // and this initialization occurs on the main thread during compositor startup.
                unsafe {
                    bypass_macos_notch(handle.ns_view.as_ptr());
                }
            }
        }

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

        // SAFETY: raw_display_handle and raw_window_handle are valid raw handles
        // retrieved from the active winit window and remain valid for the lifetime of the Metal surface.
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

        // Setup Cursor Rendering Pipeline
        let cursor_texture = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("niri-cursor-texture"),
            size: wgpu::Extent3d {
                width: 64,
                height: 64,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba8Unorm,
            usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
            view_formats: &[],
        });

        queue.write_texture(
            wgpu::TexelCopyTextureInfo {
                texture: &cursor_texture,
                mip_level: 0,
                origin: wgpu::Origin3d::ZERO,
                aspect: wgpu::TextureAspect::All,
            },
            include_bytes!("../../resources/cursor.rgba"),
            wgpu::TexelCopyBufferLayout {
                offset: 0,
                bytes_per_row: Some(64 * 4),
                rows_per_image: Some(64),
            },
            wgpu::Extent3d {
                width: 64,
                height: 64,
                depth_or_array_layers: 1,
            },
        );

        let cursor_texture_view = cursor_texture.create_view(&wgpu::TextureViewDescriptor::default());
        let cursor_sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("niri-cursor-sampler"),
            address_mode_u: wgpu::AddressMode::ClampToEdge,
            address_mode_v: wgpu::AddressMode::ClampToEdge,
            address_mode_w: wgpu::AddressMode::ClampToEdge,
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            mipmap_filter: wgpu::FilterMode::Nearest,
            ..Default::default()
        });

        let cursor_uniforms = CursorUniforms {
            viewport_size: [window_size.width as f32, window_size.height as f32],
            cursor_pos: [100.0, 100.0],
            cursor_size: [32.0, 32.0],
            hotspot: [1.0, 1.0],
        };

        use wgpu::util::DeviceExt;
        let cursor_uniform_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("niri-cursor-uniform-buffer"),
            contents: bytemuck::bytes_of(&cursor_uniforms),
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        });

        let cursor_bind_group_layout =
            device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
                label: Some("niri-cursor-bind-group-layout"),
                entries: &[
                    wgpu::BindGroupLayoutEntry {
                        binding: 0,
                        visibility: wgpu::ShaderStages::VERTEX,
                        ty: wgpu::BindingType::Buffer {
                            ty: wgpu::BufferBindingType::Uniform,
                            has_dynamic_offset: false,
                            min_binding_size: None,
                        },
                        count: None,
                    },
                    wgpu::BindGroupLayoutEntry {
                        binding: 1,
                        visibility: wgpu::ShaderStages::FRAGMENT,
                        ty: wgpu::BindingType::Texture {
                            sample_type: wgpu::TextureSampleType::Float { filterable: true },
                            view_dimension: wgpu::TextureViewDimension::D2,
                            multisampled: false,
                        },
                        count: None,
                    },
                    wgpu::BindGroupLayoutEntry {
                        binding: 2,
                        visibility: wgpu::ShaderStages::FRAGMENT,
                        ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                        count: None,
                    },
                ],
            });

        let cursor_bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("niri-cursor-bind-group"),
            layout: &cursor_bind_group_layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: cursor_uniform_buffer.as_entire_binding(),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: wgpu::BindingResource::TextureView(&cursor_texture_view),
                },
                wgpu::BindGroupEntry {
                    binding: 2,
                    resource: wgpu::BindingResource::Sampler(&cursor_sampler),
                },
            ],
        });

        let cursor_shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("niri-cursor-shader"),
            source: wgpu::ShaderSource::Wgsl(CURSOR_SHADER_SRC.into()),
        });

        let cursor_pipeline_layout =
            device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: Some("niri-cursor-pipeline-layout"),
                bind_group_layouts: &[&cursor_bind_group_layout],
                push_constant_ranges: &[],
            });

        let cursor_pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("niri-cursor-pipeline"),
            layout: Some(&cursor_pipeline_layout),
            vertex: wgpu::VertexState {
                module: &cursor_shader,
                entry_point: Some("vs_main"),
                buffers: &[],
                compilation_options: Default::default(),
            },
            fragment: Some(wgpu::FragmentState {
                module: &cursor_shader,
                entry_point: Some("fs_main"),
                targets: &[Some(wgpu::ColorTargetState {
                    format: surface_format,
                    blend: Some(wgpu::BlendState::ALPHA_BLENDING),
                    write_mask: wgpu::ColorWrites::ALL,
                })],
                compilation_options: Default::default(),
            }),
            primitive: wgpu::PrimitiveState {
                topology: wgpu::PrimitiveTopology::TriangleList,
                strip_index_format: None,
                front_face: wgpu::FrontFace::Ccw,
                cull_mode: None,
                unclipped_depth: false,
                polygon_mode: wgpu::PolygonMode::Fill,
                conservative: false,
            },
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            multiview: None,
            cache: None,
        });

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
                WinitEvent::Input(event) => {
                    state.process_input_event(event);
                    state.niri.queue_redraw(&state.backend.metal().output);
                }
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
            cursor_pipeline,
            cursor_bind_group,
            cursor_uniform_buffer,
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
            // Elegant modern dark canvas
            wgpu::Color {
                r: 0.08,
                g: 0.09,
                b: 0.12,
                a: 1.0,
            }
        };

        // Query Niri pointer location and compute cursor rendering data
        let mut cursor_uniforms = None;
        if let Some(pointer) = niri.seat.get_pointer() {
            let loc = pointer.current_location();
            let scale = output.current_scale().fractional_scale() as f32;
            let cursor_size = 28.0 * scale;

            cursor_uniforms = Some(CursorUniforms {
                viewport_size: [
                    self.surface_config.width as f32,
                    self.surface_config.height as f32,
                ],
                cursor_pos: [loc.x as f32 * scale, loc.y as f32 * scale],
                cursor_size: [cursor_size, cursor_size],
                hotspot: [1.0 * scale, 1.0 * scale],
            });
        }

        if let Some(u) = &cursor_uniforms {
            self.queue.write_buffer(
                &self.cursor_uniform_buffer,
                0,
                bytemuck::bytes_of(u),
            );
        }

        {
            let mut rpass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("niri-metal-main-pass"),
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

            // Draw Niri's own hardware-accelerated cursor
            if cursor_uniforms.is_some() {
                rpass.set_pipeline(&self.cursor_pipeline);
                rpass.set_bind_group(0, &self.cursor_bind_group, &[]);
                rpass.draw(0..6, 0..1);
            }
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

const CURSOR_SHADER_SRC: &str = r#"
struct Uniforms {
    viewport_size: vec2<f32>,
    cursor_pos: vec2<f32>,
    cursor_size: vec2<f32>,
    hotspot: vec2<f32>,
};

@group(0) @binding(0) var<uniform> u: Uniforms;
@group(0) @binding(1) var t_cursor: texture_2d<f32>;
@group(0) @binding(2) var s_cursor: sampler;

struct VertexOutput {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) uv: vec2<f32>,
};

@vertex
fn vs_main(@builtin(vertex_index) in_vertex_index: u32) -> VertexOutput {
    var out: VertexOutput;
    var pos = vec2<f32>(0.0, 0.0);
    var uv = vec2<f32>(0.0, 0.0);
    switch (in_vertex_index) {
        case 0u: { pos = vec2<f32>(0.0, 0.0); uv = vec2<f32>(0.0, 0.0); }
        case 1u: { pos = vec2<f32>(1.0, 0.0); uv = vec2<f32>(1.0, 0.0); }
        case 2u: { pos = vec2<f32>(0.0, 1.0); uv = vec2<f32>(0.0, 1.0); }
        case 3u: { pos = vec2<f32>(1.0, 0.0); uv = vec2<f32>(1.0, 0.0); }
        case 4u: { pos = vec2<f32>(1.0, 1.0); uv = vec2<f32>(1.0, 1.0); }
        case 5u: { pos = vec2<f32>(0.0, 1.0); uv = vec2<f32>(0.0, 1.0); }
        default: {}
    }
    out.uv = uv;

    let pixel_pos = (u.cursor_pos - u.hotspot) + pos * u.cursor_size;
    let ndc_x = (pixel_pos.x / u.viewport_size.x) * 2.0 - 1.0;
    let ndc_y = 1.0 - (pixel_pos.y / u.viewport_size.y) * 2.0;

    out.clip_position = vec4<f32>(ndc_x, ndc_y, 0.0, 1.0);
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    return textureSample(t_cursor, s_cursor, in.uv);
}
"#;

#[repr(C)]
#[derive(Copy, Clone, Debug, Default, PartialEq)]
pub struct NSRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

/// Configures the macOS AppKit window to cover the full physical display including the camera notch area.
///
/// # Safety
///
/// - `ns_view_ptr` must be a valid, non-null pointer to an AppKit `NSView` instance.
/// - Must be executed on the main thread (thread 0 / dispatch main queue) per AppKit threading model.
/// - Objective-C calling conventions for Apple Silicon ARM64 are adhered to: homogeneous floating-point
///   aggregates (like `NSRect`, composed of 4 `f64` doubles) are passed/returned via floating-point registers
///   `d0`-`d3`, and standard scalar/pointer parameters via integer registers `x0`-`x3`.
#[cfg(target_os = "macos")]
unsafe fn bypass_macos_notch(ns_view_ptr: *mut c_void) {
    if ns_view_ptr.is_null() {
        return;
    }

    extern "C" {
        fn sel_registerName(name: *const c_char) -> *mut c_void;
        fn objc_getClass(name: *const c_char) -> *mut c_void;
        fn objc_msgSend();
    }

    let sel_window = sel_registerName(c"window".as_ptr());
    let sel_screen = sel_registerName(c"screen".as_ptr());
    let sel_main_screen = sel_registerName(c"mainScreen".as_ptr());
    let sel_frame = sel_registerName(c"frame".as_ptr());
    let sel_set_frame = sel_registerName(c"setFrame:display:animate:".as_ptr());
    let sel_set_style_mask = sel_registerName(c"setStyleMask:".as_ptr());
    let sel_set_collection_behavior =
        sel_registerName(c"setCollectionBehavior:".as_ptr());
    let sel_set_level = sel_registerName(c"setLevel:".as_ptr());
    let sel_shared_application =
        sel_registerName(c"sharedApplication".as_ptr());
    let sel_set_presentation_options =
        sel_registerName(c"setPresentationOptions:".as_ptr());

    let msg_send_ptr: unsafe extern "C" fn(*mut c_void, *mut c_void) -> *mut c_void =
        std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
    let msg_send_rect: unsafe extern "C" fn(*mut c_void, *mut c_void) -> NSRect =
        std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
    let msg_send_void_usize: unsafe extern "C" fn(*mut c_void, *mut c_void, usize) =
        std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
    let msg_send_void_isize: unsafe extern "C" fn(*mut c_void, *mut c_void, isize) =
        std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
    let msg_send_void_rect_bool_bool: unsafe extern "C" fn(
        *mut c_void,
        *mut c_void,
        NSRect,
        bool,
        bool,
    ) = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());

    let window = msg_send_ptr(ns_view_ptr, sel_window);
    if window.is_null() {
        return;
    }

    let mut screen = msg_send_ptr(window, sel_screen);
    if screen.is_null() {
        let cls_screen = objc_getClass(c"NSScreen".as_ptr());
        if !cls_screen.is_null() {
            screen = msg_send_ptr(cls_screen, sel_main_screen);
        }
    }
    if screen.is_null() {
        return;
    }

    // [screen frame] spans the full physical display rectangle, including the camera notch area!
    let full_frame = msg_send_rect(screen, sel_frame);

    // 0 = NSWindowStyleMaskBorderless
    msg_send_void_usize(window, sel_set_style_mask, 0);

    // FullScreenAuxiliary (16) | CanJoinAllSpaces (1) | Stationary (64) | IgnoresCycle (128)
    msg_send_void_usize(window, sel_set_collection_behavior, 16 | 1 | 64 | 128);

    // setFrame:full_frame display:YES animate:NO
    msg_send_void_rect_bool_bool(window, sel_set_frame, full_frame, true, false);

    // Window level: NSMainMenuWindowLevel + 1 = 25 (renders over and behind the notch without obstruction)
    msg_send_void_isize(window, sel_set_level, 25);

    // Autohide Menu Bar and Dock for an immersive fullscreen experience
    let cls_app = objc_getClass(c"NSApplication".as_ptr());
    if !cls_app.is_null() {
        let app = msg_send_ptr(cls_app, sel_shared_application);
        if !app.is_null() {
            // NSApplicationPresentationAutoHideMenuBar (1) | NSApplicationPresentationAutoHideDock (4)
            msg_send_void_usize(app, sel_set_presentation_options, 1 | 4);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_cursor_uniforms_layout() {
        assert_eq!(std::mem::size_of::<CursorUniforms>(), 32);
        let uniforms = CursorUniforms {
            viewport_size: [1920.0, 1080.0],
            cursor_pos: [100.0, 200.0],
            cursor_size: [32.0, 32.0],
            hotspot: [1.0, 1.0],
        };
        let bytes = bytemuck::bytes_of(&uniforms);
        assert_eq!(bytes.len(), 32);
    }

    #[test]
    fn test_cursor_embedded_texture() {
        let cursor_bytes = include_bytes!("../../resources/cursor.rgba");
        // 64x64 RGBA8 = 64 * 64 * 4 = 16384 bytes
        assert_eq!(cursor_bytes.len(), 64 * 64 * 4);
        // Ensure texture contains actual non-zero pixel data
        let non_zero_count = cursor_bytes.iter().filter(|&&b| b != 0).count();
        assert!(non_zero_count > 0, "cursor texture must not be completely transparent");
    }

    #[test]
    fn test_cursor_shader_wgsl_syntax() {
        let instance = wgpu::Instance::new(&wgpu::InstanceDescriptor {
            backends: wgpu::Backends::all(),
            ..Default::default()
        });
        let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            compatible_surface: None,
            force_fallback_adapter: false,
        }));
        if let Some(adapter) = adapter {
            let (device, _queue) = pollster::block_on(adapter.request_device(
                &wgpu::DeviceDescriptor {
                    label: Some("test-device"),
                    required_features: wgpu::Features::empty(),
                    required_limits: wgpu::Limits::default(),
                    memory_hints: wgpu::MemoryHints::default(),
                },
                None,
            ))
            .expect("failed to create test device");

            let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
                label: Some("test-cursor-shader"),
                source: wgpu::ShaderSource::Wgsl(CURSOR_SHADER_SRC.into()),
            });
            let _ = shader;
        }
    }

    #[test]
    fn test_cursor_ndc_projection_math() {
        let viewport = [2560.0f32, 1600.0f32];
        let hotspot = [0.0f32, 0.0f32];
        let cursor_size = [32.0f32, 32.0f32];

        // Top-left corner (0, 0)
        let pos_tl = [0.0f32, 0.0f32];
        let pixel_tl_x = (pos_tl[0] - hotspot[0]) + 0.0 * cursor_size[0];
        let pixel_tl_y = (pos_tl[1] - hotspot[1]) + 0.0 * cursor_size[1];
        let ndc_tl_x = (pixel_tl_x / viewport[0]) * 2.0 - 1.0;
        let ndc_tl_y = 1.0 - (pixel_tl_y / viewport[1]) * 2.0;
        assert_eq!(ndc_tl_x, -1.0);
        assert_eq!(ndc_tl_y, 1.0);

        // Center (1280, 800)
        let pos_mid = [1280.0f32, 800.0f32];
        let pixel_mid_x = (pos_mid[0] - hotspot[0]) + 0.0 * cursor_size[0];
        let pixel_mid_y = (pos_mid[1] - hotspot[1]) + 0.0 * cursor_size[1];
        let ndc_mid_x = (pixel_mid_x / viewport[0]) * 2.0 - 1.0;
        let ndc_mid_y = 1.0 - (pixel_mid_y / viewport[1]) * 2.0;
        assert_eq!(ndc_mid_x, 0.0);
        assert_eq!(ndc_mid_y, 0.0);

        // Bottom-right corner (2560, 1600)
        let pos_br = [2560.0f32, 1600.0f32];
        let pixel_br_x = (pos_br[0] - hotspot[0]) + 0.0 * cursor_size[0];
        let pixel_br_y = (pos_br[1] - hotspot[1]) + 0.0 * cursor_size[1];
        let ndc_br_x = (pixel_br_x / viewport[0]) * 2.0 - 1.0;
        let ndc_br_y = 1.0 - (pixel_br_y / viewport[1]) * 2.0;
        assert_eq!(ndc_br_x, 1.0);
        assert_eq!(ndc_br_y, -1.0);
    }

    #[test]
    #[cfg(target_os = "macos")]
    fn test_notch_bypass_objc_symbols() {
        extern "C" {
            fn sel_registerName(name: *const c_char) -> *mut c_void;
            fn objc_getClass(name: *const c_char) -> *mut c_void;
            fn objc_msgSend();
        }

        let cls_screen = unsafe { objc_getClass(c"NSScreen".as_ptr()) };
        assert!(!cls_screen.is_null(), "NSScreen class must exist on macOS");

        let cls_app = unsafe { objc_getClass(c"NSApplication".as_ptr()) };
        assert!(!cls_app.is_null(), "NSApplication class must exist on macOS");

        let sel_main_screen = unsafe { sel_registerName(c"mainScreen".as_ptr()) };
        assert!(!sel_main_screen.is_null());

        let sel_frame = unsafe { sel_registerName(c"frame".as_ptr()) };
        assert!(!sel_frame.is_null());

        let msg_send_ptr: unsafe extern "C" fn(*mut c_void, *mut c_void) -> *mut c_void =
            unsafe { std::mem::transmute(objc_msgSend as unsafe extern "C" fn()) };
        let msg_send_rect: unsafe extern "C" fn(*mut c_void, *mut c_void) -> NSRect =
            unsafe { std::mem::transmute(objc_msgSend as unsafe extern "C" fn()) };

        let main_screen = unsafe { msg_send_ptr(cls_screen, sel_main_screen) };
        if !main_screen.is_null() {
            let frame = unsafe { msg_send_rect(main_screen, sel_frame) };
            assert!(frame.width > 0.0, "Screen width must be positive: {}", frame.width);
            assert!(frame.height > 0.0, "Screen height must be positive: {}", frame.height);
        }
    }
}
