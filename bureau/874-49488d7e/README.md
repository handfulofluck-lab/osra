# PR874 four retakes

Exact head49488d7e5dc93023b078b71ea5d0ab28981ab4e7; simulator debug build, production widgets, fictional family, local-only fixture.

Three dialog frames at200% linear text (SE3 English,320-width English and Arabic). Fourth frame uses native OS accessibility-extra-extra-extra-large, queried via simctl ui content_size; platform TextScaler preserved, not synthetic linear AX5. Button scrolled fully into view. First two native fixture attempts failed on lazy-list/finder handling and saved no frames; bounded outer-list scroll fixed locally without product changes, final run passed.

Selected dropdown values still clip (dense sizing); floating field labels ellipsize. NativeAX5 Add child and continue button is fully visible and centered. No overall UIUX approval. Native onboarding region value also appears clipped.

Lease02:24–02:31 UAE18Nov; content_size restored to original large and simulator shut down. iPhone untouched.
