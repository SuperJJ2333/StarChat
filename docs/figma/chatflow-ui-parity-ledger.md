# ChatFlow UI parity ledger

## 2026-08-25 — 朋友圈发表与可见范围

| Surface | Approved visual decision | Flutter delivery | Tests | Figma status |
| --- | --- | --- | --- | --- |
| 朋友圈发表 | 严格微信式；正文/九宫格；仅“谁可以看 / 添加链接” | `MomentComposerPage` | `moment_composer_page_test.dart` | Existing Moments node `29:5798`; remote update blocked because no Figma tool was exposed |
| 谁可以看 | 公开/私密为第一组；12px 间隔；只给谁看/不给谁看为二级菜单 | `MomentVisibilityPage` | `moment_visibility_page_test.dart` | Same limitation; no fabricated node or screenshot |
| 选择标签或朋友 | 标签/朋友双列、搜索、多选、选择计数、完成；Back 丢弃未完成修改 | `MomentVisibilityPeoplePage` | `moment_visibility_people_page_test.dart` | Same limitation; no fabricated node or screenshot |

Approved browser comparison artifacts were produced in the ignored local visual-companion session `.superpowers/brainstorm/visual-1787584951/`. The governing behavior and wireframe decisions are versioned in `docs/superpowers/specs/2026-08-25-identity-conversation-moments-composer-design.md`, so implementation review does not depend on an uncommitted bitmap.

The existing verified Figma contract remains `docs/verification/figma-mobile-screen-contract.csv`, where Moments maps to page `50 Discovery & Moments`, node `29:5798`. This entry records the real delivery limitation and does not claim that the remote Figma file was changed.
