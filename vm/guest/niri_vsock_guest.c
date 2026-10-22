/**
 * vm/guest/niri_vsock_guest.c
 *
 * Lightweight Wayland socket proxy daemon for Linux MicroVM guests.
 * Exposes /run/user/1000/wayland-0 and bridges Wayland wire protocol bytes
 * and SCM_RIGHTS file descriptors (e.g. keymaps, shm pools) across virtio-vsock (port 1024).
 *
 * Standards: POSIX.1-2008 + Linux AF_VSOCK (VMADDR_CID_HOST).
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <sys/types.h>

#ifdef __linux__
#include <linux/vm_sockets.h>
#else
/* Fallback definitions for compiling / testing on macOS host */
#define AF_VSOCK 40
#define VMADDR_CID_HOST 2
struct sockaddr_vm {
    sa_family_t svm_family;
    unsigned short svm_reserved1;
    unsigned int svm_port;
    unsigned int svm_cid;
    unsigned char svm_zero[sizeof(struct sockaddr) - sizeof(sa_family_t) - sizeof(unsigned short) - sizeof(unsigned int) * 2];
};
#endif

#include "../proto/niri_ipc.h"

#define DEFAULT_GUEST_WAYLAND_SOCKET "/run/user/1000/wayland-0"
#define DEFAULT_HOST_CID             VMADDR_CID_HOST
#define DEFAULT_HOST_PORT            NIRI_VSOCK_WAYLAND_PORT
#define BUFFER_SIZE                  65536

static volatile sig_atomic_t g_running = 1;

static void handle_signal(int sig) {
    (void)sig;
    g_running = 0;
}

typedef struct client_session {
    int client_fd;
    int vsock_fd;
    uint32_t session_id;
    pthread_t thread_c2v;
    pthread_t thread_v2c;
} client_session_t;

/**
 * Sends a buffer along with an optional file descriptor using sendmsg (SCM_RIGHTS).
 */
static ssize_t send_with_fd(int sock_fd, const void *data, size_t len, int pass_fd) {
    struct iovec iov;
    iov.iov_base = (void *)data;
    iov.iov_len = len;

    struct msghdr msg;
    memset(&msg, 0, sizeof(msg));
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;

    char cmsg_buf[CMSG_SPACE(sizeof(int))];
    if (pass_fd >= 0) {
        msg.msg_control = cmsg_buf;
        msg.msg_controllen = sizeof(cmsg_buf);

        struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
        cmsg->cmsg_level = SOL_SOCKET;
        cmsg->cmsg_type = SCM_RIGHTS;
        cmsg->cmsg_len = CMSG_LEN(sizeof(int));
        *((int *)CMSG_DATA(cmsg)) = pass_fd;
    }

    return sendmsg(sock_fd, &msg, 0);
}

/**
 * Receives data along with any ancillary file descriptor using recvmsg (SCM_RIGHTS).
 */
static ssize_t recv_with_fd(int sock_fd, void *buf, size_t len, int *recv_fd) {
    *recv_fd = -1;

    struct iovec iov;
    iov.iov_base = buf;
    iov.iov_len = len;

    char cmsg_buf[CMSG_SPACE(sizeof(int))];
    struct msghdr msg;
    memset(&msg, 0, sizeof(msg));
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = cmsg_buf;
    msg.msg_controllen = sizeof(cmsg_buf);

    ssize_t n = recvmsg(sock_fd, &msg, 0);
    if (n <= 0) {
        return n;
    }

    struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
    while (cmsg != NULL) {
        if (cmsg->cmsg_level == SOL_SOCKET && cmsg->cmsg_type == SCM_RIGHTS) {
            *recv_fd = *((int *)CMSG_DATA(cmsg));
            break;
        }
        cmsg = CMSG_NXTHDR(&msg, cmsg);
    }

    return n;
}

/**
 * Reads all available bytes from a file descriptor into a buffer.
 */
static uint8_t *read_entire_fd(int fd, size_t *out_size) {
    off_t cur = lseek(fd, 0, SEEK_CUR);
    off_t end = lseek(fd, 0, SEEK_END);
    if (end < 0) {
        *out_size = 0;
        return NULL;
    }
    lseek(fd, 0, SEEK_SET);

    size_t size = (size_t)end;
    uint8_t *buf = (uint8_t *)malloc(size > 0 ? size : 1);
    if (!buf) {
        *out_size = 0;
        return NULL;
    }

    size_t total = 0;
    while (total < size) {
        ssize_t n = read(fd, buf + total, size - total);
        if (n <= 0) break;
        total += n;
    }

    lseek(fd, cur, SEEK_SET);
    *out_size = total;
    return buf;
}

/**
 * Creates an anonymous memory file descriptor containing the specified bytes.
 */
static int create_memfd_with_data(const char *name, const void *data, size_t len) {
    int fd = -1;

#ifdef __linux__
#ifdef SYS_memfd_create
    fd = (int)syscall(SYS_memfd_create, name, MFD_CLOEXEC);
#endif
#endif

    if (fd < 0) {
        char temp_path[64];
        snprintf(temp_path, sizeof(temp_path), "/dev/shm/%s_XXXXXX", name);
        fd = mkstemp(temp_path);
        if (fd >= 0) {
            unlink(temp_path);
        }
    }

    if (fd >= 0 && len > 0 && data != NULL) {
        ssize_t written = 0;
        const uint8_t *p = (const uint8_t *)data;
        while ((size_t)written < len) {
            ssize_t n = write(fd, p + written, len - written);
            if (n <= 0) break;
            written += n;
        }
        lseek(fd, 0, SEEK_SET);
    }

    return fd;
}

/**
 * Thread: Guest Wayland Client -> virtio-vsock Host
 */
static void *thread_client_to_vsock(void *arg) {
    client_session_t *sess = (client_session_t *)arg;
    uint8_t raw_buf[BUFFER_SIZE];
    uint32_t seq = 1;

    while (g_running) {
        int fd = -1;
        ssize_t n = recv_with_fd(sess->client_fd, raw_buf, sizeof(raw_buf), &fd);
        if (n <= 0) {
            break;
        }

        if (fd >= 0) {
            // Client passed an FD (e.g. wl_shm.create_pool)
            size_t fd_size = 0;
            uint8_t *fd_data = read_entire_fd(fd, &fd_size);
            close(fd);

            niri_ipc_packet_header_t hdr;
            hdr.magic = NIRI_PROTOCOL_MAGIC;
            hdr.version = NIRI_PROTOCOL_VERSION;
            hdr.msg_type = NIRI_MSG_SHM_POOL_CREATE;
            hdr.payload_size = (uint32_t)fd_size;
            hdr.sequence_id = seq++;

            if (write(sess->vsock_fd, &hdr, sizeof(hdr)) != sizeof(hdr)) {
                free(fd_data);
                break;
            }
            if (fd_size > 0 && fd_data) {
                if ((size_t)write(sess->vsock_fd, fd_data, fd_size) != fd_size) {
                    free(fd_data);
                    break;
                }
            }
            free(fd_data);
        } else {
            // Raw wire protocol bytes
            niri_ipc_packet_header_t hdr;
            hdr.magic = NIRI_PROTOCOL_MAGIC;
            hdr.version = NIRI_PROTOCOL_VERSION;
            hdr.msg_type = NIRI_MSG_RAW_WIRE;
            hdr.payload_size = (uint32_t)n;
            hdr.sequence_id = seq++;

            if (write(sess->vsock_fd, &hdr, sizeof(hdr)) != sizeof(hdr)) {
                break;
            }
            if (write(sess->vsock_fd, raw_buf, n) != n) {
                break;
            }
        }
    }

    shutdown(sess->vsock_fd, SHUT_RDWR);
    shutdown(sess->client_fd, SHUT_RDWR);
    return NULL;
}

/**
 * Thread: virtio-vsock Host -> Guest Wayland Client
 */
static void *thread_vsock_to_client(void *arg) {
    client_session_t *sess = (client_session_t *)arg;
    niri_ipc_packet_header_t hdr;

    while (g_running) {
        // Read packet header
        ssize_t n = read(sess->vsock_fd, &hdr, sizeof(hdr));
        if (n <= 0) {
            break;
        }
        if (n != sizeof(hdr)) {
            fprintf(stderr, "[GUEST] Incomplete header received from vsock\n");
            break;
        }

        if (hdr.magic != NIRI_PROTOCOL_MAGIC || hdr.version != NIRI_PROTOCOL_VERSION) {
            fprintf(stderr, "[GUEST] Invalid magic or version in packet header\n");
            break;
        }

        if (hdr.payload_size > NIRI_MAX_PAYLOAD_SIZE) {
            fprintf(stderr, "[GUEST] Payload size %u exceeds limit\n", hdr.payload_size);
            break;
        }

        uint8_t *payload = NULL;
        if (hdr.payload_size > 0) {
            payload = (uint8_t *)malloc(hdr.payload_size);
            if (!payload) break;

            size_t total = 0;
            while (total < hdr.payload_size) {
                ssize_t r = read(sess->vsock_fd, payload + total, hdr.payload_size - total);
                if (r <= 0) break;
                total += r;
            }
            if (total != hdr.payload_size) {
                free(payload);
                break;
            }
        }

        if (hdr.msg_type == NIRI_MSG_RAW_WIRE) {
            // Forward raw wire bytes directly to client
            if (payload && hdr.payload_size > 0) {
                size_t written = 0;
                while (written < hdr.payload_size) {
                    ssize_t w = write(sess->client_fd, payload + written, hdr.payload_size - written);
                    if (w <= 0) break;
                    written += w;
                }
            }
        } else if (hdr.msg_type == NIRI_MSG_SHM_POOL_CREATE) {
            // Reconstruct FD sent from host (e.g. XKB keymap) and pass to client via SCM_RIGHTS
            int guest_fd = create_memfd_with_data("niri_keymap", payload, hdr.payload_size);
            if (guest_fd >= 0) {
                send_with_fd(sess->client_fd, "", 0, guest_fd);
                close(guest_fd);
            }
        }

        free(payload);
    }

    shutdown(sess->vsock_fd, SHUT_RDWR);
    shutdown(sess->client_fd, SHUT_RDWR);
    return NULL;
}

/**
 * Connects to the host over virtio-vsock (or fallback UNIX socket for testing).
 */
static int connect_to_host(uint32_t cid, uint32_t port, const char *fallback_socket) {
    (void)cid;
    (void)port;
#ifdef __linux__
    int sock = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (sock >= 0) {
        struct sockaddr_vm sa;
        memset(&sa, 0, sizeof(sa));
        sa.svm_family = AF_VSOCK;
        sa.svm_cid = cid;
        sa.svm_port = port;

        if (connect(sock, (struct sockaddr *)&sa, sizeof(sa)) == 0) {
            return sock;
        }
        close(sock);
    }
#endif

    // Fallback: connect to local UNIX domain socket (useful for host testing)
    if (fallback_socket) {
        int sock = socket(AF_UNIX, SOCK_STREAM, 0);
        if (sock >= 0) {
            struct sockaddr_un un;
            memset(&un, 0, sizeof(un));
            un.sun_family = AF_UNIX;
            strncpy(un.sun_path, fallback_socket, sizeof(un.sun_path) - 1);
            if (connect(sock, (struct sockaddr *)&un, sizeof(un)) == 0) {
                return sock;
            }
            close(sock);
        }
    }

    return -1;
}

int main(int argc, char *argv[]) {
    const char *wayland_socket = DEFAULT_GUEST_WAYLAND_SOCKET;
    const char *fallback_vsock_socket = "/tmp/niri-vsock-1024.sock";
    uint32_t host_cid = DEFAULT_HOST_CID;
    uint32_t host_port = DEFAULT_HOST_PORT;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--socket") == 0 && i + 1 < argc) {
            wayland_socket = argv[++i];
        } else if (strcmp(argv[i], "--fallback-socket") == 0 && i + 1 < argc) {
            fallback_vsock_socket = argv[++i];
        } else if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) {
            host_port = (uint32_t)atoi(argv[++i]);
        }
    }

    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);
    signal(SIGPIPE, SIG_IGN);

    // Ensure parent directory exists and has 0700 permissions
    char dir_buf[256];
    strncpy(dir_buf, wayland_socket, sizeof(dir_buf) - 1);
    char *slash = strrchr(dir_buf, '/');
    if (slash) {
        *slash = '\0';
        mkdir(dir_buf, 0700);
    }

    unlink(wayland_socket);

    int listen_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (listen_fd < 0) {
        perror("socket AF_UNIX");
        return 1;
    }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, wayland_socket, sizeof(addr.sun_path) - 1);

    if (bind(listen_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind");
        close(listen_fd);
        return 1;
    }

    chmod(wayland_socket, 0700);

    if (listen(listen_fd, 16) < 0) {
        perror("listen");
        close(listen_fd);
        return 1;
    }

    printf("============================================================\n");
    printf("Niri Linux Guest Wayland vsock Proxy Daemon\n");
    printf("Listening on:     %s\n", wayland_socket);
    printf("Target Host CID:  %u\n", host_cid);
    printf("Target Host Port: %u\n", host_port);
    printf("============================================================\n");

    uint32_t session_id_gen = 0;

    while (g_running) {
        int client_fd = accept(listen_fd, NULL, NULL);
        if (client_fd < 0) {
            if (errno == EINTR) continue;
            break;
        }

        int vsock_fd = connect_to_host(host_cid, host_port, fallback_vsock_socket);
        if (vsock_fd < 0) {
            fprintf(stderr, "[GUEST] Failed to connect to vsock host (CID %u, Port %u)\n", host_cid, host_port);
            close(client_fd);
            continue;
        }

        client_session_t *sess = (client_session_t *)malloc(sizeof(client_session_t));
        sess->client_fd = client_fd;
        sess->vsock_fd = vsock_fd;
        sess->session_id = ++session_id_gen;

        printf("[GUEST] Client session #%u established\n", sess->session_id);

        pthread_create(&sess->thread_c2v, NULL, thread_client_to_vsock, sess);
        pthread_create(&sess->thread_v2c, NULL, thread_vsock_to_client, sess);
        pthread_detach(sess->thread_c2v);
        pthread_detach(sess->thread_v2c);
    }

    unlink(wayland_socket);
    close(listen_fd);
    printf("[GUEST] Proxy shutdown cleanly.\n");
    return 0;
}
