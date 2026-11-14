### Parent app — Arabic dates use Western digits and locale-native day headers (#758)
- App startup and the background notification isolate configure `intl` once and await its locale data, so Arabic dates and times print Western digits rather than Arabic-Indic digits.
- Alert-list and social-timeline day headers now use the locale's full day/month/year order, through one shared formatter. Existing Arabic strings and all other number/plural paths are unchanged.
- Added direct background-entry and Arabic widget coverage that rejects Arabic-Indic digits, with alert-detail and alert-list evidence for the Arabic Language Bureau. No phone run is claimed.
