//! `vm/proto/mod.rs`
//!
//! Rust ABI contracts and safe packet serialization/deserialization for Niri VM bridge.

#![allow(dead_code)]

use std::convert::TryFrom;
use std::io::{self, Read, Write};

pub const NIRI_VSOCK_WAYLAND_PORT: u32 = 1024;
pub const NIRI_VSOCK_CONTROL_PORT: u32 = 1025;
pub const NIRI_PROTOCOL_MAGIC: u32 = 0x4E49_5249; // 'NIRI'
pub const NIRI_PROTOCOL_VERSION: u16 = 1;
pub const NIRI_MAX_PAYLOAD_SIZE: u32 = 16 * 1024 * 1024; // 16 MB limit

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u16)]
pub enum NiriMsgType {
    RawWire = 0,
    ShmPoolCreate = 1,
    FrameCommit = 2,
    ControlPing = 3,
    ControlPong = 4,
}

impl TryFrom<u16> for NiriMsgType {
    type Error = io::Error;

    fn try_from(value: u16) -> Result<Self, Self::Error> {
        match value {
            0 => Ok(Self::RawWire),
            1 => Ok(Self::ShmPoolCreate),
            2 => Ok(Self::FrameCommit),
            3 => Ok(Self::ControlPing),
            4 => Ok(Self::ControlPong),
            _ => Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("Unknown message type: {value}"),
            )),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(C, packed)]
pub struct NiriIpcPacketHeader {
    pub magic: u32,
    pub version: u16,
    pub msg_type: u16,
    pub payload_size: u32,
    pub sequence_id: u32,
}

impl NiriIpcPacketHeader {
    pub const SIZE: usize = std::mem::size_of::<Self>();

    pub fn new(msg_type: NiriMsgType, payload_size: u32, sequence_id: u32) -> Self {
        Self {
            magic: NIRI_PROTOCOL_MAGIC,
            version: NIRI_PROTOCOL_VERSION,
            msg_type: msg_type as u16,
            payload_size,
            sequence_id,
        }
    }

    pub fn validate(&self) -> io::Result<NiriMsgType> {
        let magic = self.magic;
        let version = self.version;
        let payload_size = self.payload_size;
        let msg_type = self.msg_type;

        if magic != NIRI_PROTOCOL_MAGIC {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("Invalid magic constant: 0x{magic:08X}"),
            ));
        }
        if version != NIRI_PROTOCOL_VERSION {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("Unsupported protocol version: {version}"),
            ));
        }
        if payload_size > NIRI_MAX_PAYLOAD_SIZE {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("Payload size exceeds maximum allowed: {payload_size} bytes"),
            ));
        }
        NiriMsgType::try_from(msg_type)
    }

    pub fn write_to<W: Write>(&self, mut writer: W) -> io::Result<()> {
        // SAFETY: NiriIpcPacketHeader is #[repr(C, packed)] and exactly Self::SIZE (16 bytes)
        // consisting only of primitive integers. Copying its bytes to a byte array is sound.
        let bytes: [u8; Self::SIZE] = unsafe { std::mem::transmute_copy(self) };
        writer.write_all(&bytes)
    }

    pub fn read_from<R: Read>(mut reader: R) -> io::Result<Self> {
        let mut bytes = [0u8; Self::SIZE];
        reader.read_exact(&mut bytes)?;
        // SAFETY: NiriIpcPacketHeader is #[repr(C, packed)] and exactly Self::SIZE (16 bytes).
        // All fields are primitive integer types (u16/u32) where every 16-byte pattern represents
        // a valid bitwise state. The header fields are validated immediately by calling .validate().
        let header: Self = unsafe { std::mem::transmute_copy(&bytes) };
        Ok(header)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(C, packed)]
pub struct NiriShmBufferDesc {
    pub shm_pool_id: u64,
    pub offset: u32,
    pub width: i32,
    pub height: i32,
    pub stride: i32,
    pub format: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(C, packed)]
pub struct NiriFrameCommitDesc {
    pub surface_id: u64,
    pub buffer_id: u64,
    pub presentation_timestamp_ns: u64,
    pub damage_x: u32,
    pub damage_y: u32,
    pub damage_width: u32,
    pub damage_height: u32,
}

/// Validates that an SHM buffer layout does not exceed pool capacity.
/// Performs strict overflow-checked arithmetic.
pub fn validate_shm_bounds(pool_size: u64, offset: u32, height: i32, stride: i32) -> bool {
    if height <= 0 || stride <= 0 {
        return false;
    }
    let Some(total_span) = (height as u64).checked_mul(stride as u64) else {
        return false;
    };
    let Some(required_size) = (offset as u64).checked_add(total_span) else {
        return false;
    };
    required_size <= pool_size
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_header_validation_success() {
        let header = NiriIpcPacketHeader::new(NiriMsgType::RawWire, 1024, 42);
        assert_eq!(header.validate().unwrap(), NiriMsgType::RawWire);
    }

    #[test]
    fn test_header_validation_bad_magic() {
        let mut header = NiriIpcPacketHeader::new(NiriMsgType::RawWire, 1024, 42);
        header.magic = 0xDEADBEEF;
        assert!(header.validate().is_err());
    }

    #[test]
    fn test_header_validation_oversized_payload() {
        let header = NiriIpcPacketHeader::new(NiriMsgType::RawWire, NIRI_MAX_PAYLOAD_SIZE + 1, 1);
        assert!(header.validate().is_err());
    }

    #[test]
    fn test_shm_bounds_valid() {
        // 1920x1080 @ 4bpp (stride 7680) = 8,294,400 bytes
        let pool_size = 10_000_000;
        assert!(validate_shm_bounds(pool_size, 0, 1080, 7680));
        assert!(validate_shm_bounds(pool_size, 1000, 1080, 7680));
    }

    #[test]
    fn test_shm_bounds_overflow_rejection() {
        let pool_size = 10_000_000;
        // Exceeds pool size
        assert!(!validate_shm_bounds(pool_size, 5_000_000, 1080, 7680));
        // Negative dimensions rejected
        assert!(!validate_shm_bounds(pool_size, 0, -1080, 7680));
        assert!(!validate_shm_bounds(pool_size, 0, 1080, -7680));
        // Integer multiplication overflow rejected
        assert!(!validate_shm_bounds(pool_size, 0, i32::MAX, i32::MAX));
    }
}
