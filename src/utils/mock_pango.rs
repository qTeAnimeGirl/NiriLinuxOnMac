//! Mock Pango and Cairo types for building without system Pango/Cairo C libraries.
#![allow(clippy::result_unit_err)]

pub mod cairo {
    use std::sync::Arc;

    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub enum Format {
        ARgb32,
        Rgb24,
        A8,
        A1,
    }

    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub enum Operator {
        Clear,
        Source,
        Over,
        In,
        Out,
        Atop,
        Dest,
        DestOver,
        DestIn,
        DestOut,
        DestAtop,
        Xor,
        Add,
        Saturate,
    }

    #[derive(Debug, Clone)]
    pub struct Error;

    impl std::fmt::Display for Error {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            write!(f, "Cairo mock error")
        }
    }

    impl std::error::Error for Error {}

    #[derive(Debug, Clone)]
    pub struct ImageSurface {
        width: i32,
        height: i32,
        stride: i32,
        data: Arc<std::sync::Mutex<Vec<u8>>>,
    }

    impl ImageSurface {
        pub fn create(format: Format, width: i32, height: i32) -> Result<Self, Error> {
            let bpp = match format {
                Format::ARgb32 | Format::Rgb24 => 4,
                Format::A8 => 1,
                Format::A1 => 1,
            };
            let stride = width * bpp;
            let len = (stride * height).max(0) as usize;
            Ok(Self {
                width,
                height,
                stride,
                data: Arc::new(std::sync::Mutex::new(vec![0; len])),
            })
        }

        pub fn width(&self) -> i32 {
            self.width
        }

        pub fn height(&self) -> i32 {
            self.height
        }

        pub fn stride(&self) -> i32 {
            self.stride
        }

        pub fn flush(&self) {}
        pub fn finish(&self) {}

        pub fn data(&self) -> Result<SurfaceData, Error> {
            Ok(SurfaceData {
                data: self.data.clone(),
            })
        }

        pub fn take_data(self) -> Result<Vec<u8>, Error> {
            let data = self.data.lock().unwrap().clone();
            Ok(data)
        }
    }

    #[allow(dead_code)]
    pub struct SurfaceData {
        data: Arc<std::sync::Mutex<Vec<u8>>>,
    }

    impl std::ops::Deref for SurfaceData {
        type Target = [u8];
        fn deref(&self) -> &Self::Target {
            // Note: For mock surface, leak or static empty if locked isn't possible
            &[]
        }
    }

    impl std::ops::DerefMut for SurfaceData {
        fn deref_mut(&mut self) -> &mut Self::Target {
            &mut []
        }
    }

    #[derive(Debug)]
    pub struct Context;

    impl Context {
        pub fn new(_surface: &ImageSurface) -> Result<Self, Error> {
            Ok(Self)
        }

        pub fn scale(&self, _sx: f64, _sy: f64) {}
        pub fn translate(&self, _tx: f64, _ty: f64) {}
        pub fn set_source_rgba(&self, _r: f64, _g: f64, _b: f64, _a: f64) {}
        pub fn set_source_rgb(&self, _r: f64, _g: f64, _b: f64) {}
        pub fn paint(&self) -> Result<(), Error> {
            Ok(())
        }
        pub fn move_to(&self, _x: f64, _y: f64) {}
        pub fn rel_move_to(&self, _dx: f64, _dy: f64) {}
        pub fn line_to(&self, _x: f64, _y: f64) {}
        pub fn stroke(&self) -> Result<(), Error> {
            Ok(())
        }
        pub fn fill(&self) -> Result<(), Error> {
            Ok(())
        }
        pub fn rectangle(&self, _x: f64, _y: f64, _w: f64, _h: f64) {}
        pub fn clip(&self) {}
        pub fn reset_clip(&self) {}
        pub fn set_line_width(&self, _w: f64) {}
        pub fn set_operator(&self, _op: Operator) {}
        pub fn save(&self) -> Result<(), Error> {
            Ok(())
        }
        pub fn restore(&self) -> Result<(), Error> {
            Ok(())
        }
        pub fn arc(&self, _xc: f64, _yc: f64, _radius: f64, _angle1: f64, _angle2: f64) {}
        pub fn new_sub_path(&self) {}
        pub fn set_source_surface(&self, _surface: &ImageSurface, _x: f64, _y: f64) -> Result<(), Error> {
            Ok(())
        }
    }

    impl Drop for Context {
        fn drop(&mut self) {}
    }
}

pub mod pango {
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct Context;

    impl Context {
        pub fn set_round_glyph_positions(&self, _round: bool) {}
    }

    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct FontDescription {
        family: Option<String>,
        size: i32,
    }

    impl FontDescription {
        pub fn new() -> Self {
            Self {
                family: None,
                size: 12,
            }
        }

        pub fn from_string(s: &str) -> Self {
            Self {
                family: Some(s.to_string()),
                size: 12,
            }
        }

        pub fn set_family(&mut self, family: &str) {
            self.family = Some(family.to_string());
        }

        pub fn family(&self) -> Option<&str> {
            self.family.as_deref()
        }

        pub fn set_size(&mut self, size: i32) {
            self.size = size;
        }

        pub fn size(&self) -> i32 {
            self.size
        }

        pub fn set_weight(&mut self, _weight: Weight) {}
        pub fn set_absolute_size(&mut self, _size: f64) {}
    }

    impl Default for FontDescription {
        fn default() -> Self {
            Self::new()
        }
    }

    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub enum Alignment {
        Left,
        Center,
        Right,
    }

    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub enum Weight {
        Normal,
        Bold,
        Semibold,
        Light,
    }

    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub enum EllipsizeMode {
        None,
        Start,
        Middle,
        End,
    }

    #[derive(Debug, Clone, Default)]
    pub struct AttrList;

    impl AttrList {
        pub fn new() -> Self {
            Self
        }
        pub fn insert<T>(&self, _attr: T) {}
    }

    pub struct AttrColor;
    impl AttrColor {
        pub fn new_foreground(_r: u16, _g: u16, _b: u16) -> Self {
            Self
        }
        pub fn new_background(_r: u16, _g: u16, _b: u16) -> Self {
            Self
        }
    }

    pub struct AttrInt;
    impl AttrInt {
        pub fn new_weight(_w: Weight) -> Self {
            Self
        }
    }

    pub struct AttrString;
    impl AttrString {
        pub fn new_family(_f: &str) -> Self {
            Self
        }
    }

    pub fn parse_markup(
        markup_text: &str,
        _accel_marker: char,
    ) -> Result<(AttrList, String, Option<char>), String> {
        // Simple tag stripping for markup
        let mut text = String::new();
        let mut in_tag = false;
        for c in markup_text.chars() {
            if c == '<' {
                in_tag = true;
            } else if c == '>' {
                in_tag = false;
            } else if !in_tag {
                text.push(c);
            }
        }
        Ok((AttrList::new(), text, None))
    }

    #[derive(Debug, Clone)]
    pub struct Layout {
        text: std::cell::RefCell<String>,
        width: std::cell::Cell<i32>,
    }

    impl Layout {
        pub fn new() -> Self {
            Self {
                text: std::cell::RefCell::new(String::new()),
                width: std::cell::Cell::new(-1),
            }
        }

        pub fn set_text(&self, text: &str) {
            *self.text.borrow_mut() = text.to_string();
        }

        pub fn text(&self) -> String {
            self.text.borrow().clone()
        }

        pub fn set_markup(&self, markup: &str) {
            let (_, text, _) = parse_markup(markup, '\0').unwrap_or((AttrList::new(), markup.to_string(), None));
            *self.text.borrow_mut() = text;
        }

        pub fn context(&self) -> Context {
            Context
        }

        pub fn set_spacing(&self, _spacing: i32) {}
        pub fn set_font_description(&self, _desc: Option<&FontDescription>) {}
        pub fn set_alignment(&self, _align: Alignment) {}
        pub fn set_width(&self, width: i32) {
            self.width.set(width);
        }
        pub fn set_ellipsize(&self, _ellipsize: EllipsizeMode) {}
        pub fn set_attributes(&self, _attrs: Option<&AttrList>) {}
        pub fn set_single_paragraph_mode(&self, _mode: bool) {}

        pub fn pixel_size(&self) -> (i32, i32) {
            let len = self.text.borrow().len() as i32;
            (len * 8, 16)
        }

        pub fn size(&self) -> (i32, i32) {
            let (w, h) = self.pixel_size();
            (w * 1024, h * 1024)
        }
    }

    impl Default for Layout {
        fn default() -> Self {
            Self::new()
        }
    }

    pub mod glib {
        pub type GString = String;
        pub fn filename_to_uri<P: AsRef<std::path::Path>>(
            path: P,
            _hostname: Option<&str>,
        ) -> Result<String, ()> {
            Ok(format!("file://{}", path.as_ref().display()))
        }
    }
}

pub mod pangocairo {
    pub use super::cairo;
    pub use super::pango;

    pub mod functions {
        use super::cairo::Context;
        use super::pango::Layout;

        pub fn create_layout(_cr: &Context) -> Layout {
            Layout::new()
        }

        pub fn show_layout(_cr: &Context, _layout: &Layout) {}
        pub fn update_layout(_cr: &Context, _layout: &Layout) {}
    }
}
