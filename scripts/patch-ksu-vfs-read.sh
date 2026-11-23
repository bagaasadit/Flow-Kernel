#!/usr/bin/env bash
# patch-ksu-vfs-read.sh
#
# Adds the missing KernelSU/SukiSU manual hook to fs/read_write.c (4.14).
# Without it the kernel never injects ksud's boot stages into init.rc, so
# post-fs-data / services / boot-completed never run and modules stay in
# /data/adb/modules_update forever.
#
# Run from the kernel source root, AFTER scripts/ksu-nova-setup.sh:
#     ./scripts/patch-ksu-vfs-read.sh
#
# It reads the real hook signature from the cloned KernelSU source instead of
# guessing, supports both known variants, is idempotent, and fails loudly if
# it cannot patch (so a skipped patch can never look like a working build).
set -euo pipefail

cd "${1:-.}"
F=fs/read_write.c
KDIR=KernelSU/kernel
[ -d "$KDIR" ] || KDIR=drivers/kernelsu

[ -f "$F" ]    || { echo "::error::$F not found (run from the kernel source root)"; exit 1; }
[ -d "$KDIR" ] || { echo "::error::KernelSU source not found (KernelSU/kernel or drivers/kernelsu)"; exit 1; }

# An existing hook only counts if it is compiled in for CONFIG_KSU. A hook left
# over from another KSU tree (e.g. BakaSU's inline hook under CONFIG_KSU_SUSFS)
# is dead code here and must be removed first, otherwise we would skip patching
# and ship a kernel whose vfs_read hook never runs.
state=$(python3 - "$F" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().split("\n")
found = active = False
for i, l in enumerate(lines):
    if re.search(r'ksu_handle_(vfs|sys)_read\(', l) and not l.lstrip().startswith("extern"):
        found = True
        ctx = "\n".join(lines[max(0, i - 4):i])
        if re.search(r'#\s*if(def)?\s+(defined\()?CONFIG_KSU\)?\s*$', ctx, re.M):
            active = True
print("active" if active else ("foreign" if found else "none"))
PY
)
case "$state" in
  active)  echo "[ksu-vfs-read] $F already has an active hook, nothing to do"; exit 0;;
  foreign) echo "::error::[ksu-vfs-read] $F has a ksu_handle_*_read call that is NOT guarded by CONFIG_KSU (likely BakaSU/CONFIG_KSU_SUSFS). Remove it first."; exit 1;;
esac

python3 - "$F" "$KDIR" <<'PY'
import os, re, sys

path, kdir = sys.argv[1], sys.argv[2]

# ---- read what the KernelSU clone really defines -------------------------
src = ""
for root, _, files in os.walk(kdir, followlinks=True):
    for n in files:
        if n.endswith((".c", ".h")):
            try:
                src += open(os.path.join(root, n), errors="ignore").read() + "\n"
            except OSError:
                pass

def find_def(name):
    m = re.search(r'\b(?:int|void|bool)\s+' + name + r'\s*\(([^)]*)\)\s*[{;]', src)
    return re.sub(r'\s+', ' ', m.group(1)).strip() if m else None

has_flag = re.search(r'\bbool\s+ksu_vfs_read_hook\b', src) is not None

vfs_sig = find_def("ksu_handle_vfs_read")
sys_sig = find_def("ksu_handle_sys_read")

text = open(path).read()

def die(msg):
    print("::error::[ksu-vfs-read] " + msg)
    sys.exit(1)

if not has_flag:
    die("KernelSU does not define 'bool ksu_vfs_read_hook'; refusing to add an "
        "unguarded hook to every read(). Send me: grep -Rn 'vfs_read' %s" % kdir)

# ---- variant A: vfs_read(file, buf, count, pos) ---------------------------
if vfs_sig:
    p = [x.strip() for x in vfs_sig.split(",")]
    want = [r'struct file\s*\*\*', r'char\s+__user\s*\*\*', r'size_t\s*\*', r'loff_t\s*\*\*']
    if len(p) != 4 or not all(re.match(w, x) for w, x in zip(want, p)):
        die("unexpected ksu_handle_vfs_read signature: (%s)" % vfs_sig)

    decl = ("#ifdef CONFIG_KSU\n"
            "extern bool ksu_vfs_read_hook __read_mostly;\n"
            "extern int ksu_handle_vfs_read(struct file **file_ptr, char __user **buf_ptr,\n"
            "\t\t\t       size_t *count_ptr, loff_t **pos);\n"
            "#endif\n\n")
    call = ("#ifdef CONFIG_KSU\n"
            "\tif (unlikely(ksu_vfs_read_hook))\n"
            "\t\tksu_handle_vfs_read(&file, &buf, &count, &pos);\n"
            "#endif\n")
    pat = re.compile(
        r'(?P<head>ssize_t vfs_read\(struct file \*file, char __user \*buf, '
        r'size_t count, loff_t \*pos\)\n\{\n\tssize_t ret;\n)')
    m = pat.search(text)
    if not m:
        die("could not find vfs_read() in %s (unexpected layout)" % path)
    new = text[:m.start()] + decl + m.group("head") + call + text[m.end():]
    open(path, "w").write(new)
    print("[ksu-vfs-read] patched vfs_read() -> ksu_handle_vfs_read()")
    sys.exit(0)

# ---- variant B (older SukiSU/KernelSU): read syscall ----------------------
if sys_sig:
    p = [x.strip() for x in sys_sig.split(",")]
    want = [r'unsigned int', r'char\s+__user\s*\*\*', r'size_t\s*\*']
    if len(p) != 3 or not all(re.match(w, x) for w, x in zip(want, p)):
        die("unexpected ksu_handle_sys_read signature: (%s)" % sys_sig)

    decl = ("#ifdef CONFIG_KSU\n"
            "extern bool ksu_vfs_read_hook __read_mostly;\n"
            "extern int ksu_handle_sys_read(unsigned int fd, char __user **buf_ptr,\n"
            "\t\t\t       size_t *count_ptr);\n"
            "#endif\n\n")
    call = ("#ifdef CONFIG_KSU\n"
            "\tif (unlikely(ksu_vfs_read_hook))\n"
            "\t\tksu_handle_sys_read(fd, &buf, &count);\n"
            "#endif\n")
    pat = re.compile(
        r'(?P<head>SYSCALL_DEFINE3\(read, unsigned int, fd, char __user \*, buf, '
        r'size_t, count\)\n\{\n)')
    m = pat.search(text)
    if not m:
        die("could not find SYSCALL_DEFINE3(read, ...) in %s" % path)
    new = text[:m.start()] + decl + m.group("head") + call + text[m.end():]
    open(path, "w").write(new)
    print("[ksu-vfs-read] patched SYSCALL_DEFINE3(read) -> ksu_handle_sys_read()")
    sys.exit(0)

die("neither ksu_handle_vfs_read nor ksu_handle_sys_read is defined in %s" % kdir)
PY

# Final sanity: the call site must now be in the file.
grep -qE '^[[:space:]]+ksu_handle_(vfs|sys)_read\(' "$F" \
  || { echo "::error::[ksu-vfs-read] patch did not land in $F"; exit 1; }
echo "[ksu-vfs-read] ok"
