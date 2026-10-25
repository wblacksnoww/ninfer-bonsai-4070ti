# AGENTS.md — 本工作区的协作约定

## 联网查询（本机限制，与项目无关）

**`WebFetch` 在本机不可用**：客户端直连，实测 **60 秒超时**（`Tool execution timed out after 60000ms`）
→ 抓网页一律用 Bash + curl。
本机 shell **没有 http_proxy 变量**，国外站点**必须显式 `-x` 走代理**，裸 curl 会挂住 30 秒然后失败。

三条**已实测**的路径（2026-10-11 验证）：

```bash
# ① 搜索 → Bing 国内站（直连 0.16s，返回带服务器渲染结果的 HTML）
curl -sL --noproxy '*' -m 20 "https://cn.bing.com/search?q=关键词" -o /tmp/bing.html
grep -oP '(?<=<h2>).*?(?=</h2>)' /tmp/bing.html | sed -e 's/<[^>]*>//g' | head -10         # 结果标题
grep -oP '(?<=<h2>)<a[^>]*href="[^"]+' /tmp/bing.html | grep -oP 'href="\K[^"]+' | head -10  # 结果链接
# ② 抓国内页面：直连
curl -sL --noproxy '*' -m 20 "<URL>" | head -c 20000
# ③ 抓国外页面：走本机 xray 代理（端口 10808；http 与 socks5 都可，实测 0.6s 通）
curl -sL -x http://127.0.0.1:10808 -m 25 "<URL>" | head -c 20000
```

- 百度直连只回 ~1.5KB 跳转页、DuckDuckGo 回 202 反爬页 → **都别用**，搜索就用 Bing
- ③ 失败 = 代理软件（xray）没开 → 直说"代理不可用"，**别反复重试**
- **`WebSearch` 工具只对 Anthropic 系供应商可用**：云端（`anthropic` 类型，如 DeepSeek）可以；
  **本地模型**（`openai-compatible`，baseURL `http://127.0.0.1:18210/v1`）会在编码阶段直接报错
  （`Provider API kind openai-compatible does not encode provider-native WebSearch`）——
  **本会话内不要再试它**，直接用上面的 curl
- 正文很长时先 `grep`/`head` 截取相关段落再读；**抓不到就直说"抓取失败"，不要凭记忆编造网页内容**

## 本机部署速记（详见 README）

- 本地推理服务：`./scripts/start-kvmem.sh long`（引擎 18202 / 压缩代理 18210，客户端接 **18210**）
- 容器线见 `docker/kvmem/README.md`；镜像自检 `./docker/kvmem/verify.sh`
- 服务与宿主共用一张 12GB 卡：跑别的大任务（游戏、视频生成）前先 `./scripts/start-kvmem.sh stop long`

## 工作区目录卫生

- 仓库根目录**只放仓库自身内容**（源码 / 文档 / 脚本 / docker）。临时材料、下载副本
  （如 `xxx(1)` 这类后缀）不要落在仓库里—— `.gitignore` 已排除 `汇总-报告与技能*/` 与
  `get-docker.sh`，但被忽略 ≠ 不碍事：它们会混进 `ls`、被 `grep -r` 扫到、进备份。
- 2026-10-25：把根目录的 `汇总-报告与技能(1)/` 挪到了 `/mnt/D/code/汇总-报告与技能-2026-09-28/`
  （20 个文件，172K；旧汇报材料，非本项目内容）。
- 权重与制品（`models/`、`*.gguf`、`*.ninfer`）不进 git；`.workbuddy/` 为本地工作数据，也不提交。
