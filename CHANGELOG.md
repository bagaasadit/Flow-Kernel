# Changelog

All notable releases of **Flow Kernel** (`miatoll` / SM7125) are documented in this file.

---

## [v1.2.4] - 2026-11-25

### RT Clamp & Scheduler Efficiency (18-Run A/B + ABBA Validated)
- **kernel/sched (`core.c`):** Lower `sysctl_sched_uclamp_util_min_rt_default` from `1024` (`SCHED_CAPACITY_SCALE`) to `384`, keeping RT compositor/audio tasks (`SurfaceFlinger`, `RenderEngine`, `FastMixer`) on Kryo-465 Gold at the `1113.6 MHz` efficiency OPP instead of slamming Gold to `2323.2 MHz` on every small RT wakeup. Cuts screen-on idle power (`~181 mA`, `P6@2323 ≈ 0%`), reduces heavy-notification QS freezes nearly in half, and maintains `0` FastMixer audio underruns.
- **kernel/sched (`fair.c`):** Tighten WALT cluster migration thresholds from `60%` up / `52%` down (`1706`/`1969`) to `55%` up / `45%` down (`1861`/`2275`, `init`-protected against vendor `post_boot` overrides) while keeping stock `schedutil/down_rate_limit_us` (`20000 us` Silver / `30000 us` Gold) so CFS UI threads (`SystemUI`, `Reddit`, `FotMob`, `TikTok`) migrate to Gold earlier without leaking idle load.

### Proactive Memory Compaction Fix (`mm/compaction.c`)
- **mm/compaction (`proactive_compact_node`, `suitable_migration_source`):** Align `PROACTIVE_COMPACT_ORDER` to `pageblock_order` (`order-3` on non-hugetlb `miatoll` instead of mismatched `order-4`), switch proactive `gfp_mask` from `GFP_KERNEL` to `GFP_HIGHUSER_MOVABLE` (`MIGRATE_MOVABLE`), and enforce `suitable_migration_source()` filtering for `cc->proactive` passes so background compaction stops scanning unmovable slabs and genuinely coalesces movable user/zRAM pageblocks. Raise `COMPACT_PROACTIVE_BASE_MS` to `4000 ms` and tune `vm.compaction_proactiveness` default to `30` to reduce live `compact_stall` events with lower background wakeup frequency.

---

## [v1.2.3] - 2026-11-22

### Charging & Stability (P0 Fix)
- **power/supply (`smb5-lib.c`, `smb5-lib.h`):** Rate-limit `sdam_sts_change_irq_handler` (`PULSE_SKIP_IRQ_BIT`) `usb_main_psy` uevent notifications to at most once per `1000 ms` while keeping `chg->irq_status` updated unconditionally, and deduplicate `smblib_icl_change_work` notifications when `settled_ua` has not changed (resetting state cleanly on USB plug/unplug). Eliminates charging IRQ/uevent storms during fast-charge taper without affecting QC/PD negotiation or plug detection.

### Thermal Management (`step_wise` + `quiet-therm-step`)
- **drivers/thermal/step_wise & dts/atoll-thermal:** Prevent inactive higher thermal trips sharing a cooling device from prematurely arming off lower stages' `cur_state - 1`, and enforce cascading lower bounds across `quiet-therm-step` Gold (`stage 2`: `47°C`, `stage 3`: `50°C`) and Silver (`stage 2`: `50°C`) cooling maps so each stage stays inactive below its trip threshold and steps down cleanly on cooldown.

### UI Smoothness, Scheduling & 6 GB Memory Management
- **kernel/sched (`fair.c`, `core.c`, `cpufreq_schedutil.c`, `tune.c`, `CONFIG_CPUSET_ASSIST`):** Tune WALT migration thresholds to `60%` up / `52%` down (`init`-protected against `post_boot` overrides), raise Gold `schedutil/down_rate_limit_us` to `30000 us` (keeping Silver at `20000 us`), enable `schedtune.prefer_idle` on `/dev/stune/foreground`, and isolate `background` (`0-2`) and `system-background` (`0-3`) cpusets in kernel.
- **mm (`compaction.c`, `page_alloc.c`):** Raise `vm.compaction_proactiveness` default to `40`, scale `extra_free_kbytes` `WMARK_LOW` contribution to `60%` (`~35.8 MB` on 6 GB `miatoll`), and set `MIN_WATERMARK_SCALE_FACTOR = 125` (`~70.4 MB` `kswapd` runway) to reduce fragmentation stalls and unnecessary `lmkd` kills.

---

## [v1.2.2] - 2026-11-21

### Memory Management & Multitasking
- **mm/compaction & mm/internal.h (`proactive_compact_node`):** Fix background proactive compaction stalling on `pageblock_order = 3` non-hugetlb kernels by switching `proactive_compact_node()` to `.order = -1` (`cc.proactive = true`) instead of `.order = 4`, preventing premature exit on a single unmovable order-4 block or `extfrag_threshold` skip; flush per-CPU page lists every 64 scanned pages and on completion so coalesced `order-3/4` blocks reach the buddy allocator, bounded by a strict `4096` migrate / `16384` free scan budget per wakeup while keeping `MIGRATE_ASYNC`, outside `psi_memstall`, and freezable Deep Sleep safety (`0` extra wakeups).
- **mm/page_alloc (`get_page_from_freelist`):** Add an early `kswapd` wakeup cushion at the midpoint between `WMARK_LOW` (`~46 MB`) and `WMARK_HIGH` (`~102 MB`) — `~74 MB` on 6 GB `miatoll` — letting `kswapd` start reclaiming inactive file cache before allocation bursts breach `WMARK_LOW` and trigger premature `lmkd` low-watermark kills, without altering `/proc/zoneinfo` `WMARK_LOW`.

### Thermal Safety (`quiet-therm-step`)
- **dts/atoll-thermal:** Preserve daily/gaming curves `<= 48°C` untouched while adding a `49°C` hardware charging pause / USB bypass trip (`chg_trip7`, `hysteresis = 3°C`, `pm6150_charger` `lvl 16`) and a `50°C` Stage 3 emergency ceiling (`Gold 1267.2 MHz`, `Silver 1248.0 MHz`, `GPU 430 MHz`) to protect battery health under sustained extreme workloads.

### Installer UI
- **AnyKernel3:** Refresh recovery installer layout (`banner` + `anykernel.sh`) to the clean Editorial Flagship style while keeping automatic `boot`/`dtbo` backups and flashing logic intact.

---

## [v1.2.1] - 2026-11-20

### Memory Management & Multitasking
- **mm/page_alloc:** Decouple `WMARK_LOW` from `watermark_scale_factor` when Android's `extra_free_kbytes` already supplies a low-watermark cushion (`~46 MB` `WMARK_LOW` / `~102 MB` `WMARK_HIGH` on 6 GB `miatoll`), eliminating `~95 MB` double-stacking that triggered premature `lmkd` kills while preserving the full `56 MB` `kswapd` runway (`MIN_WATERMARK_SCALE_FACTOR = 100`).
- **drivers/block/zram (`zram_drv.c`):** Enforce a pure-kernel `4 GiB` `zram0` disksize floor on `>=5 GiB` RAM `miatoll` variants while keeping fast `LZ4` compression and leaving `4 GiB` devices untouched, preventing early zRAM saturation and `<300 MB SwapFree` `lmkd` storms.
- **mm/compaction & kernel/sysctl:** Add Deep-Sleep-safe gentle order-4 (`64 KiB`) Proactive Compaction (`vm.compaction_proactiveness = 20`) running non-blocking `MIGRATE_ASYNC` passes with `2s..32s` exponential backoff, `WMARK_LOW` deferral, freezable sleep (`wait_event_freezable_timeout`, zero suspend wakeups), and zero `psi_memstall` inflation to eliminate `compact_stall`/`allocstall` UI micro-freezes.

### Haptics (`AW8624`)
- **drivers/misc/aw8624_haptic & dts/cust-atoll-idp:** Refine AW8624 perceptual gain curve (`LIGHT=0x44`, `MEDIUM=0x6C`, `STRONG=0x74`) and tune `wf_10` to `3300 mV` for firmer Back Gesture (`CLICK`/`TICK`) feedback without overdriven keyboard/timed rumble; fix and enable 5s-cached `ram_vbat_comp` across both `RAM_MODE` and `RAM_LOOP_MODE` with `0x80` non-clipping clamping, and update AW8624 selftests (`mock.c`) to verify voltage compensation and gain scaling.

---

## [v1.2.0] - 2026-11-19

### Memory Management & Multitasking
- **mm/page_alloc:** Raise `MIN_WATERMARK_SCALE_FACTOR` floor from `50` to `100` (~56 MB `kswapd` hysteresis runway alongside `extra_free_kbytes=30375`), giving `kswapd` headroom to absorb bursty allocations without triggering false `lmkd` low-watermark kills.
- **mm/vmscan & kernel/sysctl:** Lower default `vm_swappiness` from `100` to `60` and cap sysctl writes cleanly at `60` without returning errors so vendor `init.qcom.post_boot-atoll.sh` (`echo 100 > swappiness`) succeeds cleanly while preventing excessive zRAM thrashing.
- **mm/vmscan:** Enable MGLRU working-set protection by setting `lru_gen/min_ttl_ms` default to `1000` ms.
- **dts/atoll:** Expand reusable `linux,cma` region from `32 MiB` (`0x2000000`) to `64 MiB` (`0x4000000`) with zero idle RAM penalty to prevent CMA exhaustion during HDR camera bursts.

### Storage (`UFS 2.1`) & Anti-Stutter Writeback QoS
- **defconfig:** Enable block writeback throttling (`CONFIG_BLK_WBT=y`, `CONFIG_BLK_WBT_SQ=y`) for legacy single-queue UFS (`deadline`) to prevent background copy/archive writes from stalling foreground UI & SQLite reads.
- **mm/page-writeback & kernel/sysctl:** Bound writeback queues to `dirty_background_bytes = 32 MiB`, `dirty_bytes = 128 MiB`, `dirty_writeback_centisecs = 200`, and clamp `dirty_expire_centisecs` cleanly within `200..500` (`2..5s`) while preserving compatibility with ROM `init.rc` / `init.target.rc` writes; remove legacy `dirty_expire_centisecs_nosys` / `0444` workaround.
- **block/deadline:** Re-tune default parameters for flash UFS 2.1 (`read_expire = 100 ms`, `write_expire = 1500 ms`, `writes_starved = 4`, `fifo_batch = 8`, `front_merges = 0`).

### Deep Sleep & Power Supply
- **power/supply (`battery.c`, `smb1398-charger.c`):** Guard `pl_fcc_vote_callback()` and `smb1398_div2_cp_ilim_vote_cb()` `power_supply_changed()` notifications so `charge_pump_master` no longer storms userspace/wakeups while USB is unplugged; ignore `"main"` and `"cp_slave"` notifier events when `!usb_present` while keeping `"usb"` events instant for fast-charge plug-in; demote `pr_err` debug noise in `smb1398-charger.c` to `dev_dbg`.

### Thermal Management & `<50%` Sustained Performance
- **include/linux/thermal.h & dts/atoll-thermal:** Raise `THERMAL_MAX_TRIPS` to `20` and recalibrate `quiet-therm-step` with a smooth 2-stage Gold CPU curve (`45°C` / `2°C` hyst -> `1996.8 MHz`, `47°C` / `2°C` hyst -> `1708.8 MHz`), dedicated GPU trips (`46°C` -> `650 MHz`, `48°C` -> `565 MHz`, `2°C` hyst) decoupled from modem throttling, and tropical-friendly modem hysteresis (`45°C`/`47°C` with `2°C` hyst) while keeping `chg_trip0..6` fast-charging limits intact.

### Documentation, Build & CI
- Add comprehensive English `README.md` and `CHANGELOG.md`.
- Upgrade GitHub Actions CI to publish per-version releases (`/releases/tag/vX.Y.Z`) with dedicated changelogs, SHA-256 checksums, and `BLK_WBT` verification checks, and make `build.sh` derive zip version automatically from `CONFIG_LOCALVERSION`.

---

## [v1.1.1] - 2026-11-17

- **mm/page_alloc:** Set `watermark_scale_factor` default and floor to `50` (~28 MB `kswapd` hysteresis band) and clamp writes below `50` cleanly so `/vendor/bin/init.qcom.post_boot-atoll.sh` (`echo 1 > watermark_scale_factor`) succeeds without breaking kswapd watermarks (`dc38684d3692`, `c34966a383aa`).

---

## [v1.1.0] - 2026-11-17

- **mm/fork/mglru:** Fix MGLRU generation aging races and `memcg` migration races, reconcile empty generation counters cleanly, remove `kswapd_waiters` early bail so `kswapd` reclaims all the way to `WMARK_HIGH`, and re-enable MGLRU (`9f5e493df2b4`, `17b0be72c11c`).
- **sched/cpufreq:** Enable `CONFIG_PELT_UTIL_HALFLIFE_8=y`, remove the 20% lower-OPP hysteresis in `schedutil` `get_next_freq()`, clamp `stale_ns` to a 12 ms floor, and enable `SCHEDTUNE_BOOST_HOLD_ALL` for smoother 60Hz responsiveness (`fd9953670fe2`, `17b0be72c11c`).

---

## [v1.0.9] - 2026-11-17

- **mm:** Enable `CONFIG_VM_EVENT_COUNTERS` for detailed reclaim/swap/compaction `/proc/vmstat` telemetry (`0acf0beb3c88`).
- **mm/userfaultfd:** Commit memcg charge before LRU insertion (`730151d6919e`).
- **build/ci:** Update release packaging to `v1.0.9` (`1006fc13bc67`).

---

## [v1.0.8] - 2026-11-17

- **init/build:** Derive `init_uts_ns` release and `linux_banner` dynamically from `CONFIG_LOCALVERSION` under `CONFIG_FAKE_UNAME_5_15`, drop stale `-kinesis-omega-bpf` suffix, and verify expected UTS release in CI (`5d17c73245b4`).
- **bpf:** Avoid `ksize(NULL)` warning in `copy_array()` (`871d500c50dc`).
- **drivers/haptics:** Extend AW8624 `stop_delay` poll budget to 300 iterations (`14cecf95268c`).

---

## [v1.0.7] - 2026-11-17

- **sched/arm64:** Disable BORE, restore QTI EAS Kryo-465 energy/capacity model, boost util, and set `HZ=300` (`2ae7f7fd574d`).
- **mm/android:** Temporarily disable legacy MGLRU pending race fixes, balance anon/file reclaim, and use `kvzalloc` for Android Binder (`a3360e19b662`).
- **thermal:** Add 2-step GPU curve, skin trip hysteresis, and `step_wise` `THERMAL_TREND_STABLE` fix (`21e00593ae33`).
- **drivers:** Balance AW8624 HAL `FF_GAIN` keyboard haptics, speed up stop polling, and quiet default UFS debug logs (`bb4e50a18e79`).
- **ci:** Configure standalone `bagaasadit/Flow-Kernel` `main` CI workflow (`14a4b34fdac9`).
