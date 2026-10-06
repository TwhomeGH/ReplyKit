"""變更歷史與開發索引工具（本機網頁 GUI + CLI）。

把原本集中在 ``Scripts/change_log.py`` 的職責拆成獨立模組，並把網頁資產從
Python 字串移出到 :mod:`changelog.assets` 底下：

* :mod:`changelog.storage`  — ``Docs/ChangeHistory.md`` 的解析、組版與讀寫
* :mod:`changelog.devindex` — 功能／API／文件／近期改動的唯讀索引
* :mod:`changelog.server`  — 本機 HTTP 伺服器與路由
* :mod:`changelog.cli`     — 命令列介面
* :mod:`changelog.assets`  — 網頁資產（HTML／CSS／JS）載入

對外仍以 ``Scripts/change_log.py`` 與 ``Scripts/dev_index.py`` 兩個入口保持相容。
"""

__all__ = ["assets", "cli", "devindex", "server", "storage"]
