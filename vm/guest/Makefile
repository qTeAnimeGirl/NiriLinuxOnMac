# vm/guest/Makefile
CC ?= gcc
CFLAGS ?= -O2 -Wall -Wextra -Werror -pthread
TARGET = niri_vsock_guest

all: $(TARGET)

$(TARGET): niri_vsock_guest.c ../proto/niri_ipc.h
	$(CC) $(CFLAGS) $< -o $@

clean:
	rm -f $(TARGET)

.PHONY: all clean
