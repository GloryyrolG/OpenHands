# prompt-plugin 分支设计文档

**日期**: 2026-03-10
**状态**: 已批准

## 目标

从 `multiuser`（即 cda-demo）切出独立的 `prompt-plugin` 分支，用于 prompt plugin 功能内测实验，与 cda-demo 生产部署完全隔离，互不影响。

## 隔离资源对照表

| 配置项 | cda-demo（multiuser） | prompt-plugin（新） |
|--------|----------------------|---------------------|
| App 端口 | 3005 | 3007 |
| 容器名 | `openhands-app-multi` | `openhands-app-pp` |
| Agent 前缀 | `oh-multi-` | `oh-pp-` |
| Persistence 目录 | `~/.openhands-multi` | `~/.openhands-pp` |
| Ingress 名称 | `openhands-multi` | `openhands-pp` |
| 本地隧道端口 | 3006 | 3008 |

## 需要创建/修改的文件

1. **新建** `setup-openhands-klogin-pp.sh` — 复制自 `setup-openhands-klogin-multi.sh`，替换所有资源标识符
2. **修改** `setup-openhands-klogin.md` — README 表格新增 `prompt-plugin` 行（若该文件存在于分支）

## 分支策略

```
multiuser  ──────────────────────────────►  (cda-demo 生产, 不动)
                 │
                 └──► prompt-plugin         (内测实验, 独立演进)
```

## 隔离保证

- 不同端口（3007 vs 3005）：两实例可在同一 klogin 机器同时运行
- 不同容器名 / agent 前缀：`docker ps` 互不干扰
- 不同 persistence 目录：用户数据、SQLite DB、对话文件完全分开
- 不同 ingress 域名：访问 URL 不重叠
