### Parent app — iPhone controls that aren't built yet say so instead of failing (#1088, epic #1092)
- On 24 Nov the iPhone child acked Ring, Lock and Pause internet as `not_supported` within seconds while the parent app still showed working buttons.
- The API now sends `setup.unsupportedCommands` for each device, from the server's capability table (never from the phone). For an iPhone that is Lock/Unlock, Pause/Resume, Pause internet and Ring/Stop ring.
- The parent app draws those controls at 38% with a neutral "Not yet available" pill (child card and map). A tap explains why in a snackbar and sends nothing. One line under the device row names what isn't available and what works now (UI/UX Bureau copy, 7146060347).
- Nothing is decided from `platform == 'ios'`: when Ring (#760) or Lock/Pause (#1089) empty their row in the table, the controls come back with no app change.
- The child-wide Pause internet follows the same rule: for an iPhone-only child the dashboard pill reads "Not yet available" and never pauses; with an iPhone and an Android, the confirm dialog (and the device-card snackbar) names the iPhone that stays online.
