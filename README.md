# Pinebook Pro Bluetooth Fix (BCM4345C5 / AP6255)

Fixes non-functional Bluetooth on Armbian kernel 6.0.6-rockchip64 (and similar) for the Pinebook Pro's AP6255 WiFi/BT module (BCM4345C5).

## Problem

The kernel's `hci_uart_bcm` serdev driver has a **NULL pointer dereference bug** that crashes when trying to change baud rate. On 6.0.6-rockchip64 the crash is at `hci_uart_setup+0xa8/0x180` and prevents any BT operation.

Additionally, the BT chip's LPO 32kHz clock from the RK808 PMIC isn't claimed (no DT consumer) and gets gated, causing initialization to fail with `hardware error 0x00`.

## Solution

Bypass the kernel driver entirely:

1. **Disable the BT subnode** in the DTB so the kernel serdev driver doesn't claim UART0
2. Add **`uart-has-rtscts`** to the serial node for hardware flow control at higher speeds
3. Use **`hciattach`** (userspace Broadcom handler) to load firmware and initialize the chip
4. Operate at **921600 baud** (or 460800 fallback) with flow control for clean A2DP audio

## Files

| File | Purpose |
|------|---------|
| `bt-attach.sh` | Startup script — powers on chip, runs hciattach in foreground |
| `bt-attach.service` | Systemd unit that runs `bt-attach.sh` at boot before bluetooth.service |
| `rk3399-pinebook-pro-nobt.dts` | Modified device tree source with BT disabled and uart-has-rtscts |

## Deployment

```bash
# Install tools
sudo apt install device-tree-compiler bluez

# Backup original DTB
sudo cp /boot/dtb/rockchip/rk3399-pinebook-pro.dtb /boot/dtb/rockchip/rk3399-pinebook-pro.dtb.bak

# Compile and install modified DTB
dtc -I dts -O dtb -o rk3399-pinebook-pro-nobt.dtb rk3399-pinebook-pro-nobt.dts
sudo cp rk3399-pinebook-pro-nobt.dtb /boot/dtb/rockchip/rk3399-pinebook-pro.dtb

# Install scripts and service
sudo mkdir -p /usr/local/bin
sudo cp bt-attach.sh /usr/local/bin/bt-attach.sh
sudo chmod +x /usr/local/bin/bt-attach.sh
sudo cp bt-attach.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable bt-attach.service

sudo reboot
```

## Verification

```bash
hciconfig -a
# Should show: UP RUNNING, BD Address, Features, Manufacturer: Broadcom (15)

stty -F /dev/ttyS0 | grep speed
# Should show: speed 921600 baud; line = 15;

bluetoothctl scan on
# Should find nearby devices
```

## How It Works

At boot, `bt-attach.service` runs `bt-attach.sh` which:

1. **Resets the BT chip** — Drives GPIO0_B1 (BT_REG_ON) LOW then HIGH
2. **Sets BT_DEV_WAKE** — Drives GPIO2_D3 HIGH
3. **Runs hciattach** — Loads firmware (`BCM4345C0_*.hcd`), configures 921600 baud with flow control, sets line discipline N_HCI

## Audio Interruptions (A2DP Stuttering)

The AP6255's BT uses **UART** rather than SDIO/USB, creating a bandwidth bottleneck. At 460800 baud (~46080 bytes/sec), SBC at 328 kbps (~42200 bytes/sec with overhead) saturates ~92% of UART bandwidth. Any momentary CPU load or interrupt jitter causes buffer underruns and audible stuttering.

Three fixes applied (see full details below):

| Fix | Impact |
|-----|--------|
| UART speed 460800→921600 baud | Double bandwidth headroom (~8%→~54%) |
| SBC quality 0→1 (~237 kbps) | Bandwidth drops to ~64% of 921600 |
| hciattach priority `Nice=-15` | Reduces UART interrupt servicing delay |
| A2DP sink buffer ×4 (1024→4096 frames) | Absorbs residual timing jitter |

With all fixes, stuttering is eliminated or greatly reduced even during CPU-intensive workloads (video playback, compilation, etc.).

## Restoring Original Configuration

```bash
sudo cp /boot/dtb/rockchip/rk3399-pinebook-pro.dtb.bak /boot/dtb/rockchip/rk3399-pinebook-pro.dtb
sudo systemctl disable bt-attach.service
sudo reboot
```

---

## Kernel Upgrade Procedure

Upgrading the kernel (e.g. `linux-image-edge-rockchip64` 22.08.8 → 24.8.3) replaces the DTB — your custom BT DTB will be **overwritten** and BT will stop working. The `bt-attach.sh` script and `bt-attach.service` are unaffected.

### Before upgrade — backup custom DTB

```bash
sudo cp /boot/dtb/rockchip/rk3399-pinebook-pro.dtb /home/max/pinebook-pro-bt-fix/custom-dtb-backup.dtb
```

### Upgrade kernel

```bash
sudo apt update && sudo apt install linux-image-edge-rockchip64 linux-dtb-edge-rockchip64
sudo reboot
```

### After upgrade — restore custom DTB

After reboot, BT will not work. Restore your DTB:

```bash
sudo cp /home/max/pinebook-pro-bt-fix/custom-dtb-backup.dtb /boot/dtb/rockchip/rk3399-pinebook-pro.dtb
```

The old DTB is fully compatible with the new kernel — DTBs don't need to match the kernel version for the same board.

---

## Switching Sound Stack (PipeWire + WirePlumber)

The default Armbian audio stack on this board uses `pipewire-media-session` + PulseAudio. Switching to WirePlumber improves audio latency handling and reduces post-playback hiss. This also resolves A2DP BT audio profile errors (`br-connection-profile-unavailable`) by installing the missing PipeWire BlueZ plugin.

### Install WirePlumber, PulseAudio compat, and BT plugin

```bash
sudo apt install wireplumber pipewire-pulse libspa-0.2-bluetooth
systemctl --user disable pipewire-media-session 2>/dev/null
systemctl --user enable --now wireplumber
systemctl --user restart pipewire pipewire-pulse
```

### Verify

```bash
pactl info | grep 'Server Name'
# Should show: PulseAudio (on PipeWire 0.3.48)

pactl list sinks | grep -E 'Name|State'
# Should show the audio sink and BT sink when connected
```

### Important: WirePlumber config format per version

WirePlumber changed config format between major versions. Use the correct format for your version:

| WP Version | Config format | Config location |
|------------|---------------|-----------------|
| ≤ 0.4.x | Lua (`.lua`) | `~/.config/wireplumber/*.lua.d/` |
| ≥ 0.5.x | JSON (`.conf`) | `~/.config/wireplumber/wireplumber.conf.d/` |

Check your version: `wireplumber --version`. If using WP 0.5+, all config below must use JSON `.conf` format.

### Reduce post-playback hiss (WirePlumber suspend timeout)

The speaker amp stays powered for ~10s after audio stops. Create a 1-second suspend timeout.

**WirePlumber ≤ 0.4.x (Lua):**

Write `~/.config/wireplumber/main.lua.d/51-suspend-timeout.lua`:
```lua
table.insert(alsa_monitor.rules, {
  matches = {},
  apply_properties = {
    ["session.suspend-timeout-seconds"] = 1,
  },
})
```

**WirePlumber ≥ 0.5.x (JSON):**

Write `~/.config/wireplumber/wireplumber.conf.d/51-suspend-timeout.conf`:
```ini
monitor.alsa.rules = [
  {
    matches = [
      {
        node.name = "~.*"
      }
    ]
    actions = {
      update-props = {
        session.suspend-timeout-seconds = 1
      }
    }
  }
]
```

Restart:
```bash
systemctl --user restart wireplumber
```

### ALSA mixer tweaks (reduce hiss during playback)

```bash
# Headphone volume (controls speaker output on ES8316 codec)
amixer -c 0 set 'Headphone' 3

# Disable unused/noisy circuits
amixer -c 0 set 'Mic Boost' off
amixer -c 0 set 'DAC Stereo Enhancement' 0
amixer -c 0 set 'DAC Double Fs' off
amixer -c 0 set 'DAC Soft Ramp' on
amixer -c 0 set 'DAC Soft Ramp Rate' 0

# Save permanently
sudo alsactl store
```

### Pop/click suppression (dapm_pop_time)

If the kernel has `CONFIG_SND_SOC_DEBUGFS=y`, the DAPM pop time can be set to 50ms:

```bash
# Check availability
find /sys -name dapm_pop_time 2>/dev/null

# If the path exists:
echo 50 | sudo tee /sys/kernel/debug/asoc/rockchip,es8316-codec/dapm_pop_time

# Make permanent:
echo 'w /sys/kernel/debug/asoc/rockchip,es8316-codec/dapm_pop_time - - - - 50' \
  | sudo tee /etc/tmpfiles.d/pinebook-pro-audio.conf
```

If the path doesn't exist, the kernel lacks `CONFIG_SND_SOC_DEBUGFS`. Consider upgrading the kernel (see section above) — newer kernels enable this.

---

### Bluetooth A2DP (high-quality audio) after WirePlumber

After switching to WirePlumber, BT speakers may connect as **Headset Head Unit (HSP/HFP)** — mono telephony profile (16 kHz, CVSD codec) — instead of **A2DP Sink** (stereo, SBC codec). This happens because the default config has `device.profile = "a2dp-sink"` unset, so HSP/HFP connects first.

#### Fix: prefer A2DP via WirePlumber config

**WirePlumber ≤ 0.4.x (Lua):**

Create `~/.config/wireplumber/bluetooth.lua.d/51-a2dp-priority.lua`:
```lua
bluez_monitor.rules = {
  {
    matches = {
      {
        { "device.name", "matches", "bluez_card.*" },
      },
    },
    apply_properties = {
      ["bluez5.auto-connect"] = "[ hfp_hf hsp_hs a2dp_sink ]",
      ["device.profile"] = "a2dp-sink",
      ["bluez5.codecs"] = "[ sbc aac ldac aptx aptx_hd ]",
      ["bluez5.default.rate"] = 48000,
      ["bluez5.default.channels"] = 2,
    },
  },
}
```

**WirePlumber ≥ 0.5.x (JSON):**

Create `~/.config/wireplumber/wireplumber.conf.d/51-bluetooth-a2dp.conf`:
```ini
monitor.bluez.rules = [
  {
    matches = [
      {
        device.name = "~bluez_card.*"
      }
    ]
    actions = {
      update-props = {
        bluez5.auto-connect = "[ hfp_hf hsp_hs a2dp_sink ]"
        bluez5.codecs = "[ sbc aac ldac aptx aptx_hd ]"
        bluez5.a2dp.sbc.quality = 1
        bluez5.default.rate = 48000
        bluez5.default.channels = 2
        device.profile = "a2dp-sink"
      }
    }
  }
  {
    matches = [
      {
        node.name = "~bluez_output.*"
      }
    ]
    actions = {
      update-props = {
        session.suspend-timeout-seconds = 1
        node.pause-on-idle = false
        node.latency = "4096/48000"
        clock.quantum-limit = 16384
      }
    }
  }
]
```

Restart WirePlumber and re-pair:

```bash
systemctl --user restart wireplumber pipewire pipewire-pulse
bluetoothctl remove <device-MAC>
bluetoothctl scan on
bluetoothctl pair <device-MAC>
bluetoothctl connect <device-MAC>
pactl set-card-profile bluez_card.<MAC> a2dp-sink
```

#### Verify A2DP is active

```bash
pactl list cards | grep -E 'Active Profile|codec'
# Should show:
#   Active Profile: a2dp-sink
```

#### Switch between SBC and SBC-XQ (if supported)

```bash
pactl set-card-profile bluez_card.<MAC> a2dp-sink-sbc       # standard quality
pactl set-card-profile bluez_card.<MAC> a2dp-sink-sbc_xq   # higher quality
```

---

### Fixing A2DP stuttering

The AP6255 BT module connects via UART rather than SDIO or USB. UART bandwidth is the primary bottleneck for A2DP audio. Multiple fixes are applied:

#### 1. Increase UART baud rate (root cause fix)

Doubles bandwidth from 460800 to 921600 baud (~46080 → ~92160 bytes/sec), increasing headroom from ~8% to ~54%.

Edit `/home/max/pinebook-pro-bt-fix/bt-attach.sh`:
```bash
exec /usr/bin/hciattach -s 115200 -n /dev/ttyS0 bcm43xx 921600 flow
#                                                       ^^^^^^ was 460800
```
Apply:
```bash
sudo cp /home/max/pinebook-pro-bt-fix/bt-attach.sh /usr/local/bin/bt-attach.sh
sudo systemctl restart bt-attach
# Re-pair:
bluetoothctl remove <device-MAC>
bluetoothctl scan on
bluetoothctl pair <device-MAC>
bluetoothctl connect <device-MAC>
```

#### 2. Reduce SBC bitrate via `bluez5.a2dp.sbc.quality`

Prerequisite: PipeWire ≥ 0.3.60. Upgrade from stock 0.3.48 via PPA:
```bash
sudo add-apt-repository ppa:pipewire-debian/pipewire-upstream
sudo add-apt-repository ppa:pipewire-debian/wireplumber-upstream
sudo apt update
sudo apt upgrade pipewire pipewire-bin pipewire-pulse libpipewire-0.3-0 libpipewire-0.3-modules libspa-0.2-bluetooth libspa-0.2-modules wireplumber
```

Quality values: `0` (~328 kbps) → `1` (~237 kbps) → `2` (~183 kbps). Value `1` is the sweet spot — drops bandwidth to ~64% while remaining transparent.

Set via WP 0.5 JSON config (see section above for full file).

#### 3. Increase A2DP sink buffer

Added to the BT node in `monitor.bluez.rules` (see JSON config above):
```
node.latency = "4096/48000"    # buffer size: ~85ms (was ~21ms)
clock.quantum-limit = 16384    # max quantum: ~341ms (was ~170ms)
```
This absorbs residual timing jitter from CPU load or UART scheduling delays.

#### 4. Raise hciattach process priority

The `hciattach` process handles UART traffic for BT. Under CPU load, it can get preempted, causing UART FIFO overruns.

Create a systemd drop-in:

**`~/pinebook-pro-bt-fix/50-rt-priority.conf`**:
```ini
[Service]
Nice=-15
```

Apply:
```bash
sudo mkdir -p /etc/systemd/system/bt-attach.service.d
sudo cp ~/pinebook-pro-bt-fix/50-rt-priority.conf /etc/systemd/system/bt-attach.service.d/
sudo systemctl daemon-reload
sudo systemctl restart bt-attach
```

Verify with `ps -o pid,nice,comm -p $(pgrep hciattach)` — should show nice `-15`.

#### 5. Fallback: if 921600 baud is unstable

Revert baud rate to 460800 and increase SBC quality to `2` instead:

```bash
# Edit bt-attach.sh back to 460800
# Set bluez5.a2dp.sbc.quality = 2 in the WP config
sudo cp bt-attach.sh /usr/local/bin/bt-attach.sh
sudo systemctl restart bt-attach
```

At quality `2` (~183 kbps, ~42% of 460800 baud), bandwidth is well within UART limits and stuttering is eliminated, though audio quality is noticeably reduced.

Restart and verify:
```bash
systemctl --user restart wireplumber pipewire pipewire-pulse
pactl list cards | grep -E 'Active Profile|codec'
# Should show:
#   Active Profile: a2dp-sink
