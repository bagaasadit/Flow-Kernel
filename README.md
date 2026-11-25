# Flow Kernel

A tuned, stability-focused Linux kernel for Qualcomm Snapdragon 720G (`miatoll` / `SM7125`) devices — engineered around real telemetry to maximize sustained responsiveness, true multitasking memory retention, cool thermals, deep-sleep efficiency, and fast charging without placebo tweaks.

[![Releases](https://img.shields.io/github/v/release/bagaasadit/Flow-Kernel?label=Latest%20Release&style=flat-square)](https://github.com/bagaasadit/Flow-Kernel/releases)
[![Build Status](https://img.shields.io/github/actions/workflow/status/bagaasadit/Flow-Kernel/build-kernel.yml?branch=main&label=CI%20Build&style=flat-square)](https://github.com/bagaasadit/Flow-Kernel/actions/workflows/build-kernel.yml)

---

## Supported Devices (`miatoll`)

Unified AnyKernel3 package for all Snapdragon 720G (`atoll`) variants running **Android 11 – 17**:

| Device | Codename |
|---|---|
| Redmi Note 9S | `curtana` |
| Redmi Note 9 Pro (Global) | `joyeuse` |
| Redmi Note 9 Pro Max | `excalibur` |
| POCO M2 Pro | `gram` |

### Test Environment
While the unified `miatoll` build supports all four variants above, all telemetry profiling and multi-cycle stability benchmarks are validated on:
* **Device:** Redmi Note 9 Pro (`joyeuse`) — 6 GB RAM / 64 GB UFS
* **ROM & GApps:** Project Infinity-X 4.1 Vanilla (Android 17) + BiTGApps Core

---

## Kernel Base & Version Identity

* **True Kernel Source Base:** Linux `4.14.357` (Qualcomm `msm-4.14` / `atoll`) with targeted modern Linux 5.x/6.x subsystem backports (MGLRU, `BLK_WBT`, BBRv3, LZ4 v1.11, TEO cpuidle, SUSFS, etc.).
* **Reported `uname -r` (`5.15.207-Flow-vX.Y.Z`):** Derived dynamically from `CONFIG_LOCALVERSION` under `CONFIG_FAKE_UNAME_5_15=y` in [`init/version.c`](init/version.c) so modern Android 15–17 ROMs, userspace tooling, and apps remain fully compatible.

---

## Key Features (Verified in Source)

### Performance, Scheduling & 60Hz Smoothness
* **QTI EAS (Kryo-465 Model) + 8ms PELT + `HZ=300`:** Balances snappy frame pacing with low power consumption, paired with RT efficiency clamp (`sched_util_clamp_min_rt_default = 384`), `init`-protected WALT migration thresholds (`55%` up / `45%` down), `schedtune.prefer_idle = 1` on `foreground` for `SystemUI`/UI frame responsiveness, and in-kernel `CONFIG_CPUSET_ASSIST` isolating `background` (`0-2`) and `system-background` (`0-3`) while keeping `foreground`, `top-app`, and `camera-daemon` on `0-7`.
* **Direct `schedutil` Scaling & `SCHEDTUNE_BOOST_HOLD_ALL`:** Removes the 20% lower-OPP hysteresis in `get_next_freq()`, holds Gold frequencies smoothly with `30 ms` `down_rate_limit_us` (`20 ms` on Silver), clamps `stale_ns` to a 12 ms floor for 60Hz frame continuity, and retains SchedTune boost across brief UI/RenderThread sleeps.
* **Recalibrated `quiet-therm-step` Thermals:** Fixed `step_wise` multi-trip premature arming with cascading cooling-map lower bounds so each Gold/Silver stage triggers strictly at its threshold — 3-stage Gold CPU throttling (`45°C` -> `1996.8 MHz`, `47°C` -> `1708.8 MHz`, `50°C` emergency -> `1267.2 MHz`), `47°C`/`50°C` Silver scaling (`1516.8 MHz` -> `1248.0 MHz`), independent GPU trips (`46°C`/`48°C`/`50°C` -> `430 MHz`), tropical-friendly modem hysteresis (`2°C`), and a `49°C` hardware charging pause / USB bypass (`lvl 16`) to protect the battery under sustained extreme loads.

### Memory Management & Multitasking
* **Fixed Multi-Gen LRU (MGLRU) with Working-Set Protection:** Includes generation aging & memcg migration race fixes, `kswapd` full-to-high-watermark reclaim, and default `lru_gen/min_ttl_ms = 1000` to protect active foreground apps.
* **Widened Watermarks & Early `kswapd` Wakeup Cushion:** `WMARK_LOW` decoupled from `watermark_scale_factor` (`~35.8 MB` `LOW`, `~106.1 MB` `HIGH` on 6 GB devices) with `watermark_scale_factor` floor locked at `125` (`~70.4 MB` `kswapd` runway) and early `kswapd` wakeup at `~71 MB` to prevent premature `lmkd` low-watermark kills.
* **4 GiB `LZ4` zRAM & Budgeted Proactive Compaction:** Pure-kernel `4 GiB` `zram0` floor on 6+ GB variants paired with `vm.swappiness` capped cleanly at `60` (`kvzalloc` Binder buffers, `64 MiB` `reusable` `linux,cma`) and Deep-Sleep-safe budgeted movable proactive compaction (`PROACTIVE_COMPACT_ORDER = pageblock_order`, `GFP_HIGHUSER_MOVABLE` `suitable_migration_source` filtering, `vm.compaction_proactiveness = 30`, per-CPU `pcp` drain) to reduce buddy fragmentation and allocation stalls.

### Storage (`UFS 2.1` + `F2FS`)
* **Block Writeback Throttling (`CONFIG_BLK_WBT_SQ=y`):** Throttles heavy background buffered writes dynamically whenever interactive read/sync latency spikes, keeping messaging apps and SystemUI responsive under heavy file I/O.
* **Bounded Writeback Queue:** Caps `dirty_background_bytes` at `32 MiB`, `dirty_bytes` at `128 MiB`, `dirty_writeback_centisecs` at `200`, and clamps `dirty_expire_centisecs` (`200..500`) cleanly against legacy ROM `init.rc` overrides.
* **Flash-Tuned `deadline` I/O Scheduler:** `read_expire=100ms`, `write_expire=1500ms`, `writes_starved=4`, `fifo_batch=8`, and `front_merges=0`.

### Battery, Deep Sleep & Charging
* **Deep Sleep & Charger Stability Fixes:** Plugs unnecessary `charge_pump_master` / `smb1398` power-supply notifications when unplugged (`battery.c` & `smb1398-charger.c`) and rate-limits `sdam-sts` (`PULSE_SKIP_IRQ_BIT`) `usb_main_psy` uevents (`<= 1 Hz`) with `smblib_icl_change_work` deduplication (`smb5-lib.c`) to stop fast-charge taper IRQ/uevent storms while keeping QC/PD fast charging instant, alongside `TEO` tickless deep C-state fixes and `CONFIG_RCU_FAST_NO_HZ=y`.
* **Fast Charging:** Unlocked PD / HVDCP3.5 33W charging ceiling with calibrated PMIC charging thermal trips.

### Root, Networking & Extras
* **BakaSU + SUSFS + NoMount:** Inline-hooked KernelSU (BakaSU) with full SUSFS hiding hooks intact for banking compatibility.
* **Networking:** `BBRv3` (`CONFIG_DEFAULT_BBR=y`) paired with `fq_codel` (`WESTWOOD` & `CUBIC` also built-in).
* **Display & Haptics:** KCAL color calibration (`CONFIG_DRM_MSM_KCAL_CTRL=y`), refined AW8624 perceptual gain curve (`0x44`/`0x6C`/`0x74`) + `wf_10` `3300 mV` tuning for firmer Back Gesture feedback, 5s-cached `ram_vbat_comp` voltage compensation, and extended `stop_delay` poll reliability.

---

## Downloads & Releases

Every release version has its own dedicated release page containing the flashable kernel zip, matching **BakaSU Manager APK**, SHA-256 checksums, and per-version changelog:

* **All Releases (Per-Version):** 👉 **[GitHub Releases](https://github.com/bagaasadit/Flow-Kernel/releases)**
* **BakaSU Manager APK (`v4.2.0-rc3`):** [BakaSU_v4.2.0-rc3_35252-arm64-v8a-release.apk](https://github.com/bagaasadit/Flow-Kernel/releases/download/v1.2.4/BakaSU_v4.2.0-rc3_35252-arm64-v8a-release.apk)  
  SHA-256: `43ccd6ec08844bf656b0800d84567c4f04412203446e6dada9570008f180fe25`

---

## Installation

1. Download `Flow-Kernel-vX.Y.Z-miatoll-BakaSU.zip` **and** `BakaSU_v4.2.0-rc3_35252-arm64-v8a-release.apk` from the version's page under **[Releases](https://github.com/bagaasadit/Flow-Kernel/releases)** (verify the SHA-256 checksums if desired).
2. Flash the kernel zip in a custom recovery (TWRP/OrangeFox) or a Kernel Flasher app (Franco Kernel Manager / Horizon Kernel Flasher).
   * AnyKernel3 automatically backs up your current `boot` and `dtbo` images to `/sdcard/backup_boot.img` and `/sdcard/backup_dtbo.img` before flashing.
3. Reboot to system and install **BakaSU Manager** (`BakaSU_v4.2.0-rc3_35252-arm64-v8a-release.apk`) to manage root access, modules, and SUSFS configuration.

---

## Disclaimer (DYOR)

> **Do Your Own Research — Flash at Your Own Risk.**  
> Custom kernels modify low-level hardware, memory, thermal, and power behavior. Although every release is tested thoroughly on `Redmi Note 9 Pro (6/64)` running `Infinity-X 4.1 Vanilla (Android 17) + BiTGApps Core`, you are responsible for verifying compatibility with your own ROM/setup and backing up your `boot`, `dtbo`, and important data before flashing. The maintainer assumes no liability for bootloops, data loss, hardware issues, or banking/Play Integrity changes.

---

## Building from Source

Flow Kernel builds using LLVM / **Neutron Clang** with ThinLTO + Polly (`CONFIG_LLVM_POLLY=y`, no GNU binutils).

```bash
git clone --depth=1 https://github.com/bagaasadit/Flow-Kernel.git -b main Flow-Kernel
cd Flow-Kernel
./build.sh
```

`build.sh` validates host prerequisites (`make`, `tar`, `zip`, `bc`, `bison`, `flex`, `zstd`, `curl`/`wget`), probes Polly support, clones BakaSU at the pinned commit, compiles `out/arch/arm64/boot/Image`, `cust-atoll-ab.dtb`, and `dtbo.img`, and packages `AnyKernel/Flow-Kernel-vX.Y.Z-BakaSU-miatoll-<timestamp>.zip`.

---

## Credits & License

* Upstream kernel lineage: **Sixfaced** ([`NothingNormal`](https://github.com/NothingNormal) / `rkmandilwar-rgb`) & **BlackHole** (`kim_chi_96` / `arshad-jamil33`) — full git commit history preserved
* Linux Kernel contributors & Qualcomm CAF / LineageOS `msm-4.14` (`atoll` / `miatoll`) base
* [Baka-SU / BakaSU](https://github.com/Baka-SU/BakaSU) & SUSFS contributors
* Neutron Toolchains, osm0sis (AnyKernel3), and upstream MGLRU / BBRv3 / BLK_WBT authors
* Licensed under the **GNU General Public License v2.0 (GPLv2)** — see [COPYING](COPYING).
