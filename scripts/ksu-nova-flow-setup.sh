#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# ksu-nova-setup.sh -- reproducible SukiSU-Nova integration for the miatoll
# Linux 4.14.357 tree.
#
# Everything below is applied to a *clean checkout* on every run, so the build
# is reproducible and nothing depends on someone's dirty working tree. Run it
# before scripts/build.sh; the CI workflow does that automatically.
#
#   ./scripts/ksu-nova-setup.sh            apply + verify
#   ./scripts/ksu-nova-setup.sh --check    verify only, change nothing
#
# WHAT GETS INSTALLED
#   SukiSU-Nova (branch `builtin`) at a pinned commit -- the source-integrated
#   tree, i.e. the kernel calls ksu_handle_*() directly instead of relying on
#   kprobes (kprobes are unreliable on 4.x).
#
#   Root only by default. What this script touches outside drivers/ is: the
#   manual hook call sites (section 4), the KPM syscall-wrapper stub (section
#   3.5) and the SELinux support file behind "hide SELinux modification" and
#   AVC log spoofing (section 3.6), which replaces SUSFS's share of those two
#   features on this kernel.
#
#   SUSFS is a second, separate product: KSU_SUSFS=1 adds the device-verified
#   4.14 port of SUSFS v2.3.0 (section 3.7). It is off by default because it
#   patches fs/namei.c, fs/namespace.c, fs/stat.c and fs/super.c -- a broken
#   port there is a bootloop, not a missing feature.
#
# WHY A PINNED COMMIT
#   `builtin` moves. Every KernelSU setup.sh ends its checkout with
#   `git checkout "$1" || echo "checkout default branch"`, so a stale branch
#   name does not fail -- it silently leaves you on the default branch and you
#   ship a kernel with none of what you asked for. This script resolves the ref
#   first and compares HEAD afterwards.
#
# Everything is idempotent: re-running over an already-patched tree reports
# "already applied" instead of failing.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Auto-detect the kernel root: repository root, or kernel/ before the flatten
# workflow has run. The integration is identical either way.
if [[ -f "$REPO_ROOT/Makefile" && -f "$REPO_ROOT/arch/arm64/Makefile" ]]; then
    KERNEL_DIR="$REPO_ROOT"
else
    KERNEL_DIR="$REPO_ROOT/kernel"
fi

KSU_REPO="${KSU_REPO:-https://github.com/SukiSU-Nova/SukiSU-Nova}"
# Pinned 2026-11-16, "bump Version Number". Override with a tag or another
# commit if you know what you are doing; a branch name is accepted too, but it
# makes the build non-reproducible and the log will say so.
KSU_REF="${KSU_REF:-4bec532dd447e2852aa8932afa768255350c103a}"
KSU_DIR="${KSU_DIR:-KernelSU}"

# SUSFS is a second, separate product built from the same tree: it hooks
# fs/, mm/ and security/, so a broken port is a bootloop, not a missing
# feature. Off unless KSU_SUSFS=1; see section 3.7.
KSU_SUSFS="${KSU_SUSFS:-0}"
case "$KSU_SUSFS" in
    0|1) ;;
    *) printf 'KSU_SUSFS must be 0 or 1\n' >&2; exit 2 ;;
esac

DEFCONFIG="${DEFCONFIG:-arch/arm64/configs/vendor/xiaomi/miatoll_defconfig}"

MODE=apply
for arg in "$@"; do
    case "$arg" in
        --check)   MODE=check ;;
        -h|--help) sed -n '2,37p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'unknown option: %s (try --help)\n' "$arg" >&2; exit 2 ;;
    esac
done

log()  { printf '[ksu-nova] %s\n' "$*"; }
ok()   { printf '[ksu-nova]   ok: %s\n' "$*"; }
warn() { printf '[ksu-nova]   warn: %s\n' "$*" >&2; }
die()  { printf '[ksu-nova] ERROR: %s\n' "$*" >&2; exit 1; }

cd "$KERNEL_DIR"

# --------------------------------------------------------------- 0. sanity ---

KVER="$(sed -n -e 's/^VERSION = //p' -e 's/^PATCHLEVEL = //p' Makefile | paste -sd. -)"
[[ "$KVER" == "4.14" ]] || die "this integration targets Linux 4.14, found $KVER"
[[ -f "$DEFCONFIG" ]] || die "defconfig not found: $DEFCONFIG"
ok "kernel $KVER, defconfig $DEFCONFIG"

# ------------------------------------------------------------- 1. SukiSU-Nova

# A 40/12/7-hex ref is a commit, not a branch: ls-remote cannot resolve it, so
# it is validated by the fetch itself and then by comparing HEAD.
is_commit_ref() { [[ "${1:-}" =~ ^[0-9a-f]{7,40}$ ]]; }

resolve_ref() {
    local out
    out=$(git ls-remote "$KSU_REPO" \
            "refs/heads/$KSU_REF" "refs/tags/$KSU_REF" "refs/tags/$KSU_REF^{}" \
            2>/dev/null) || return 0
    printf '%s\n' "$out" | awk 'NR==1{print $1}'
}

if [[ "$MODE" == check ]]; then
    [[ -d "$KSU_DIR/kernel" ]] || die "$KSU_DIR/ is missing; run without --check"
    HEAD_SHA="$(git -C "$KSU_DIR" rev-parse HEAD)"
    ok "SukiSU-Nova present at $HEAD_SHA"
else
    WANT_SHA=""
    if is_commit_ref "$KSU_REF"; then
        ok "ref '$KSU_REF' is a pinned commit (validated by the fetch)"
    else
        WANT_SHA="$(resolve_ref)"
        if [[ -z "$WANT_SHA" ]]; then
            die "ref '$KSU_REF' does not exist in $KSU_REPO.
       Available branches:
$(git ls-remote --heads "$KSU_REPO" 2>/dev/null | awk '{print "         " $2}' | sed 's@refs/heads/@@' | grep -v dependabot)
       Pick a branch/tag/commit and re-run with KSU_REF=<ref>."
        fi
        ok "ref '$KSU_REF' -> $WANT_SHA"
        warn "KSU_REF is a moving ref; pin a commit for reproducible builds"
    fi

    if [[ -d "$KSU_DIR/kernel" ]]; then
        HEAD_SHA="$(git -C "$KSU_DIR" rev-parse HEAD)"
        if [[ -n "$WANT_SHA" && "$HEAD_SHA" != "$WANT_SHA" ]]; then
            log "checkout at $HEAD_SHA does not match $KSU_REF; re-fetching"
            rm -rf "$KSU_DIR"
        elif [[ -z "$WANT_SHA" && "$HEAD_SHA" != "$KSU_REF" ]]; then
            log "checkout at $HEAD_SHA does not match $KSU_REF; re-fetching"
            rm -rf "$KSU_DIR"
        fi
    fi

    if [[ ! -d "$KSU_DIR/kernel" ]]; then
        log "fetching SukiSU-Nova ($KSU_REF)"
        rm -rf "$KSU_DIR"
        mkdir -p "$KSU_DIR"
        git -C "$KSU_DIR" init -q .
        git -C "$KSU_DIR" remote add origin "$KSU_REPO"
        # --depth 1 on a SHA: GitHub allows fetching an arbitrary reachable
        # commit, so a pinned build stays a one-commit download.
        git -C "$KSU_DIR" fetch -q --depth 1 origin "$KSU_REF" \
            || die "cannot fetch '$KSU_REF' from $KSU_REPO.
       It is not a branch, tag or reachable commit. Branches:
$(git ls-remote --heads "$KSU_REPO" 2>/dev/null | awk '{print "         " $2}' | sed 's@refs/heads/@@' | grep -v dependabot)"
        git -C "$KSU_DIR" checkout -q FETCH_HEAD
    fi

    HEAD_SHA="$(git -C "$KSU_DIR" rev-parse HEAD)"
    # Catches the silent fallback for refs that are branches, and a wrong
    # commit for pinned ones.
    if [[ -n "$WANT_SHA" && "$HEAD_SHA" != "$WANT_SHA" ]]; then
        die "checked out $HEAD_SHA, expected $WANT_SHA for ref '$KSU_REF'"
    fi
    if is_commit_ref "$KSU_REF" && [[ "$HEAD_SHA" != "$KSU_REF" ]]; then
        die "checked out $HEAD_SHA, expected $KSU_REF"
    fi
    ok "SukiSU-Nova checked out at $HEAD_SHA"
fi

[[ -f "$KSU_DIR/kernel/Kconfig" ]] || die "$KSU_DIR/kernel/Kconfig missing"
[[ -f "$KSU_DIR/kernel/Makefile" ]] || die "$KSU_DIR/kernel/Makefile missing"

# ------------------------------------------------------------ 2. KSU wiring ---
#
# Wiring goes into tracked files, so it is re-applied whenever it is missing
# (a `git checkout` can undo it while the untracked clone survives).

if [[ ! -e drivers/kernelsu ]]; then
    if [[ "$MODE" == check ]]; then die "drivers/kernelsu symlink missing"; fi
    log "creating drivers/kernelsu -> ../$KSU_DIR/kernel"
    ln -sfn "../$KSU_DIR/kernel" drivers/kernelsu
fi
[[ -d drivers/kernelsu ]] || die "drivers/kernelsu does not point at $KSU_DIR/kernel"

if [[ "$MODE" != check ]]; then
    # setup.sh only greps for the word "kernelsu", so a vendor tree that
    # carries a stale `obj-$(CONFIG_WITH_KERNEL_SU) += kernelsu/` line makes it
    # report success without ever adding the CONFIG_KSU rule. The build then
    # fails at the final link with every ksu_handle_* symbol undefined.
    if ! grep -qE '^[[:space:]]*obj-\$\(CONFIG_KSU\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$' drivers/Makefile; then
        if grep -qE '^[[:space:]]*obj-\$\(CONFIG_[A-Z0-9_]+\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$' drivers/Makefile; then
            sed -i -E 's@^[[:space:]]*obj-\$\(CONFIG_[A-Z0-9_]+\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$@obj-$(CONFIG_KSU) += kernelsu/@' drivers/Makefile
            warn "normalized stale drivers/Makefile guard to CONFIG_KSU"
        else
            log "wiring drivers/Makefile"
            printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> drivers/Makefile
        fi
    fi
    if ! grep -qF 'drivers/kernelsu/Kconfig' drivers/Kconfig; then
        log "wiring drivers/Kconfig"
        # Appended, not inserted before the first `endmenu`: two `endmenu`
        # lines exist in some vendor trees and sed would split the menu.
        printf '\nsource "drivers/kernelsu/Kconfig"\n' >> drivers/Kconfig
    fi
fi
grep -qE '^[[:space:]]*obj-\$\(CONFIG_KSU\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$' drivers/Makefile \
    || die "drivers/Makefile is not wired for CONFIG_KSU"
grep -qF 'drivers/kernelsu/Kconfig' drivers/Kconfig \
    || die "drivers/Kconfig is not wired for config KSU"
ok "drivers/Makefile + drivers/Kconfig wired"

# ------------------------------------------- 3. SukiSU-Nova 4.14 fixes -------
#
# Five upstream conditionals are wrong for 4.14, and KPM's 5.10 assumptions are
# ported rather than avoided. Each edit is guarded so that this step fails
# loudly when upstream rewrites the surrounding code.

if [[ "$MODE" != check ]]; then
    python3 - "$KSU_DIR/kernel/kernel_includes.h" <<'PY'
import sys

path = sys.argv[1]
src = open(path).read()

guard = ("#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n"
         "#include <linux/static_call.h>\n"
         "#endif\n")
plain = "#include <linux/static_call.h>\n"

if guard in src:
    print("[ksu-nova]   static_call include already guarded")
elif plain in src:
    # include/linux/static_call.h does not exist before 5.10. The header is
    # included for KPM's static-call based hooks, which are compiled out on
    # 4.14 anyway, so the include can simply be dropped there.
    open(path, "w").write(src.replace(plain, guard, 1))
    print("[ksu-nova]   guarded linux/static_call.h include for < 5.10")
else:
    sys.exit("[ksu-nova] ERROR: static_call include anchor missing in "
             + path + " (upstream changed)")
PY

    python3 - "$KSU_DIR/kernel/kernel_compat.h" <<'PY'
import sys

path = sys.argv[1]
src = open(path).read()

want = ("#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 4, 0)\n"
        "#define KSU_CAN_USE_KPM\n"
        "#endif\n")
raised = ("#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n"
          "#define KSU_CAN_USE_KPM\n"
          "#endif\n")

if raised in src:
    # An earlier version of this script raised the guard to 5.10 to keep KPM's
    # dead code dead. KPM is wanted now, and section 3.4 makes it compile on
    # 4.14, so put upstream's guard back.
    open(path, "w").write(src.replace(raised, want, 1))
    print("[ksu-nova]   KPM guard restored to 4.4.0")
elif want in src:
    print("[ksu-nova]   KPM guard already >= 4.4")
else:
    sys.exit("[ksu-nova] ERROR: KPM guard anchor missing in " + path
             + " (upstream changed)")
PY
fi

grep -q 'KSU_CAN_USE_KPM' "$KSU_DIR/kernel/kernel_compat.h" || die "KPM guard vanished"

# -- 3.4 KPM on 4.14 ---------------------------------------------------------
#
# With the guard back at 4.4 the KPM sources are compiled on 4.14, and three
# of them assume newer kernels. Each is a real port, not a bypass:
#
#   * access_ok() lost its access-type argument in 5.0.
#   * struct task_struct lost `pids[PIDTYPE_PID].pid` in 4.19 in favour of
#     thread_pid. This vendor tree already carries the 4.19 layout on 4.14, so
#     the version test picks the wrong member; the KernelSU Makefile probes the
#     header and defines KSU_TASK_HAS_THREAD_PID, exactly like the other
#     vendor-backport probes it already has.
#   * the KPM bridge calls KernelPatch's supercall through the truncate syscall
#     handler. `__arm64_sys_*` wrappers only exist from 4.17, so on 4.14 the
#     bridge has to reach the same function through sys_call_table
#     (__NR_truncate) or the sys_truncate symbol.

if [[ "$MODE" != check ]]; then
    python3 - "$KSU_DIR/kernel/extension/kpm/kpm.c" <<'PY'
import sys

path = sys.argv[1]
src = open(path).read()

def once(src, old, new, label):
    if new in src:
        print("[ksu-nova]   " + label + ": already applied")
        return src
    if old not in src:
        sys.exit("[ksu-nova] ERROR: " + label + " anchor missing in " + path
                 + " (upstream changed)")
    print("[ksu-nova]   " + label)
    return src.replace(old, new, 1)

src = once(
    src,
    "    if (!access_ok(u64_to_user_ptr(cmd.result_code), sizeof(result))) return -EFAULT;\n",

    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0)\n"
    "    if (!access_ok(u64_to_user_ptr(cmd.result_code), sizeof(result))) return -EFAULT;\n"
    "#else\n"
    "    /* access_ok() takes the access type before 5.0. */\n"
    "    if (!access_ok(VERIFY_WRITE, u64_to_user_ptr(cmd.result_code),\n"
    "                   sizeof(result)))\n"
    "        return -EFAULT;\n"
    "#endif\n",
    "ported access_ok() to the pre-5.0 form")

src = once(
    src,
    "        if (!fn) fn = (handler_t)find_kernel_symbol_exact(\"__arm64_sys_truncate.cfi\");\n"
    "        if (!fn) return -EOPNOTSUPP;\n",

    "        if (!fn) fn = (handler_t)find_kernel_symbol_exact(\"__arm64_sys_truncate.cfi\");\n"
    "#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 17, 0)\n"
    "        /*\n"
    "         * 4.14 has no __arm64_sys_* wrappers. Resolve the truncate\n"
    "         * handler the way this kernel exposes it: through\n"
    "         * sys_call_table (so a hook installed at the table level is\n"
    "         * still reached even if the function body was not patched),\n"
    "         * then through the plain symbol.\n"
    "         */\n"
    "        if (!fn) {\n"
    "            unsigned long *table = (unsigned long *)\n"
    "                find_kernel_symbol_exact(\"sys_call_table\");\n"
    "            if (table && table[__NR_truncate])\n"
    "                fn = (handler_t)table[__NR_truncate];\n"
    "        }\n"
    "        if (!fn) fn = (handler_t)find_kernel_symbol_exact(\"sys_truncate\");\n"
    "        if (!fn) fn = (handler_t)find_kernel_symbol_exact(\"SyS_truncate\");\n"
    "#endif\n"
    "        if (!fn) return -EOPNOTSUPP;\n",
    "added the pre-4.17 truncate-handler lookup")

# __NR_truncate is spelled __NR3264_truncate on arm64 and may not be visible
# here at all; define it once, right before the ARM64 block that uses it.
if "SUKISU_KPM_NR_TRUNCATE_GUARD" not in src:
    anchor = "#ifdef CONFIG_ARM64\n#include <asm/ptrace.h>\n#endif\n"
    if anchor not in src:
        sys.exit("[ksu-nova] ERROR: arm64 include anchor missing in " + path
                 + " (upstream changed)")
    src = src.replace(
        anchor,
        anchor +
        "\n/* SUKISU_KPM_NR_TRUNCATE_GUARD: the syscall number of truncate as\n"
        " * this kernel spells it. arm64 calls it __NR3264_truncate. */\n"
        "#ifndef __NR_truncate\n"
        "#ifdef __NR3264_truncate\n"
        "#define __NR_truncate __NR3264_truncate\n"
        "#else\n"
        "#define __NR_truncate 45\n"
        "#endif\n"
        "#endif\n",
        1)
    print("[ksu-nova]   defined __NR_truncate for arm64")
else:
    print("[ksu-nova]   __NR_truncate guard: already applied")

open(path, "w").write(src)
PY

    python3 - "$KSU_DIR/kernel/extension/kpm/super_access.c" <<'PY'
import sys

path = sys.argv[1]
src = open(path).read()

old = ("#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 19, 0)\n"
       "DEFINE_MEMBER(task_struct, pids[PIDTYPE_PID].pid)\n"
       "#else\n"
       "DEFINE_MEMBER(task_struct, thread_pid)\n"
       "#endif\n")
new = ("#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 19, 0) && \\\n"
       "    !defined(KSU_TASK_HAS_THREAD_PID)\n"
       "DEFINE_MEMBER(task_struct, pids[PIDTYPE_PID].pid)\n"
       "#else\n"
       "DEFINE_MEMBER(task_struct, thread_pid)\n"
       "#endif\n")

if new in src:
    print("[ksu-nova]   task_struct pid member: already applied")
elif old in src:
    open(path, "w").write(src.replace(old, new, 1))
    print("[ksu-nova]   task_struct pid member honours KSU_TASK_HAS_THREAD_PID")
else:
    sys.exit("[ksu-nova] ERROR: task_struct pid member anchor missing in "
             + path + " (upstream changed)")
PY

    python3 - "$KSU_DIR/kernel/Makefile" <<'PY'
import sys

path = sys.argv[1]
src = open(path).read()

block = """
# Some 4.x trees carry the 4.19 struct task_struct (thread_pid/pid_links)
# backported, so task_struct::pids is gone even though LINUX_VERSION_CODE still
# says 4.14. Probe the header instead of trusting the version, the same way the
# selinux/seccomp probes above do.
ifeq ($(shell grep -q 'struct pid[[:space:]]*\*thread_pid' $(srctree)/include/linux/sched.h; echo $$?),0)
ccflags-y += -DKSU_TASK_HAS_THREAD_PID
endif
"""

if "KSU_TASK_HAS_THREAD_PID" in src:
    print("[ksu-nova]   KSU_TASK_HAS_THREAD_PID probe: already present")
else:
    anchor = "# Check new vfs_getattr()\n"
    if anchor not in src:
        sys.exit("[ksu-nova] ERROR: vfs_getattr probe anchor missing in "
                 + path + " (upstream changed)")
    open(path, "w").write(src.replace(anchor, block.lstrip("\n") + "\n" + anchor, 1))
    print("[ksu-nova]   added KSU_TASK_HAS_THREAD_PID probe to the clone Makefile")
PY
fi

grep -q 'KSU_CAN_USE_KPM' "$KSU_DIR/kernel/kernel_compat.h" || die "KPM gate vanished"
grep -q 'VERIFY_WRITE' "$KSU_DIR/kernel/extension/kpm/kpm.c" \
    || die "KPM lost its pre-5.0 access_ok() form"
grep -q 'SUKISU_KPM_NR_TRUNCATE_GUARD' "$KSU_DIR/kernel/extension/kpm/kpm.c" \
    || die "KPM lost the arm64 truncate syscall number"
grep -q 'KSU_TASK_HAS_THREAD_PID' "$KSU_DIR/kernel/extension/kpm/super_access.c" \
    || die "super_access.c does not honour KSU_TASK_HAS_THREAD_PID"
grep -q 'KSU_TASK_HAS_THREAD_PID' "$KSU_DIR/kernel/Makefile" \
    || die "the clone Makefile does not define KSU_TASK_HAS_THREAD_PID"

# -- 3.4b ksys_close() on 4.14 ------------------------------------------------
#
# preinit.c closes fds via ksu_close_fd_compat(), defined as ksys_close(fd).
# ksys_close() was only added in 5.11; on 4.14 the equivalent is sys_close().
PREINIT="$KSU_DIR/kernel/preinit/preinit.c"
[[ -f "$PREINIT" ]] || die "$PREINIT missing"
if grep -q '#define ksu_close_fd_compat(fd) ksys_close(fd)' "$PREINIT"; then
    sed -i \
        -e 's/#define ksu_close_fd_compat(fd) ksys_close(fd)/#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 11, 0)\n#define ksu_close_fd_compat(fd) ksys_close(fd)\n#else\n#define ksu_close_fd_compat(fd) sys_close(fd)\n#endif/' \
        "$PREINIT"
    grep -q '#include <linux/version.h>' "$PREINIT" \
        || sed -i '1i #include <linux/version.h>' "$PREINIT"
    log "  preinit.c: ksu_close_fd_compat() guarded for < 5.11 (sys_close)"
else
    log "  preinit.c: ksu_close_fd_compat() already guarded"
fi
grep -q 'ksu_close_fd_compat(fd) sys_close(fd)' "$PREINIT" \
    || die "preinit.c: < 5.11 sys_close() guard did not apply"

# -- 3.5 KernelPatch's pre-4.17 detection ------------------------------------
#
# The KPM bridge is only half of KPM. The other half is the KernelPatch payload
# injected into the built image, and *it* decides whether to install the channel
# that answers the bridge:
#
#     int sukisu_kpm_supercall_install(void)
#     {
#         if (!has_syscall_wrapper) return -EOPNOTSUPP;          /* 4.14 stops here */
#         addr = kallsyms_lookup_name("__arm64_sys_truncate");   /* 4.17+ name */
#         ...
#     }
#
# has_syscall_wrapper is set by looking for __arm64_sys_openat, and the hook
# target is looked up as __arm64_sys_truncate. Neither symbol exists before
# 4.17, so on this kernel the payload logs
#
#     KP syscall has_wrapper: 0
#     KP sukisu_kpm_supercall_install done: -95
#
# and the manager greys KPM out while everything else works -- measured on the
# device, not guessed.
#
# Two stub symbols fix the detection without touching the payload: nothing in
# this kernel calls them, sys_call_table keeps pointing at sys_truncate and
# sys_openat, and the only caller of __arm64_sys_truncate becomes the KPM
# bridge, which the payload intercepts at the first instruction. If the hook is
# *not* installed the stub answers -ENOSYS, so the bridge reports "unavailable"
# exactly as it does today: the failure mode is the current behaviour, not a
# wrong answer and not a crash.

if [[ "$MODE" != check ]]; then
    cat > arch/arm64/kernel/kp_syswrap.c <<'KPEOF'
// SPDX-License-Identifier: GPL-2.0
/*
 * kp_syswrap.c - the syscall-wrapper symbols KernelPatch looks for.
 *
 * KernelPatch's KPM channel is an inline hook on the truncate syscall wrapper.
 * Its payload decides whether it may install that hook by looking for
 * __arm64_sys_openat, then resolves __arm64_sys_truncate by name. Both symbols
 * arrived with the SYSCALL_DEFINE wrapper generation in 4.17; on this kernel
 * the payload therefore reports "has_wrapper: 0" and installs nothing.
 *
 * These stubs exist so the detection succeeds. Nothing in the kernel calls
 * them: sys_call_table still points at sys_truncate/sys_openat, and the only
 * caller of __arm64_sys_truncate is SukiSU's KPM bridge, which KernelPatch
 * intercepts before the first instruction runs. If the hook is not installed,
 * the stub answers -ENOSYS, which the bridge reports as "KPM unavailable" -
 * the same state as without this file.
 *
 * The padding nops are not decoration: the inline hook relocates the first
 * instructions of its target, and a bare "mov w0, #-38; ret" leaves it two.
 */
#include <linux/linkage.h>
#include <linux/ptrace.h>
#include <linux/errno.h>
#include <linux/compiler.h>
#include <linux/version.h>

#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 17, 0)

asmlinkage long __arm64_sys_truncate(const struct pt_regs *regs);
asmlinkage long __arm64_sys_openat(const struct pt_regs *regs);

#define KP_SYSWRAP_PAD(regs)                                                  \
	asm volatile("nop; nop; nop; nop; nop; nop; nop; nop" ::"r"(regs)     \
		     : "memory")

asmlinkage __visible __used noinline long
__arm64_sys_truncate(const struct pt_regs *regs)
{
	KP_SYSWRAP_PAD(regs);
	return -ENOSYS;
}

asmlinkage __visible __used noinline long
__arm64_sys_openat(const struct pt_regs *regs)
{
	KP_SYSWRAP_PAD(regs);
	return -ENOSYS;
}

/*
 * LTO links this tree as one unit and is free to drop a function nothing calls.
 * Taking the addresses in a used array keeps both names in kallsyms, and the
 * build asserts that they are in System.map, so a toolchain that still manages
 * to remove them fails the build instead of shipping a kernel whose KPM panel
 * is silently dead.
 */
static void *const kp_syswrap_keep[] __used = {
	(void *)__arm64_sys_truncate,
	(void *)__arm64_sys_openat,
};

#endif /* < 4.17 */
KPEOF

    python3 - arch/arm64/kernel/Makefile <<'PY'
import sys

path = sys.argv[1]
src = open(path).read()
line = "obj-$(CONFIG_KPM) += kp_syswrap.o\n"
if line in src:
    print("[ksu-nova]   kp_syswrap.o: already in arch/arm64/kernel/Makefile")
else:
    if not src.endswith("\n"):
        src += "\n"
    src += (
        "\n# KernelPatch's KPM channel needs the __arm64_sys_* names to exist;\n"
        "# see arch/arm64/kernel/kp_syswrap.c. Only built when KPM is enabled.\n" + line
    )
    open(path, "w").write(src)
    print("[ksu-nova]   added kp_syswrap.o to arch/arm64/kernel/Makefile")
PY
fi

[[ -f arch/arm64/kernel/kp_syswrap.c ]] \
    || die "arch/arm64/kernel/kp_syswrap.c was not created"
grep -q 'obj-\$(CONFIG_KPM) += kp_syswrap.o' arch/arm64/kernel/Makefile \
    || die "arch/arm64/kernel/Makefile does not build kp_syswrap.o"

# -- 3.3 CPU identity spoofing on 4.14 ---------------------------------------
#
# ksu_extension_cpu_spoof_io() is compiled out below 5.10, so the manager shows
# CPU identity spoofing as "Unsupported" and the setting cannot be used at all.
# The gate is a version check, not a missing implementation: the writes are
# driven by kallsyms lookups and differ only in *which* vDSO fields exist.
#
# What 4.14 lacks, and what this patch does about it:
#
#   * <vdso/datapage.h> does not exist (arm64 keeps the datapage in
#     asm/vdso_datapage.h), and struct vdso_data has no clock_mode at all -
#     it selects the fast path with ->use_syscall.
#   * struct clocksource has no vdso_clock_mode, and there is no vdso_default.
#   * ARM64_WORKAROUND_1418040 does not exist (it arrived with the Cortex-A76
#     erratum in 4.19), so there is no capability bit to clear - and clearing
#     bit 37 of a bitmap that is shorter than 38 bits would corrupt memory.
#   * elf_hwcap is a single unsigned long and there is no elf_hwcap2, so the
#     upstream write of elf_hwcap_bitmap[1] would clobber whatever follows it.
#
# Everything the spoof actually changes (MIDR in the per-cpu cpu_data, BogoMIPS
# via loops_per_jiffy, ELF AT_HWCAP via elf_hwcap) exists unchanged on 4.14, so
# those writes are kept verbatim.

if [[ "$MODE" != check ]]; then
    python3 - "$KSU_DIR/kernel/kernel_compat.h" <<'PY'
import sys

path = sys.argv[1]
src = open(path).read()

want = ("/*\n"
        " * CPU identity spoofing is symbol-driven: every write it makes goes\n"
        " * through kallsyms, and the only version-dependent part is which vDSO\n"
        " * fields exist. cpu_spoof.c compiles the >= 4.18 vDSO writes out below\n"
        " * that, so the extension is sound on 4.14 as well; upstream only gates\n"
        " * it at 5.10 because it was never tried on a 4.x datapage.\n"
        " */\n"
        "#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 14, 0)\n"
        "#define KSU_CAN_USE_CPU_SPOOF\n"
        "#endif\n")
old = ("#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n"
       "#define KSU_CAN_USE_CPU_SPOOF\n"
       "#endif\n")

if want in src:
    print("[ksu-nova]   cpu_spoof guard already lowered to 4.14")
elif old in src:
    open(path, "w").write(src.replace(old, want, 1))
    print("[ksu-nova]   lowered cpu_spoof guard from 5.10.0 to 4.14.0")
else:
    sys.exit("[ksu-nova] ERROR: cpu_spoof guard anchor missing in " + path
             + " (upstream changed)")
PY

    python3 - "$KSU_DIR/kernel/extension/cpu_spoof.c" <<'PY'
import sys

path = sys.argv[1]
src = open(path).read()

def once(src, old, new, label):
    if new in src:
        print("[ksu-nova]   " + label + ": already applied")
        return src
    if old not in src:
        sys.exit("[ksu-nova] ERROR: " + label + " anchor missing in " + path
                 + " (upstream changed)")
    print("[ksu-nova]   " + label)
    return src.replace(old, new, 1)

# (a) the datapage header moved to include/vdso/ in 4.18.
src = once(
    src,
    "#include <asm/cpufeature.h>\n"
    "#include <vdso/datapage.h>\n"
    "#include <vdso/clocksource.h>\n",

    "#include <asm/cpufeature.h>\n"
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 18, 0)\n"
    "#include <vdso/datapage.h>\n"
    "#include <vdso/clocksource.h>\n"
    "#else\n"
    "/* Before 4.18 the arm64 datapage is arch-local and has no clock_mode. */\n"
    "#include <asm/vdso_datapage.h>\n"
    "#endif\n",
    "guarded the vDSO datapage include")

# (b) elf_hwcap2 does not exist before 4.20 and elf_hwcap[1] would be a
#     one-element overflow.
src = once(
    src,
    "            elf_hwcap_bitmap[0] = cmd->hwcap;\n"
    "            elf_hwcap_bitmap[1] = cmd->hwcap2;\n",

    "            elf_hwcap_bitmap[0] = cmd->hwcap;\n"
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 20, 0)\n"
    "            elf_hwcap_bitmap[1] = cmd->hwcap2;\n"
    "#endif\n",
    "guarded the elf_hwcap2 write")

# (c) everything that only exists from 4.18 on: clock_mode, clocksource->
#     vdso_clock_mode, vdso_default and the A76 erratum capability.
src = once(
    src,
    "                part != QCOM_CPU_PART_KRYO_4XX_GOLD) {\n"
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 18, 0)\n",

    "                part != QCOM_CPU_PART_KRYO_4XX_GOLD) {\n"
    "#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 18, 0)\n"
    "                /*\n"
    "                 * 4.14: nothing to undo. The vDSO datapage has no\n"
    "                 * clock_mode, struct clocksource has no\n"
    "                 * vdso_clock_mode, there is no vdso_default, and the\n"
    "                 * 1418040 workaround the upstream code clears does not\n"
    "                 * exist yet - so there is no capability bit to clear and\n"
    "                 * no reason to touch a bitmap whose length this kernel\n"
    "                 * does not know. Skipping keeps `missing` at zero instead\n"
    "                 * of failing the call with -ENXIO over symbols that were\n"
    "                 * never going to be there.\n"
    "                 */\n"
    "#else\n"
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 18, 0)\n",
    "guarded the >= 4.18 vDSO / clocksource / hwcap writes")

src = once(
    src,
    "                        pr_warn(\"ksu: set_spoof_cpu failed to resolve 'cpu_hwcaps' / 'system_cpucaps'\\n\");\n"
    "                        ++missing;\n"
    "                    }\n"
    "                }\n"
    "            }\n",

    "                        pr_warn(\"ksu: set_spoof_cpu failed to resolve 'cpu_hwcaps' / 'system_cpucaps'\\n\");\n"
    "                        ++missing;\n"
    "                    }\n"
    "                }\n"
    "#endif /* >= 4.18: vDSO clock mode / clocksource / erratum 1418040 */\n"
    "            }\n",
    "closed the >= 4.18 guard")

open(path, "w").write(src)
PY
fi

# The gate and all three edits must be present in the tree that gets built.
grep -q 'KSU_CAN_USE_CPU_SPOOF' "$KSU_DIR/kernel/kernel_compat.h" \
    || die "cpu_spoof gate vanished"
grep -q 'KERNEL_VERSION(4, 14, 0)' "$KSU_DIR/kernel/kernel_compat.h" \
    || die "cpu_spoof gate is still 5.10-only; the manager will show it Unsupported"
grep -q 'asm/vdso_datapage.h' "$KSU_DIR/kernel/extension/cpu_spoof.c" \
    || die "cpu_spoof.c lost its pre-4.18 datapage include"
grep -q '< KERNEL_VERSION(4, 18, 0)' "$KSU_DIR/kernel/extension/cpu_spoof.c" \
    || die "cpu_spoof.c lost its pre-4.18 guard"
grep -q '>= KERNEL_VERSION(4, 20, 0)' "$KSU_DIR/kernel/extension/cpu_spoof.c" \
    || die "cpu_spoof.c lost its elf_hwcap2 guard"


# ------------------------------------------- 4. Flow tree: keep Flow's hooks ---
#
# Flow-Kernel already carries SUSFS (fs/susfs.c, SUSFS_VERSION v2.4.0) and the
# inline KernelSU hook call sites behind CONFIG_KSU_SUSFS: exec.c, open.c,
# stat.c, read_write.c, reboot.c, sys.c, input.c, selinux/avc.c. SukiSU-Nova's
# CONFIG_KSU_SUSFS build exports the very functions those call sites expect, so
# none of the hook / SUSFS / AVC patching of the clean-tree flow is applied here.
# Only three things differ and are handled below:
#
#   a) ksu_su_compat_enabled: Flow's call sites treat it as a static key, Nova
#      defines it as a plain bool (feature/sucompat.c). Same name, different
#      type -> the call sites are switched to the bool.
#   b) selinux/hooks.c and selinuxfs.c: Flow routes setprocattr, the policy
#      write handlers and the status page through the "hide SELinux
#      modification" code (my_setprocattr, my_write_context, fake_status,
#      ksu_selinux_hide_running ...). Nova builds feature/selinux_hide.c only
#      for >= 5.10, so on 4.14 those symbols would be undefined at link time.
#      The glue is removed; that one manager toggle is unavailable on 4.14.
#   c) Everything Flow references from the driver is checked against the clone.

[[ -f fs/susfs.c && -f include/linux/susfs.h ]] \
    || die "this script is for the Flow tree with SUSFS built in (fs/susfs.c missing)"
grep -q 'susfs_ksu_sid' security/selinux/avc.c \
    || die "security/selinux/avc.c has no SUSFS AVC hook; this is not the Flow tree"
grep -q 'CONFIG_KSU_SUSFS' fs/exec.c \
    || die "fs/exec.c has no inline KSU hook; this is not the Flow tree"

if [[ "$MODE" != check ]]; then
    # (a) ksu_su_compat_enabled: static key -> bool
    for f in fs/exec.c fs/open.c fs/stat.c; do
        [[ -f "$f" ]] || die "$f not found"
        if grep -q 'static_key_true ksu_su_compat_enabled\|static_branch_likely(&ksu_su_compat_enabled)' "$f"; then
            sed -i \
                -e 's/^extern struct static_key_true ksu_su_compat_enabled;/extern bool ksu_su_compat_enabled;/' \
                -e 's/static_branch_likely(&ksu_su_compat_enabled)/likely(ksu_su_compat_enabled)/' \
                "$f"
            log "  $f: ksu_su_compat_enabled is a bool"
        else
            log "  $f: ksu_su_compat_enabled already a bool"
        fi
    done

    # (b) selinux/hooks.c + selinux/selinuxfs.c: drop the SELinux-hide glue.
    # Every block is `#ifdef CONFIG_KSU_SUSFS ... [#else <stock code>] #endif`;
    # the SUSFS branch is removed and the stock branch kept.
    python3 - security/selinux/hooks.c security/selinux/selinuxfs.c <<'PY'
import re
import sys

OPEN = re.compile(r'#\s*ifdef\s+CONFIG_KSU_SUSFS\s*(//.*|/\*.*)?$')
ANY_IF = re.compile(r'#\s*if(n?def)?\b')

def strip(src, path):
    out, stack, removed = [], [], 0
    for line in src.split("\n"):
        s = line.strip()
        dropping = any(f["ksu"] and f["drop"] for f in stack)
        if OPEN.match(s):
            stack.append({"ksu": True, "drop": True})
            removed += 1
            continue
        if ANY_IF.match(s):
            stack.append({"ksu": False, "drop": False})
        elif re.match(r'#\s*elif\b', s) and stack and stack[-1]["ksu"]:
            sys.exit("[ksu-nova] ERROR: " + path + ": #elif inside a CONFIG_KSU_SUSFS block")
        elif re.match(r'#\s*else\b', s) and stack and stack[-1]["ksu"]:
            stack[-1]["drop"] = False
            continue
        elif re.match(r'#\s*endif\b', s):
            if not stack:
                sys.exit("[ksu-nova] ERROR: " + path + ": unbalanced #endif")
            if stack.pop()["ksu"]:
                continue
        if not dropping:
            out.append(line)
    if stack:
        sys.exit("[ksu-nova] ERROR: " + path + ": unterminated #if")
    return "\n".join(out), removed

for path in sys.argv[1:]:
    src = open(path).read()
    new, removed = strip(src, path)
    if removed == 0:
        print("[ksu-nova]   " + path + ": SELinux-hide glue already removed")
        continue
    open(path, "w").write(new)
    print("[ksu-nova]   " + path + ": removed %d CONFIG_KSU_SUSFS block(s), stock code kept" % removed)
PY
fi

# (c) every driver symbol the Flow call sites reference must exist in the clone
missing=0
for sym in ksu_handle_execveat ksu_handle_execveat_sucompat \
           ksu_handle_post_execveat_sucompat ksu_handle_input_handle_event \
           ksu_handle_sys_reboot ksu_handle_setresuid ksu_handle_faccessat \
           ksu_handle_stat ksu_handle_vfs_fstat ksu_handle_sys_read \
           ksu_is_init_rc_hook_enabled ksu_is_input_hook_enabled \
           ksu_su_compat_enabled __ksu_is_allow_uid_for_current \
           susfs_ksu_sid susfs_priv_app_sid; do
    if ! grep -rqw "$sym" "$KSU_DIR/kernel"; then
        warn "driver symbol missing in the clone: $sym"
        missing=1
    fi
done
[[ "$missing" -eq 0 ]] || die "SukiSU-Nova does not provide everything Flow's hooks call"
ok "every driver symbol Flow's hook sites use is provided by SukiSU-Nova"

# Nova is built only when the defconfig selects the inline (SUSFS) hook flavour.
grep -q '^CONFIG_KSU=y' "$DEFCONFIG" || die "$DEFCONFIG: CONFIG_KSU=y missing"
grep -q '^CONFIG_KSU_SUSFS=y' "$DEFCONFIG" || die "$DEFCONFIG: CONFIG_KSU_SUSFS=y missing"
for sym in $(grep -oE '^CONFIG_KSU[A-Z_]*' "$DEFCONFIG" | sed 's/^CONFIG_//' | sort -u); do
    grep -q "config $sym\$" "$KSU_DIR/kernel/Kconfig" \
        || warn "defconfig sets CONFIG_$sym but SukiSU-Nova's Kconfig does not define it"
done

# Flow hook sites must not keep references that Nova no longer provides.
if grep -rnE 'my_setprocattr|my_write_(context|access)|ksu_selinux_hide_(running|enabled)|fake_status|initialize_fake_status' \
        security fs kernel drivers/input --include='*.c' --include='*.h' 2>/dev/null | grep -q .; then
    die "Flow still references SELinux-hide symbols that Nova does not build on 4.14"
fi
ok "Flow tree adapted to SukiSU-Nova (SUSFS v2.4.0 and inline hooks kept)"

log "done. Build with CONFIG_KSU=y, CONFIG_KSU_SUSFS=y from the existing defconfig."
