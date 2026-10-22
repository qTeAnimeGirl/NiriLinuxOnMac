#!/usr/bin/env python3
"""
vm/scripts/test_pacman_alpm_db.py

Automated integration test for Arch Linux ALPM database version 9,
POSIX /dev symlinks (/dev/fd, /dev/stdin, /dev/stdout, /dev/stderr),
and live package database synchronization (pacman -Sy) on MicroVM with persistent disk.
"""

import os
import pty
import re
import select
import subprocess
import sys
import time

def main():
    repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    dist_dir = os.path.join(repo_root, "dist", "Niri.app")
    launcher = os.path.join(dist_dir, "Contents", "MacOS", "microvm_launcher")
    kernel = os.path.join(dist_dir, "Contents", "Resources", "vm_images", "Image")
    initrd = os.path.join(dist_dir, "Contents", "Resources", "vm_images", "initramfs.cpio.gz")

    if not os.path.exists(launcher):
        print(f"[ERROR] Launcher not found at {launcher}")
        sys.exit(1)
    if not os.path.exists(kernel):
        print(f"[ERROR] Kernel not found at {kernel}")
        sys.exit(1)
    if not os.path.exists(initrd):
        print(f"[ERROR] Initramfs not found at {initrd}")
        sys.exit(1)

    disk_path = f"/tmp/pacman_test_disk_{int(time.time())}.img"
    print(f"[SETUP] Creating 10GB persistent test disk at {disk_path}...")
    subprocess.run(["truncate", "-s", "10G", disk_path], check=True)

    master, slave = pty.openpty()

    cmd = [
        launcher,
        "--kernel", kernel,
        "--initrd", initrd,
        "--disk", disk_path,
        "--cpus", "2",
        "--memory", "2048",
        "--cmdline", "console=hvc0 root=/dev/vda rw init=/init quiet loglevel=3 panic=-1"
    ]

    print("[SETUP] Launching MicroVM via Apple Virtualization...")
    proc = subprocess.Popen(
        cmd,
        stdin=slave,
        stdout=slave,
        stderr=slave,
        close_fds=True
    )
    os.close(slave)

    buffer = ""

    def read_until(pattern, timeout=60):
        nonlocal buffer
        start = time.time()
        regex = re.compile(pattern)
        while time.time() - start < timeout:
            r, _, _ = select.select([master], [], [], 0.5)
            if r:
                try:
                    data = os.read(master, 4096).decode("utf-8", errors="replace")
                    if not data:
                        break
                    buffer += data
                    sys.stdout.write(data)
                    sys.stdout.flush()
                    m = regex.search(buffer)
                    if m:
                        matched_str = buffer[:m.end()]
                        buffer = buffer[m.end():]
                        return matched_str
                except OSError:
                    break
        raise TimeoutError(f"Timed out waiting for pattern '{pattern}' after {timeout}s")

    def run_cmd(command, timeout=60):
        print(f"\n[GUEST RUN] Sending: {command}")
        marker = f"__CMD_END_{int(time.time()*1000)}__"
        full_command = f"{command}; echo \"{marker}:$?\"\n"
        os.write(master, full_command.encode("utf-8"))
        
        output = read_until(rf"{marker}:(\d+)", timeout=timeout)
        match = re.search(rf"{marker}:(\d+)", output)
        exit_code = int(match.group(1)) if match else -1
        # Extract command output between echo and marker
        clean_output = output
        return exit_code, clean_output

    test_results = {}

    try:
        print("[TEST] Waiting for guest boot and shell prompt...")
        read_until(r"Interactive shell ready\.", timeout=30)
        time.sleep(1) # Let shell settle

        # Step 4a: Test POSIX /dev symlinks
        print("\n" + "="*60)
        print("TEST 1: POSIX /dev symlinks (/dev/fd, /dev/stdin, /dev/stdout, /dev/stderr)")
        print("="*60)
        ec1, out1 = run_cmd("ls -la /dev/fd /dev/stdin /dev/stdout /dev/stderr", timeout=15)
        test_results["ls_dev_symlinks"] = {
            "exit_code": ec1,
            "passed": ec1 == 0 and "/dev/fd -> /proc/self/fd" in out1 and "/dev/stdin -> /proc/self/fd/0" in out1,
            "output": out1
        }
        print(f"Result Test 1: {'PASS' if test_results['ls_dev_symlinks']['passed'] else 'FAIL'} (exit={ec1})")

        # Step 4b: Test ALPM database version file
        print("\n" + "="*60)
        print("TEST 2: Check /var/lib/pacman/local/ALPM_DB_VERSION")
        print("="*60)
        ec2, out2 = run_cmd("cat /var/lib/pacman/local/ALPM_DB_VERSION", timeout=15)
        alpm_version = out2.strip()
        test_results["alpm_version"] = {
            "exit_code": ec2,
            "passed": ec2 == 0 and "9" in out2,
            "output": out2
        }
        print(f"Result Test 2: {'PASS' if test_results['alpm_version']['passed'] else 'FAIL'} (exit={ec2}, version='{alpm_version}')")

        # Step 4c: Test pacman -Sy
        print("\n" + "="*60)
        print("TEST 3: Execute pacman -Sy (Sync Arch Linux Repositories)")
        print("="*60)
        ec3, out3 = run_cmd("pacman -Sy", timeout=90)
        has_db_error = "database is incorrect version" in out3.lower() or "error: failed to synchronize" in out3.lower()
        test_results["pacman_sy"] = {
            "exit_code": ec3,
            "passed": ec3 == 0 and not has_db_error,
            "output": out3
        }
        print(f"Result Test 3: {'PASS' if test_results['pacman_sy']['passed'] else 'FAIL'} (exit={ec3})")

        # Step 4d: Check storage persistence and pacman cache directory
        print("\n" + "="*60)
        print("TEST 4: Check OverlayFS mount and local db files")
        print("="*60)
        ec4, out4 = run_cmd("df -h /mnt/storage /usr /var && ls -la /var/lib/pacman/sync", timeout=15)
        test_results["storage_check"] = {
            "exit_code": ec4,
            "passed": ec4 == 0,
            "output": out4
        }
        print(f"Result Test 4: {'PASS' if test_results['storage_check']['passed'] else 'FAIL'} (exit={ec4})")

    finally:
        print("\n[CLEANUP] Gracefully shutting down MicroVM...")
        try:
            os.write(master, b"sync; poweroff -f\n")
            time.sleep(2)
        except OSError:
            pass
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        os.close(master)
        if os.path.exists(disk_path):
            os.remove(disk_path)
            print(f"[CLEANUP] Removed test disk {disk_path}")

    # Final assertion
    print("\n" + "="*60)
    print("AUTOMATED MICROVM TEST SUMMARY")
    print("="*60)
    all_passed = True
    for test_name, res in test_results.items():
        status = "PASS" if res["passed"] else "FAIL"
        if not res["passed"]:
            all_passed = False
        print(f"- {test_name}: [{status}] (exit code {res['exit_code']})")

    if all_passed:
        print("\nALL AUTOMATED TESTS PASSED (100%)!")
        sys.exit(0)
    else:
        print("\nTEST FAILURES DETECTED!")
        sys.exit(1)

if __name__ == "__main__":
    main()
