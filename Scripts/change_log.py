#!/usr/bin/env python3
"""變更歷史工具 — 進入點（薄殼）。

實作已拆分到 ``Scripts/changelog/`` 套件：

* :mod:`changelog.storage`  變更歷史資料層
* :mod:`changelog.devindex` 功能／API／文件／近期改動索引
* :mod:`changelog.server`   本機 HTTP 伺服器
* :mod:`changelog.cli`      命令列介面
* :mod:`changelog.assets`   網頁資產載入

此檔保留為穩定入口，並重新匯出舊有符號以維持相容（測試與腳本可直接呼叫）。

用法:
  python Scripts/change_log.py                 # 啟動本機網頁 GUI（自動開瀏覽器）
  python Scripts/change_log.py serve --port 8765 --no-browser
  python Scripts/change_log.py add "修復 xxx" [--type 修復] [--file path] [--date YYYY.MM.DD] [--time HH:MM] [--ref '[說明](路徑)']
  python Scripts/change_log.py list [--grep 關鍵字] [--since 2026.06.01] [--type 修復] [--file Socket]
  python Scripts/change_log.py show <編號|關鍵字>

資料檔: Docs/ChangeHistory.md（最新在最上面）。零外部依賴。
"""

import os
import sys

# 讓 `python Scripts/change_log.py` 與 `import change_log` 都能解析到 changelog 套件。
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from changelog import assets, cli, devindex, server, storage  # noqa: E402,F401
from changelog.cli import cmd_add, cmd_list, cmd_show, main  # noqa: E402,F401
from changelog.server import Handler, _Server, serve  # noqa: E402,F401
from changelog.storage import (  # noqa: E402,F401  （重新匯出，維持相容）
    HISTORY,
    ROOT,
    build_block,
    delete_entry,
    git_changed_files,
    insert_block,
    parse_entries,
    read_history,
    update_entry,
)

if sys.platform == "win32":
    sys.stdout.reconfigure(encoding="utf-8")


if __name__ == "__main__":
    main()
