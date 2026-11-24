import '../../api/models.dart';

/// Platform predicates for a child's paired devices, reading `Device.platform`
/// straight from the API (`GET /v1/devices`).
///
/// Issue #1046: Apple keeps per-app lists and per-app minutes on the child's
/// iPhone. A child is treated as an iPhone-only child when they have at least
/// one paired device and every paired device has `platform == 'ios'`.
///
/// If a child has no paired devices yet (`devices.isEmpty`), this returns
/// `false` so we never guess from null or an empty device list. If a child has
/// both an iPhone and an Android device, [isIphoneOnlyChild] is `false` so the
/// Android device's screen time and app list keep showing as today.
bool hasIphoneDevice(Iterable<Device> devices) =>
    devices.any((d) => d.platform == 'ios');

/// Whether any paired device for this child is an Android device.
bool hasAndroidDevice(Iterable<Device> devices) =>
    devices.any((d) => d.platform == 'android');

/// Whether this child has at least one paired device and all paired devices
/// report `platform == 'ios'`.
bool isIphoneOnlyChild(Iterable<Device> devices) =>
    devices.isNotEmpty && devices.every((d) => d.platform == 'ios');
