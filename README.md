# opencode2api-proxy-pool

[opencode2api](https://github.com/jasonxu114514/opencode2api)（OpenCode → OpenAI/Anthropic 兼容 API 网关）与
[easy_proxies](https://github.com/jasonwong1991/easy_proxies)（sing-box 内核免费节点代理池）打包进**单个 Docker 镜像**，
适配 [Render](https://render.com) 单端口部署，并通过 Caddy 前缀路由聚合两个原生 WebUI。

## 架构

```
客户端 ──► Render $PORT ──► Caddy（唯一公网出口）
                             ├─ /healthz  → 200（容器存活探针，规避启动期 503）
                             ├─ /v1/*     → opencode2api :8080   （OpenAI/Anthropic API）
                             ├─ /oc2a/*   → opencode2api :8081   （网关管理台）
                             ├─ /pool/*   → easy_proxies :9091   （代理池面板）
                             └─ /*        → 门户页
opencode2api 出站 ──► http://pool:***@127.0.0.1:2323（easy_proxies 池入口，随机口令每次启动生成）
easy_proxies 出站 ──► 订阅/节点（VLESS/VMess/Trojan/SS/Hysteria2…）
```

进程管理：supervisord（三进程崩溃独立重启）；两个上游仓库 pin 到固定 commit 后构建，
WebUI 单文件 HTML 在构建期打补丁把根绝对路径 `/api/*` 改为 `/oc2a/api/*`、`/pool/api/*`，实现同源前缀共存。

## 环境变量

| 变量 | 必填 | 说明 |
|---|---|---|
| `SERVER_KEYS` | 建议 | 客户端调用 `/v1/*` 的密钥，逗号分隔；留空则 API 不鉴权 |
| `PROXY_SUBSCRIPTIONS` | 建议 | 代理池订阅链接，逗号分隔（URL 内含 token 属敏感信息） |
| `MGMT_PASSWORD` | **必设** | `/pool/` 面板登录密码；留空会随机生成且无法找回 |
| `OC2A_WEBUI_PASSWORD` | 建议 | `/oc2a/` 管理台密码（用户名默认 `admin`）；留空随机生成 |
| `SUB_REFRESH_INTERVAL` | 可选 | 订阅定时刷新间隔，默认 `30m` |
| `PREFER` | 可选 | 上游偏好 `zen`/`go`，默认 `go` |

所有密钥只通过 Render Dashboard 注入（render.yaml 中均为 `sync: false`），运行时写入容器内 `/run/app`，
不进镜像层、不打日志。未提供订阅时启动会注入一个占位节点保证进程可引导，部署后到 `/pool/` 添加订阅即可。

## 本地运行

```bash
docker build -t oc2a-pool .
docker run --rm -p 8080:8080 \
  -e PORT=8080 \
  -e SERVER_KEYS=sk-rp-test123 \
  -e PROXY_SUBSCRIPTIONS="https://example.com/sub?token=xxx" \
  -e MGMT_PASSWORD=admin123 \
  -e OC2A_WEBUI_PASSWORD=admin123 \
  oc2a-pool
```

验证：打开 <http://localhost:8080/> 门户 → 两个面板分别登录。

## 部署到 Render

1. 本仓库推送到 GitHub
2. Render Dashboard → New → Blueprint → 选仓库（或 New Web Service → Docker）
3. 在环境变量里填入上表四个值（Blueprint 会逐个提示）
4. free 套餐 512MB：已裁剪 sing-box 编译标签（去 wireguard/gvisor/clash_api）、关闭 GeoIP；
   冷启动含订阅抓取 + models 刷新，首次就绪约需 30-60s

免费实例 15 分钟无流量会休眠，唤醒同样需要冷启动时间。

## 安全说明

- 公网仅暴露 Caddy 的 `$PORT`，代理池入口(2323)与两个面板后端全部 loopback 监听
- 池入口带随机认证（`pool:<random>`），即使被探测也无法直连
- 上游 krismile20/opencode2api 的 deploy/config.json 曾公开提交过真实 server key——如仍在使用请先轮换

## 目录结构

```
├── Dockerfile          多阶段构建 + 构建期 WebUI 补丁 + pin commit
├── start.sh            运行时从环境变量生成两份配置，exec supervisord
├── supervisord.conf    caddy / proxy_pool / api_gateway 三 program
├── Caddyfile           $PORT 单端口前缀路由
├── web/index.html      门户页
└── render.yaml         Render Blueprint
```
