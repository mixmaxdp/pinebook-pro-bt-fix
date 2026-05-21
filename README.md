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
4. Operate at **460800 baud** with flow control for clean A2DP audio

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
# Should show: speed 460800 baud; line = 15;

bluetoothctl scan on
# Should find nearby devices
```

## How It Works

At boot, `bt-attach.service` runs `bt-attach.sh` which:

1. **Resets the BT chip** — Drives GPIO0_B1 (BT_REG_ON) LOW then HIGH
2. **Sets BT_DEV_WAKE** — Drives GPIO2_D3 HIGH
3. **Runs hciattach** — Loads firmware (`BCM4345C0_*.hcd`), configures 460800 baud with flow control, sets line discipline N_HCI

## Audio Interruptions

If you hear brief audio interruptions during BT playback, the most likely cause is **BT/WiFi coexistence**. The AP6255 module shares a single antenna between WiFi (2.4 GHz) and Bluetooth. When WiFi transmits on 2.4 GHz, BT audio can stutter.

Fixes (in order of preference):

1. **Use 5 GHz WiFi** — BT only uses 2.4 GHz, so 5 GHz WiFi eliminates the conflict entirely
2. **Increase PulseAudio A2DP buffer** — Larger buffers absorb the brief gaps (adds ~500ms latency)
3. **Disable WiFi when streaming audio** — `sudo nmcli radio wifi off` before playing music

### PulseAudio Buffer Tweak

If 5 GHz isn't available, increase the A2DP buffer in PulseAudio:

```bash
# Edit PulseAudio config
sudo tee -a /etc/pulse/default.pa > /dev/null << 'EOF'
.ifexists module-bluetooth-discover.so
load-module module-bluetooth-discover
load-module module-bluetooth-policy
.endif
EOF

# Increase buffer via PipeWire or PulseAudio module parameters
# For PulseAudio:
pactl set-port-latency-offset bluez_sink <device> 500000
```

Alternatively, add to `/etc/pulse/system.pa`:
```
load-module module-udev-detect tsched=no fixed_latency_range=500000
```

This increases the audio buffer to ~500ms, smoothing over WiFi-caused gaps at the cost of slightly higher audio latency.

## Restoring Original Configuration

```bash
sudo cp /boot/dtb/rockchip/rk3399-pinebook-pro.dtb.bak /boot/dtb/rockchip/rk3399-pinebook-pro.dtb
sudo systemctl disable bt-attach.service
sudo reboot
```
