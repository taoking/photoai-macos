#!/usr/bin/env python3
"""按文件名批量给照片打分，直接操作 Catalog 数据库。

存在的理由：应用运行时把整个 Catalog 持在内存里，并按行增量写回。一次
`updateAssetMetadata` 会把 rating/flag/颜色标签/备注/收藏/配方/导出时间七个字段
一起写出，取的全是内存里的值。所以外部进程改了评分之后，只要在界面上碰一下
同一张照片，那个评分就会被静默覆盖——因此本脚本只在应用关闭时工作，并自己检查。

匹配规则是文件名精确匹配，同名的全部打同一个分。这条在本机数据上验证过：
425 个重名组的文件大小与拍摄时间全部一致，即同名确实是同一张照片的多份备份。
但这是"当时成立"，换机身或计数器归零就可能出现真正的撞名，所以每次运行都会
复验这个不变量，不一致就停下来报出来。
"""

import argparse
import os
import sqlite3
import subprocess
import sys
from datetime import datetime

DEFAULT_DB = os.path.expanduser(
    "~/Library/Application Support/PhotoAI-Mac/catalog.sqlite"
)


def fail(message):
    print(f"错误：{message}", file=sys.stderr)
    sys.exit(1)


def app_is_running():
    """应用是否在跑。exit code 0 表示 pgrep 找到了进程。"""
    return subprocess.run(
        ["pgrep", "-x", "PhotoAIMac"],
        capture_output=True,
    ).returncode == 0


def connect(db_path):
    if not os.path.exists(db_path):
        fail(f"找不到数据库：{db_path}")
    connection = sqlite3.connect(db_path)
    connection.row_factory = sqlite3.Row
    return connection


def backup(db_path):
    """用 SQLite 自己的备份接口，这样 WAL 里尚未合并的内容也会包含进来。"""
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    backup_path = f"{db_path}.backup-{stamp}"
    source = sqlite3.connect(db_path)
    destination = sqlite3.connect(backup_path)
    with destination:
        source.backup(destination)
    destination.close()
    source.close()
    return backup_path


def lookup(connection, names):
    """返回 {文件名: [行, ...]}，未命中的名字对应空列表。"""
    found = {name: [] for name in names}
    placeholders = ",".join("?" * len(names))
    rows = connection.execute(
        f"""
        SELECT a.filename, a.id, a.rating, a.file_size, a.capture_date,
               a.relative_path, s.display_name AS source_name
        FROM assets a JOIN sources s ON s.id = a.source_id
        WHERE a.filename IN ({placeholders})
        ORDER BY a.filename, s.display_name, a.relative_path
        """,
        names,
    ).fetchall()
    for row in rows:
        found[row["filename"]].append(row)
    return found


def inconsistent_groups(found):
    """同名但大小或拍摄时间不同的组——这些不该被当成同一张照片。"""
    bad = {}
    for name, rows in found.items():
        if len(rows) < 2:
            continue
        sizes = {row["file_size"] for row in rows}
        dates = {row["capture_date"] for row in rows}
        if len(sizes) > 1 or len(dates) > 1:
            bad[name] = rows
    return bad


def report_lookup(found):
    matched = [name for name, rows in found.items() if rows]
    missing = [name for name, rows in found.items() if not rows]
    total_rows = sum(len(rows) for rows in found.values())

    for name in sorted(matched):
        rows = found[name]
        detail = ", ".join(
            f'{row["source_name"]}/{row["relative_path"]}（当前 {row["rating"]} 星）'
            for row in rows
        )
        print(f"  ✓ {name}  ×{len(rows)}  {detail}")
    for name in sorted(missing):
        print(f"  ✗ {name}  库中不存在")

    print(f"\n命中 {len(matched)} 个名字 / 共 {total_rows} 条记录；未找到 {len(missing)} 个。")
    return missing


def read_names_file(path):
    """每行一个文件名；空行和 # 开头的行忽略。"""
    with open(path, encoding="utf-8") as handle:
        return [
            line.strip()
            for line in handle
            if line.strip() and not line.lstrip().startswith("#")
        ]


def main():
    parser = argparse.ArgumentParser(
        description="按文件名批量给照片打分（需先关闭 PhotoAI Mac）"
    )
    parser.add_argument("names", nargs="*", help="照片文件名，如 DSC01926.JPG")
    parser.add_argument("--set", type=int, metavar="N", help="要打的星级 0-5；省略则只查询")
    parser.add_argument(
        "--query", action="store_true", help="只查询，不写入（省略 --set 时的默认行为）"
    )
    parser.add_argument("--from-file", metavar="FILE", help="从文件读取文件名，每行一个")
    parser.add_argument("--db", default=DEFAULT_DB, help="数据库路径")
    parser.add_argument("--dry-run", action="store_true", help="只预演，不写入")
    parser.add_argument(
        "--force",
        action="store_true",
        help="即使发现同名文件的大小或拍摄时间不一致也继续",
    )
    args = parser.parse_args()

    names = list(args.names)
    if args.from_file:
        names += read_names_file(args.from_file)
    names = list(dict.fromkeys(names))  # 去重并保持顺序
    if not names:
        fail("没有给出任何文件名。")

    if args.query and args.set is not None:
        fail("--query 与 --set 不能同时使用。")
    if args.set is not None and not 0 <= args.set <= 5:
        fail(f"星级必须在 0 到 5 之间，收到 {args.set}。")

    writing = args.set is not None and not args.dry_run
    # 只有写应用真正在用的那个库才需要拦：对副本演练时应用开着也无所谓。
    targets_live_db = os.path.realpath(args.db) == os.path.realpath(DEFAULT_DB)
    if writing and targets_live_db and app_is_running():
        fail(
            "PhotoAI Mac 正在运行。\n"
            "       应用把整个 Catalog 持在内存里并按行写回，此时外部写入的评分\n"
            "       会在你下次触碰同一张照片时被静默覆盖。请先退出应用再运行。"
        )

    connection = connect(args.db)
    found = lookup(connection, names)

    print(f"查询 {len(names)} 个文件名：")
    missing = report_lookup(found)

    bad = inconsistent_groups(found)
    if bad:
        print("\n⚠️  以下同名文件的大小或拍摄时间不一致，可能并不是同一张照片：")
        for name, rows in sorted(bad.items()):
            print(f"  {name}")
            for row in rows:
                print(
                    f"      {row['source_name']}/{row['relative_path']}"
                    f"  {row['file_size']} 字节  capture_date={row['capture_date']}"
                )
        if not args.force:
            fail("为避免给不同的照片打上同一个分数，已中止。确认无误可加 --force。")
        print("  （--force 已指定，继续执行）")

    if args.set is None:
        print("\n未指定 --set，仅查询。")
        return

    target_names = [name for name, rows in found.items() if rows]
    if not target_names:
        fail("没有任何文件名命中，无事可做。")

    if args.dry_run:
        affected = sum(len(found[name]) for name in target_names)
        print(f"\n[预演] 将把 {affected} 条记录设为 {args.set} 星，未写入任何内容。")
        return

    backup_path = backup(args.db)
    print(f"\n已备份数据库到：{backup_path}")

    with connection:
        connection.executemany(
            "UPDATE assets SET rating = ? WHERE filename = ?",
            [(args.set, name) for name in target_names],
        )
    # 让主库文件包含全部改动，应用下次打开时直接可见。
    connection.execute("PRAGMA wal_checkpoint(TRUNCATE);")

    verified = connection.execute(
        f"""
        SELECT COUNT(*) FROM assets
        WHERE rating = ? AND filename IN ({",".join("?" * len(target_names))})
        """,
        [args.set, *target_names],
    ).fetchone()[0]
    expected = sum(len(found[name]) for name in target_names)

    print(f"已将 {verified} / {expected} 条记录设为 {args.set} 星。")
    if verified != expected:
        fail("写入后校验数量不符，请检查备份并排查。")
    if missing:
        print(f"提醒：有 {len(missing)} 个名字未找到，它们未被修改。")
    connection.close()


if __name__ == "__main__":
    main()
