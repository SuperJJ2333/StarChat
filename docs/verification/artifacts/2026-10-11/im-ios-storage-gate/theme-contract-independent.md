# Independent SPEC → QUALITY review: startup theme static contract

Verdict: **PASS** for root's test-only correction. Reviewed root HEAD `9902d35079e9cb051125808a251ae479b06893cb` plus the current five-insertion/one-deletion diff in `tests/mobile/test_figma_ui_contract.py`. No main/theme production diff exists in this correction. No tests were rerun for this review.

SPEC: the sole broad-gate failure is the stale literal `await themeController.load()` at test line 227. Actual `prepareApplication` constructs `loadedThemeController` with `SharedPreferencesThemePreferenceStore`, awaits its load at main line 108, publishes that same instance at line 130, then sets `shellPrepared = true` at line 131. The changed assertion checks the actual name and additionally enforces that ordering. It does not remove loading, persistence or readiness requirements. The startup shell uses the prepared controller only after readiness.

QUALITY: `ThemeController.load` still reads the stored system/light/dark selection; writes still require successful `setString`, and write failures restore the previous setting with a visible error. Root `LiuhetongApp` resolves the selected preference against platform brightness at line 458. The existing feature-wide prohibition on `MediaQuery.platformBrightnessOf` remains unchanged, and source search finds `themeController.resolve` only at the root. This is a static-contract false positive caused by the local variable rename, not evidence of lost theme persistence. The static test remains a source-structure guard rather than a substitute for runtime theme tests.

Evidence inspected: `im-reliability-release/boundaries-final.log` reports **400 passed / 1 failed / 1 skipped**, with the only failure exactly the old literal. `theme-contract-corrected.txt` reports **10 passed in 0.54s**. These are recorded independently: the corrected file passed; this review does not relabel the earlier full run as an all-green rerun or turn its skip into a pass.

SHA256 of reviewed workspace bytes:

- `tests/mobile/test_figma_ui_contract.py`: `5ccb00636e64dba5b00e0344790893c5473c29f657b9a85d1b788ae1508bf073`
- `apps/mobile_flutter/lib/main.dart`: `9c81b9e8dc21432bb399c0a41eac9e60d7b8030ca8bf096f27d9f58dcbbdd35b`
- `apps/mobile_flutter/lib/ui/theme/theme_controller.dart`: `1683718b2b8989bee1e9f82cfd22c8c7fe8a72e803913fbcac8a7b9ea1509835`
- `boundaries-final.log`: `d5c3358ba8bfb0478dde3a2549b925dfbedd8bca9a9c833313995cdde3c34b76`
- `theme-contract-corrected.txt`: `60738f70dec0c9b02ae57bb066a73b913e49ba391365911aec7738bf6e429ed0`
