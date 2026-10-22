//! Mock input types for non-Linux platforms (e.g. macOS).
#![allow(clippy::result_unit_err, clippy::missing_safety_doc)]

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Device;

impl Device {
    pub fn name(&self) -> &str {
        "mock-input-device"
    }

    pub fn sysname(&self) -> &str {
        "mock0"
    }

    pub fn has_capability(&self, _cap: DeviceCapability) -> bool {
        false
    }

    pub fn config_accel_set_profile(&mut self, _profile: AccelProfile) -> Result<(), ()> {
        Ok(())
    }

    pub fn config_tap_set_enabled(&mut self, _enabled: bool) -> Result<(), ()> {
        Ok(())
    }

    pub fn config_tap_set_button_map(&mut self, _map: TapButtonMap) -> Result<(), ()> {
        Ok(())
    }

    pub fn config_tap_set_drag_enabled(&mut self, _enabled: bool) -> Result<(), ()> {
        Ok(())
    }

    pub fn config_tap_set_drag_lock_enabled(&mut self, _enabled: DragLockState) -> Result<(), ()> {
        Ok(())
    }

    pub fn config_natural_scroll_set_enabled(&mut self, _enabled: bool) -> Result<(), ()> {
        Ok(())
    }

    pub fn config_left_handed_set_enabled(&mut self, _enabled: bool) -> Result<(), ()> {
        Ok(())
    }

    pub fn config_middle_emulation_set_enabled(&mut self, _enabled: bool) -> Result<(), ()> {
        Ok(())
    }

    pub fn config_dwt_set_enabled(&mut self, _enabled: bool) -> Result<(), ()> {
        Ok(())
    }

    pub fn config_dwtp_set_enabled(&mut self, _enabled: bool) -> Result<(), ()> {
        Ok(())
    }

    pub fn config_scroll_set_method(&mut self, _method: ScrollMethod) -> Result<(), ()> {
        Ok(())
    }

    pub fn config_scroll_set_button(&mut self, _button: u32) -> Result<(), ()> {
        Ok(())
    }

    pub fn config_scroll_set_button_lock(
        &mut self,
        _state: ScrollButtonLockState,
    ) -> Result<(), ()> {
        Ok(())
    }

    pub fn config_click_set_method(&mut self, _method: ClickMethod) -> Result<(), ()> {
        Ok(())
    }

    pub fn config_send_events_set_mode(&mut self, _mode: SendEventsMode) -> Result<(), ()> {
        Ok(())
    }

    pub fn config_accel_set_speed(&mut self, _speed: f64) -> Result<(), ()> {
        Ok(())
    }

    pub fn config_tap_finger_count(&self) -> u32 {
        0
    }

    pub fn config_scroll_natural_scroll_enabled(&self) -> bool {
        false
    }

    pub fn config_scroll_set_natural_scroll_enabled(&mut self, _enabled: bool) -> Result<(), ()> {
        Ok(())
    }

    pub fn config_left_handed_set(&mut self, _enabled: bool) -> Result<(), ()> {
        Ok(())
    }

    pub fn config_tap_default_drag_enabled(&self) -> bool {
        false
    }

    pub fn config_accel_default_profile(&self) -> Option<AccelProfile> {
        None
    }

    pub fn config_scroll_default_method(&self) -> Option<ScrollMethod> {
        None
    }

    pub fn config_tap_default_button_map(&self) -> Option<TapButtonMap> {
        None
    }

    pub fn config_click_default_method(&self) -> Option<ClickMethod> {
        None
    }

    pub fn config_calibration_set_matrix(&mut self, _matrix: [f32; 6]) -> Result<(), ()> {
        Ok(())
    }

    pub fn config_calibration_default_matrix(&self) -> Option<[f32; 6]> {
        None
    }

    pub unsafe fn udev_device(&self) -> Option<UdevDevice> {
        None
    }

    pub fn led_update(&mut self, _leds: DeviceLed) {}
}

#[derive(Debug, Clone)]
pub struct UdevDevice;

impl UdevDevice {
    pub fn property_value(&self, _prop: &str) -> Option<&str> {
        None
    }
}

bitflags::bitflags! {
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub struct DeviceLed: u32 {
        const NUM_LOCK = 1;
        const CAPS_LOCK = 2;
        const SCROLL_LOCK = 4;
    }
}

impl From<smithay::input::keyboard::LedState> for DeviceLed {
    fn from(state: smithay::input::keyboard::LedState) -> Self {
        let mut leds = DeviceLed::empty();
        if state.num == Some(true) {
            leds |= DeviceLed::NUM_LOCK;
        }
        if state.caps == Some(true) {
            leds |= DeviceLed::CAPS_LOCK;
        }
        if state.scroll == Some(true) {
            leds |= DeviceLed::SCROLL_LOCK;
        }
        leds
    }
}

impl smithay::backend::input::Device for Device {
    fn id(&self) -> String {
        "mock-id".to_string()
    }
    fn name(&self) -> String {
        "mock-device".to_string()
    }
    fn has_capability(&self, _capability: smithay::backend::input::DeviceCapability) -> bool {
        false
    }
    fn usb_id(&self) -> Option<(u32, u32)> {
        None
    }
    fn syspath(&self) -> Option<std::path::PathBuf> {
        None
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum DeviceCapability {
    Keyboard,
    Pointer,
    Touch,
    TabletTool,
    TabletPad,
    Gesture,
    Switch,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AccelProfile {
    Flat,
    Adaptive,
}

impl From<niri_config::input::AccelProfile> for AccelProfile {
    fn from(value: niri_config::input::AccelProfile) -> Self {
        match value {
            niri_config::input::AccelProfile::Adaptive => Self::Adaptive,
            niri_config::input::AccelProfile::Flat => Self::Flat,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TapButtonMap {
    Lrm,
    Lmr,
}

impl From<niri_config::input::TapButtonMap> for TapButtonMap {
    fn from(value: niri_config::input::TapButtonMap) -> Self {
        match value {
            niri_config::input::TapButtonMap::LeftRightMiddle => Self::Lrm,
            niri_config::input::TapButtonMap::LeftMiddleRight => Self::Lmr,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScrollMethod {
    NoScroll,
    TwoFinger,
    Edge,
    OnButtonDown,
}

impl From<niri_config::input::ScrollMethod> for ScrollMethod {
    fn from(value: niri_config::input::ScrollMethod) -> Self {
        match value {
            niri_config::input::ScrollMethod::NoScroll => Self::NoScroll,
            niri_config::input::ScrollMethod::TwoFinger => Self::TwoFinger,
            niri_config::input::ScrollMethod::Edge => Self::Edge,
            niri_config::input::ScrollMethod::OnButtonDown => Self::OnButtonDown,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScrollButtonLockState {
    Enabled,
    Disabled,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DragLockState {
    EnabledTimeout,
    EnabledSticky,
    Disabled,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClickMethod {
    None,
    ButtonAreas,
    Clickfinger,
}

impl From<niri_config::input::ClickMethod> for ClickMethod {
    fn from(value: niri_config::input::ClickMethod) -> Self {
        match value {
            niri_config::input::ClickMethod::Clickfinger => Self::Clickfinger,
            niri_config::input::ClickMethod::ButtonAreas => Self::ButtonAreas,
        }
    }
}

bitflags::bitflags! {
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub struct SendEventsMode: u32 {
        const ENABLED = 1;
        const DISABLED = 2;
        const DISABLED_ON_EXTERNAL_MOUSE = 4;
    }
}

pub mod event {
    pub mod gesture {
        pub trait GestureEventCoordinates {
            fn dx(&self) -> f64 {
                0.0
            }
            fn dy(&self) -> f64 {
                0.0
            }
        }

        #[derive(Debug)]
        pub struct GestureSwipeUpdateEvent;

        impl GestureSwipeUpdateEvent {
            pub fn dx_unaccelerated(&self) -> f64 {
                0.0
            }
            pub fn dy_unaccelerated(&self) -> f64 {
                0.0
            }
        }

        impl GestureEventCoordinates for GestureSwipeUpdateEvent {}
    }
}
