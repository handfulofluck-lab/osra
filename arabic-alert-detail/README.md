# PR #980 Arabic alert detail

The iPhone SE simulator rendered `AlertDetailScreen` from `e04b454fa8d60fd09d6fd1088a846d2634263834` with the existing Arabic catalog and synthetic family and alert data.

| Preview state | Light 100% | Light 200% | Dark 100% | Dark 200% |
| --- | --- | --- | --- | --- |
| Available | [PNG](pr980-e04b454f-ar-light-100-available.png) | [PNG](pr980-e04b454f-ar-light-200-available.png) | [PNG](pr980-e04b454f-ar-dark-100-available.png) | [PNG](pr980-e04b454f-ar-dark-200-available.png) |
| Permission denied | [PNG](pr980-e04b454f-ar-light-100-no-permission.png) | [PNG](pr980-e04b454f-ar-light-200-no-permission.png) | [PNG](pr980-e04b454f-ar-dark-100-no-permission.png) | [PNG](pr980-e04b454f-ar-dark-200-no-permission.png) |

The harness verifies Arabic right-to-left layout, the selected theme and text scale, the presence of the expected state, visibility of the action or permission explanation, and absence of the fixture's vault excerpt. It scrolls the alert body if needed to keep the relevant state visible.

All eight frames passed and were visually inspected. The available view keeps the Social activity button fully visible at both scales. The permission-denied view shows the complete heading and explanation and omits the button. At 200% the alert body scrolls to show that explanation. The approved copy wraps without clipping or midword breaks.

[Simulator checks](simulator-checks.txt)
