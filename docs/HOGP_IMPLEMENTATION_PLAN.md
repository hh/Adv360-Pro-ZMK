# Implementation Plan: BLE Trackpad/Mouse Support for Kinesis 360

## Executive Summary

Add BLE HID Central (HOGP) support to the Kinesis Advantage 360 Pro, enabling connection
of external pointing devices (Magic Trackpad, BLE mice) that forward input through the
keyboard to the active BLE host profile.

**Key Insights**:
1. The ZMK split keyboard already uses BLE Central - we extend this pattern
2. Use Windows Precision Touchpad (PTP) format for full multitouch passthrough
3. Single composite HID device with keyboard + mouse + touchpad collections
4. Translation layer converts Apple/generic formats to our output format

---

## Architecture Overview

### HID Report Structure

```
ZMK Composite HID Device:
├── Report ID 0x01: Keyboard (existing)
├── Report ID 0x02: Consumer Control (existing)
├── Report ID 0x03: Mouse (existing - relative, 5 buttons, scroll)
├── Report ID 0x04: Touchpad (NEW - Windows PTP, 5 contacts)
├── Report ID 0x05: Device Caps (NEW - Feature report)
└── Report ID 0x06: PTPHQA Cert (NEW - Feature report, 256 bytes)
```

### Data Flow

```
┌─────────────────────┐     ┌─────────────────────┐
│ Magic Trackpad      │     │ BLE Mouse           │
│ (BLE HID Peripheral)│     │ (BLE HID Peripheral)│
└─────────┬───────────┘     └─────────┬───────────┘
          │                           │
          │ Apple multitouch          │ Standard HID
          │ report format             │ mouse report
          ▼                           ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Kinesis 360 Left Half                        │
│                    (NRF52840 - BLE Central)                     │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ HOGP Client Layer                                       │   │
│  │ - Scan for HID devices (UUID 0x1812)                    │   │
│  │ - Connect, pair, discover characteristics               │   │
│  │ - Subscribe to Input Report notifications               │   │
│  │ - Read Report Map for format detection                  │   │
│  └─────────────────────────────────────────────────────────┘   │
│                              │                                  │
│                              ▼                                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ Translation Layer                                       │   │
│  │                                                         │   │
│  │ Trackpad path:              Mouse path:                 │   │
│  │ - Parse Apple format        - Parse HID mouse report    │   │
│  │ - Scale coordinates         - Extract buttons, X, Y     │   │
│  │ - Build PTP report          - Extract scroll wheel      │   │
│  │ - Up to 5 contacts          - Build mouse report        │   │
│  └─────────────────────────────────────────────────────────┘   │
│                              │                                  │
│                              ▼                                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ ZMK HID Output (existing + extended)                    │   │
│  │ - Report ID 0x03: Mouse → zmk_endpoints_send_mouse()    │   │
│  │ - Report ID 0x04: Touchpad → zmk_endpoints_send_ptp()   │   │
│  └─────────────────────────────────────────────────────────┘   │
│                              │                                  │
└──────────────────────────────┼──────────────────────────────────┘
                               │
          ┌────────────────────┼────────────────────┐
          ▼                    ▼                    ▼
    [Computer 1]         [Computer 2]         [Computer N]
    (Profile 0)          (Profile 1)          (Profile N)
         │                    │                    │
         ▼                    ▼                    ▼
    OS Gesture           OS Gesture           OS Gesture
    Recognition          Recognition          Recognition
```

### Connection Layout

```
CONFIG_BT_MAX_CONN=8
CONFIG_BT_MAX_PAIRED=8

Slot │ Device              │ Role              │ Notes
─────┼─────────────────────┼───────────────────┼──────────────────────────
  0  │ Right keyboard half │ ZMK Split (custom)│ Existing
 1-5 │ Host computers      │ BLE Peripheral    │ Existing (profiles 0-4)
  6  │ Trackpad            │ HOGP Central      │ NEW - Magic Trackpad
  7  │ Mouse               │ HOGP Central      │ NEW - BLE mouse
```

---

## Implementation Phases

### Phase 1: HID Descriptor Extension

**Goal**: Add Windows Precision Touchpad collection to ZMK's HID descriptor.

**File**: `app/include/zmk/hid.h`

Add after existing mouse collection:

```c
#if IS_ENABLED(CONFIG_ZMK_POINTING_TOUCHPAD)

#define ZMK_HID_REPORT_ID_TOUCHPAD 0x04
#define ZMK_HID_REPORT_ID_TOUCHPAD_CAPS 0x05
#define ZMK_HID_REPORT_ID_TOUCHPAD_CERT 0x06

#define ZMK_HID_TOUCHPAD_MAX_CONTACTS 5

// Windows Precision Touchpad Collection
// Usage Page: Digitizer (0x0D), Usage: Touch Pad (0x05)
static const uint8_t zmk_hid_touchpad_report_desc[] = {
    0x05, 0x0D,        // Usage Page (Digitizer)
    0x09, 0x05,        // Usage (Touch Pad)
    0xA1, 0x01,        // Collection (Application)
    0x85, ZMK_HID_REPORT_ID_TOUCHPAD,  // Report ID

    // Finger 1-5 collections (repeat 5 times)
    // Each finger: Confidence, Tip, ContactID, X, Y = 5 bytes
    // ... (see full descriptor in HID header)

    // Scan Time (2 bytes, 100µs units)
    0x05, 0x0D,        // Usage Page (Digitizer)
    0x09, 0x56,        // Usage (Scan Time)
    0x75, 0x10,        // Report Size (16)
    0x95, 0x01,        // Report Count (1)
    0x81, 0x02,        // Input (Data, Var, Abs)

    // Contact Count (1 byte)
    0x09, 0x54,        // Usage (Contact Count)
    0x75, 0x08,        // Report Size (8)
    0x95, 0x01,        // Report Count (1)
    0x81, 0x02,        // Input (Data, Var, Abs)

    // Button (1 byte)
    0x05, 0x09,        // Usage Page (Button)
    0x09, 0x01,        // Usage (Button 1)
    0x75, 0x01,        // Report Size (1)
    0x95, 0x01,        // Report Count (1)
    0x81, 0x02,        // Input (Data, Var, Abs)
    0x75, 0x07,        // Report Size (7) - padding
    0x95, 0x01,        // Report Count (1)
    0x81, 0x03,        // Input (Const)

    // Device Caps Feature Report
    0x85, ZMK_HID_REPORT_ID_TOUCHPAD_CAPS,
    0x05, 0x0D,        // Usage Page (Digitizer)
    0x09, 0x55,        // Usage (Maximum Contacts)
    0x09, 0x59,        // Usage (Button Type)
    0x75, 0x08,        // Report Size (8)
    0x95, 0x02,        // Report Count (2)
    0xB1, 0x02,        // Feature (Data, Var, Abs)

    // PTPHQA Certification Feature Report (256 bytes)
    0x85, ZMK_HID_REPORT_ID_TOUCHPAD_CERT,
    0x06, 0x00, 0xFF,  // Usage Page (Vendor)
    0x09, 0xC5,        // Usage (Vendor Usage)
    0x75, 0x08,        // Report Size (8)
    0x96, 0x00, 0x01,  // Report Count (256)
    0xB1, 0x02,        // Feature (Data, Var, Abs)

    0xC0,              // End Collection
};

// Touchpad report structure
struct zmk_hid_touchpad_finger {
    uint8_t confidence : 1;
    uint8_t tip_switch : 1;
    uint8_t contact_id : 3;
    uint8_t padding : 3;
    uint16_t x;
    uint16_t y;
} __packed;

struct zmk_hid_touchpad_report_body {
    struct zmk_hid_touchpad_finger fingers[ZMK_HID_TOUCHPAD_MAX_CONTACTS];
    uint16_t scan_time;
    uint8_t contact_count;
    uint8_t button;
} __packed;

struct zmk_hid_touchpad_report {
    uint8_t report_id;
    struct zmk_hid_touchpad_report_body body;
} __packed;

#endif // CONFIG_ZMK_POINTING_TOUCHPAD
```

**Estimated size**: ~350 bytes added to HID descriptor

---

### Phase 2: HOGP Client - Connection Management

**Goal**: Scan, connect, and manage BLE HID device connections.

**File**: `app/src/pointing/hogp/hogp_central.c` (~500 LOC)

Key components (modeled on `split/bluetooth/central.c`):

```c
// Device slot structure
struct hogp_device_slot {
    enum {
        HOGP_STATE_OPEN,
        HOGP_STATE_SCANNING,
        HOGP_STATE_CONNECTING,
        HOGP_STATE_DISCOVERING,
        HOGP_STATE_CONNECTED
    } state;

    struct bt_conn *conn;
    bt_addr_le_t addr;

    // GATT handles
    struct bt_gatt_discover_params discover_params;
    struct bt_gatt_subscribe_params report_subscribe;

    uint16_t hid_service_handle;
    uint16_t report_map_handle;
    uint16_t input_report_handle;
    uint16_t input_report_ccc_handle;

    // Device info
    enum hogp_device_type {
        HOGP_DEVICE_UNKNOWN,
        HOGP_DEVICE_MOUSE,
        HOGP_DEVICE_TRACKPAD
    } type;

    // Report map cache (for parsing)
    uint8_t report_map[256];
    uint16_t report_map_len;
};

static struct hogp_device_slot hogp_slots[CONFIG_ZMK_POINTING_HOGP_MAX_DEVICES];

// Public API
int zmk_hogp_start_pairing(void);
int zmk_hogp_stop_pairing(void);
int zmk_hogp_clear_bond(int slot);
int zmk_hogp_disconnect(int slot);
bool zmk_hogp_is_connected(int slot);
```

---

### Phase 3: GATT Discovery & Subscription

**Goal**: Discover HID service and subscribe to input reports.

```c
// HID Service UUIDs
#define BT_UUID_HID_SERVICE       BT_UUID_DECLARE_16(0x1812)
#define BT_UUID_HID_REPORT_MAP    BT_UUID_DECLARE_16(0x2A4B)
#define BT_UUID_HID_REPORT        BT_UUID_DECLARE_16(0x2A4D)
#define BT_UUID_HID_PROTOCOL_MODE BT_UUID_DECLARE_16(0x2A4E)

// Discovery flow:
// 1. Discover HID service (0x1812)
// 2. Discover Report Map characteristic (0x2A4B)
// 3. Read Report Map to determine device type
// 4. Discover Report characteristic(s) (0x2A4D)
// 5. Subscribe to Input Report notifications

static uint8_t hogp_discovery_cb(struct bt_conn *conn,
                                 const struct bt_gatt_attr *attr,
                                 struct bt_gatt_discover_params *params) {
    // Store handles, continue discovery
    // When complete, read report map and subscribe
}

static uint8_t hogp_report_notify_cb(struct bt_conn *conn,
                                     struct bt_gatt_subscribe_params *params,
                                     const void *data, uint16_t len) {
    // Route to appropriate parser based on device type
    struct hogp_device_slot *slot = hogp_slot_for_conn(conn);

    if (slot->type == HOGP_DEVICE_TRACKPAD) {
        hogp_parse_trackpad_report(slot, data, len);
    } else {
        hogp_parse_mouse_report(slot, data, len);
    }
}
```

---

### Phase 4: Report Parsing & Translation

**Goal**: Parse incoming HID reports and translate to ZMK format.

**File**: `app/src/pointing/hogp/hogp_translate.c` (~400 LOC)

#### Mouse Report Parser

```c
// Standard HID mouse report (Report Protocol)
struct hid_mouse_report {
    uint8_t buttons;
    int16_t x;
    int16_t y;
    int8_t wheel;
    int8_t pan;
} __packed;

void hogp_parse_mouse_report(struct hogp_device_slot *slot,
                             const uint8_t *data, uint16_t len) {
    // Parse based on report map (or assume standard format)
    uint8_t buttons = data[0];
    int16_t x = (int16_t)(data[1] | (data[2] << 8));
    int16_t y = (int16_t)(data[3] | (data[4] << 8));
    int8_t wheel = (len > 5) ? (int8_t)data[5] : 0;

    // Send to ZMK mouse subsystem
    zmk_hid_mouse_buttons_press(buttons & 0x1F);
    zmk_hid_mouse_movement_update(x, y);
    zmk_hid_mouse_scroll_update(0, wheel);
    zmk_endpoints_send_mouse_report();
}
```

#### Apple Trackpad Parser

```c
// Apple Magic Trackpad finger (9 bytes in BLE format)
struct apple_trackpad_finger {
    uint16_t abs_x : 13;
    uint16_t abs_y : 13;
    uint8_t touch_major;
    uint8_t touch_minor;
    uint8_t orientation : 4;
    uint8_t finger_id : 4;
    uint8_t state;
    uint8_t pressure;
} __packed;

void hogp_parse_trackpad_report(struct hogp_device_slot *slot,
                                const uint8_t *data, uint16_t len) {
    // Parse Apple format header
    uint8_t click = data[1] & 0x01;
    uint8_t num_fingers = data[...];

    struct zmk_hid_touchpad_report_body report = {0};
    report.button = click;
    report.contact_count = MIN(num_fingers, ZMK_HID_TOUCHPAD_MAX_CONTACTS);
    report.scan_time = k_uptime_get_32() / 100;  // 100µs units

    // Parse each finger
    for (int i = 0; i < report.contact_count; i++) {
        struct apple_trackpad_finger *af = parse_apple_finger(data, i);

        report.fingers[i].confidence = 1;
        report.fingers[i].tip_switch = (af->pressure > 0);
        report.fingers[i].contact_id = af->finger_id % 4;

        // Scale coordinates
        report.fingers[i].x = scale_coord(af->abs_x,
                                          APPLE_MIN_X, APPLE_MAX_X,
                                          0, PTP_LOGICAL_MAX_X);
        report.fingers[i].y = scale_coord(af->abs_y,
                                          APPLE_MIN_Y, APPLE_MAX_Y,
                                          0, PTP_LOGICAL_MAX_Y);
    }

    // Send touchpad report
    zmk_endpoints_send_touchpad_report(&report);
}
```

---

### Phase 5: Endpoint Integration

**Goal**: Add touchpad report sending to ZMK endpoints.

**Files to modify**:
- `app/src/endpoints.c`
- `app/src/hog.c` (BLE HID output)
- `app/src/usb_hid.c` (USB HID output)

```c
// In endpoints.c
int zmk_endpoints_send_touchpad_report(struct zmk_hid_touchpad_report_body *report) {
    struct zmk_hid_touchpad_report full_report = {
        .report_id = ZMK_HID_REPORT_ID_TOUCHPAD,
        .body = *report
    };

    switch (zmk_endpoints_selected()) {
    case ZMK_ENDPOINT_USB:
        return zmk_usb_hid_send_touchpad_report(&full_report);
    case ZMK_ENDPOINT_BLE:
        return zmk_hog_send_touchpad_report(&full_report);
    }
    return -ENOTSUP;
}
```

---

### Phase 6: Key Bindings

**Goal**: Add keyboard shortcuts for HOGP management.

**File**: `app/src/behaviors/behavior_hogp.c` (~150 LOC)

```c
// Behavior parameters
#define HOGP_PAIR     0x01  // Enter pairing mode (scan for new device)
#define HOGP_CLEAR    0x02  // Clear bond for specific slot
#define HOGP_CLEAR_6  0x06  // Clear trackpad slot
#define HOGP_CLEAR_7  0x07  // Clear mouse slot

// Device tree binding
// &hogp HOGP_PAIR    - Enter pairing mode
// &hogp HOGP_CLEAR_6 - Clear trackpad bond
// &hogp HOGP_CLEAR_7 - Clear mouse bond
```

**Keymap example** (MOD layer):
```dts
bindings = <
    ...
    &hogp HOGP_PAIR     // Pair new device
    &hogp HOGP_CLEAR_6  // Clear trackpad
    &hogp HOGP_CLEAR_7  // Clear mouse
    ...
>;
```

---

### Phase 7: Settings Persistence

**Goal**: Save bonded device addresses for auto-reconnect.

```c
// Settings structure
struct hogp_settings {
    bt_addr_le_t bonded_addr[CONFIG_ZMK_POINTING_HOGP_MAX_DEVICES];
    bool has_bond[CONFIG_ZMK_POINTING_HOGP_MAX_DEVICES];
};

// On startup: load bonds, scan for known devices
// On new pairing: save bond
// On clear: remove bond from settings
```

---

## File Structure

```
app/
├── include/
│   └── zmk/
│       ├── hid.h                    (modified - add touchpad descriptor)
│       └── pointing/
│           └── hogp.h               (NEW - ~100 LOC)
│
├── src/
│   ├── hid.c                        (modified - touchpad report functions)
│   ├── endpoints.c                  (modified - send_touchpad_report)
│   ├── hog.c                        (modified - BLE touchpad output)
│   ├── usb_hid.c                    (modified - USB touchpad output)
│   │
│   └── pointing/
│       └── hogp/
│           ├── CMakeLists.txt       (NEW)
│           ├── Kconfig              (NEW - ~80 LOC)
│           ├── hogp_central.c       (NEW - ~500 LOC)
│           ├── hogp_translate.c     (NEW - ~400 LOC)
│           ├── hogp_settings.c      (NEW - ~150 LOC)
│           └── apple_trackpad.h     (NEW - ~100 LOC)
│
├── behaviors/
│   └── behavior_hogp.c              (NEW - ~150 LOC)
│
└── dts/bindings/behaviors/
    └── zmk,behavior-hogp.yaml       (NEW)

config/boards/arm/adv360/
├── adv360_left_defconfig            (modified)
└── adv360.keymap                    (modified - add HOGP bindings)
```

---

## Estimated Code Size

| Component | Lines | Notes |
|-----------|-------|-------|
| HID descriptor extension | ~350 | Touchpad collection |
| hogp_central.c | ~500 | Connection management |
| hogp_translate.c | ~400 | Report parsing/translation |
| hogp_settings.c | ~150 | Bond persistence |
| hogp.h | ~100 | Public API |
| apple_trackpad.h | ~100 | Apple format definitions |
| behavior_hogp.c | ~150 | Key bindings |
| Kconfig | ~80 | Configuration options |
| Modifications to existing | ~200 | endpoints, hog, usb_hid |
| **Total** | **~2000 LOC** | |

---

## Testing Plan

### Unit Tests
1. Coordinate scaling (Apple → PTP range)
2. Report parsing (known test vectors)
3. Slot management

### Integration Tests

| Test | Steps | Expected |
|------|-------|----------|
| Mouse pairing | Press HOGP_PAIR, power on mouse | Mouse connects, pointer moves |
| Trackpad pairing | Press HOGP_PAIR, wake trackpad | Trackpad connects |
| Single finger | Touch trackpad | Pointer moves |
| Two-finger scroll | Two fingers, drag | Window scrolls |
| Three-finger gesture | Three fingers | OS gesture triggered |
| Profile switch | Switch BLE profile | Mouse/trackpad follows |
| Reconnect | Power cycle keyboard | Auto-reconnect to devices |

### Device Compatibility

| Device | Priority | Notes |
|--------|----------|-------|
| Apple Magic Trackpad 2/3 | High | Primary target |
| Logitech MX Master 3 | Medium | Popular BLE mouse |
| Generic BLE mouse | Medium | Standard HID |
| Apple Magic Mouse | Low | Limited gestures |

---

## Configuration Options

```kconfig
CONFIG_ZMK_POINTING_HOGP=y           # Enable HOGP support
CONFIG_ZMK_POINTING_HOGP_MAX_DEVICES=2   # Max devices (default 2)
CONFIG_ZMK_POINTING_TOUCHPAD=y       # Enable touchpad collection
CONFIG_ZMK_POINTING_TOUCHPAD_MAX_CONTACTS=5  # Max touch points

CONFIG_BT_MAX_CONN=8                 # Connection slots
CONFIG_BT_MAX_PAIRED=8               # Pairing slots
```

---

## Risk Mitigation

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Apple protocol changes | Low | High | Version detection, fallback to mouse mode |
| Memory overflow | Low | High | Careful buffer management, testing |
| Pairing difficulties | Medium | Medium | Clear error reporting, manual pair option |
| Gesture issues on some OS | Medium | Low | Focus on raw data accuracy, let OS handle gestures |

---

## References

### Code References
- ZMK split central: `~/src/refil/zmk/app/src/split/bluetooth/central.c`
- Adafruit BLE HID client: `~/src/adafruit/Adafruit_nRF52_Arduino/libraries/Bluefruit52Lib/src/clients/BLEClientHidAdafruit.cpp`
- mac-precision-touchpad: `~/src/imbushuo/mac-precision-touchpad/src/AmtPtpDeviceSpiKm/`
- nRF SDK HOGP: `~/src/nrfconnect/sdk-nrf/subsys/bluetooth/services/hogp.c`

### Documentation
- [Windows PTP Implementation Guide](https://learn.microsoft.com/en-us/windows-hardware/design/component-guidelines/touchpad-implementation-guide)
- [Windows PTP HID Descriptors](https://learn.microsoft.com/en-us/windows-hardware/design/component-guidelines/touchpad-required-hid-descriptors)
- [ZMK Issue #2395 - BLE mouse passthrough](https://github.com/zmkfirmware/zmk/issues/2395)

---

## Revision History

| Date | Changes |
|------|---------|
| 2025-11-27 | Initial plan with touchpad passthrough architecture |
