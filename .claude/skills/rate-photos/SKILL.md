---
name: rate-photos
description: 按文件名批量给 PhotoAI Mac 图库中的照片打星级，或查询照片是否存在、当前几星。当用户给出一批照片文件名（如 DSC01926.JPG）并要求打分、查询评分、确认照片是否在库中时使用。
---

# 批量给照片打分

用户给一批文件名和一个星级，本技能把它写进 PhotoAI Mac 的 Catalog 数据库。
同一批文件用同一个分数——这是用户确认过的用法。

## 唯一入口

```sh
Scripts/rate-photos.py --query DSC01926.JPG DSC01927.JPG    # 查询：是否存在、当前几星、在哪些来源
Scripts/rate-photos.py --set 4 DSC01926.JPG DSC01927.JPG    # 打分
Scripts/rate-photos.py --set 4 --from-file names.txt        # 批量，每行一个文件名
Scripts/rate-photos.py --set 4 --dry-run DSC01926.JPG       # 预演
```

**不要手写 SQL 去改 `rating`。** 脚本里的四道检查（应用是否在运行、自动备份、
同名一致性复验、写后校验）都是有具体原因的，绕过去就等于把那些原因重新踩一遍。
只读查询可以直接用 sqlite3，写入必须走脚本。

## 执行前必须做的两件事

1. **确认应用已退出。** 脚本会自己检查并拒绝，但提前告诉用户能省一轮往返：

   ```sh
   pgrep -x PhotoAIMac && echo "应用在运行，需要先退出"
   ```

2. **先 `--query` 再 `--set`。** 把命中情况摆给用户看——尤其是**没找到的名字**和
   **一个名字对应多条记录**的情况——确认后再写。用户给 50 个名字而其中 3 个不存在时，
   他必须看得见。

## 为什么写入不能在应用运行时进行

`CatalogStore` 启动时把整个 Catalog 读进内存，之后按行增量写回。一次
`updateAssetMetadata` 会把 rating、flag、颜色标签、备注、收藏、调整配方、导出时间
**七个字段一起写出，取的全是内存里的值**。

所以外部进程改了评分之后，只要用户在界面上碰一下同一张照片（哪怕只是按个 P），
应用就会把内存里的旧评分连同其他字段一起写回去——**评分消失，且没有任何提示**。
应用在重启前也看不到外部改动。

## 为什么同名全部打分是安全的

匹配规则是文件名精确匹配，同名的全部打同一个分。用户的库里同名文件是同一张照片的
多份备份（都来自同一台相机导出）。这条在真实数据上验证过：425 个重名组的**文件大小
与拍摄时间全部一致，零例外**。

但这是"当时成立"。换机身或计数器归零就可能出现真正的撞名，所以脚本每次运行都会复验
这个不变量，发现不一致就停下来把两边摊开给用户看，需要 `--force` 才继续。
**不要习惯性地加 `--force`**——它响起来的时候多半是真出事了。

## 只读查询

读不受上述限制（SQLite WAL 允许并发读），应用开着也能查：

```sh
sqlite3 ~/Library/Application\ Support/PhotoAI-Mac/catalog.sqlite \
  "SELECT a.filename, s.display_name, a.relative_path, a.rating
   FROM assets a JOIN sources s ON s.id = a.source_id
   WHERE a.filename = 'DSC01926.JPG';"
```

常用字段：`rating`(0-5)、`flag`('none'/'picked'/'rejected')、`color_label`、`comment`、
`exported_at`、`capture_date`（SQLite 里是 Apple 纪元，转换用 `capture_date + 978307200`）。

## 范围

本技能只做"用户定分数、脚本执行"。看图评分是另一回事：项目有一条既有原则是
**AI 的建议必须可解释且不自动改动评分**（`CleanupWorkflowStore`、`CullingWorkflowStore`
都只产出候选列表）。真要做看图评分，应当产出建议加理由、由用户确认后再走本脚本。
