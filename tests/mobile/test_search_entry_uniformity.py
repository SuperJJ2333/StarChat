"""搜索入口统一 + 导航标题过渡的源码契约。

验收标准（缺陷精准化后的可执行条款）：
- 「消息 / 通讯录 / 发现」三个 Tab 根页的搜索 icon 必须都构造
  GlobalSearchPage 且传入同一个 Matrix 数据源参数（matrix:），
  即统一指向同一"搜索"页面（页面 ID：global-search-nav）；
- 四个相关导航栏（三个 Tab 根页 + 统一搜索页）声明
  transitionBetweenRoutes: false，标题不再做 Hero 飞行，
  随页面标准转场（约 300ms 滑入）整体出现，无空白停顿与跳变。
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MOBILE = ROOT / "apps" / "mobile_flutter" / "lib"


def _read(relative: str) -> str:
    return (MOBILE / relative).read_text(encoding="utf-8")


def test_all_three_tab_search_entries_push_the_same_global_search_page():
    sources = [
        "features/matrix/matrix_home_page.dart",
        "features/contacts/contacts_page.dart",
        "features/discovery/discovery_page.dart",
    ]
    for relative in sources:
        source = _read(relative)
        matches = re.findall(r"GlobalSearchPage\((.*?)\)", source, re.S)
        assert matches, f"{relative} must open GlobalSearchPage"
        for call in matches:
            assert "api:" in call, f"{relative} GlobalSearchPage needs api:"
            assert "matrix:" in call, (
                f"{relative} GlobalSearchPage must pass the same matrix "
                "data source so every entry opens an identical search page"
            )


def test_nav_bars_skip_the_hero_flight_to_avoid_blank_title_gaps():
    sources = [
        "features/matrix/matrix_home_page.dart",
        "features/contacts/contacts_page.dart",
        "features/discovery/discovery_page.dart",
        "features/search/global_search_page.dart",
    ]
    for relative in sources:
        assert "transitionBetweenRoutes: false" in _read(relative), (
            f"{relative} nav bar must set transitionBetweenRoutes: false "
            "so the title appears with the page slide (no blank gap)"
        )


def test_global_search_page_exposes_matrix_data_source_and_stable_id():
    source = _read("features/search/global_search_page.dart")
    assert "this.matrix" in source, "GlobalSearchPage needs a matrix source"
    assert "Key('global-search-nav')" in source, (
        "unified search page must carry the global-search-nav id"
    )
