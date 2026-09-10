# StarChat Product Language

This glossary fixes user-facing product and asset terms while preserving the established encrypted-communications and financial-domain identifiers.

## Product and identity

**畅聊 ChatFlow**:
The user-visible product name. Main product titles and store-facing application labels use the full name; constrained in-product copy may use “畅聊”.
_Avoid_: 六合通

**畅聊号**:
The user-visible identifier label for a ChatFlow account username.
_Avoid_: ChatFlow号, 用户ID

## Assets

**点钻**:
The sole user-visible name for the two-decimal internal CAIBI asset, including balances, transfers, red packets, receipts, notifications, email, admin UI, and the HTML demo.
_Avoid_: 彩币, CAIBI（用户界面中）

**CAIBI**:
The immutable internal asset code for 点钻. It identifies the existing ledger, API asset values, event schemas, database records, and migration history.
_Avoid_: 点钻（内部资产代码）

**USDT**:
The six-decimal TRC20 custody asset. It remains isolated from CAIBI/点钻.
_Avoid_: 点钻兑换, USDT 转点钻

## UI delivery

**UI contract**:
The checked Flutter–HTML registry that declares a component’s public name, files, HTML tag, props, variants, states, and token mappings. Figma keys and the Figma export ledger are retired; the registry rejects them.
_Avoid_: 临时页面样式, 未登记组件, Figma 台账

**HTML design demo**:
The Flutter-side HTML demo under `frontend/` (catalog screens, tokens, demo page `frontend/index.html`). It is the visual source of record for UI review and is updated in the same change as the Flutter implementation.
_Avoid_: 截图口头评审, 无 demo 的 UI 变更

**UI design reviewer**:
The developer role that checks the HTML demo’s design quality and reports defects. It does not update component contracts.
_Avoid_: Figma 同步负责人
