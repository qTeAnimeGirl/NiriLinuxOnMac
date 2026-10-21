/**
 * interface_contracts.h
 *
 * Inter-Agent & IPC Interface Definitions for Niri macOS + MicroVM Bridge.
 * Standard C header defining ABI, vsock wire packets, and shared-memory descriptor formats.
 */

#ifndef NIRI_MACOS_INTERFACE_CONTRACTS_H
#define NIRI_MACOS_INTERFACE_CONTRACTS_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NIRI_VSOCK_WAYLAND_PORT 1024
#define NIRI_VSOCK_CONTROL_PORT 1025
#define NIRI_PROTOCOL_MAGIC     0x4E495249 /* 'NIRI' */
#define NIRI_PROTOCOL_VERSION   1

/* Buffer format definitions */
typedef enum niri_pixel_format {
    NIRI_FORMAT_ARGB8888 = 0,
    NIRI_FORMAT_XRGB8888 = 1,
    NIRI_FORMAT_RGBA8888 = 2,
    NIRI_FORMAT_BGRA8888 = 3,
} niri_pixel_format_t;

/* Header for vsock tunneled messages with out-of-band FD/shm metadata */
#pragma pack(push, 1)
typedef struct niri_ipc_packet_header {
    uint32_t magic;         /* Must equal NIRI_PROTOCOL_MAGIC */
    uint16_t version;       /* Must equal NIRI_PROTOCOL_VERSION */
    uint16_t msg_type;      /* 0 = Raw Wayland Wire, 1 = SHM Pool Create, 2 = Frame Commit */
    uint32_t payload_size;  /* Length of trailing payload in bytes */
    uint32_t sequence_id;   /* Monotonic sequence identifier */
} niri_ipc_packet_header_t;

/* SHM buffer allocation descriptor transferred over vsock */
typedef struct niri_shm_buffer_desc {
    uint64_t shm_pool_id;
    uint32_t offset;
    int32_t  width;
    int32_t  height;
    int32_t  stride;
    uint32_t format;        /* niri_pixel_format_t */
} niri_shm_buffer_desc_t;

/* Frame presentation synchronization packet */
typedef struct niri_frame_commit_desc {
    uint64_t surface_id;
    uint64_t buffer_id;
    uint64_t presentation_timestamp_ns;
    uint32_t damage_x;
    uint32_t damage_y;
    uint32_t damage_width;
    uint32_t damage_height;
} niri_frame_commit_desc_t;
#pragma pack(pop)

/* Boundary validation helper declarations */
int niri_validate_shm_bounds(uint64_t pool_size, uint32_t offset, int32_t height, int32_t stride);

#ifdef __cplusplus
}
#endif

#endif /* NIRI_MACOS_INTERFACE_CONTRACTS_H */
