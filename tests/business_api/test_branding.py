from app.core.branding import (
    CAIBI_ASSET_CODE,
    CAIBI_DISPLAY_NAME,
    CAIBI_SCALE,
    PRODUCT_NAME,
    PRODUCT_SLUG,
    USDT_ASSET_CODE,
    USDT_SCALE,
)


def test_public_and_internal_product_contract_is_stable() -> None:
    assert PRODUCT_NAME == "六合通"
    assert PRODUCT_SLUG == "liuhetong"
    assert CAIBI_ASSET_CODE == "CAIBI"
    assert CAIBI_DISPLAY_NAME == "彩币"
    assert CAIBI_SCALE == 2
    assert USDT_ASSET_CODE == "USDT_TRC20"
    assert USDT_SCALE == 6
