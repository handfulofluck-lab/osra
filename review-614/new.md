# Read-only missing-Arabic inventory (#614)

Source: `1ed24f83ce95e6713a3d9d38b273dd1cff9910d2` · Generated: 2026-11-13T15:32:26Z

- **180 new candidates** (143 app literals and 37 website terms rows).
- **135 already-tracked website rows**, marked rather than repeated as new work.
- **2 brand-label checks** for the Bureau, not automatic translation requests.
- **317 total rows** including both categories and the brand checks.

## Resource coverage

- Flutter `app_en.arb` / `app_ar.arb`: no missing keys.
- iOS `en.lproj` / `ar.lproj` and InfoPlist files: no missing keys.
- Android `values/strings.xml`: only `app_name` (OSRA) and `sos_tile_label` (OSRA SOS) lack a same-key Arabic value; see `brand-labels.md` for the brand review.
- API email templates and account-deletion pages already contain English and Arabic blocks, so they are not listed as missing.
- The site home, guide and download pages already have Arabic counterparts and are excluded. Privacy, terms and delete-account pages are listed.

## Method and exclusions

Read-only key comparison followed by a manual surface review of hard-coded strings. SQL, logs, protocol values, decoder internals, serialization, localized wrappers and developer-only stderr are excluded. Dynamic metadata is not presented as fixed English copy. The personal name/address in the privacy and terms pages is replaced with `[name and address in source]`; the source file retains the legal text for the Bureau to read in context.

No Arabic text or source file was written or changed. No CI check was added.

## Files

- `full-sweep.md`: every row and its status.
- `new.md`: the 180 new candidates, with file:line, English, surface, suggested key and status.
- `already-tracked.md`: the 135 rows already on #604 or sheet 2.
- `brand-labels.md`: the two brand-label checks.
- `full-sweep.csv`: all rows in spreadsheet form.
- `full-sweep.json`: the structured evidence.
- `ci-candidates.md`: possible future automated checks.

| File:line | English text | Where the user sees it | Suggested key | Bureau status |
|---|---|---|---|---|
| apps/agent-desktop/Services/PairingDialog.cs:49 | OSRA — Pair this device | Pairing flow | pairing_dialog_osra_pair_device | new |
| apps/agent-desktop/Services/PairingDialog.cs:56 | Server URL: | Pairing flow | pairing_dialog_server_url | new |
| apps/agent-desktop/Services/PairingDialog.cs:60 | Pairing code: | Pairing flow | pairing_dialog_pairing_code | new |
| apps/agent-desktop/Services/PairingDialog.cs:64 | Parent PIN: | Pairing flow | pairing_dialog_parent_pin | new |
| apps/agent-desktop/Services/PairingDialog.cs:66 | Repeat PIN: | Pairing flow | pairing_dialog_repeat_pin | new |
| apps/agent-desktop/Services/PairingDialog.cs:69 | Pair | Pairing flow | pairing_dialog_pair | new |
| apps/agent-desktop/Services/PairingDialog.cs:97 | Enter the server URL and the 6-digit pairing code. | Pairing flow | pairing_dialog_enter_server_url_6 | new |
| apps/agent-desktop/Services/PairingDialog.cs:109 | The two PIN entries do not match. | Pairing flow | pairing_dialog_two_pin_entries_do | new |
| apps/agent-desktop/Services/PairingDialog.cs:123 | Pairing rejected — check the code and server URL. | Pairing flow | pairing_dialog_pairing_rejected_check_code | new |
| apps/agent-desktop/Services/PairingDialog.cs:140 | Pairing failed: {ex.Message} | Pairing flow | pairing_dialog_pairing_failed_ex_message | new |
| apps/agent-desktop/Services/PairingService.cs:73 | This code is already being used by another device. Ask your parent for a new code. | Pairing flow | pairing_service_code_already_being_used | new |
| apps/agent-desktop/Services/PairingService.cs:75 | Your parent needs to give consent in the OSRA app before this PC can be paired. | Pairing flow | pairing_service_parent_needs_give_consent | new |
| apps/agent-desktop/Services/PairingService.cs:110 | Your parent declined this PC. If that was a mistake, ask them for a new code. | Pairing flow | pairing_service_parent_declined_pc_if | new |
| apps/agent-desktop/Services/PairingService.cs:112 | The code expired before your parent allowed this PC. Ask them for a new code. | Pairing flow | pairing_service_code_expired_before_parent | new |
| apps/agent-desktop/Services/PairingService.cs:114 | Your parent needs to give consent in the OSRA app before this PC can be paired. | Pairing flow | pairing_service_parent_needs_give_consent | new |
| apps/agent-desktop/Services/PairingService.cs:121 | The code expired before your parent allowed this PC. Ask them for a new code. | Pairing flow | pairing_service_code_expired_before_parent | new |
| apps/agent-desktop/Services/RuleSyncService.cs:170 | Web filter was bypassed | Windows agent UI or parent alert | rule_sync_service_web_filter_bypassed | new |
| apps/agent-desktop/Services/RuleSyncService.cs:171 | The OSRA proxy was disabled in Windows settings | Windows agent UI or parent alert | rule_sync_service_osra_proxy_disabled_windows | new |
| apps/agent-desktop/Services/RuleSyncService.cs:199 | VPN active | Windows agent UI or parent alert | rule_sync_service_vpn_active | new |
| apps/agent-desktop/Services/RuleSyncService.cs:200 | A VPN tunnel may be routing traffic around the filter | Windows agent UI or parent alert | rule_sync_service_vpn_tunnel_may_be | new |
| apps/agent-desktop/Services/SosHotkey.cs:49 | SOS from {Environment.MachineName} | SOS flow | sos_hotkey_sos_environment_machinename | new |
| apps/agent-desktop/Services/SosHotkey.cs:50 | The SOS hotkey (Shift+F11) was pressed | SOS flow | sos_hotkey_sos_hotkey_shift_f11 | new |
| apps/agent-desktop/Services/SosHotkey.cs:284 | SOS sent to your parent | SOS flow | sos_hotkey_sos_sent_parent | new |
| apps/agent-desktop/Services/SosHotkey.cs:286 | OK | SOS flow | sos_hotkey_ok | new |
| apps/agent-desktop/Services/WebFilterProxy.cs:15 | Blocked by OSRA | Desktop block page | web_filter_proxy_html_body_h1_blocked | new |
| apps/agent-desktop/Services/WebFilterProxy.cs:240 | Blocked website: {host} | Desktop block page | web_filter_proxy_blocked_website_host | new |
| apps/agent-desktop/Services/WebFilterProxy.cs:260 | Web filter failed to start | Desktop block page | web_filter_proxy_web_filter_failed_start | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/commands/CommandDispatcher.kt:212 | Parent commands | Android child app | command_dispatcher_parent_commands | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/commands/CommandDispatcher.kt:425 | Parent commands | Android child app | command_dispatcher_parent_commands | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/commands/CommandDispatcher.kt:429 | Screen time ending | Android child app | command_dispatcher_screen_time_ending | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/commands/CommandDispatcher.kt:430 | Screen will lock in $minutes minutes | Android child app | command_dispatcher_screen_will_lock_minutes | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/commands/CommandDispatcher.kt:483 | locate_now refused: $reason — a location foreground service started from the background | Android child app | command_dispatcher_locate_now_refused_reason | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/commands/CommandPollWorker.kt:62 | Command checks | Android child app | command_poll_worker_command_checks | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/commands/CommandPollWorker.kt:67 | Checking for parent commands | Android child app | command_poll_worker_checking_parent_commands | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/commands/RingActivity.kt:35 | 🔔 Your parent is ringing this phone | Android child app | ring_activity_parent_ringing_phone | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/commands/RingActivity.kt:36 | \nIt keeps ringing until a parent stops it. | Android child app | ring_activity_nit_keeps_ringing_until | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/commands/RingActivity.kt:39 | Stop ringing (parent PIN) | Android child app | ring_activity_stop_ringing_parent_pin | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/enforcement/BlockActivity.kt:204 | Access requested | Lock/bedtime screen | block_activity_access_requested | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/enforcement/BlockActivity.kt:205 | Child requested access to $pkg | Lock/bedtime screen | block_activity_child_requested_access_pkg | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/receivers/AccessibilityOffReceiver.kt:54 | Protection was disabled | Android child app | accessibility_off_receiver_protection_disabled | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/receivers/AccessibilityOffReceiver.kt:55 | The OSRA accessibility service was turned off on this device | Android child app | accessibility_off_receiver_osra_accessibility_service_turned | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/receivers/PackageAddedReceiver.kt:76 | New app installed | Android child app | package_added_receiver_new_app_installed | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/receivers/PackageAddedReceiver.kt:77 | $appName ($packageId) was installed on this device | Android child app | package_added_receiver_appname_packageid_installed_device | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/receivers/PackageReplacedReceiver.kt:59 | Agent updated | Android child app | package_replaced_receiver_agent_updated | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/receivers/PackageReplacedReceiver.kt:60 | OSRA agent was reinstalled/updated | Android child app | package_replaced_receiver_osra_agent_reinstalled_updated | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/security/AdminEnrolmentPolicy.kt:97 | Protection could not be enabled | Android child app | admin_enrolment_policy_protection_could_not_be | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/security/AdminEnrolmentPolicy.kt:98 | The system sheet closed without activating anything. Samsung's Knox layer still | Android child app | admin_enrolment_policy_system_sheet_closed_without | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/security/TamperAlertWorker.kt:74 | Protection was changed | Android child app | tamper_alert_worker_protection_changed | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/security/TamperGuardActivity.kt:54 | Go back | Android child app | tamper_guard_activity_go_back | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/security/TamperGuardActivity.kt:92 | Re-pairing this device needs your parent's PIN. | Android child app | tamper_guard_activity_re_pairing_device_needs | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/security/TamperGuardActivity.kt:93 | Removing protection needs your parent's PIN. | Android child app | tamper_guard_activity_removing_protection_needs_parent | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/security/TamperGuardActivity.kt:94 | Stopping the ring needs your parent's PIN. | Android child app | tamper_guard_activity_stopping_ring_needs_parent | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/security/TamperGuardActivity.kt:167 | settings | Android child app | tamper_guard_activity_settings | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/security/TamperGuardActivity.kt:169 | remove | Android child app | tamper_guard_activity_remove | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/services/LocationService.kt:381 | Location sharing is active | Android child app | location_service_location_sharing_active | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/services/LocationService.kt:486 | Lock screen permission removed | Android child app | location_service_lock_screen_permission_removed | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/services/LocationService.kt:487 | \"Display over other apps\" was turned off for OSRA; the lock and pause screens cannot be shown until it is re-enabled | Android child app | location_service_display_over_other_apps | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/services/LocationService.kt:552 | VPN active | Android child app | location_service_vpn_active | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/services/LocationService.kt:553 | A VPN is routing this device's traffic around the filter | Android child app | location_service_vpn_routing_device_s | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/LocationStatusPolicy.kt:66 | \n⚠️ Location permission is required for live GPS tracking and geofence alerts. | Android child app | location_status_policy_n_location_permission_required | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/LocationStatusPolicy.kt:68 | \n⚠️ Location: needs \"Allow all the time\" — without it Locate and geofence alerts | Android child app | location_status_policy_n_location_needs_allow | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/LocationStatusPolicy.kt:70 | \n⚠️ Location service is not running. | Android child app | location_status_policy_n_location_service_not | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/LocationStatusPolicy.kt:71 | \n✓ Location tracking: Active | Android child app | location_status_policy_n_location_tracking_active | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/LocationStatusPolicy.kt:76 | Grant location permission | Android child app | location_status_policy_grant_location_permission | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/LocationStatusPolicy.kt:77 | Allow location all the time | Android child app | location_status_policy_allow_location_all_time | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/LocationStatusPolicy.kt:78 | Start location service | Android child app | location_status_policy_start_location_service | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/OnboardingPolicy.kt:26 | Locate the device and geofence alerts; background access keeps it working with the app closed. | Android child app | onboarding_policy_locate_device_geofence_alerts | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/OnboardingPolicy.kt:30 | Reads notifications from monitored apps for the safety scan (Phase 2.6). | Android child app | onboarding_policy_reads_notifications_monitored_apps | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/OnboardingPolicy.kt:112 | This build captures messages from the screen only. The sideloaded Full build adds $what capture. | Android child app | onboarding_policy_build_captures_messages_screen | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt:550 | Without it, protection is alert-only. | Pairing flow | pairing_activity_without_protection_alert_only | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt:555 | Activate device admin | Pairing flow | pairing_activity_activate_device_admin | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt:561 | Skip for now (alert-only protection) | Pairing flow | pairing_activity_skip_now_alert_only | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt:587 | Try Activate again | Pairing flow | pairing_activity_try_activate_again | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt:593 | Continue without protection | Pairing flow | pairing_activity_continue_without_protection | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt:628 | Setup complete | Pairing flow | pairing_activity_setup_complete | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt:630 | The agent is now monitoring this device. | Pairing flow | pairing_activity_agent_now_monitoring_device | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt:643 | Grant call & SMS permissions | Pairing flow | pairing_activity_grant_call_sms_permissions | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt:651 | Open status | Pairing flow | pairing_activity_open_status | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt:669 | Each item below opens the one screen that grants it. Come back here after each one; the list re-checks itself. | Pairing flow | pairing_activity_each_item_below_opens | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt:672 | Back | Pairing flow | pairing_activity_back | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt:691 | Grant: ${g.title} | Pairing flow | pairing_activity_grant_g_title | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt:720 | ⚠️ Web filter not set up — allow the OSRA VPN (it only filters web addresses on this phone; nothing leaves the device). | Pairing flow | pairing_activity_web_filter_not_set | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt:726 | Set up web filter | Pairing flow | pairing_activity_set_up_web_filter | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt:736 | ✓ Web filter: connected (SafeSearch, blocked sites, pause-internet) | Pairing flow | pairing_activity_web_filter_connected_safesearch | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt:739 | ⚠️ Web filter: not connected | Pairing flow | pairing_activity_web_filter_not_connected | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt:743 | Reconnect web filter | Pairing flow | pairing_activity_reconnect_web_filter | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt:804 | Child: $childId\nDevice: $deviceId\nServer: $server | Pairing flow | pairing_activity_child_childid_ndevice_deviceid | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt:810 | \n⚠️ Protection: alert-only — device admin is not active | Pairing flow | pairing_activity_n_protection_alert_only | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt:817 | Activate device admin | Pairing flow | pairing_activity_activate_device_admin | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt:863 | Open accessibility settings | Pairing flow | pairing_activity_open_accessibility_settings | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt:879 | Finish protection (${missing.size} to grant) | Pairing flow | pairing_activity_finish_protection_missing_size | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt:879 | Protection checklist | Pairing flow | pairing_activity_protection_checklist | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt:886 | Re-pair (parent PIN) | Pairing flow | pairing_activity_re_pair_parent_pin | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt:899 | Remove protection (parent PIN) | Pairing flow | pairing_activity_remove_protection_parent_pin | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt:960 | server returned HTTP ${response.code} | Pairing flow | pairing_activity_server_returned_http_response | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt:994 | pairing response has no device id | Pairing flow | pairing_activity_pairing_response_has_no | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt:1012 | pairing did not finish | Pairing flow | pairing_activity_pairing_did_not_finish | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/PairQrScanActivity.kt:61 | Enter the server URL and pairing code below, or allow Camera in Settings and scan again. | Android child app | pair_qr_scan_activity_enter_server_url_pairing | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/PairQrScanActivity.kt:90 | Camera preview | Android child app | pair_qr_scan_activity_camera_preview | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/PairQrScanActivity.kt:107 | Starting the camera… | Android child app | pair_qr_scan_activity_starting_camera | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/PairQrScanActivity.kt:115 | Cancel scanning | Android child app | pair_qr_scan_activity_cancel_scanning | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/PairQrScanActivity.kt:116 | Cancel scanning and return to the pairing form | Android child app | pair_qr_scan_activity_cancel_scanning_return_pairing | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/PairQrScanActivity.kt:126 | Scan the pairing QR code | Android child app | pair_qr_scan_activity_scan_pairing_qr_code | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/PairQrScanActivity.kt:135 | Enter code instead | Android child app | pair_qr_scan_activity_enter_code_instead | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/PairQrScanActivity.kt:138 | Enter the server URL and pairing code below. | Android child app | pair_qr_scan_activity_enter_server_url_pairing | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/PairQrScanActivity.kt:151 | The camera could not start. Enter the server URL and pairing code below. | Android child app | pair_qr_scan_activity_camera_could_not_start | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/PairQrScanActivity.kt:171 | Camera ready. Point the phone at the QR code on the parent's screen. | Android child app | pair_qr_scan_activity_camera_ready_point_phone | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/setup/PairQrScanActivity.kt:174 | The camera could not start. Enter the server URL and pairing code below. | Android child app | pair_qr_scan_activity_camera_could_not_start | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/social/SocialScanQueue.kt:134 | Child contacted/received from $digits via $app | Android child app | social_scan_queue_child_contacted_received_digits | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/sos/SosActivity.kt:104 | SOS from ${Build.MODEL} | SOS flow | sos_activity_sos_build_model | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/sos/SosActivity.kt:105 | Your child pressed the SOS button | SOS flow | sos_activity_child_pressed_sos_button | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/sos/SosActivity.kt:150 | Sending SOS in ${(s.remainingMs + 999) / 1000}… | SOS flow | sos_activity_sending_sos_s_remainingms | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/sos/SosActivity.kt:157 | Stay calm — tap Cancel if this was accidental. | SOS flow | sos_activity_stay_calm_tap_cancel | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/sos/SosActivity.kt:168 | Alert sent — stay where you are | SOS flow | sos_activity_alert_sent_stay_where | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/sos/SosActivity.kt:175 | Your parent has been notified. | SOS flow | sos_activity_parent_has_been_notified | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/sos/SosActivity.kt:182 | Need help right now? | SOS flow | sos_activity_need_help_right_now | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/sos/SosActivity.kt:196 | SOS cancelled. | SOS flow | sos_activity_sos_cancelled | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/vpn/FilterVpnService.kt:285 | Content filter | Android child app | filter_vpn_service_content_filter | new |
| apps/child-android/app/src/main/java/com/familyshield/agent/vpn/FilterVpnService.kt:290 | Content filter active | Android child app | filter_vpn_service_content_filter_active | new |
| apps/child-ios/Sources/FamilyShieldAgent/DeviceActivityMonitor.swift:204 | Screen time limit reached | OSRA Kids on iPhone | device_activity_monitor_screen_time_limit_reached | new |
| apps/child-ios/Sources/FamilyShieldAgent/DeviceActivityMonitor.swift:205 | Screen time threshold reached (event \(event.rawValue), activity \(activity.rawValue)). | OSRA Kids on iPhone | device_activity_monitor_screen_time_threshold_reached | new |
| apps/child-ios/Sources/FamilyShieldAgent/PairingView.swift:98 | Failed to persist identity: shared app group is unavailable. Verify app group provisioning. | Pairing flow | pairing_view_failed_persist_identity_shared | new |
| apps/child-ios/Sources/FamilyShieldAgent/ShieldConfiguration.swift:111 | Child asked for access | OSRA Kids on iPhone | shield_configuration_child_asked_access | new |
| apps/child-ios/Sources/FamilyShieldAgent/ShieldConfiguration.swift:112 | Child pressed 'Ask parent' on a shield screen. | OSRA Kids on iPhone | shield_configuration_child_pressed_ask_parent | new |
| apps/parent-app/lib/features/coach/coach_card_section.dart:32 | How to talk about this | Parent app | coach_card_section_how_talk_about | new |
| apps/parent-app/lib/features/coach/coach_content.dart:29 | If your child may be hurting themselves | Parent app | coach_content_if_child_may_be | new |
| apps/parent-app/lib/features/coach/coach_content.dart:60 | When an adult may be grooming your child | Parent app | coach_content_when_adult_may_be | new |
| apps/parent-app/lib/features/coach/coach_content.dart:90 | If your child is being bullied online | Parent app | coach_content_if_child_being_bullied | new |
| apps/parent-app/lib/features/coach/coach_content.dart:120 | Talking about sexual content | Parent app | coach_content_talking_about_sexual_content | new |
| apps/parent-app/lib/features/coach/coach_content.dart:124 | less. Frame the issue as safety, not shame: their body, their privacy, and never sharing | Parent app | coach_content_less_frame_issue_as | new |
| apps/parent-app/lib/features/coach/coach_content.dart:134 | Agree on a no-questions-asked rule for reporting weird messages. | Parent app | coach_content_agree_no_questions_asked | new |
| apps/parent-app/lib/features/coach/coach_content.dart:146 | If your child sees or shares violent content | Parent app | coach_content_if_child_sees_shares | new |
| apps/parent-app/lib/features/coach/coach_content.dart:172 | When your child encounters hate speech | Parent app | coach_content_when_child_encounters_hate | new |
| apps/parent-app/lib/features/coach/coach_content.dart:199 | A worrying message — how to respond | Parent app | coach_content_worrying_message_how_respond | new |
| apps/parent-app/lib/features/coach/coach_content.dart:202 | Start from curiosity, not accusation. Pick a calm moment, mention what you noticed without | Parent app | coach_content_start_curiosity_not_accusation | new |
| apps/parent-app/lib/features/coach/coach_content.dart:210 | Describe what you noticed, not verdicts about their friends. | Parent app | coach_content_describe_what_noticed_not | new |
| apps/parent-app/lib/features/coach/coach_content.dart:225 | Agreeing on screen-time limits together | Parent app | coach_content_agreeing_screen_time_limits | new |
| apps/parent-app/lib/features/coach/coach_content.dart:255 | Staying safe in gaming chats | Parent app | coach_content_staying_safe_gaming_chats | new |
| apps/parent-app/lib/features/coach/coach_content.dart:282 | A calm first conversation | Parent app | coach_content_calm_first_conversation | new |
| apps/parent-app/lib/features/coach/coach_content.dart:285 | Whatever the alert is about, the first conversation sets the tone. Stay calm, be honest | Parent app | coach_content_whatever_alert_about_first | new |
| apps/parent-app/lib/providers/auth_provider.dart:254 | request failed | Parent app | auth_provider_request_failed | new |
| apps/parent-app/lib/push/local_notifier.dart:63 | OSRA alerts | Push notification | local_notifier_osra_alerts | new |
| apps/parent-app/lib/push/local_notifier.dart:64 | Lock screen, screen time and safety alerts from your family | Push notification | local_notifier_lock_screen_screen_time | new |
| site/terms/index.html:16 | OSRA terms of use | Website: terms | index_osra_terms_use | new |
| site/terms/index.html:52 | OSRA terms of use | Website: terms | index_osra_terms_use | new |
| site/terms/index.html:55 | Effective 12 November 2026. | Website: terms | index_effective_12_november_2026 | new |
| site/terms/index.html:59 | These terms are the agreement between you and OSRA ("we"); section 12 gives the legal details. By creating an OSRA account, or by installing or using an OSRA app, you accept them. If you do not accept them, do not use OSRA. | Website: terms | index_these_terms_agreement_between | new |
| site/terms/index.html:63 | 1. Who may use OSRA | Website: terms | index_1_who_may_use | new |
| site/terms/index.html:66 | OSRA is for parents and legal guardians aged 18 or over, to supervise their own children's phones. You must not use it to monitor another adult or anyone you are not responsible for. You are responsible for using OSRA lawfully in your country, and for telling your child that OSRA is on their phone. | Website: terms | index_osra_parents_legal_guardians | new |
| site/terms/index.html:70 | 2. What OSRA is, and what it is not | Website: terms | index_2_what_osra_what | new |
| site/terms/index.html:73 | OSRA is a tool that helps a parent. It does not replace a parent's own care and supervision. We do not promise that OSRA will detect every risk, block every app or website, show a location that is exact or current, deliver every alert, or work without interruption. It depends on the phone, its settings and battery, the network, and on Apple's and Google's systems, and a child may switch off or get around parts of it. | Website: terms | index_osra_tool_helps_parent | new |
| site/terms/index.html:76 | OSRA is not an emergency service. The SOS button alerts the parent; it does not call the police, an ambulance or anyone else. In an emergency, call your local emergency number. | Website: terms | index_osra_not_emergency_service | new |
| site/terms/index.html:80 | 3. Your account | Website: terms | index_3_account | new |
| site/terms/index.html:83 | Keep your password and your sign-in codes to yourself. You are responsible for what is done through your account, and for the parents and guardians you invite to your family. | Website: terms | index_keep_password_sign_codes | new |
| site/terms/index.html:87 | 4. Changes to OSRA | Website: terms | index_4_changes_osra | new |
| site/terms/index.html:90 | We may add, change or remove features, and we may stop offering OSRA. We may suspend an account that is used against these terms. | Website: terms | index_we_may_add_change | new |
| site/terms/index.html:94 | 5. Payments and refunds | Website: terms | index_5_payments_refunds | new |
| site/terms/index.html:97 | If you pay for anything in OSRA, the payment is handled by the app store you bought it from, under that store's own refund rules. We give no other refund or reimbursement, except where the law requires one. | Website: terms | index_if_pay_anything_osra | new |
| site/terms/index.html:101 | 6. No warranty | Website: terms | index_6_no_warranty | new |
| site/terms/index.html:104 | To the fullest extent the law allows, OSRA is provided "as is" and "as available", without any warranty or guarantee of any kind, whether stated or implied. | Website: terms | index_fullest_extent_law_allows | new |
| site/terms/index.html:108 | 7. Our liability, and the claims you give up | Website: terms | index_7_our_liability_claims | new |
| site/terms/index.html:111 | To the fullest extent the law allows: | Website: terms | index_fullest_extent_law_allows | new |
| site/terms/index.html:116 | We are not liable to you, to your child or to anyone in your family for any loss, damage, cost or harm of any kind that arises from OSRA or from your use of it. This includes something OSRA did not detect, block, show or send; a location or an alert that was wrong or late; a feature that failed or was unavailable; and lost data. | Website: terms | index_we_not_liable_child | new |
| site/terms/index.html:119 | You give up any right to claim compensation, damages or reimbursement from us for any such loss, | Website: terms | index_give_up_any_right | new |
| site/terms/index.html:120 | unless you prove that we caused the harm on purpose | Website: terms | index_unless_prove_we_caused | new |
| site/terms/index.html:126 | The law of some countries does not allow all of these limits. Nothing in these terms takes away a right that the law says cannot be taken away or given up, such as rights under the consumer-protection or data-protection law of your country. Where a limit cannot apply in full, it applies as far as that law allows, and our total liability to you is then limited to the amount you paid us for OSRA in the 12 months before your claim. | Website: terms | index_law_some_countries_does | new |
| site/terms/index.html:130 | 8. Ending | Website: terms | index_8_ending | new |
| site/terms/index.html:133 | You can stop using OSRA and delete your account at any time: see | Website: terms | index_can_stop_using_osra | new |
| site/terms/index.html:135 | . Sections 6 and 7 continue to apply after your account is deleted. | Website: terms | index_sections_6_7_continue | new |
| site/terms/index.html:139 | 9. Your data | Website: terms | index_9_data | new |
| site/terms/index.html:142 | How we handle your family's data is set out in the | Website: terms | index_how_we_handle_family | new |
| site/terms/index.html:143 | privacy policy | Website: terms | index_privacy_policy | new |
| site/terms/index.html:148 | 10. Changes to these terms | Website: terms | index_10_changes_these_terms | new |
| site/terms/index.html:155 | 11. Governing law | Website: terms | index_11_governing_law | new |
| site/terms/index.html:158 | These terms are governed by the laws of the United Arab Emirates as they apply in the Emirate of Dubai, and the courts of Dubai decide any dispute about them. If the law of the country you live in gives you, as a consumer, a protection or a court that cannot be set aside by agreement, you keep it. | Website: terms | index_these_terms_governed_laws | new |
| site/terms/index.html:162 | 12. Contact | Website: terms | index_12_contact | new |
| site/terms/index.html:170 | OSRA is developed and offered by [name and address in source] | Website: terms | index_osra_developed_offered_karim | new |
| site/terms/index.html:183 | Privacy policy | Website: terms | index_privacy_policy | new |
| site/terms/index.html:185 | Terms of use | Website: terms | index_terms_use | new |
| site/terms/index.html:187 | Delete your account | Website: terms | index_delete_account | new |
