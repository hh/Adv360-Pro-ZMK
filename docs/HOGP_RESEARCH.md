# BLE HID Central (HOGP) Research for Kinesis Advantage 360 Pro

## Overview

This document captures research into adding BLE HID Central support to ZMK firmware,
enabling the Kinesis Advantage 360 Pro to connect to external pointing devices
(Magic Trackpad, BLE mice) and forward their input to host computers.

**Goal**: Connect a Magic Trackpad or mouse via Bluetooth to the keyboard's left half,
and have pointing events follow the active BLE profile when switching between computers.

---

## Hardware Platform

### NRF52840 (Kinesis Advantage 360 Pro)

| Resource | Specification |
|----------|---------------|
| Flash | 1 MB |
| RAM | 256 KB |
| BLE | Bluetooth 5.0, supports Central + Peripheral simultaneously |
| Current firmware size | ~530 KB |

The NRF52840 supports **multi-role BLE** - it can act as both Central and Peripheral
at the same time, which is required for this feature.

**Note**: USB Host is NOT supported by NRF52840 (device-only USB controller),
so USB trackpad connection is not feasible without additional hardware.

---

## Current ZMK Architecture

### Split Keyboard BLE Configuration

The left half of the Adv360 **already runs as BLE Central** for split keyboard communication:

```
File: /src/refil/zmk/app/src/split/bluetooth/Kconfig

ZMK_SPLIT_ROLE_CENTRAL selects:
├── CONFIG_BT_CENTRAL=y              ✓ Central role active
├── CONFIG_BT_GATT_CLIENT=y          ✓ GATT client active
├── CONFIG_BT_SCAN_WITH_IDENTITY=y   ✓ Scanning enabled
```

Default connection limits (Kconfig.defaults):
```
CONFIG_BT_MAX_CONN=6    (1 split + 5 host profiles)
CONFIG_BT_MAX_PAIRED=6
```

### ZMK Pointing Subsystem

Located in `/src/refil/zmk/app/src/pointing/`:

| File | Lines | Purpose |
|------|-------|---------|
| input_listener.c | ~200 | Receives Zephyr input events, processes through pipeline |
| input_split.c | ~70 | Bridges split peripheral input → central's input subsystem |
| Kconfig | ~100 | Pointing configuration options |

**Key function** in `input_split.c` (central side):
```c
int zmk_input_split_report_peripheral_event(uint8_t reg, uint8_t type,
                                            uint16_t code, int32_t value, bool sync) {
    return input_report(proxy_inputs[i].dev, type, code, value, sync, K_NO_WAIT);
}
```

This injects input events into Zephyr's input subsystem, which then flows through
`input_listener.c` → `zmk_endpoints_send_mouse_report()` → active BLE profile.

### Split Central Connection Management

File: `/src/refil/zmk/app/src/split/bluetooth/central.c` (1357 lines)

Key patterns:

1. **Slot Management**
```c
struct peripheral_slot {
    enum peripheral_slot_state state;  // OPEN/CONNECTING/CONNECTED
    struct bt_conn *conn;
    struct bt_gatt_discover_params discover_params;
    struct bt_gatt_subscribe_params subscribe_params;
    uint16_t handles[...];  // discovered GATT handles
};
```

2. **Scanning** (only when needed)
```c
static int start_scanning(void) {
    // Only scan if has_unconnected peripherals
    if (!has_unconnected) return 0;

    bt_le_scan_start(BT_LE_SCAN_PASSIVE, split_central_device_found);
}
```

3. **UUID-based Filtering**
```c
// In split_central_eir_parse():
if (bt_uuid_cmp(&uuid.uuid, BT_UUID_DECLARE_128(ZMK_SPLIT_BT_SERVICE_UUID)) != 0) {
    continue;  // Not our service
}
```

4. **Connection Flow**
```c
stop_scanning();
bt_conn_le_create(addr, BT_CONN_LE_CREATE_CONN, param, &slot->conn);
// On connected: bt_gatt_discover() for service
// Then discover characteristics
// Then bt_gatt_subscribe() for notifications
start_scanning();  // Resume for remaining devices
```

5. **Data Flow**
```c
notify_callback()
  → k_msgq_put(&queue, &event)
  → k_work_submit(&work)
  → work_callback() processes event
```

---

## HOGP (HID Over GATT Profile) Analysis

### nRF Connect SDK Implementation

Location: `/src/nrfconnect/sdk-nrf/subsys/bluetooth/services/`

| File | Lines | Purpose |
|------|-------|---------|
| hogp.c | 1363 | HOGP client implementation |
| hogp.h | 685 | API header |
| Kconfig.hogp | 27 | Configuration |

**Dependencies** (also in nRF SDK):
| File | Lines | Purpose |
|------|-------|---------|
| gatt_dm.c | 799 | GATT Discovery Manager |
| scan.c | 1639 | BLE scan helper |

**Total nRF SDK code**: ~4900 lines

### HOGP Client API

```c
// Initialization
void bt_hogp_init(struct bt_hogp *hogp, const struct bt_hogp_init_params *params);

// After GATT discovery
int bt_hogp_handles_assign(struct bt_gatt_dm *dm, struct bt_hogp *hogp);

// Subscribe to input reports
int bt_hogp_rep_subscribe(struct bt_hogp *hogp, struct bt_hogp_rep_info *rep,
                          bt_hogp_read_cb func);

// Callbacks
typedef uint8_t (*bt_hogp_read_cb)(struct bt_hogp *hogp,
                                   struct bt_hogp_rep_info *rep,
                                   uint8_t err,
                                   const uint8_t *data);  // HID report data

// Boot protocol access
struct bt_hogp_rep_info *bt_hogp_rep_boot_mouse_in(struct bt_hogp *hogp);
struct bt_hogp_rep_info *bt_hogp_rep_boot_kbd_in(struct bt_hogp *hogp);
```

### Central HIDS Sample

Location: `/src/nrfconnect/sdk-nrf/samples/bluetooth/central_hids/`

Configuration (`prj.conf`):
```kconfig
CONFIG_BT=y
CONFIG_BT_CENTRAL=y
CONFIG_BT_SMP=y
CONFIG_BT_GATT_CLIENT=y
CONFIG_BT_GATT_DM=y
CONFIG_BT_HOGP=y
CONFIG_BT_SCAN=y
```

Flow:
```c
main():
  bt_hogp_init(&hogp, &params);
  bt_scan_filter_add(BT_SCAN_FILTER_TYPE_UUID, BT_UUID_HIDS);
  bt_scan_start();

scan_filter_match():
  // Found HID device

connected():
  bt_gatt_dm_start(conn, BT_UUID_HIDS, &discovery_cb, NULL);

discovery_completed_cb():
  bt_hogp_handles_assign(dm, &hogp);

hogp_ready_cb():
  bt_hogp_rep_subscribe(&hogp, rep, hogp_notify_cb);

hogp_notify_cb():
  // data contains HID report bytes
  printk("Notification, id: %u, size: %u, data:", bt_hogp_rep_id(rep), size);
```

---

## Vanilla Zephyr BLE Capabilities

### Available APIs

```c
// Central role
CONFIG_BT_CENTRAL=y

// GATT Client
bt_gatt_discover(conn, &discover_params);
bt_gatt_read(conn, &read_params);
bt_gatt_write(conn, &write_params);
bt_gatt_subscribe(conn, &subscribe_params);

// Scanning
bt_le_scan_start(BT_LE_SCAN_PASSIVE, device_found_cb);
bt_le_scan_stop();
```

### What Zephyr Has vs Doesn't Have

| Component | Zephyr | nRF SDK | Needed for HOGP |
|-----------|--------|---------|-----------------|
| BLE Central | ✓ | ✓ | ✓ |
| GATT Client | ✓ | ✓ | ✓ |
| GATT Discovery Manager | ✗ | ✓ bt_gatt_dm | Nice to have |
| Scan helper | Basic | ✓ bt_scan | Nice to have |
| HOGP Client | ✗ | ✓ bt_hogp | **Required** |
| HID Server (peripheral) | ✓ peripheral_hids | ✓ hids | N/A |

### Zephyr Input Subsystem

```c
#include <zephyr/input/input.h>

// Report an input event
int input_report(const struct device *dev, uint8_t type, uint16_t code,
                 int32_t value, bool sync, k_timeout_t timeout);

// Types (from input_codes.h)
INPUT_EV_REL  // Relative movement (mouse)
INPUT_EV_ABS  // Absolute position (touchpad)
INPUT_EV_KEY  // Button press

// Codes
INPUT_REL_X, INPUT_REL_Y, INPUT_REL_WHEEL
INPUT_BTN_LEFT, INPUT_BTN_RIGHT, INPUT_BTN_MIDDLE
```

---

## HID Report Formats

### Boot Protocol Mouse Report (3 bytes)
```
Byte 0: Buttons (bit 0=left, bit 1=right, bit 2=middle)
Byte 1: X movement (int8_t, -127 to +127)
Byte 2: Y movement (int8_t, -127 to +127)
```

### Common Report Protocol Mouse (varies)
```
Byte 0: Report ID (if present)
Byte 1: Buttons
Byte 2: X movement (int8_t or int16_t)
Byte 3: Y movement (int8_t or int16_t)
Byte 4+: Wheel, pan, etc.
```

### Magic Trackpad Considerations
- Uses standard BLE HID protocol
- Works well with Linux (good sign for compatibility)
- May have Apple-specific quirks in pairing
- Multi-touch gestures are complex but basic pointer should work

---

## Proposed Connection Architecture

```
CONFIG_BT_MAX_CONN=8
CONFIG_BT_MAX_PAIRED=8

Connection Slots:
├── Slot 0: Right keyboard half (ZMK split peripheral)
├── Slots 1-5: Host computers (BLE profiles 0-4)
├── Slot 6: Trackpad (HOGP device #1)
└── Slot 7: Mouse (HOGP device #2)
```

### Data Flow

```
[Magic Trackpad / Mouse]
        │
        │ BLE HID (peripheral role)
        ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    NRF52840 (Left Keyboard)                         │
│                                                                     │
│   ┌─────────────────────┐       ┌───────────────────────────────┐  │
│   │ NEW: HOGP Central   │       │ EXISTING: BLE Peripheral      │  │
│   │                     │       │                               │  │
│   │ hogp_central.c:     │       │  hog.c (HID Server)           │  │
│   │ - Scan for 0x1812   │       │  → Profile 0 (Computer 1)     │  │
│   │ - Connect           │       │  → Profile 1 (Computer 2)     │  │
│   │ - Discover HID svc  │       │  → etc.                       │  │
│   │ - Subscribe reports │       │                               │  │
│   └─────────┬───────────┘       └──────────────▲────────────────┘  │
│             │                                  │                    │
│             │ Parse HID report                 │ zmk_endpoints_*    │
│             ▼                                  │                    │
│   ┌─────────────────────────────────────────────┐                  │
│   │           input_report()                    │                  │
│   │   (Zephyr input subsystem)                  │                  │
│   │                │                            │                  │
│   │                ▼                            │                  │
│   │       input_listener.c                      │                  │
│   │   (existing ZMK pointing pipeline)          │                  │
│   └─────────────────────────────────────────────┘                  │
└─────────────────────────────────────────────────────────────────────┘
        │                           │                      │
        ▼                           ▼                      ▼
   [Computer 1]                [Computer 2]           [Computer N]
   (Profile 0)                 (Profile 1)            (Profile N)
```

---

## Memory Considerations

### Current Usage
- Firmware size: ~530 KB (of 1 MB flash)
- RAM: Unknown exact, but NRF52840 has 256 KB

### Additional Memory for HOGP

| Component | Estimated RAM | Notes |
|-----------|---------------|-------|
| 2 extra BLE connections | ~4-6 KB | Connection contexts |
| HOGP client state | ~2 KB | Per-device state |
| HID report parsing | ~1 KB | Buffers |
| **Total** | **~8 KB** | Should fit comfortably |

Flash increase: ~10-20 KB for HOGP code

---

## Related Source Files

### ZMK (ReFil fork: github.com/refil/zmk branch adv360-z3.5-2)

```
app/src/split/bluetooth/
├── central.c              (1357 lines) - Split central connection management
├── central_bas_proxy.c    (98 lines)   - Battery level proxying
├── peripheral.c           (196 lines)  - Split peripheral side
├── service.c              (454 lines)  - Split BLE service definition
├── split_listener.c       (47 lines)   - Event listener
├── Kconfig                (117 lines)  - Configuration
└── Kconfig.defaults       (34 lines)   - Default values

app/src/pointing/
├── input_listener.c       - Receives input events, processes pipeline
├── input_split.c          - Split peripheral → central input bridge
├── Kconfig                - Pointing configuration
└── input_processor.c      - Input processing chain

app/include/zmk/pointing/
└── input_split.h          - zmk_input_split_report_peripheral_event()
```

### nRF Connect SDK (github.com/nrfconnect/sdk-nrf)

```
subsys/bluetooth/services/
├── hogp.c                 (1363 lines) - HOGP client
├── hogp.h → include/bluetooth/services/hogp.h (685 lines)
├── hids.c                 (37252 lines) - HID server
├── Kconfig.hogp           (27 lines)
└── Kconfig.hids           (varies)

subsys/bluetooth/
├── gatt_dm.c              (799 lines)  - GATT Discovery Manager
├── scan.c                 (1639 lines) - Scan helper

samples/bluetooth/central_hids/
├── src/main.c             (694 lines)  - Sample application
└── prj.conf               (31 lines)   - Configuration
```

### Vanilla Zephyr (github.com/zephyrproject-rtos/zephyr)

```
subsys/bluetooth/host/
├── gatt.c                 - GATT implementation
├── scan.c                 - Scanning
├── conn.c                 - Connection management

include/zephyr/bluetooth/
├── gatt.h                 - GATT API
├── conn.h                 - Connection API
├── uuid.h                 - BLE UUIDs (BT_UUID_HIDS = 0x1812)

include/zephyr/input/
├── input.h                - Input subsystem API
└── input_codes.h          - Input event types and codes

samples/bluetooth/
├── central/               - Basic central sample
└── peripheral_hids/       - HID peripheral sample (server)
```

### Keyboard Config (this repo)

```
config/
├── west.yml               - Points to refil/zmk adv360-z3.5-2
├── boards/arm/adv360/
│   ├── adv360_left_defconfig   - Left half config (has CONFIG_ZMK_POINTING=y)
│   ├── adv360_right_defconfig  - Right half config
│   ├── adv360.dtsi             - Device tree base
│   └── Kconfig                 - Board Kconfig
├── adv360.keymap          - Keymap definitions
└── keymap.json            - Layer definitions
```

---

## References

- [nRF Connect SDK HOGP Documentation](https://docs.nordicsemi.com/bundle/ncs-latest/page/nrf/libraries/bluetooth_services/services/hogp.html)
- [Nordic DevZone: Central HIDS issues](https://devzone.nordicsemi.com/f/nordic-q-a/92078/central-hids-example-can-t-connect-with-ble-hogp-mouse)
- [Zephyr GATT API](https://docs.zephyrproject.org/latest/connectivity/bluetooth/api/gatt.html)
- [Bluetooth HID Service Specification](https://www.bluetooth.com/specifications/specs/hid-service-1-0/)

---

---

## Community Research & Prior Art

### ZMK Feature Requests

**Issue #2395: Passthrough BLE mouse to selected output**
- [GitHub Issue](https://github.com/zmkfirmware/zmk/issues/2395)
- Requested: Transform ZMK keyboard into BLE KVM switch
- Status: Open, no implementation yet
- Pete Johanson's guidance: "Create a GATT client that scans for and connects to the pointer, subscribes to HID Over GATT characteristics"

**Issue #1732: Forward mouse events from USB over Bluetooth**
- [GitHub Issue](https://github.com/zmkfirmware/zmk/issues/1732)
- Two approaches identified:
  1. BLE mouse connection (easier, no hardware changes)
  2. USB Host support (requires MAX3421E chip)
- Status: Open, waiting on Zephyr USB Host improvements

### Existing ZMK Modules

**zmk-split-peripheral-input-relay** (now deprecated)
- [GitHub](https://github.com/badjeff/zmk-split-peripheral-input-relay)
- Relays input events from split peripheral to central
- Now integrated into ZMK main branch (PR #2477)
- Shows the pattern: input events via BLE → virtual device → input_listener

### Adafruit nRF52 BLE HID Central (Key Reference!)

**Location**: `github.com/adafruit/Adafruit_nRF52_Arduino`

The Adafruit Bluefruit library has a **working BLE HID Central implementation**:

```
libraries/Bluefruit52Lib/
├── examples/Central/central_hid/central_hid.ino  (example app)
└── src/clients/
    ├── BLEClientHidAdafruit.h   (122 lines)
    └── BLEClientHidAdafruit.cpp (247 lines)
```

**Key characteristics**:
- Uses Boot Protocol mode (simpler, works with most devices)
- Discovers HID service UUID `0x1812`
- Subscribes to:
  - `UUID16_CHR_BOOT_KEYBOARD_INPUT_REPORT` (0x2A22)
  - `UUID16_CHR_BOOT_MOUSE_INPUT_REPORT` (0x2A33)
  - `UUID16_CHR_REPORT` (for gamepad)
- Clean callback-based API: `setMouseReportCallback()`

**Flow**:
```cpp
// 1. Scan for HID devices
Bluefruit.Scanner.filterService(hid);
Bluefruit.Scanner.start(0);

// 2. On scan hit, connect
void scan_callback(ble_gap_evt_adv_report_t* report) {
    Bluefruit.Central.connect(report);
}

// 3. On connect, discover HID service
void connect_callback(uint16_t conn_handle) {
    hid.discover(conn_handle);
    conn->requestPairing();
}

// 4. After pairing, enable notifications
void connection_secured_callback(uint16_t conn_handle) {
    hid.setBootMode(true);
    hid.enableMouse();
}

// 5. Receive reports via callback
void mse_client_notify_cb(BLEClientCharacteristic* chr, uint8_t* data, uint16_t len) {
    // data contains boot mouse report: buttons, X, Y
}
```

This is **~370 lines total** for a complete BLE HID Central client - much simpler than the nRF SDK HOGP implementation (~2000 lines).

### Nordic DevZone Discussions

- [BLE HID Multiple Peripheral](https://devzone.nordicsemi.com/f/nordic-q-a/57856) - Combining keyboard + mouse
- [Central HIDS issues](https://devzone.nordicsemi.com/f/nordic-q-a/92078) - HOGP client troubleshooting

---

## Revised Implementation Approach

Based on the Adafruit reference, the implementation can be simpler than originally planned:

### Simplified Architecture

Instead of porting the full nRF SDK HOGP client (~2000 LOC), we can:

1. **Use Boot Protocol only** - Works with 95%+ of devices, much simpler
2. **Direct characteristic subscription** - No HID descriptor parsing needed
3. **Model on Adafruit's BLEClientHidAdafruit** - Clean, proven pattern

### Estimated Code Size (Revised)

| Component | Original Estimate | Revised (Boot Protocol) |
|-----------|-------------------|------------------------|
| HOGP client | ~1500 LOC | ~400 LOC |
| Input bridge | ~300 LOC | ~200 LOC |
| Behaviors | ~100 LOC | ~100 LOC |
| **Total** | **~2000 LOC** | **~700 LOC** |

---

---

## Boot Protocol vs Report Protocol

### Boot Protocol (Limited)

| Feature | Supported |
|---------|-----------|
| 3 buttons | ✓ |
| X/Y movement | ✓ |
| Scroll wheel | ✗ |
| Extra buttons | ✗ |
| Multitouch | ✗ |

**Boot Mouse Report** (3 bytes only):
```
Byte 0: Buttons (bits 0-2)
Byte 1: X (int8)
Byte 2: Y (int8)
```

### Report Protocol (Full Featured)

Supports scroll wheel, extra buttons, and multitouch via HID Report Descriptors.

**Conclusion**: Must use Report Protocol for real functionality.

---

## USB Host Analysis

### NRF52840 Native USB
- **Device-only** USB controller
- Cannot act as USB Host

### External USB Host Option (MAX3421E)
- Zephyr has driver: `drivers/usb/uhc/uhc_max3421e.c`
- Requires hardware modification (SPI + GPIO)
- No USB Host HID class driver in Zephyr
- **Not practical** for this project

---

## Magic Trackpad Protocol Research

### Apple Trackpad Input Format

Source: [mac-precision-touchpad](https://github.com/imbushuo/mac-precision-touchpad)

```c
#define SPI_TRACKPAD_MAX_FINGERS 10

typedef struct _SPI_TRACKPAD_FINGER {
    SHORT OriginalX, OriginalY;
    SHORT X, Y;
    SHORT HorizontalAccel, VerticalAccel;
    SHORT ToolMajor, ToolMinor;
    SHORT Orientation;
    SHORT TouchMajor, TouchMinor;
    SHORT Pressure;
    // ~30 bytes per finger
} SPI_TRACKPAD_FINGER;

typedef struct _SPI_TRACKPAD_PACKET {
    UINT8 PacketType;
    UINT8 ClickOccurred;
    UINT8 Reserved[...];
    UINT8 NumOfFingers;
    SPI_TRACKPAD_FINGER Fingers[10];
} SPI_TRACKPAD_PACKET;
```

### Windows Precision Touchpad Output Format

Per-finger report (5 bytes):
```
Byte 0: Confidence (1 bit) | Tip Switch (1 bit) | Contact ID (3 bits) | Padding (3 bits)
Byte 1-2: X position (16-bit absolute)
Byte 3-4: Y position (16-bit absolute)
```

Full report structure:
```
Report ID 0x05 (Multitouch):
├── Finger 1-5: [Confidence|Tip|ID|X|Y] × 5  (25 bytes)
├── Scan Time (2 bytes, 100µs units)
├── Contact Count (1 byte)
└── Button (1 byte, bit 0 = click)

Report ID 0x07 (Device Caps - Feature):
├── Maximum Contacts (1 byte)
└── Button Type (1 byte, 0=depressible, 1=non-depressible)

Report ID 0x08 (PTPHQA Certification - Feature):
└── 256-byte blob (can be dummy on Windows 10+)
```

### Translation Algorithm

```c
// Apple → Windows PTP per-finger
ptp_finger.confidence = 1;  // Always confident unless palm detected
ptp_finger.tip_switch = (apple_finger.Pressure > PRESSURE_THRESHOLD);
ptp_finger.contact_id = finger_index % 4;  // 0-3, wraps

// Scale coordinates from Apple range to our logical range
ptp_finger.x = scale_linear(apple_finger.X,
                           APPLE_MIN_X, APPLE_MAX_X,
                           0, PTP_LOGICAL_MAX_X);
ptp_finger.y = scale_linear(apple_finger.Y,
                           APPLE_MIN_Y, APPLE_MAX_Y,
                           0, PTP_LOGICAL_MAX_Y);
```

### Reference Projects

| Project | Purpose | Link |
|---------|---------|------|
| mac-precision-touchpad | Windows driver for Apple trackpads | [GitHub](https://github.com/imbushuo/mac-precision-touchpad) |
| MT2-ReverseEngineering | Protocol documentation | [GitHub](https://github.com/elementumparasol/MT2-ReverseEngineering) |
| Linux bcm5974 | Kernel driver | [Pull Request](https://github.com/torvalds/linux/pull/332) |

---

## Architectural Decision: Single Composite Device

### Why Not Multiple BLE Devices?

Over BLE, one connection = one HID service. "Three devices" would require three BLE connections per host:

```
If 3 devices per host:
├── Slots 0-2: Host 1 (keyboard, trackpad, mouse)
├── Slots 3-5: Host 2 (keyboard, trackpad, mouse)
├── Slots 6-7: Host 3 (keyboard only, partial)
└── Result: Only 2 full hosts instead of 5
```

### Chosen Architecture: Single Composite Device

```
One HID Service with multiple collections:
├── Report ID 0x01: Keyboard
├── Report ID 0x02: Consumer Control
├── Report ID 0x03: Mouse (relative, 5 buttons, scroll)
├── Report ID 0x04: Touchpad (absolute, 5 contacts, Windows PTP)
└── Feature Reports: Device Caps, Certification
```

**Benefits**:
- One pairing per host
- Profile switching affects all input
- BLE connection efficiency
- Standard OS driver support

---

## badjeff/zmk-split-peripheral-input-relay Analysis

**Location**: `~/src/badjeff/zmk-split-peripheral-input-relay`

This archived module (superseded by ZMK PR #2477) provides an excellent reference implementation
for BLE-based input relay. While it relays input from split peripherals (not external HOGP devices),
the patterns are directly applicable.

### File Structure (~588 LOC total)

| File | Lines | Purpose |
|------|-------|---------|
| `src/input_relay_central.c` | 406 | Central side: GATT discovery, subscription, event injection |
| `src/input_relay_peripheral.c` | 129 | Peripheral side: captures input, sends via GATT notify |
| `src/virtual_input.c` | 20 | Virtual device for re-emitting events on central |
| `include/.../event.h` | 15 | Event structure definition |
| `include/.../uuid.h` | 18 | Custom GATT service/characteristic UUIDs |

### Key Patterns to Reuse

**1. Slot-based connection management** (`input_relay_central.c:24-40`)
```c
enum ir_peripheral_slot_state {
    PERIPHERAL_SLOT_STATE_OPEN,
    PERIPHERAL_SLOT_STATE_CONNECTING,
    PERIPHERAL_SLOT_STATE_CONNECTED,
};

struct ir_peripheral_slot {
    enum ir_peripheral_slot_state state;
    struct bt_conn *conn;
    struct bt_gatt_discover_params discover_params;
    struct bt_gatt_subscribe_params subscribe_params;
    // ...
};
```

**2. Connection callbacks with role filtering** (`input_relay_central.c:304-320`)
```c
static void split_central_connected(struct bt_conn *conn, uint8_t conn_err) {
    bt_conn_get_info(conn, &info);
    if (info.role != BT_CONN_ROLE_CENTRAL) {
        return;  // Skip peripheral connections
    }
    // Reserve slot, start GATT discovery
}
```

**3. GATT service discovery chain** (`input_relay_central.c:228-280`)
```
bt_gatt_discover(PRIMARY)
  → split_central_service_discovery_func()
    → bt_gatt_discover(CHARACTERISTIC)
      → split_central_chrc_discovery_func()
        → bt_gatt_subscribe()
```

**4. Message queue + work queue for event processing** (`input_relay_central.c:130-155`)
```c
K_MSGQ_DEFINE(peripheral_input_relay_event_msgq, sizeof(struct input_event), ...);
K_WORK_DEFINE(peripheral_input_event_work, peripheral_input_relay_event_work_callback);

// In notify callback:
k_msgq_put(&peripheral_input_relay_event_msgq, &ev, K_NO_WAIT);
k_work_submit(&peripheral_input_event_work);

// In work callback:
while (k_msgq_get(&msgq, &ev, K_NO_WAIT) == 0) {
    input_report_rel(ev.dev, ev.code, ev.value, ev.sync, K_NO_WAIT);
}
```

**5. Device tree driven configuration** (`input_relay_central.c:369-390`)
```c
#define INPUT_RELY_CFG_DEFINE(n)                                              \
    static const struct split_peripheral_input_relay_config config_##n = {    \
        .relay_channel = DT_PROP(DT_DRV_INST(n), relay_channel),              \
        .device = DEVICE_DT_GET(DT_INST_PHANDLE(n, device)),                  \
    };
DT_INST_FOREACH_STATUS_OKAY(INPUT_RELY_CFG_DEFINE)
```

### Differences for HOGP Implementation

| Aspect | badjeff module | HOGP client (new) |
|--------|----------------|-------------------|
| Connection initiation | Piggybacks on existing split connection | Must scan/connect independently |
| Service UUID | Custom `ZMK_SPLIT_BT_IR_SERVICE_UUID` | Standard HID `0x1812` |
| Data format | Custom `zmk_split_bt_input_relay_event` | Raw HID reports (need parsing) |
| Pairing | Uses split keyboard pairing | Needs own pairing flow |
| Device discovery | Already connected | Must scan for HID devices |

### What We Can Reuse Directly

1. **Slot management pattern** - same struct, different state machine
2. **GATT discovery flow** - change UUIDs, same bt_gatt_discover chain
3. **Message queue + work queue** - identical pattern for async event handling
4. **Virtual device injection** - `input_report()` is the right API
5. **Device tree macros** - same pattern for config

### What We Must Add

1. **BLE scanning** for HID devices (UUID filter for 0x1812)
2. **HID Report Map parsing** to understand device format
3. **HID report parsing** to extract buttons/X/Y/wheel
4. **Pairing behavior** (`&hogp HOGP_PAIR`)
5. **Bond storage** for auto-reconnect

### Estimated Delta

Starting from badjeff's ~600 LOC base:
- Scanning logic: +150 LOC
- HID parsing: +300 LOC
- Pairing behavior: +100 LOC
- Settings storage: +100 LOC
- **Total estimate: ~1200-1500 LOC** (vs original 2000 estimate)

---

## Official ZMK input_split.c Comparison

**Location**: `~/src/refil/zmk/app/src/pointing/input_split.c` (69 lines)

The official ZMK implementation is much more compact because:
1. It integrates with the existing split BLE service (no separate connection)
2. Uses `zmk_split_bt_report_input()` which is part of the split subsystem
3. Virtual device is just a devicetree-defined proxy

Key function on central side:
```c
int zmk_input_split_report_peripheral_event(uint8_t reg, uint8_t type,
                                            uint16_t code, int32_t value, bool sync) {
    for (size_t i = 0; i < ARRAY_SIZE(proxy_inputs); i++) {
        if (reg == proxy_inputs[i].reg) {
            return input_report(proxy_inputs[i].dev, type, code, value, sync, K_NO_WAIT);
        }
    }
    return -ENODEV;
}
```

This confirms `input_report()` is the correct injection point for our HOGP client.

---

## ReFil Branch Analysis

### Branch Overview (by date)

| Branch | Date | Purpose | Relevance |
|--------|------|---------|-----------|
| `Form-studio-2` | Apr 2025 | Latest Kinesis Form development | Best architecture, too divergent |
| `multi-touch-all-fingers` | Apr 2024 | 5-finger PTP in single report | **Ported** - proper PTP |
| `unified-ptp` | Feb 2024 | PTP refinements | Minor tweaks only |
| `multi-touch-one-contact` | Apr 2024 | 1-finger-per-report PTP | Wrong approach, skipped |
| `form-mouse` | May 2024 | Mouse-mode only | Not needed |
| `trackpad-reporting` | Aug 2023 | Early PTP work | Superseded |
| `Trackpad` | Sep 2023 | WIP trackpad | Superseded |

### What We Ported

From `multi-touch-all-fingers` branch:
- 5-finger PTP report structure
- `zmk_hid_ptp_set(f0, f1, f2, f3, f4, contact_count, scan_time, buttons)`
- Proper Windows PTP compliance for gestures

---

## Form-studio-2 Architecture Analysis (Future Reference)

The `Form-studio-2` branch (April 2025) has a cleaner modular architecture that separates
mouse/trackpad code into its own module. While too divergent to port directly (515 files changed),
it provides a better pattern for future development.

### Module Structure

```
app/src/mouse/
├── CMakeLists.txt      # Conditional compilation
├── Kconfig             # CONFIG_ZMK_MOUSE, CONFIG_ZMK_TRACKPAD
├── hid.c               # PTP report management (~170 LOC)
├── hog.c               # BLE GATT service (~360 LOC)
├── usb_hid.c           # USB HID device (~215 LOC)
├── trackpad.c          # Cirque driver (~250 LOC)
└── input_listener.c    # Generic input → HID (~280 LOC)

app/include/zmk/mouse/
├── hid.h               # HID descriptor + structs (~310 LOC)
├── hog.h               # BLE API
├── usb_hid.h           # USB API
├── trackpad.h          # Trackpad API
└── types.h             # Type definitions
```

### Key Improvements Over multi-touch-all-fingers

**1. Configurable finger count via LISTIFY macro**

```c
// HID descriptor generates finger collections based on config
#define TRACKPAD_FINGER_DESC(n, c) \
    HID_USAGE(HID_USAGE_DIGITIZERS_FINGER), \
    HID_COLLECTION(HID_COLLECTION_LOGICAL), \
    // ... finger data ...
    HID_END_COLLECTION,

static const uint8_t zmk_mouse_hid_report_desc[] = {
    LISTIFY(CONFIG_ZMK_TRACKPAD_FINGERS, TRACKPAD_FINGER_DESC, ())
    // ...
};
```

**2. Array-based finger storage**

```c
// Form-studio-2 (cleaner)
struct zmk_hid_ptp_report_body {
    struct zmk_ptp_finger fingers[CONFIG_ZMK_TRACKPAD_FINGERS];
    uint16_t scan_time;
    uint8_t contact_count : 4;
    uint8_t button1 : 1;
    uint8_t button2 : 1;
    uint8_t button3 : 1;
    uint8_t padding : 1;
} __packed;

// multi-touch-all-fingers (what we have)
struct zmk_hid_ptp_report_body {
    struct zmk_ptp_finger finger0;
    struct zmk_ptp_finger finger1;
    struct zmk_ptp_finger finger2;
    struct zmk_ptp_finger finger3;
    struct zmk_ptp_finger finger4;
    // ...
} __packed;
```

**3. Per-finger API with auto-management**

```c
// Form-studio-2 API
int zmk_mouse_hid_set_ptp_finger(struct zmk_ptp_finger finger);  // Auto-manages array
void zmk_mouse_hid_ptp_clear_lifted_fingers(void);               // Auto-cleanup
void zmk_mouse_hid_ptp_update_scan_time(void);                   // Auto-timestamp

// vs multi-touch-all-fingers (manual)
void zmk_hid_ptp_set(f0, f1, f2, f3, f4, contact_count, scan_time, buttons);
```

**4. Cleaner finger struct with bitfields**

```c
// Form-studio-2
struct zmk_ptp_finger {
    uint8_t touch_valid : 1;
    uint8_t tip_switch : 1;
    uint8_t contact_id : 4;
    uint8_t padding : 2;
    uint16_t x;
    uint16_t y;
} __packed;

// multi-touch-all-fingers
struct zmk_ptp_finger {
    uint8_t confidence_tip;  // Combined field
    uint8_t contact_id;
    uint16_t x;
    uint16_t y;
} __packed;
```

**5. input_listener.c - Generic input handling**

This is the most valuable piece for HOGP integration:

```c
// Handles Zephyr input subsystem events → HID reports
static void input_handler(const struct input_listener_config *config,
                          struct input_listener_data *data,
                          struct input_event *evt) {
    switch (evt->type) {
    case INPUT_EV_REL:   // Relative mouse movement
        handle_rel_code(data, evt);
        break;
    case INPUT_EV_ABS:   // Absolute/multitouch (PTP)
        handle_abs_code(config, data, evt);
        break;
    case INPUT_EV_KEY:   // Buttons
        handle_key_code(config, data, evt);
        break;
    }

    if (evt->sync) {
        // Send accumulated data
        switch (config->mode) {
        case INPUT_LISTENER_MODE_MOUSE:
            zmk_endpoints_send_mouse_report();
            break;
        case INPUT_LISTENER_MODE_PTP:
            zmk_mouse_hid_ptp_update_scan_time();
            zmk_endpoints_send_ptp_report();
            zmk_mouse_hid_ptp_clear_lifted_fingers();
            break;
        }
    }
}
```

**Multitouch slot handling:**
```c
case INPUT_ABS_MT_SLOT:
    // Switch to different finger
    data->ptp.finger_idx = evt->value;
    break;
case INPUT_ABS_X:
    data->ptp.data.x = evt->value;
    break;
case INPUT_ABS_Y:
    data->ptp.data.y = evt->value;
    break;
```

### Why This Matters for HOGP

With Form-studio-2 architecture, HOGP integration would be cleaner:

```
Current approach (multi-touch-all-fingers):
  BLE HID Device → hogp_central.c → zmk_hid_ptp_set(f0,f1,f2,f3,f4,...) → endpoints

Form-studio-2 approach:
  BLE HID Device → hogp_central.c → input_report() → input_listener → auto-managed
                                    ↑
                                    Zephyr input subsystem
```

The `input_listener.c` pattern allows us to:
1. Parse BLE HID reports in `hogp_central.c`
2. Inject events via `input_report(dev, INPUT_ABS_MT_SLOT, finger_id, ...)`
3. Let the existing infrastructure handle PTP report building

### Porting Considerations

**Minimum to port (~1000 LOC new, -265 LOC removed):**
- `app/src/mouse/` directory structure
- `hid.c`, `hid.h` - Report management
- Modify `endpoints.c` to route to module
- Remove mouse code from main `hid.c`, `hog.c`, `usb_hid.c`

**Skip for now:**
- `trackpad.c` - Cirque-specific, not needed for HOGP
- `input_listener.c` - Nice-to-have, not required for PoC

**Decision:** Stick with `multi-touch-all-fingers` for PoC. The API is less elegant but functional.
Consider refactoring to Form-studio-2 architecture after basic HOGP works.

---

## Date

Research conducted: November 26-27, 2025
