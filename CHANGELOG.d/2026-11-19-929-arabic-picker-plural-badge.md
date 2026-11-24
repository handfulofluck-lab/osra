### Parent app — the Arabic plural, the mirrored badge and the Allow label (#929)
- The app picker's "showing the first N apps" notice is an Arabic **plural** now, so the Android cap of
  500 reads the singular form the language requires (`{count, plural, one{عرض أول تطبيق} two{عرض أول تطبيقين} few{عرض أول {count} تطبيقات} many{عرض أول {count} تطبيقًا} other{عرض أول {count} تطبيق}}`), with `few` and `many` covering 3-10 and
  11-99. English is unchanged.
- The unknown-app badge draws the mirrored Arabic question mark (U+061F) when the app has no name and the
  screen is right-to-left; English keeps `?`.
- `allowAction` and `appActionAllow` read «السماح», the word Android itself uses for "Allow".
- Wording issued by the Arabic Language Bureau and copied verbatim; three new rows pin the literals, and
  reverting any of the three changes reddens its own row.
