### Child agent — a protection alert names every screen tried in its window (1.1)
- Repeated attempts stay one alert per five minutes (#227), but the window now keeps each distinct screen
  (`deactivate_admin`, `space_setup`, …) and the aggregate body lists them as the parent reads them
  ("Screens tried: device admin, second space setup."). Before, a second kind of attempt
  inside the window only raised the count, so the parent never saw it (Flip4 run, 10 Nov).
- The list is persisted with the window and capped at 8. New `GuardAttemptScreensTest`.
