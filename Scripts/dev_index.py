"""開發索引 — 相容入口（薄殼）。

實作在 :mod:`changelog.devindex`；此檔重新匯出公開符號，讓舊有的
``import dev_index`` 呼叫端（含測試）維持可用。

直接執行可驗證 features.json：``python Scripts/dev_index.py``。
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

if sys.platform == "win32":
    sys.stdout.reconfigure(encoding="utf-8")

from changelog.devindex import (  # noqa: E402,F401
    CATALOG,
    ROOT,
    files,
    git,
    link,
    roots,
    route,
    safe_file,
    snapshot,
    validate,
)

if __name__ == "__main__":
    print("功能索引驗證通過：", len(validate()), "項")
