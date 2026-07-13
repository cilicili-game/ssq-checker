# ssq-checker

[![营收看板](https://img.shields.io/badge/%E8%90%A5%E6%94%B6%E7%9C%8B%E6%9D%BF-Pages-2ea44f?style=flat-square&logo=github)](https://cilicili-game.github.io/ssq-checker/)

中国福利彩票双色球（SSQ）结果查询 + 中奖比对工具。**纯 Python stdlib，零运行时依赖。**

## 为什么有这个 repo

原本是 Hermes 上一个调 AI 的 cron job：抓官网 → 比对号码 → 发消息。但这件事根本不需要 AI 判断，规则全部硬编码就行。剥离成独立 repo 可以：

- 零 token 烧钱，跑得快、确定
- 可被多种调度方式调用：本地 cron、Hermes cron `no_agent=True` 模式、GitHub Actions
- 单测覆盖所有奖级，规则有问题立刻能查出来

## 数据源

`https://www.17500.cn/getData/ssq.TXT` — 唯一靠谱的、可 curl 直拉的双色球开奖数据源。`cwl.gov.cn` 官网会 403 屏蔽机房 IP，`datachart.500.com` 是 SPA 拉不到内容。详见 `chinese-lottery-data` 技能。

## 安装

```bash
pip install -e .
```

或不安装直接跑（无依赖）：

```bash
PYTHONPATH=src python -m ssq_checker
```

## 投注表

把你买的号码记在 `bets.csv` 里，随时改这个文件就改了投注。一注 2 元，**一期金额 = 2 × 倍数自动算**：

```csv
红球,蓝球,倍数
01 02 03 04 08 09,07,1
05 12 18 22 27 33,11,2
```

- 红球：6 个不重复的 1-33，空格分隔，放一个单元格
- 蓝球：1 个 1-16
- 倍数：整数，留空默认 1
- `#` 开头的行和空行会被忽略

可以用 Excel/Numbers 打开编辑，也可以直接文本编辑。

## 使用

只要 `bets.csv` 存在，默认就读它、逐注比对、汇总总投入和总中奖：

```bash
ssq-checker
```

一次性查某组号码（不动投注表）：

```bash
ssq-checker --reds 05 12 18 22 27 33 --blue 11
```

指定别的投注表：

```bash
ssq-checker --bets my-bets.csv
```

JSON 输出（适合管道/解析）：

```bash
ssq-checker --json
```

## 输出示例

读投注表（默认）：

```
🎱 双色球第2026070期开奖（06月21日）

🔴 红球：01 02 03 14 15 16
🔵 蓝球：07

你的投注（共2注，总投入 ¥6）：

① 🔴 01 02 03 04 08 09  🔵 07  ×2倍（¥4）
   红球3个（01 02 03）｜蓝球✅ → 🎉 五等奖（¥10 ×2 = ¥20）
② 🔴 05 12 18 22 27 33  🔵 11  ×1倍（¥2）
   红球0个｜蓝球❌ → 未中奖

总中奖：¥20
```

## 测试

```bash
pip install -e .[dev]
pytest -v
```

覆盖：每个奖级（一到六等奖、不中）+ 数据解析 + 数字规范化。

## 调度

### 本地 cron

```cron
0 22 * * 0,2,4  ssq-checker | tee -a ~/lottery.log
```

### Hermes cron（`no_agent=True`，零 token）

```python
cronjob(action='create', name='双色球',
        schedule='0 22 * * 0,2,4',
        no_agent=True,
        script='/home/logan/Projects/ssq-checker/run.sh',
        deliver='telegram:-1004407117408')
```

`run.sh` 内容：

```bash
#!/usr/bin/env bash
exec /home/logan/Projects/ssq-checker/venv/bin/ssq-checker
```

### 本机 cron 推送（当前采用）

GitHub Actions 播报已退役，改为在本机用 cron 跑 `scripts/notify_local.sh` 推 Telegram。
幂等由 CLI 保证：`ssq-checker --telegram --notify-new --state-file <f>` 只拉取一次、期号比上次回执更新才推送，成功后原子写回执（详见脚本注释与 `CLAUDE.md`）。凭据放仓库根 `.env`（gitignore、chmod 600）。

```cron
*/15 21-23 * * 0,2,4 /path/to/ssq-checker/scripts/notify_local.sh >> /path/to/logs/cron_wrapper.log 2>&1
```

## 营收看板（GitHub Pages）

`--sync-history` 会把开奖结果记进**按月分区的历史**（`docs/data/YYYY-MM.json`），显示累计盈亏（挣还是亏）、曲线图、每期明细。数据在本机生成并 commit 进仓库，Pages 直接从 `master` 分支的 `/docs` 目录托管（**不跑任何 CI**）。

关键设计：**每条记录按当时的号码和倍数冻结保存**。以后改 `bets.csv` 换号码，只影响之后的新期，过去的营收不会被重算。

启用步骤：

1. **Settings → Pages → Source** 选 **Deploy from a branch**，分支 `master`、目录 `/docs`。
2. 本机跑一次 `ssq-checker --sync-history` 回填 `docs/data/`，commit 后推上去即可。
3. 之后每次本机同步 + push 页面即更新。

页面地址：`https://cilicili-game.github.io/ssq-checker/`。

手动同步历史（写到 `docs/data/`）：

```bash
ssq-checker --sync-history                       # 默认自 2025-01-01 起
ssq-checker --sync-history --start-date 2025-03-01
```

### 命令行手动投递

```bash
TELEGRAM_BOT_TOKEN=xxx TELEGRAM_CHAT_ID=-1004407117408 ssq-checker --telegram
```

`--telegram` 会在打印报告之外，额外把同一份报告发到 Telegram。凭据缺失或投递失败时进程返回退出码 3。

## 奖级表（参考）

| 红球命中 | 蓝球命中 | 奖级 | 金额 |
|---------|---------|------|------|
| 6 | ✅ | 一等奖 | 奖池/浮动 |
| 6 | ❌ | 二等奖 | 奖池/浮动 |
| 5 | ✅ | 三等奖 | ¥3,000 |
| 5 | ❌ | 四等奖 | ¥200 |
| 4 | ✅ | 四等奖 | ¥200 |
| 4 | ❌ | 五等奖 | ¥10 |
| 3 | ✅ | 五等奖 | ¥10 |
| 2 | ✅ | 六等奖 | ¥5 |
| 1 | ✅ | 六等奖 | ¥5 |
| 0 | ✅ | 六等奖 | ¥5 |

## License

MIT
