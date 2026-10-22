/**
 * vm/proto/niri_ipc.h
 *
 * Wire protocol definition and shared memory descriptor ABI for Niri macOS + MicroVM.
 * Conforms to interface contracts specified in agents/specs/interface_contracts.h.
 */

#ifndef NIRI_VM_PROTO_IPC_H
#define NIRI_VM_PROTO_IPC_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NIRI_VSOCK_WAYLAND_PORT 1024
#define NIRI_VSOCK_CONTROL_PORT 1025
#define NIRI_PROTOCOL_MAGIC     0x4E495249 /* 'NIRI' */
#define NIRI_PROTOCOL_VERSION   1
#define NIRI_MAX_PAYLOAD_SIZE   (16 * 1024 * 1024) /* 16 MB max message size */

/* Packet message types */
typedef enum niri_msg_type {
    NIRI_MSG_RAW_WIRE         = 0, /* Raw Wayland wire protocol bytes */
    NIRI_MSG_SHM_POOL_CREATE  = 1, /* SHM pool creation / FD transfer */
    NIRI_MSG_FRAME_COMMIT     = 2, /* Frame presentation commit & damage */
    NIRI_MSG_CONTROL_PING     = 3, /* Health check ping */
    NIRI_MSG_CONTROL_PONG     = 4, /* Health check pong */
} niri_msg_type_t;

/* Buffer format definitions matching wl_shm formats */
typedef enum niri_pixel_format {
    NIRI_FORMAT_ARGB8888 = 0,
    NIRI_FORMAT_XRGB8888 = 1,
    NIRI_FORMAT_RGBA8888 = 2,
    NIRI_FORMAT_BGRA8888 = 3,
} niri_pixel_format_t;

/* Header for vsock tunneled messages */
#pragma pack(push, 1)
typedef struct niri_ipc_packet_header {
    uint32_t magic;         /* Must equal NIRI_PROTOCOL_MAGIC */
    uint16_t version;       /* Must equal NIRI_PROTOCOL_VERSION */
    uint16_t msg_type;      /* niri_msg_type_t */
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

/* SHM Pool creation payload transfer descriptor */
typedef struct niri_shm_pool_init {
    uint64_t pool_id;
    uint64_t size;
    char     shm_path[256]; /* Optional virtio-fs shared path, or empty if inline */
} niri_shm_pool_init_t;

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

/**
 * Validates that an SHM buffer layout does not exceed pool capacity.
 * Checks for integer multiplication and addition overflows.
 *
 * @param pool_size   Total capacity of the backing SHM pool in bytes.
 * @param offset      Byte offset within the pool for the buffer start.
 * @param height      Height of the buffer in pixels (must be > 0).
 * @param stride      Row pitch in bytes (must be > 0).
 * @return 0 if valid and safely bounded, -1 if invalid or overflow detected.
 */
static inline int niri_validate_shm_bounds(uint64_t pool_size, uint32_t offset, int32_t height, int32_t stride) {
    if (height <= 0 || stride <= 0) {
        return -1;
    }
    uint64_t total_span;
    if (__builtin_mul_overflow((uint64_t)height, (uint64_t)stride, &total_span)) {
        return -1;
    }
    uint64_t required_size;
    if (__builtin_add_overflow((uint64_t)offset, total_span, &required_size)) {
        return -1;
    }
    if (required_size > pool_size) {
        return -1;
    }
    return 0;
}

#ifdef __cplusplus
}
#endif

#endif /* NIRI_VM_PROTO_IPC_H */
