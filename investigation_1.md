# Pinebook Pro Boot Log Analysis — Investigation Report 1

**Date:** 2026-08-10
**Device:** Pine64 Pinebook Pro (Rockchip RK3399, AP6255 WiFi/BT module)
**Target kernel:** Armbian `6.0.6-rockchip64` (per README; upgrade path to 24.8.3 documented)
**Analyst:** opencode (build mode)

---

## 1. Source material available

| Path | Content |
|---|---|
| `~/pinebook-pro-bt-fix/` | Git repo: BT-fix implementation + README log analysis |
| `~/pinebook-pro-bt-fix/README.md` (lines 7–9, 73–86, 88–107) | Primary boot-log symptom documentation |
| `~/pinebook-pro-bt-fix/.git/logs/HEAD` | Full commit timeline (18 entries) |
| `~/pinebook-pro-bt-fix/rk3399-pinebook-pro-nobt.dts` (4327 lines) | Modified device tree source |
| `~/pinebook-pro-bt-fix/bt-attach.sh` | Userspace BT attach script |
| `~/pinebook-pro-bt-fix/bt-attach.service` | Systemd unit (runs before bluetooth.service) |
| `~/pinebook-pro-bt-fix/50-rt-priority.conf` | Nice=-15 drop-in for hciattach |
| `~/Downloads/pine64-pinebookPro-2023.07-007.tar.xz` | Tow-Boot SPI bootloader image — binaries only, **no logs** |

**Evidence caveat:** No raw `dmesg`, `journalctl -b`, or kernel ring-buffer dump text files are present in the
workspace. The symptoms below are transcribed **verbatim from** `README.md` and the commit messages.
If raw boot output is later recovered, this report should be annotated against it.

---

## 2. Issues found (from boot/log evidence)

### 2.1 Kernel OOPS — `hci_uart_bcm` NULL pointer dereference  (CRITICAL — kernel stability)

| Key | Value |
|---|---|
| Symptom logged | Kernel crash during BT initialization; no HCI device appears |
| Crash address | `hci_uart_setup+0xa8/0x180` |
| Affected kernel | `6.0.6-rockchip64` (and similar) |
| Affected driver | `hci_uart_bcm` serdev driver (`drivers/bluetooth/hci_uart_bcm.c`) |
| Trigger | Driver attempts to change baud rate on the AP6255's BCM4345C5 UART |
| Root cause (assessed) | A pointer — most likely the BCM-private serdev data or the baud-rate `table` entry — is dereferenced before a NULL check inside `hci_uart_setup()`. At commit c4ea58d the workaround bypasses the driver entirely; no patch-level fix is shipped. |
| Impact | BT non-functional; kernel crash on boot if serdev binding proceeds. |

### 2.2 RK808 PMIC LPO 32 kHz clock never consumed  (HIGH — driver/hardware)

| Key | Value |
|---|---|
| Symptom logged | `hardware error 0x00` on BT chip init |
| Root cause (assessed) | In the stock DTB the BT subnode under `serial@ff180000` does not declare itself as a consumer of the RK808 PMIC's 32 kHz LPO (`xin32k` / `rk808-clkout2`, clock index `<0x00>` from `pmic@1b` at `i2c@ff3c0000`). The clock is therefore gated; the BCM4345C5 has no reference clock → init handshake returns 0x00. |
| Impact | BCM4345C5 never receives its reference clock → init fails. (Mitigated indirectly by the workaround, see §3.) |

### 2.3 PCIe link-training timeout on empty M.2 slot  (HIGH — boot perf + reboot hang)

| Key | Value |
|---|---|
| Symptom logged | `PCIe link training gen1 timeout!` on every boot; reboot/shutdown hangs |
| Boot-time cost | ~10–15 s added to kernel boot |
| Root cause | `pcie@f8000000` node has `status = "okay"` and `bus-scan-delay-ms = <0x3e8>` (1000 ms) but no endpoint device present → link-training times out and retries. |
| Secondary | On shutdown the PCIe power domain (`power-domain@23` / `power-domain@24`) fails to sequence down cleanly → **reboot hang**. |
| Impact | Slow boot + unreliable reboot/shutdown when no NVMe SSD installed. |

### 2.4 A2DP audio stuttering via UART bottleneck  (MEDIUM — audio quality)

| Key | Value |
|---|---|
| Symptom | Stuttering/underruns during BT A2DP playback under CPU load |
| Bandwidth math | UART @ 460800 baud ≈ 46 080 B/s; SBC @ quality 0 ≈ 328 kbps ≈ 42 200 B/s **with overhead** → ~92 % utilization |
| Root cause | AP6255 exposes BT over UART (not SDIO/USB). At stock 460800 baud the link is nearly saturated; any CPU/IRQ jitter causes TX FIFO overruns → audible gaps. |
| Impact | A2DP audio breaks up during video playback, compilation, or 2.4 GHz WiFi contention. |

### 2.5 BT defaults to HSP/HFP (mono) after WirePlumber switch  (MEDIUM — audio quality)

| Key | Value |
|---|---|
| Symptom | Headphones connect as "Headset Head Unit" (HSP/HFP, 16 kHz CVSD) instead of A2DP Sink (stereo SBC) |
| Root cause | WirePlumber default `monitor.bluez` rules do not set `device.profile = "a2dp-sink"` or enumerate `bluez5.codecs`, so the telephony profile binds first. |
| Impact | Mono audio at low bitrate instead of stereo A2DP. |

### 2.6 Post-playback speaker hiss  (LOW — audio comfort)

| Key | Value |
|---|---|
| Symptom | Amplified speakers hiss for ~10 s after audio stops |
| Root cause | WirePlumber/ALSA default suspend timeout keeps the ES8316 codec + TPA6596 amp powered for the full default window. |
| Impact | Audible hiss when idle; battery drain. |

### 2.7 Kernel upgrade wipes custom DTB  (MEDIUM — operational risk)

| Key | Value |
|---|---|
| Symptom | After `apt install linux-image-edge-rockchip64 … linux-dtb-edge-rockchip64`, BT stops working again on next boot |
| Root cause | The kernel package's `linux-dtb-*` provides `/boot/dtb/rockchip/rk3399-pinebook-pro.dtb` and overwrites the patched one without a `dpkg-divert` or hook. |
| Impact | Silent regression — BT silently falls back to the broken in-tree serdev driver and OOPSes again. |

---

## 3. Severity / priority matrix

| Priority | Issue | Class |
|---|---|---|
| P0 (crash) | `hci_uart_bcm` NULL-deref OOPS | Kernel stability |
| P0 (boot) | PCIe empty-slot timeout + reboot hang | Boot performance / reliability |
| P1 (function) | RK808 LPO clock gated → BT init fail | Driver/hardware |
| P2 (quality) | UART bandwidth saturation → A2DP stutter | Audio |
| P2 (quality) | HSP/HFP binds instead of A2DP | Audio |
| P3 (minor) | Post-playback hiss | Audio comfort |
| P2 (ops) | Kernel upgrade clobbers custom DTB | Operational |

---

## 4. Fixes/workarounds already applied (git history)

| Commit | Issues | What changed | Files |
|---|---|---|---|
| `c4ea58d` | 2.1, 2.2, 2.6* | New DT overlay `rk3399-pinebook-pro-nobt.dts`; BT subnode under `serial@ff180000` set `status = "disabled"`; `uart-has-rtscts` added; `bt-attach.sh` + `bt-attach.service` use userspace `hciattach` instead of kernel serdev | DTS, .sh, .service, README |
| `e049b61` | 2.4 | UART raised 460800 → 921600 baud; added `50-rt-priority.conf` (Nice=-15); PipeWire ≥ 0.3.60 upgrade path; WirePlumber A2DP profile configs (JSON `.conf` / Lua `.lua` per version); SBC quality 0→1; `node.latency = "4096/48000"`; `clock.quantum-limit = 16384` | README, bt-attach.sh, 50-rt-priority.conf |
| `c321232` | 2.3 | `pcie@f8000000` → `status = "disabled"` (valid only when no NVMe present) | DTS, README |

\* Issue 2.6 (hiss) is addressed **indirectly** — disabling the in-tree serdev driver and using `hciattach` removes the high-priority IRQ contention that contributed to codec scheduling jitter.

---

## 5. Plan: remaining gaps and next steps

### 5.1 Immediate verification (recommended before trusting the fix)

1. **Confirm crash signature on current kernel** — run on the device:
   ```
   dmesg | grep -iE 'hci_uart_setup|Unable to handle|Kernel BUG|serdev'
   uname -a
   ```
   The README cites `6.0.6-rockchip64`. If the device has since upgraded (the README documents a
   `22.08.8 → 24.8.3` path), re-test whether upstream fixed the `hci_uart_bcm` OOPS — newer
   kernels may not need the `no_bt` DTB hack at all.

2. **Verify the RK808 LPO clock** is actually gated (issue 2.2 fix is indirect):
   ```
   dmesg | grep -iE 'lpo|xin32k|32k'
   ```
   The current workaround disables the BT DT subnode rather than wiring up a clock consumer, so
   the LPO is *still* gated — `hciattach` simply doesn't depend on it at 921600 baud. If upstream
   drivers ever re-enable the serdev path, this latent bug returns.

3. **PCIe confirmation** — confirm the board currently has **no** NVMe installed. If an NVMe *is*
   present, `status = "disabled"` on `pcie@f8000000` will break the SSD. Gate the disable behind
   a second DTB variant.

### 5.2 Outstanding items to close gaps

| ID | Action | File / Artifact | Effort |
|---|---|---|---|
| A | Auto-re-apply custom DTB after kernel upgrade (dpkg-divert or apt hook) | new hook / `dtc` script | Small |
| B | Add a second DTS variant with BT + PCIe intact for NVMe-equipped boards | `rk3399-pinebook-pro-full.dts` | Small |
| C | Capture a real `dmesg` and `journalctl -b` from the *broken* (stock DTB) state | `logs/dmesg-stock.log` | 5 min (on-device) |
| D | Validate `921600` baud stability across suspend/resume | on-device testing | Medium |
| E | Verify `pactl list cards` shows `Active Profile: a2dp-sink` on both WP ≤ 0.4 and ≥ 0.5 | on-device | 5 min each |
| F | Add `tmpfiles.d` / udev rule so DAPM `pop_time` survives reboot without manual `tee` | `/etc/tmpfiles.d/pinebook-pro-audio.conf` | Small |

### 5.3 Recommended execution ordering

```
Phase 1 (stability):     2.1 → 2.2 → 2.3     (kernel OOPS, clock, PCIe)
Phase 2 (audio quality):   2.4 → 2.5 → 2.6    (UART baud, A2DP profile, hiss)
Phase 3 (operational):     2.7 + A, B, F      (dtb persistence, NVMe variant)
Phase 4 (validation):      C, D, E            (real dmesg, suspend/resume, profile check)
```

---

## 6. Key file references

| Concern | File:line (current repo) |
|---|---|
| BT subnode disabled | `rk3399-pinebook-pro-nobt.dts:741-743` |
| `uart-has-rtscts` added | `rk3399-pinebook-pro-nobt.dts:738` |
| PCIe disabled | `rk3399-pinebook-pro-nobt.dts:263` (`status = "disabled"`) |
| hciattach baud / GPIO reset | `bt-attach.sh:5-11` |
| hciattach priority | `50-rt-priority.conf:3` (`Nice=-15`) |
| Crash address cite | `README.md:7` |
| PCIe timeout cite | `README.md:90` |
| UART bottleneck math | `README.md:75-76` |

---

*End of report.*
