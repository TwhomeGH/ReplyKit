"""開發索引：唯讀 Git／文件／宣告索引。

提供功能清單（features.json）、原始碼宣告定位（文字掃描，非 Swift AST）、
Markdown 文件內容與近期 Git 改動。功能語意由版本控管的清單提供，程式只做
定位與呈現，不推測語意。

所有 HTTP 回應皆由 :func:`route` 產生，供 :mod:`changelog.server` 轉接；頁面
資產（HTML／CSS／JS）由 :mod:`changelog.assets` 載入。
"""

import html
import json
import os
import re
import subprocess
from pathlib import Path
from urllib.parse import parse_qs, urlencode

from . import assets

# 專案根目錄（Scripts/changelog/devindex.py → 往上兩層）。
ROOT = Path(__file__).resolve().parents[2]
CATALOG = ROOT / "Docs/development/features.json"


def roots():
    """索引來源位置。底層 checkout 由環境變數指定，不依賴某台機器的磁碟配置。"""
    result = {"app": ROOT}
    external = os.environ.get("REPLYKIT_HAISHINKIT_ROOT")
    if external and Path(external).is_dir():
        result["haishinkit"] = Path(external).resolve()
    return result


def git(root, *args):
    """固定參數呼叫 Git；不透過 shell，失敗明確回報。"""
    result = subprocess.run(["git", "-C", str(root), *args], capture_output=True,
                            encoding="utf-8", errors="replace", timeout=15)
    if result.returncode:
        raise ValueError("無法讀取 Git 資訊：" + result.stderr[:200])
    return result.stdout


def files(root):
    """只索引版本控管或未忽略的 Swift／Markdown，略過隱藏設定與產物。"""
    paths = git(root, "ls-files", "--cached", "--others", "--exclude-standard", "-z").split("\0")
    return sorted({p for p in paths if p and Path(p).suffix in (".swift", ".md")
                   and not any(part.startswith(".") for part in Path(p).parts)})


def safe_file(repo, name):
    """檔案檢視僅允許索引內檔案，並阻擋路徑穿越及連到根目錄外的 symlink。"""
    root = roots().get(repo)
    if root is None or name not in files(root):
        raise ValueError("檔案不在索引範圍")
    path = (root / name).resolve()
    if not path.is_relative_to(root.resolve()) or not path.is_file() or path.stat().st_size > 2_000_000:
        raise ValueError("檔案不可讀取或超過 2 MB")
    return path


def link(repo, path, line=1):
    """檔案內某行的站內連結（以 hash 指向行號，不需重載）。"""
    return "/development/file?" + urlencode({"repo": repo, "path": path}) + "#L" + str(line)


def validate():
    """CI 驗證穩定 ID、必要欄位與 App 文件／原始碼連結。"""
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    seen = set()
    for feature in catalog:
        for field in ("id", "name", "summary", "replaykit", "screencapturekit", "ui", "verification", "files", "docs"):
            if not feature.get(field):
                raise ValueError("功能缺少欄位：" + field)
        if feature["id"] in seen:
            raise ValueError("重複功能 ID")
        seen.add(feature["id"])
        for name in feature["files"] + feature["docs"]:
            safe_file("app", name)
    return catalog


# 宣告行：修飾詞 + func/struct/class/enum/protocol/actor/extension 等。
_DECL_RE = re.compile(
    r"^\s*(?:(?:public|private|internal|fileprivate|open|final|static|class|nonisolated|override|mutating)\s+)*"
    r"(?:func|struct|class|enum|protocol|actor|extension|typealias)\s+")


def snapshot():
    """即時取得版本和近期提交；不把 Git 修改檔案推測成新增功能。"""
    data = {"features": validate(), "repos": [], "symbols": [], "documents": []}
    for repo, root in roots().items():
        data["repos"].append({"name": repo, "head": git(root, "rev-parse", "HEAD").strip(),
            "changes": git(root, "status", "--short"),
            "commits": git(root, "log", "-20", "--date=iso-strict", "--format=%h %ad %s", "--name-only")})
        for name in files(root):
            try:
                path = (root / name).resolve()
                if not path.is_relative_to(root.resolve()) or path.stat().st_size > 2_000_000:
                    continue
                text = path.read_text(encoding="utf-8", errors="replace")
            except (ValueError, OSError):
                continue
            if name.endswith(".md"):
                data["documents"].append({"name": name, "repo": repo, "url": link(repo, name),
                                          "text": text[:100000]})
                continue
            comments = []
            for number, line in enumerate(text.splitlines(), 1):
                if line.strip().startswith("///"):
                    comments.append(line.strip()[3:].strip())
                    continue
                # 文字掃描提供定位，不冒充 Swift AST 或完整呼叫關係。
                if _DECL_RE.match(line):
                    data["symbols"].append({"name": line.strip(), "repo": repo, "file": name,
                        "line": number, "comment": " ".join(comments), "url": link(repo, name, number)})
                if line.strip():
                    comments = []
    lock = json.loads((ROOT / "Package.resolved").read_text(encoding="utf-8"))
    data["lockedPackages"] = [{"identity": p["identity"], "revision": p["state"].get("revision")}
                              for p in lock["pins"]]
    return data


def _file_page(repo, name, line):
    """組出檔案檢視頁（含行號與目標行）。"""
    source = safe_file(repo, name).read_text(encoding="utf-8", errors="replace")
    content = "".join(
        '<span id="L%d"><a href="#L%d">%5d</a>%s</span>' % (i, i, i, html.escape(text))
        for i, text in enumerate(source.splitlines(), 1)
    )
    return assets.render(
        "file.html",
        title=html.escape(name), repo=html.escape(repo), path=html.escape(name),
        line=str(line), content=content)


def route(path, query):
    """回傳 (HTTP 狀態, 內容, MIME)，由既有本機工具提供服務。"""
    try:
        if path == "/development":
            return 200, assets.read("dev.html"), "text/html; charset=utf-8"
        if path == "/development/data":
            return 200, json.dumps(snapshot(), ensure_ascii=False), "application/json; charset=utf-8"
        if path == "/development/file":
            values = parse_qs(query)
            repo = values.get("repo", ["app"])[0]
            name = values.get("path", [""])[0]
            line_arg = values.get("line", [""])[0]
            line = int(line_arg) if line_arg.isdigit() else 0
            return 200, _file_page(repo, name, line), "text/html; charset=utf-8"
    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
        return 400, json.dumps({"error": str(error)}, ensure_ascii=False), "application/json; charset=utf-8"
    return 404, "找不到頁面", "text/plain; charset=utf-8"


if __name__ == "__main__":
    print("功能索引驗證通過：", len(validate()), "項")
