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
| site/delete-account/index.html:16 | Delete your OSRA account | Website: delete-account | index_delete_osra_account | already on #604 or sheet 2 |
| site/delete-account/index.html:52 | Delete your OSRA account and data | Website: delete-account | index_delete_osra_account_data | already on #604 or sheet 2 |
| site/delete-account/index.html:55 | Only the OSRA parent app has accounts. The OSRA child app has no account of its own: a child's data belongs to the family account and is deleted with it. | Website: delete-account | index_only_osra_parent_app | already on #604 or sheet 2 |
| site/delete-account/index.html:59 | In the OSRA app | Website: delete-account | index_osra_app | already on #604 or sheet 2 |
| site/delete-account/index.html:64 | Open the OSRA app and sign in. | Website: delete-account | index_open_osra_app_sign | already on #604 or sheet 2 |
| site/delete-account/index.html:67 | On the dashboard, tap the menu (⋮, top right), then | Website: delete-account | index_dashboard_tap_menu_top | already on #604 or sheet 2 |
| site/delete-account/index.html:68 | Delete account | Website: delete-account | index_delete_account | already on #604 or sheet 2 |
| site/delete-account/index.html:72 | Type your email address, then your password, and your authenticator code if two-step sign-in is on. | Website: delete-account | index_type_email_address_then | already on #604 or sheet 2 |
| site/delete-account/index.html:75 | Confirm. The deletion happens at once and cannot be undone. | Website: delete-account | index_confirm_deletion_happens_once | already on #604 or sheet 2 |
| site/delete-account/index.html:81 | Without the app | Website: delete-account | index_without_app | already on #604 or sheet 2 |
| site/delete-account/index.html:86 | from the email address you sign in with, and ask us to delete your account. We reply to that address to confirm the request comes from you, then delete the account within 30 days and tell you when it is done. | Website: delete-account | index_email_address_sign_ask | already on #604 or sheet 2 |
| site/delete-account/index.html:90 | What is deleted | Website: delete-account | index_what_deleted | already on #604 or sheet 2 |
| site/delete-account/index.html:96 | If you created the family | Website: delete-account | index_if_created_family | already on #604 or sheet 2 |
| site/delete-account/index.html:97 | (the owner): the whole family. That is every child's location history, app use, alerts, message excerpts, rules and places, every linked phone, and every other parent's and guardian's access. | Website: delete-account | index_owner_whole_family_every | already on #604 or sheet 2 |
| site/delete-account/index.html:101 | If you joined someone else's family | Website: delete-account | index_if_joined_someone_else | already on #604 or sheet 2 |
| site/delete-account/index.html:102 | : only your own account. The family and the children stay. | Website: delete-account | index_only_own_account_family | already on #604 or sheet 2 |
| site/delete-account/index.html:108 | What is kept, and for how long | Website: delete-account | index_what_kept_how_long | already on #604 or sheet 2 |
| site/delete-account/index.html:113 | The identifiers of signed-out sessions, until those sessions would have expired (at most 8 days), so they cannot be reused. | Website: delete-account | index_identifiers_signed_out_sessions | already on #604 or sheet 2 |
| site/delete-account/index.html:116 | Encrypted database backups, if we keep any: each backup is deleted within 90 days. | Website: delete-account | index_encrypted_database_backups_if | already on #604 or sheet 2 |
| site/delete-account/index.html:119 | Server logs, which hold identifiers but no messages or content, for at most 90 days. | Website: delete-account | index_server_logs_which_hold | already on #604 or sheet 2 |
| site/delete-account/index.html:124 | Everything else is deleted at once. See the | Website: delete-account | index_everything_else_deleted_once | already on #604 or sheet 2 |
| site/delete-account/index.html:125 | privacy policy | Website: delete-account | index_privacy_policy | already on #604 or sheet 2 |
| site/delete-account/index.html:126 | for more. | Website: delete-account | index_more | already on #604 or sheet 2 |
| site/delete-account/index.html:139 | Privacy policy | Website: delete-account | index_privacy_policy | already on #604 or sheet 2 |
| site/delete-account/index.html:141 | Terms of use | Website: delete-account | index_terms_use | already on #604 or sheet 2 |
| site/delete-account/index.html:143 | Delete your account | Website: delete-account | index_delete_account | already on #604 or sheet 2 |
| site/privacy/index.html:16 | OSRA privacy policy | Website: privacy | index_osra_privacy_policy | already on #604 or sheet 2 |
| site/privacy/index.html:52 | OSRA privacy policy | Website: privacy | index_osra_privacy_policy | already on #604 or sheet 2 |
| site/privacy/index.html:55 | Effective 12 November 2026. | Website: privacy | index_effective_12_november_2026 | already on #604 or sheet 2 |
| site/privacy/index.html:59 | This policy explains what the OSRA apps collect, why, where it is kept, for how long, and how to delete it. It covers the | Website: privacy | index_policy_explains_what_osra | already on #604 or sheet 2 |
| site/privacy/index.html:61 | parent app and the | Website: privacy | index_parent_app | already on #604 or sheet 2 |
| site/privacy/index.html:62 | OSRA child app | Website: privacy | index_osra_child_app | already on #604 or sheet 2 |
| site/privacy/index.html:63 | (OSRA Kids) distributed on Google Play and on Apple's App Store. An OSRA app distributed in any other way has its own notice, shown where you download it. In this policy, "we" and "OSRA" mean the developer of the OSRA apps, who is responsible for how this data is used; section 13 gives the legal details. You can reach us at | Website: privacy | index_osra_kids_distributed_google | already on #604 or sheet 2 |
| site/privacy/index.html:69 | 1. Who OSRA is for | Website: privacy | index_1_who_osra | already on #604 or sheet 2 |
| site/privacy/index.html:72 | OSRA is for parents and legal guardians who supervise their own children's phones. A parent creates the account in the OSRA app and pairs the child's phone with the OSRA child app. The child app is visible on the child's phone and shows that it is active. OSRA must not be used to monitor another adult or anyone you are not responsible for. | Website: privacy | index_osra_parents_legal_guardians | already on #604 or sheet 2 |
| site/privacy/index.html:75 | Accounts are for adults (18 or over). Children do not create accounts; a child's data belongs to the family account the parent created. | Website: privacy | index_accounts_adults_18_over | already on #604 or sheet 2 |
| site/privacy/index.html:79 | 2. What the OSRA child app collects | Website: privacy | index_2_what_osra_child | already on #604 or sheet 2 |
| site/privacy/index.html:82 | On an Android phone | Website: privacy | index_android_phone | already on #604 or sheet 2 |
| site/privacy/index.html:85 | The child app sends the following to the family's account, so the parent can see it in the OSRA app: | Website: privacy | index_child_app_sends_following | already on #604 or sheet 2 |
| site/privacy/index.html:92 | , including in the background: the phone's position, its accuracy and the time. It is used to show where the child is, to answer the parent's "locate now" request, and for alerts when the child arrives at or leaves a place the parent has set. | Website: privacy | index_including_background_phone_s | already on #604 or sheet 2 |
| site/privacy/index.html:96 | App use | Website: privacy | index_app_use | already on #604 or sheet 2 |
| site/privacy/index.html:97 | : how many minutes each app was used, total screen time, how many times the phone was unlocked, and which app is open while the screen is on. It is used for screen-time limits, schedules and reports. | Website: privacy | index_how_many_minutes_each | already on #604 or sheet 2 |
| site/privacy/index.html:101 | Installed apps | Website: privacy | index_installed_apps | already on #604 or sheet 2 |
| site/privacy/index.html:102 | : the list of apps on the phone, so the parent can set rules per app and be told when a new app is installed. | Website: privacy | index_list_apps_phone_so | already on #604 or sheet 2 |
| site/privacy/index.html:106 | Messages in chat apps the parent chooses | Website: privacy | index_messages_chat_apps_parent | already on #604 or sheet 2 |
| site/privacy/index.html:107 | : the text shown on screen in those apps, together with the chat partner's displayed name or number. Email addresses, phone numbers and other long numbers in the text are masked on the phone before anything is sent. Our server checks the text against safety rules (for example for bullying or self-harm). Text that raises no concern is discarded straight away and not stored. When text does raise a concern, a short excerpt (at most 240 characters) is stored encrypted so the parent can see why the alert was raised. The parent chooses which apps are checked during setup, and can switch each one off at any time. | Website: privacy | index_text_shown_screen_those | already on #604 or sheet 2 |
| site/privacy/index.html:111 | Unknown contacts | Website: privacy | index_unknown_contacts | already on #604 or sheet 2 |
| site/privacy/index.html:112 | : if the parent has set a list of allowed contacts, a number that is not on the list raises an alert that includes that number. | Website: privacy | index_if_parent_has_set | already on #604 or sheet 2 |
| site/privacy/index.html:116 | Requests and SOS | Website: privacy | index_requests_sos | already on #604 or sheet 2 |
| site/privacy/index.html:117 | : when the child asks for more time or access to a blocked app, or presses SOS, the request or alert is sent to the parent. | Website: privacy | index_when_child_asks_more | already on #604 or sheet 2 |
| site/privacy/index.html:121 | Device and app information | Website: privacy | index_device_app_information | already on #604 or sheet 2 |
| site/privacy/index.html:122 | : the phone's model and Android version, battery level, which OSRA permissions and protections are switched on, how many other user profiles the phone has (counts only), the version of the OSRA child app, a push-notification token, and alerts when a protection is switched off. It is used to keep the protection working, to tell the parent when something needs fixing, and to detect tampering. | Website: privacy | index_phone_s_model_android | already on #604 or sheet 2 |
| site/privacy/index.html:127 | The child app does | Website: privacy | index_child_app_does | already on #604 or sheet 2 |
| site/privacy/index.html:129 | read SMS or MMS messages, call logs, email, contacts, photos, videos, files or the calendar. It does not record audio. The camera is used only to scan the pairing QR code, and no image is stored or sent. | Website: privacy | index_read_sms_mms_messages | already on #604 or sheet 2 |
| site/privacy/index.html:133 | Web filtering. | Website: privacy | index_web_filtering | already on #604 or sheet 2 |
| site/privacy/index.html:134 | To apply the parent's website rules, the child app runs a local filter on the phone (Android shows it as a VPN). Web addresses are checked on the phone and are | Website: privacy | index_apply_parent_s_website | already on #604 or sheet 2 |
| site/privacy/index.html:136 | sent to us, and we do not keep a browsing history. Name lookups are forwarded to the network's own DNS resolver; when that resolver cannot be found, they go to the public resolvers of Cloudflare (1.1.1.1) and Google (8.8.8.8), under those companies' own privacy policies. | Website: privacy | index_sent_us_we_do | already on #604 or sheet 2 |
| site/privacy/index.html:140 | On an iPhone | Website: privacy | index_iphone | already on #604 or sheet 2 |
| site/privacy/index.html:143 | On an iPhone the child app (OSRA Kids) works through Apple's Screen Time framework and collects less. It sends: | Website: privacy | index_iphone_child_app_osra | already on #604 or sheet 2 |
| site/privacy/index.html:150 | , including in the background, for the same purposes as on Android. | Website: privacy | index_including_background_same_purposes | already on #604 or sheet 2 |
| site/privacy/index.html:154 | Blocks and requests | Website: privacy | index_blocks_requests | already on #604 or sheet 2 |
| site/privacy/index.html:155 | : that a group of apps the parent chose was blocked, and the child's request for access to it. | Website: privacy | index_group_apps_parent_chose | already on #604 or sheet 2 |
| site/privacy/index.html:159 | Device and app information | Website: privacy | index_device_app_information | already on #604 or sheet 2 |
| site/privacy/index.html:160 | : the iPhone's model and iOS version, which OSRA permissions are switched on, the version of the app, and a push-notification token. | Website: privacy | index_iphone_s_model_ios | already on #604 or sheet 2 |
| site/privacy/index.html:165 | On an iPhone the child app does | Website: privacy | index_iphone_child_app_does | already on #604 or sheet 2 |
| site/privacy/index.html:167 | read chat messages or anything else on the screen, does not filter or see web traffic, and does not report minutes of use per app. Apple does not give OSRA the names of the apps on the iPhone: the parent chooses groups of apps on the iPhone itself, and we receive only the names the parent gives those groups. It also does not read SMS, call logs, email, contacts, photos, files or the calendar, and does not record audio. | Website: privacy | index_read_chat_messages_anything | already on #604 or sheet 2 |
| site/privacy/index.html:171 | 3. What the OSRA parent app collects | Website: privacy | index_3_what_osra_parent | already on #604 or sheet 2 |
| site/privacy/index.html:177 | Account details | Website: privacy | index_account_details | already on #604 or sheet 2 |
| site/privacy/index.html:178 | : your name, email address and password. The password is stored only as a one-way hash, never in readable form. | Website: privacy | index_name_email_address_password | already on #604 or sheet 2 |
| site/privacy/index.html:182 | Family details | Website: privacy | index_family_details | already on #604 or sheet 2 |
| site/privacy/index.html:183 | : the family name, region and time zone; each child's name and birth year; the parental consent record (how and when you confirmed you are the child's parent or guardian); and the email addresses of other parents or guardians you invite. | Website: privacy | index_family_name_region_time | already on #604 or sheet 2 |
| site/privacy/index.html:187 | Rules and places | Website: privacy | index_rules_places | already on #604 or sheet 2 |
| site/privacy/index.html:188 | : the screen-time rules, schedules, app and website rules you set, and the places you add on the map, such as home or school (their location and name). | Website: privacy | index_screen_time_rules_schedules | already on #604 or sheet 2 |
| site/privacy/index.html:192 | Push-notification token | Website: privacy | index_push_notification_token | already on #604 or sheet 2 |
| site/privacy/index.html:193 | , if you allow notifications, so we can send you alerts. | Website: privacy | index_if_allow_notifications_so | already on #604 or sheet 2 |
| site/privacy/index.html:198 | The parent app does not read your own phone's location, contacts, messages, photos or files. It contains no advertising or analytics code. | Website: privacy | index_parent_app_does_not | already on #604 or sheet 2 |
| site/privacy/index.html:202 | 4. How we use the data | Website: privacy | index_4_how_we_use | already on #604 or sheet 2 |
| site/privacy/index.html:205 | We use the data only to provide OSRA's features to the family: showing the parent the child's location, activity and alerts; enforcing the parent's rules on the child's phone; sending alerts and emails the parent asked for (such as sign-in codes, password resets and summaries); keeping accounts secure; and fixing problems. Alerts are raised automatically by fixed rules; they inform the parent and decide nothing about the child by themselves. We do not sell data, we do not use it for advertising, and we do not share it with anyone for their own purposes. | Website: privacy | index_we_use_data_only | already on #604 or sheet 2 |
| site/privacy/index.html:209 | Our legal grounds | Website: privacy | index_our_legal_grounds | already on #604 or sheet 2 |
| site/privacy/index.html:210 | , where European or similar law asks for them: for a child's data, the consent the parent or guardian gives for that child (section 8); for the parent's own account, the contract to provide OSRA to you; and for keeping accounts and the service secure, our legitimate interest in doing so. | Website: privacy | index_where_european_similar_law | already on #604 or sheet 2 |
| site/privacy/index.html:214 | 5. Service providers | Website: privacy | index_5_service_providers | already on #604 or sheet 2 |
| site/privacy/index.html:217 | We use these providers to run OSRA. They receive only what their task needs: | Website: privacy | index_we_use_these_providers | already on #604 or sheet 2 |
| site/privacy/index.html:223 | Amazon Web Services | Website: privacy | index_amazon_web_services | already on #604 or sheet 2 |
| site/privacy/index.html:224 | : hosting of our servers and database, in the European Union. | Website: privacy | index_hosting_our_servers_database | already on #604 or sheet 2 |
| site/privacy/index.html:228 | Google Firebase Cloud Messaging | Website: privacy | index_google_firebase_cloud_messaging | already on #604 or sheet 2 |
| site/privacy/index.html:229 | and, for iPhones, the | Website: privacy | index_iphones | already on #604 or sheet 2 |
| site/privacy/index.html:230 | Apple Push Notification service | Website: privacy | index_apple_push_notification_service | already on #604 or sheet 2 |
| site/privacy/index.html:231 | : delivery of push notifications. An alert's title passes through them. | Website: privacy | index_delivery_push_notifications_alert | already on #604 or sheet 2 |
| site/privacy/index.html:235 | Google Maps | Website: privacy | index_google_maps | already on #604 or sheet 2 |
| site/privacy/index.html:236 | : the map in the parent app. The parent's phone asks Google for the map of the area being shown. | Website: privacy | index_map_parent_app_parent | already on #604 or sheet 2 |
| site/privacy/index.html:240 | Email delivery | Website: privacy | index_email_delivery | already on #604 or sheet 2 |
| site/privacy/index.html:241 | (Resend, moving to Amazon Simple Email Service): sending account emails. | Website: privacy | index_resend_moving_amazon_simple | already on #604 or sheet 2 |
| site/privacy/index.html:247 | 6. Where the data is stored | Website: privacy | index_6_where_data_stored | already on #604 or sheet 2 |
| site/privacy/index.html:250 | Family data is stored on Amazon Web Services servers in the European Union, for families in every country, including the Middle East. The database is encrypted at rest. All traffic between the apps and our servers uses HTTPS. | Website: privacy | index_family_data_stored_amazon | already on #604 or sheet 2 |
| site/privacy/index.html:253 | The push, map and email providers in section 5 may handle the limited data they receive outside the European Union, including in the United States, under their own data-protection terms. | Website: privacy | index_push_map_email_providers | already on #604 or sheet 2 |
| site/privacy/index.html:257 | 7. How long we keep it | Website: privacy | index_7_how_long_we | already on #604 or sheet 2 |
| site/privacy/index.html:265 | Kept for | Website: privacy | index_kept | already on #604 or sheet 2 |
| site/privacy/index.html:270 | Location history | Website: privacy | index_location_history | already on #604 or sheet 2 |
| site/privacy/index.html:272 | 30 days | Website: privacy | index_30_days | already on #604 or sheet 2 |
| site/privacy/index.html:277 | Activity events and stored message excerpts | Website: privacy | index_activity_events_stored_message | already on #604 or sheet 2 |
| site/privacy/index.html:279 | 90 days | Website: privacy | index_90_days | already on #604 or sheet 2 |
| site/privacy/index.html:284 | Daily app-use totals | Website: privacy | index_daily_app_use_totals | already on #604 or sheet 2 |
| site/privacy/index.html:286 | 365 days | Website: privacy | index_365_days | already on #604 or sheet 2 |
| site/privacy/index.html:293 | 12 months, or until the child or the account is deleted if that comes first | Website: privacy | index_12_months_until_child | already on #604 or sheet 2 |
| site/privacy/index.html:298 | Installed-app list and device information | Website: privacy | index_installed_app_list_device | already on #604 or sheet 2 |
| site/privacy/index.html:300 | Replaced by each new report; deleted when the phone is unpaired or the child is removed | Website: privacy | index_replaced_each_new_report | already on #604 or sheet 2 |
| site/privacy/index.html:305 | Records of a reset of two-step sign-in | Website: privacy | index_records_reset_two_step | already on #604 or sheet 2 |
| site/privacy/index.html:307 | 12 months after the reset ends | Website: privacy | index_12_months_after_reset | already on #604 or sheet 2 |
| site/privacy/index.html:312 | Encrypted database backups, if we keep any | Website: privacy | index_encrypted_database_backups_if | already on #604 or sheet 2 |
| site/privacy/index.html:314 | Each backup is deleted within 90 days | Website: privacy | index_each_backup_deleted_within | already on #604 or sheet 2 |
| site/privacy/index.html:319 | Server logs (identifiers, no messages or content) | Website: privacy | index_server_logs_identifiers_no | already on #604 or sheet 2 |
| site/privacy/index.html:321 | At most 90 days | Website: privacy | index_most_90_days | already on #604 or sheet 2 |
| site/privacy/index.html:326 | Everything else in the family account | Website: privacy | index_everything_else_family_account | already on #604 or sheet 2 |
| site/privacy/index.html:328 | Until the account is deleted | Website: privacy | index_until_account_deleted | already on #604 or sheet 2 |
| site/privacy/index.html:335 | 8. Consent and the child's role | Website: privacy | index_8_consent_child_s | already on #604 or sheet 2 |
| site/privacy/index.html:338 | A parent cannot add a child without confirming that they are the child's parent or legal guardian and that they consent to OSRA processing the child's data. The parent can withdraw that consent in the app; the child's phone then stops sending data. Data already collected stays until it expires (section 7) or is deleted (section 9). | Website: privacy | index_parent_cannot_add_child | already on #604 or sheet 2 |
| site/privacy/index.html:342 | For the child: | Website: privacy | index_child | already on #604 or sheet 2 |
| site/privacy/index.html:343 | OSRA helps your parent keep you safe. It shows them where your phone is, how long you use apps, and warns them if something in a chat might hurt you. On an Android phone it can read the chats in the apps your parent chose; on an iPhone it cannot read any chat. It does not read your SMS text messages or call history, does not look through your photos, and does not listen to you. If you are worried about anything, talk to your parent. | Website: privacy | index_osra_helps_parent_keep | already on #604 or sheet 2 |
| site/privacy/index.html:347 | 9. Your rights and deleting your data | Website: privacy | index_9_rights_deleting_data | already on #604 or sheet 2 |
| site/privacy/index.html:350 | You can ask us for a copy of your family's data (in a form you can take to another service), ask us to correct it, ask us to delete it, or ask us to stop or limit a use of it, by writing to | Website: privacy | index_can_ask_us_copy | already on #604 or sheet 2 |
| site/privacy/index.html:352 | from the email address you sign in with. We answer within one month. A parent can withdraw consent for a child at any time (section 8); that does not undo what was done before. | Website: privacy | index_email_address_sign_we | already on #604 or sheet 2 |
| site/privacy/index.html:355 | You can delete your account yourself in the OSRA app, or follow the steps at | Website: privacy | index_can_delete_account_yourself | already on #604 or sheet 2 |
| site/privacy/index.html:357 | . If you created the family, deleting your account deletes the whole family and every child's data. If you joined someone else's family, it deletes only your own account. | Website: privacy | index_if_created_family_deleting | already on #604 or sheet 2 |
| site/privacy/index.html:360 | You may also complain to the data protection authority of your country, for example in the European Union or the United Kingdom. | Website: privacy | index_may_also_complain_data | already on #604 or sheet 2 |
| site/privacy/index.html:364 | 10. Security | Website: privacy | index_10_security | already on #604 or sheet 2 |
| site/privacy/index.html:367 | All connections use HTTPS. Each paired phone signs its requests with its own key. Parents can turn on two-step sign-in with an authenticator app. Message excerpts are stored encrypted. | Website: privacy | index_all_connections_use_https | already on #604 or sheet 2 |
| site/privacy/index.html:371 | 11. Changes | Website: privacy | index_11_changes | already on #604 or sheet 2 |
| site/privacy/index.html:378 | 12. Terms of use | Website: privacy | index_12_terms_use | already on #604 or sheet 2 |
| site/privacy/index.html:382 | terms of use | Website: privacy | index_terms_use | already on #604 or sheet 2 |
| site/privacy/index.html:383 | , which set out the limits of our liability. | Website: privacy | index_which_set_out_limits | already on #604 or sheet 2 |
| site/privacy/index.html:387 | 13. Contact | Website: privacy | index_13_contact | already on #604 or sheet 2 |
| site/privacy/index.html:395 | The person legally responsible for OSRA and for this data (the "controller" in European law) is [name and address in source] | Website: privacy | index_person_legally_responsible_osra | already on #604 or sheet 2 |
| site/privacy/index.html:408 | Privacy policy | Website: privacy | index_privacy_policy | already on #604 or sheet 2 |
| site/privacy/index.html:410 | Terms of use | Website: privacy | index_terms_use | already on #604 or sheet 2 |
| site/privacy/index.html:412 | Delete your account | Website: privacy | index_delete_account | already on #604 or sheet 2 |
