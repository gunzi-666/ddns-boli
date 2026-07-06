# DDNS 一体化脚本

单文件 `ddns.sh`，适用于 Linux（Debian/Ubuntu/CentOS/Alpine）。

功能：调用换 IP 接口 → 快速轮询检测新公网 IP → 立即更新 Cloudflare A 记录 → Telegram 通知（可选）。支持交互式配置，自动生成配置文件和 systemd 服务。

兼容 [BOILCLOUD ippanel API](https://cloud.boil.network/tutorial.php#api)（`getIP` / `changeIP`，POST + Bearer Token），也支持任意「访问一下就换 IP」的自定义链接。

## 快速开始

```bash
# 从 GitHub 拉取
wget -O ddns.sh https://raw.githubusercontent.com/gunzi-666/ddns-boli/main/ddns.sh
chmod +x ddns.sh
sudo ./ddns.sh install
```

跟着交互提示依次填写即可，向导会自动：

1. 检测并安装依赖（`curl`、`jq`）
2. 询问换 IP 接口（BOILCLOUD Token 或自定义链接），并在线验证 Token
3. 询问 Cloudflare Token、域名，并在线验证
4. 询问运行模式：固定间隔 / 每天固定时间
5. 询问 Telegram 通知（可选，会发测试消息）
6. 生成配置 `/etc/ddns/ddns.conf`（权限 600）
7. 把脚本安装到 `/usr/local/bin/ddns.sh`，生成 systemd 服务并启动 + 开机自启

## 命令一览

| 命令 | 作用 |
|------|------|
| `sudo ddns.sh install` | 交互式配置并安装（首次使用） |
| `sudo ddns.sh config` | 重新配置 |
| `ddns.sh update` | 仅把当前公网 IP 同步到 DNS |
| `ddns.sh change` | 手动触发一次换 IP 并更新解析 |
| `ddns.sh status` | 查看服务状态 + 最近日志 |
| `ddns.sh tg-subs` | TG 广播模式：刷新并查看订阅者列表 |
| `sudo ddns.sh uninstall` | 停止并卸载 |

服务管理：

```bash
systemctl status ddns      # 状态
journalctl -u ddns -f      # 实时日志
systemctl restart ddns     # 改完配置后重启生效
```

## BOILCLOUD API 兼容说明

- 取 IP：`POST https://ippanel.boil.network/api/v1/getIP`（Bearer Token）
- 换 IP：`POST https://ippanel.boil.network/api/v1/changeIP/`（Bearer Token）
- 接口返回 400 错误（如「当日更换IP次数已用完」「频率限制中」「Token 已失效」）时，脚本会记录日志并推送 TG 告警，不做无意义的等待
- 检测 IP 优先走官方 `getIP`，失败自动回退到公共 IP 检测源（ipify / ip.sb / ifconfig.me / ipinfo）

## 速度优化

- 触发换 IP 后以 2 秒间隔轮询公网 IP，检测到变化立刻更新 DNS
- Cloudflare Zone ID / Record ID 本地缓存，每次更新解析只需 1 次 API 请求
- DNS TTL 默认 60 秒（Cloudflare 最低值）
- TG 通知异步发送，不阻塞主流程
- TG 通知内容包含旧 IP、新 IP 和「换 IP → 解析生效」总耗时

## Telegram 通知（可选）

先找 [@BotFather](https://t.me/BotFather) 创建机器人拿到 Bot Token，然后在向导里二选一：

**方式一：推送到指定 Chat ID（群组或个人）**

- 个人：找 [@userinfobot](https://t.me/userinfobot) 获取自己的 Chat ID
- 群组：把机器人拉进群后，访问 `https://api.telegram.org/bot<TOKEN>/getUpdates` 找到群的 `chat.id`（负数）

**方式二：广播给所有和机器人私聊过的用户**

- 想接收通知的人只需给机器人发一条消息（如 `/start`）即自动订阅
- 订阅者持久化保存在 `/etc/ddns/tg_subscribers`；服务运行时实时收集，也可用 `ddns.sh tg-subs` 手动刷新/查看；要移除某人，直接编辑该文件删掉对应行
- 注意：该机器人不能同时设置 webhook，否则 `getUpdates` 收不到消息

服务器无法直连 Telegram 时，向导里可以填自己的反代地址。

## TG 机器人远程控制

服务（daemon）运行时，配置里 `TG_ADMIN_IDS` 中的用户可以直接在 TG 里给机器人发命令：

| 命令 | 作用 |
|------|------|
| `/update` | 立即把当前公网 IP 同步到 DNS |
| `/change` | 立即换 IP 并更新解析，完成后推送结果 |
| `/status` | 查看当前 IP、域名和换 IP 模式 |
| `/help` | 显示命令列表 |

说明：

- 管理员 Chat ID 在向导里设置（`chat` 模式默认就是推送的 Chat ID），多个用英文逗号分隔；留空则禁用远程控制
- 非管理员发命令会被拒绝；群里发 `/change@你的机器人` 这种带后缀的写法也能识别
- 手动命令和定时任务之间有文件锁，不会同时换 IP 打架
- 旧版本升级上来的用户：配置文件里没有 `TG_ADMIN_IDS`，重新跑一遍 `sudo ddns.sh config`，或手动在 `/etc/ddns/ddns.conf` 里加一行 `TG_ADMIN_IDS="你的ChatID"` 后重启服务
