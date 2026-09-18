# android-ci 守卫测试被自己改红：修复记录（提交 `250ccc79`）

- 日期：2026-09-18（Asia/Hong_Kong）
- 现象：CI 在**仓库 Python 守卫测试**阶段失败，而非 Flutter 测试失败。
- 失败断言：`tests/mobile/test_android_ci_workflow.py:21`

```python
assert "run: flutter test" in ci
```

## 1. 原因（我的责任）

上一步为了**让下一次 CI 失败可被定位**，把全量测试步骤从单行改成多行 shell 块
（捕获完整日志、汇总真正的失败用例、上传 artifact）：

```yaml
- name: Test (full suite)
  run: |
    set -o pipefail
    ...
    flutter test 2>&1 | tee "$log"
```

工作流里仍然**包含** `flutter test`，但不再包含那个精确子串 `run: flutter test`。
该断言钉住的是「单行 `run:` 的写法」，而不是守卫注释里写明的意图：

> 全量测试必须存在（不得被降级为 analyze-only）

即：**守卫的本意是对的，被钉住的实现细节被我改掉了。**

## 2. 修复（提交 `250ccc79`）

按守卫的**意图**重写，并且比原来更严：

| 断言 | 作用 |
| --- | --- |
| `"flutter test" in ci` | 全量测试必须存在于门禁中 |
| 可执行行检查：含 `flutter test` 且**不以 `#` 开头**的非空行必须存在 | 不得被注释掉 |
| 该行必须等于 `flutter test 2>&1 | tee "$log"` | 必须**真的执行**，而不是只出现在注释/字符串里 |
| `"flutter analyze" in ci` | analyze 步骤不得被测试步骤吞掉 |
| `"full-suite.log" in ci` | 完整日志捕获不得被删 |
| `"Failing tests:" in ci` 且 `"sed -n '/^Failing tests:/,$p'" in ci` | 失败用例清单的**提取逻辑**必须在（断言落在提取逻辑上，而不是某条 echo 文案上） |

没有采用「把工作流降级回 `run: flutter test`」的方案：那会删掉日志捕获与失败用例汇总，
正是这次能定位问题所依赖的能力。

## 3. 验证

| 项目 | 命令 | 结果 |
| --- | --- | --- |
| 真实基线（工作流已改 + 守卫未改） | 把守卫回退到 HEAD 版后 `pytest tests/mobile/test_android_ci_workflow.py` | **1 failed, 8 passed**（`AssertionError` at line 21）——复现 CI 失败 |
| 修复后 | 同上 | **9 passed** |
| 用 **origin/main 的守卫**实跑 | 取出 `origin/main:tests/mobile/test_android_ci_workflow.py` 覆盖后运行 | **9 passed**（确认推送的版本确实通过） |
| 变异 1：注释掉 `flutter test` | 改工作流后跑守卫 | **转红** |
| 变异 2：破坏失败用例提取（`sed` → `cat`） | 同上 | **转红** |
| 变异 3：删掉日志捕获（`full-suite.log` 改名） | 同上 | **转红** |
| 复原 | 同上 | **9 passed** |

推送：`250ccc79`；`origin/main...main = 0 0`。

## 4. 一处需注意的甄别：`tests/mobile` 里另有一个**无关**失败

`python -m pytest tests/mobile -q` 当前为 `1 failed, 69 passed`，失败项是：

```
tests/mobile/test_getui_privacy.py::test_secret_literals_absent_from_repository
FileNotFoundError: ... 'docs\\verification\\artifacts\\2026-09-11\\finance-chat'
```

- 该目录在本机**是存在的**，报错形态（`rglob` 触发 `WinError 3`）指向 Windows 路径长度/遍历限制，
  属**环境性偶发**；
- 与本任务无关：该测试扫描仓库机密字面量，既不读 `.github/workflows`，也不读 Flutter 代码；
- 本次两处改动（`.github/workflows/android-ci.yml`、`tests/mobile/test_android_ci_workflow.py`）
  都不参与它的扫描输入。

因此**不能**把 `tests/mobile` 的整体绿灯算作本次修复的前置条件；本任务相关守卫
`tests/mobile/test_android_ci_workflow.py` 已 9/9 通过。

## 5. 未验证

- CI 侧要在下一次运行确认：守卫通过 + 全量 Flutter 测试步骤仍按新形态执行
  （失败时会输出失败用例清单）。
- 上一轮 `bd28dbff` 引入的「失败用例汇总」是否真能在真实失败时产出可用输出，
  需等一次真实失败才能看到实际效果；本轮已用 stub `flutter` 验证成功/失败两条路径的
  退出码与汇总写入（见 `docs/verification/artifacts/2026-09-18/ci-flutter-failure-diagnostics/check_workflow.py`）。
