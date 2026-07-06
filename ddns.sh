#!/usr/bin/env bash
# ================================================================
# DDNS 一体化脚本（单文件）
#   换 IP + Cloudflare 域名解析更新 + Telegram 通知（可选）
#   兼容 BOILCLOUD ippanel API（getIP / changeIP）和自定义换 IP 链接
#
# 快速开始（从 GitHub 拉取后直接执行）:
#   chmod +x ddns.sh
#   sudo ./ddns.sh install     # 交互式配置，自动生成配置文件 + systemd 服务
#
# 其他用法:
#   ddns.sh update      仅把当前公网 IP 同步到 DNS（不换 IP）
#   ddns.sh change      触发一次换 IP，检测到新 IP 后立即更新 DNS
#   ddns.sh daemon      前台常驻运行（systemd 服务调用的就是它）
#   ddns.sh config      重新运行交互式配置
#   ddns.sh status      查看服务状态和最近日志
#   ddns.sh tg-subs     TG 广播模式下查看/刷新订阅者列表
#   ddns.sh uninstall   停止服务并卸载
# ================================================================
set -u

# ---------------- 常量路径 ----------------
CONF_FILE="${DDNS_CONF:-/etc/ddns/ddns.conf}"
INSTALL_PATH="/usr/local/bin/ddns.sh"
SERVICE_FILE="/etc/systemd/system/ddns.service"
STATE_DIR="/var/tmp/ddns"
DEFAULT_LOG="/var/log/ddns.log"

BOIL_API="https://ippanel.boil.network/api/v1"
CF_API="https://api.cloudflare.com/client/v4"
CURL_OPTS=(-s --connect-timeout 5 --max-time 15)

# ---------------- 通用工具 ----------------
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    [[ -n "${LOG_FILE:-}" ]] && echo "$msg" >> "$LOG_FILE" 2>/dev/null
}

die() { log "错误: $*"; notify_tg "❌ DDNS 出错: $*"; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || { echo "此操作需要 root 权限，请用 sudo 运行" >&2; exit 1; }; }

check_deps() {
    local miss=()
    command -v curl >/dev/null 2>&1 || miss+=(curl)
    command -v jq   >/dev/null 2>&1 || miss+=(jq)
    [[ ${#miss[@]} -eq 0 ]] && return 0
    echo "缺少依赖: ${miss[*]}，尝试自动安装..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y -qq "${miss[@]}"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q "${miss[@]}"
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache "${miss[@]}"
    else
        echo "无法自动安装，请手动安装: ${miss[*]}" >&2; exit 1
    fi
}

valid_ipv4() { [[ "${1:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

load_conf() {
    [[ -f "$CONF_FILE" ]] || die "找不到配置文件 $CONF_FILE，请先运行: sudo $0 install"
    # shellcheck disable=SC1090
    source "$CONF_FILE"
    mkdir -p "$STATE_DIR"
    CACHE_FILE="$STATE_DIR/${CF_RECORD_NAME}.cache"
}

# ---------------- Telegram 通知（异步，不阻塞主流程） ----------------
# 推送模式 TG_PUSH_MODE:
#   chat      推送到指定 Chat ID（群组或个人）
#   broadcast 推送给所有和机器人私聊过的用户（自动收集并保存订阅者列表）
TG_SUBSCRIBERS_FILE="/etc/ddns/tg_subscribers"

tg_api_base() { echo "${TG_API_HOST:-https://api.telegram.org}/bot${TG_BOT_TOKEN}"; }

tg_send_to() { # tg_send_to <chat_id> <text>
    curl "${CURL_OPTS[@]}" -X POST "$(tg_api_base)/sendMessage" \
        --data-urlencode "chat_id=$1" \
        --data-urlencode "text=$2" \
        --data-urlencode "parse_mode=HTML" >/dev/null 2>&1
}

# 通过 getUpdates 收集私聊过机器人的用户，合并进订阅者文件（TG 只保留 24h 更新，故需持久化）
tg_refresh_subscribers() {
    local resp ids
    resp=$(curl "${CURL_OPTS[@]}" "$(tg_api_base)/getUpdates?limit=100" 2>/dev/null)
    ids=$(echo "$resp" | jq -r '.result[]?.message.chat | select(.type=="private") | .id' 2>/dev/null | sort -u)
    [[ -z "$ids" ]] && return 0
    mkdir -p "$(dirname "$TG_SUBSCRIBERS_FILE")"
    { [[ -f "$TG_SUBSCRIBERS_FILE" ]] && cat "$TG_SUBSCRIBERS_FILE"; echo "$ids"; } \
        | grep -E '^-?[0-9]+$' | sort -u > "${TG_SUBSCRIBERS_FILE}.tmp" \
        && mv "${TG_SUBSCRIBERS_FILE}.tmp" "$TG_SUBSCRIBERS_FILE"
}

notify_tg() {
    [[ -z "${TG_BOT_TOKEN:-}" ]] && return 0
    if [[ "${TG_PUSH_MODE:-chat}" == "broadcast" ]]; then
        # 整体放后台：先刷新订阅者，再逐个发送
        (
            tg_refresh_subscribers
            [[ -f "$TG_SUBSCRIBERS_FILE" ]] || exit 0
            while read -r cid; do
                [[ -n "$cid" ]] && tg_send_to "$cid" "$1"
            done < "$TG_SUBSCRIBERS_FILE"
        ) &
    else
        [[ -z "${TG_CHAT_ID:-}" ]] && return 0
        tg_send_to "$TG_CHAT_ID" "$1" &
    fi
}

# ---------------- 获取公网 IPv4 ----------------
PUBLIC_IP_SOURCES=(
    "https://api.ipify.org"
    "https://api-ipv4.ip.sb/ip"
    "https://ifconfig.me/ip"
    "https://ipinfo.io/ip"
)

# BOILCLOUD getIP 接口（POST + Bearer）
boil_get_ip() {
    local resp ip
    resp=$(curl "${CURL_OPTS[@]}" -X POST \
        -H "Authorization: Bearer ${BOIL_TOKEN}" \
        "${BOIL_API}/getIP" 2>/dev/null)
    # 从响应中提取第一个 IPv4（兼容不同返回格式）
    ip=$(echo "$resp" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)
    valid_ipv4 "$ip" && { echo "$ip"; return 0; }
    return 1
}

get_public_ip() {
    local ip src
    # BOILCLOUD 用户优先走官方 getIP 接口
    if [[ "${IP_API_TYPE:-custom}" == "boil" ]]; then
        ip=$(boil_get_ip) && { echo "$ip"; return 0; }
    fi
    for src in "${PUBLIC_IP_SOURCES[@]}"; do
        ip=$(curl -4 -s --connect-timeout 3 --max-time 5 "$src" 2>/dev/null | tr -d '[:space:]')
        valid_ipv4 "$ip" && { echo "$ip"; return 0; }
    done
    return 1
}

# ---------------- 触发换 IP ----------------
# 返回 0 表示已触发；返回 1 表示接口明确报错（不再等待新 IP）
call_change_ip() {
    local resp http_code body err
    if [[ "${IP_API_TYPE:-custom}" == "boil" ]]; then
        resp=$(curl -s --connect-timeout 5 --max-time 30 -w '\n%{http_code}' -X POST \
            -H "Authorization: Bearer ${BOIL_TOKEN}" \
            "${BOIL_API}/changeIP/" 2>/dev/null)
        http_code=$(echo "$resp" | tail -n1)
        body=$(echo "$resp" | sed '$d')
        if [[ "$http_code" != "200" ]]; then
            err=$(echo "$body" | jq -r '.error // empty' 2>/dev/null)
            [[ -z "$err" ]] && err="HTTP $http_code: $body"
            log "换 IP 接口返回错误: $err"
            notify_tg "⚠️ <b>换 IP 接口报错</b>
域名: <code>${CF_RECORD_NAME}</code>
错误: ${err}"
            return 1
        fi
        log "换 IP 接口调用成功: $(echo "$body" | tr -d '\n' | head -c 200)"
    else
        curl "${CURL_OPTS[@]}" "${CUSTOM_CHANGE_URL}" >/dev/null 2>&1
        log "自定义换 IP 链接已调用"
    fi
    return 0
}

# ---------------- Cloudflare API ----------------
cf_api() { # cf_api <method> <path> [json_body]
    local method="$1" path="$2" body="${3:-}"
    if [[ -n "$body" ]]; then
        curl "${CURL_OPTS[@]}" -X "$method" "$CF_API$path" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H "Content-Type: application/json" \
            --data "$body"
    else
        curl "${CURL_OPTS[@]}" -X "$method" "$CF_API$path" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H "Content-Type: application/json"
    fi
}

load_cache() { ZONE_ID="" RECORD_ID=""; [[ -f "$CACHE_FILE" ]] && source "$CACHE_FILE"; }
save_cache() { printf 'ZONE_ID="%s"\nRECORD_ID="%s"\n' "$ZONE_ID" "$RECORD_ID" > "$CACHE_FILE"; }

get_zone_id() {
    [[ -n "$ZONE_ID" ]] && return 0
    local resp
    resp=$(cf_api GET "/zones?name=${CF_ZONE_NAME}&status=active")
    ZONE_ID=$(echo "$resp" | jq -r '.result[0].id // empty')
    [[ -n "$ZONE_ID" ]] || die "获取 Zone ID 失败，请检查 CF_API_TOKEN 和 CF_ZONE_NAME。响应: $(echo "$resp" | jq -c '.errors' 2>/dev/null)"
}

get_record_id() {
    [[ -n "$RECORD_ID" ]] && return 0
    local resp
    resp=$(cf_api GET "/zones/${ZONE_ID}/dns_records?type=A&name=${CF_RECORD_NAME}")
    RECORD_ID=$(echo "$resp" | jq -r '.result[0].id // empty')
}

cf_put_or_post() { # cf_put_or_post <json_body>  更新或创建记录，成功输出响应
    local body="$1" resp
    if [[ -n "$RECORD_ID" ]]; then
        resp=$(cf_api PUT "/zones/${ZONE_ID}/dns_records/${RECORD_ID}" "$body")
    else
        resp=$(cf_api POST "/zones/${ZONE_ID}/dns_records" "$body")
        RECORD_ID=$(echo "$resp" | jq -r '.result.id // empty')
    fi
    echo "$resp"
}

update_dns() { # update_dns <new_ip>
    local new_ip="$1" resp ok body
    body=$(jq -nc --arg name "$CF_RECORD_NAME" --arg ip "$new_ip" \
        --argjson ttl "${CF_TTL:-60}" --argjson proxied "${CF_PROXIED:-false}" \
        '{type:"A", name:$name, content:$ip, ttl:$ttl, proxied:$proxied}')

    load_cache
    get_zone_id
    get_record_id
    resp=$(cf_put_or_post "$body")
    ok=$(echo "$resp" | jq -r '.success' 2>/dev/null)
    if [[ "$ok" == "true" ]]; then
        save_cache
        log "DNS 更新成功: $CF_RECORD_NAME -> $new_ip"
        return 0
    fi

    # 缓存的 record_id 可能失效（记录被手动删除），清缓存重试一次
    log "DNS 更新失败，清除缓存重试... 响应: $(echo "$resp" | jq -c '.errors' 2>/dev/null)"
    rm -f "$CACHE_FILE"; ZONE_ID="" RECORD_ID=""
    get_zone_id; get_record_id
    resp=$(cf_put_or_post "$body")
    ok=$(echo "$resp" | jq -r '.success' 2>/dev/null)
    if [[ "$ok" == "true" ]]; then
        save_cache
        log "DNS 更新成功(重试): $CF_RECORD_NAME -> $new_ip"
        return 0
    fi
    log "DNS 更新失败: $(echo "$resp" | jq -c '.errors' 2>/dev/null)"
    return 1
}

# ---------------- 核心流程 ----------------
do_update() {
    local ip
    ip=$(get_public_ip) || die "无法获取公网 IP"
    log "当前公网 IP: $ip"
    if update_dns "$ip"; then
        notify_tg "✅ <b>DDNS 同步完成</b>
域名: <code>${CF_RECORD_NAME}</code>
IP: <code>${ip}</code>"
    else
        notify_tg "❌ <b>DDNS 更新失败</b>
域名: <code>${CF_RECORD_NAME}</code>
IP: <code>${ip}</code>"
        return 1
    fi
}

do_change_ip() {
    local old_ip new_ip start elapsed t0 t1 cost

    old_ip=$(get_public_ip) || old_ip="未知"
    log "换 IP 前的 IP: $old_ip"

    t0=$(date +%s%3N)
    call_change_ip || return 1
    log "开始轮询检测新 IP（间隔 ${IP_CHECK_INTERVAL:-2}s，超时 ${IP_CHANGE_TIMEOUT:-120}s）"

    start=$(date +%s)
    while true; do
        new_ip=$(get_public_ip) || new_ip=""
        [[ -n "$new_ip" && "$new_ip" != "$old_ip" ]] && break
        elapsed=$(( $(date +%s) - start ))
        if (( elapsed >= ${IP_CHANGE_TIMEOUT:-120} )); then
            log "等待新 IP 超时（${IP_CHANGE_TIMEOUT:-120}s），IP 未变化"
            notify_tg "⚠️ <b>换 IP 超时</b>
域名: <code>${CF_RECORD_NAME}</code>
IP 仍为: <code>${old_ip}</code>"
            return 1
        fi
        sleep "${IP_CHECK_INTERVAL:-2}"
    done

    log "检测到新 IP: $new_ip，立即更新 DNS"
    if update_dns "$new_ip"; then
        t1=$(date +%s%3N)
        cost=$(( (t1 - t0) / 1000 ))
        log "完成：换 IP + 更新解析总耗时 ${cost}s"
        notify_tg "🔄 <b>IP 已更换</b>
域名: <code>${CF_RECORD_NAME}</code>
旧 IP: <code>${old_ip}</code>
新 IP: <code>${new_ip}</code>
总耗时: ${cost}s"
    else
        notify_tg "❌ <b>换 IP 后 DNS 更新失败</b>
域名: <code>${CF_RECORD_NAME}</code>
新 IP: <code>${new_ip}</code>，请手动处理"
        return 1
    fi
}

seconds_until_daily() {
    local target now
    target=$(date -d "today ${DAILY_TIME}" +%s 2>/dev/null) || return 1
    now=$(date +%s)
    (( target <= now )) && target=$(date -d "tomorrow ${DAILY_TIME}" +%s)
    echo $(( target - now ))
}

do_daemon() {
    log "守护进程启动，模式: ${MODE}"
    do_update || true

    if [[ "$MODE" == "interval" ]]; then
        log "每 ${RUN_INTERVAL}s 换一次 IP"
        while true; do
            sleep "$RUN_INTERVAL"
            do_change_ip || true
        done
    elif [[ "$MODE" == "daily" ]]; then
        date -d "today ${DAILY_TIME}" +%s >/dev/null 2>&1 || die "DAILY_TIME 格式错误: $DAILY_TIME（应为 HH:MM）"
        log "每天 ${DAILY_TIME} 换一次 IP"
        while true; do
            local wait_sec
            wait_sec=$(seconds_until_daily)
            log "下次换 IP 时间: $(date -d "+${wait_sec} seconds" '+%Y-%m-%d %H:%M:%S')（${wait_sec}s 后）"
            sleep "$wait_sec"
            do_change_ip || true
        done
    else
        die "MODE 配置错误: $MODE（只能是 interval 或 daily）"
    fi
}

# ---------------- 交互式配置向导 ----------------
ask() { # ask <提示> <默认值(可空)>  结果存入 REPLY
    local prompt="$1" def="${2:-}"
    if [[ -n "$def" ]]; then
        read -rp "$prompt [默认: $def]: " REPLY
        [[ -z "$REPLY" ]] && REPLY="$def"
    else
        read -rp "$prompt: " REPLY
    fi
}

ask_required() { # 必填项，为空则重复询问
    local prompt="$1"
    while true; do
        read -rp "$prompt: " REPLY
        [[ -n "$REPLY" ]] && return 0
        echo "  该项不能为空，请重新输入。"
    done
}

setup_wizard() {
    need_root
    check_deps
    echo "=============================================="
    echo "        DDNS 一体化脚本 - 交互式配置"
    echo "=============================================="
    echo

    # ----- 换 IP 接口 -----
    echo "【1/5】换 IP 接口"
    echo "  1) BOILCLOUD (ippanel.boil.network 官方 API)"
    echo "  2) 自定义链接（curl 访问一次即触发换 IP）"
    local ip_api_type boil_token custom_url
    while true; do
        ask "请选择 (1/2)" "1"
        case "$REPLY" in
            1) ip_api_type="boil"; break ;;
            2) ip_api_type="custom"; break ;;
            *) echo "  请输入 1 或 2" ;;
        esac
    done
    boil_token="" custom_url=""
    if [[ "$ip_api_type" == "boil" ]]; then
        echo "  提示: 登录 https://ippanel.boil.network/ -> 获取API -> 复制 Token"
        ask_required "请输入 BOILCLOUD API Token"; boil_token="$REPLY"
        echo -n "  正在验证 Token（调用 getIP 接口）... "
        local test_ip
        test_ip=$(BOIL_TOKEN="$boil_token" IP_API_TYPE="boil" boil_get_ip) \
            && echo "成功，当前 IP: $test_ip" \
            || echo "失败！请检查 Token 是否正确（也可能是面板暂时不可用），稍后可用 'ddns.sh config' 重新配置"
    else
        ask_required "请输入换 IP 链接（完整 URL）"; custom_url="$REPLY"
    fi
    echo

    # ----- Cloudflare -----
    echo "【2/5】Cloudflare 解析"
    echo "  提示: Cloudflare 控制台 -> My Profile -> API Tokens -> 用 'Edit zone DNS' 模板创建"
    local cf_token zone_name record_name cf_ttl cf_proxied
    ask_required "请输入 Cloudflare API Token"; cf_token="$REPLY"
    ask_required "请输入根域名（如 example.com）"; zone_name="$REPLY"
    ask "请输入要解析的完整域名" "nat.${zone_name}"; record_name="$REPLY"
    ask "DNS 记录 TTL（秒，最低 60）" "60"; cf_ttl="$REPLY"
    ask "是否开启 Cloudflare 代理小黄云 (y/N)" "N"
    [[ "$REPLY" =~ ^[Yy]$ ]] && cf_proxied="true" || cf_proxied="false"

    echo -n "  正在验证 Cloudflare Token 和域名... "
    local zid
    zid=$(curl "${CURL_OPTS[@]}" -X GET "$CF_API/zones?name=${zone_name}&status=active" \
        -H "Authorization: Bearer $cf_token" -H "Content-Type: application/json" \
        | jq -r '.result[0].id // empty' 2>/dev/null)
    [[ -n "$zid" ]] && echo "成功（Zone ID: $zid）" \
        || echo "失败！请检查 Token 权限和根域名，稍后可用 'ddns.sh config' 重新配置"
    echo

    # ----- 运行模式 -----
    echo "【3/5】自动换 IP 的时机"
    echo "  1) 固定间隔（如每小时换一次）"
    echo "  2) 每天固定时间（如凌晨 4 点）"
    local mode run_interval daily_time
    run_interval=3600 daily_time="04:00"
    while true; do
        ask "请选择 (1/2)" "1"
        case "$REPLY" in
            1) mode="interval"
               ask "换 IP 间隔（秒，3600=每小时）" "3600"; run_interval="$REPLY"
               break ;;
            2) mode="daily"
               while true; do
                   ask "每天执行时间（24小时制 HH:MM）" "04:00"
                   [[ "$REPLY" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] && { daily_time="$REPLY"; break; }
                   echo "  格式不对，示例: 04:00 或 23:30"
               done
               break ;;
            *) echo "  请输入 1 或 2" ;;
        esac
    done
    echo

    # ----- Telegram -----
    echo "【4/5】Telegram 通知（可选，直接回车跳过）"
    local tg_token tg_chat tg_host tg_push_mode
    ask "Bot Token（@BotFather 获取，留空跳过）" ""; tg_token="$REPLY"
    tg_chat="" tg_host="https://api.telegram.org" tg_push_mode="chat"
    if [[ -n "$tg_token" ]]; then
        ask "TG API 地址（无法直连 TG 时填反代地址）" "https://api.telegram.org"; tg_host="$REPLY"
        echo "  推送方式:"
        echo "    1) 推送到指定 Chat ID（群组或个人）"
        echo "    2) 推送给所有和机器人私聊过的用户（用户给机器人发条消息即自动订阅）"
        while true; do
            ask "请选择 (1/2)" "1"
            case "$REPLY" in
                1) tg_push_mode="chat"; break ;;
                2) tg_push_mode="broadcast"; break ;;
                *) echo "  请输入 1 或 2" ;;
            esac
        done

        if [[ "$tg_push_mode" == "chat" ]]; then
            echo "  提示: 个人 Chat ID 可通过 @userinfobot 获取；"
            echo "        群组需先把机器人拉进群，群 ID 为负数（可通过 getUpdates 查看）"
            ask_required "Chat ID"; tg_chat="$REPLY"
            echo -n "  正在发送测试消息... "
            curl "${CURL_OPTS[@]}" -X POST "${tg_host}/bot${tg_token}/sendMessage" \
                --data-urlencode "chat_id=${tg_chat}" \
                --data-urlencode "text=✅ DDNS 脚本通知测试成功" >/dev/null 2>&1 \
                && echo "已发送，请检查 TG 是否收到" || echo "发送失败，请检查 Token/ChatID/网络"
        else
            echo "  提示: 让需要接收通知的用户先给机器人发一条消息（如 /start），"
            echo "        脚本每次推送前会自动收集新订阅者并保存到 $TG_SUBSCRIBERS_FILE"
            echo "        注意: 该机器人不能同时设置 webhook，否则收集不到订阅者"
            echo -n "  正在收集当前订阅者并发送测试消息... "
            local sub_count
            TG_BOT_TOKEN="$tg_token" TG_API_HOST="$tg_host" tg_refresh_subscribers
            if [[ -s "$TG_SUBSCRIBERS_FILE" ]]; then
                sub_count=$(wc -l < "$TG_SUBSCRIBERS_FILE")
                echo "已收集到 ${sub_count} 个订阅者"
                while read -r cid; do
                    [[ -n "$cid" ]] && TG_BOT_TOKEN="$tg_token" TG_API_HOST="$tg_host" \
                        tg_send_to "$cid" "✅ DDNS 脚本通知测试成功（广播模式）"
                done < "$TG_SUBSCRIBERS_FILE"
                echo "  测试消息已发送，请检查 TG 是否收到"
            else
                echo "暂无订阅者"
                echo "  现在可以去给机器人发条消息，之后脚本推送时会自动收集到"
            fi
        fi
    fi
    echo

    # ----- 写配置 -----
    echo "【5/5】生成配置和服务"
    mkdir -p "$(dirname "$CONF_FILE")" "$STATE_DIR"
    cat > "$CONF_FILE" <<EOF
# DDNS 配置文件（由 ddns.sh install 自动生成，可手动修改后 systemctl restart ddns）
IP_API_TYPE="${ip_api_type}"
BOIL_TOKEN="${boil_token}"
CUSTOM_CHANGE_URL="${custom_url}"

CF_API_TOKEN="${cf_token}"
CF_ZONE_NAME="${zone_name}"
CF_RECORD_NAME="${record_name}"
CF_TTL=${cf_ttl}
CF_PROXIED=${cf_proxied}

MODE="${mode}"
RUN_INTERVAL=${run_interval}
DAILY_TIME="${daily_time}"

TG_BOT_TOKEN="${tg_token}"
# 推送模式: chat=指定 Chat ID（群组或个人）; broadcast=所有和机器人私聊过的用户
TG_PUSH_MODE="${tg_push_mode}"
TG_CHAT_ID="${tg_chat}"
TG_API_HOST="${tg_host}"

IP_CHECK_INTERVAL=2
IP_CHANGE_TIMEOUT=120
LOG_FILE="${DEFAULT_LOG}"
EOF
    chmod 600 "$CONF_FILE"
    echo "  配置已写入: $CONF_FILE（权限 600）"

    # 把脚本自身安装到系统路径
    if [[ "$(readlink -f "$0")" != "$INSTALL_PATH" ]]; then
        install -m 755 "$0" "$INSTALL_PATH"
        echo "  脚本已安装到: $INSTALL_PATH"
    fi

    # 生成 systemd 服务
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=DDNS - 自动换 IP 并更新 Cloudflare 解析
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$INSTALL_PATH daemon
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    echo "  systemd 服务已生成: $SERVICE_FILE"
    echo

    ask "是否立即启动并设置开机自启 (Y/n)" "Y"
    if [[ ! "$REPLY" =~ ^[Nn]$ ]]; then
        systemctl enable --now ddns
        echo
        echo "  服务已启动！常用命令:"
    else
        echo
        echo "  稍后可手动启动。常用命令:"
    fi
    echo "    systemctl status ddns      查看状态"
    echo "    journalctl -u ddns -f      实时日志"
    echo "    $INSTALL_PATH change       手动换一次 IP"
    echo "    $INSTALL_PATH update       手动同步当前 IP 到 DNS"
    echo "    $INSTALL_PATH config       重新配置"
    echo "=============================================="
}

do_uninstall() {
    need_root
    ask "确认卸载 DDNS 服务？配置和日志也会删除 (y/N)" "N"
    [[ "$REPLY" =~ ^[Yy]$ ]] || { echo "已取消"; exit 0; }
    systemctl disable --now ddns 2>/dev/null
    rm -f "$SERVICE_FILE" && systemctl daemon-reload
    rm -f "$CONF_FILE" "$INSTALL_PATH" "$TG_SUBSCRIBERS_FILE"
    rm -rf "$STATE_DIR"
    echo "已卸载（日志文件 $DEFAULT_LOG 未删除，如不需要可手动删除）"
}

do_status() {
    systemctl status ddns --no-pager 2>/dev/null || echo "服务未安装"
    echo
    if [[ -f "$DEFAULT_LOG" ]]; then
        echo "--- 最近 20 条日志 ---"
        tail -n 20 "$DEFAULT_LOG"
    fi
}

# 广播模式：手动刷新并查看订阅者列表
do_tg_subs() {
    load_conf
    [[ -n "${TG_BOT_TOKEN:-}" ]] || { echo "未配置 TG Bot Token"; exit 1; }
    echo "正在从 getUpdates 收集新订阅者..."
    tg_refresh_subscribers
    if [[ -s "$TG_SUBSCRIBERS_FILE" ]]; then
        echo "当前订阅者列表（$TG_SUBSCRIBERS_FILE，如需移除某人可直接编辑此文件删掉对应行）:"
        cat "$TG_SUBSCRIBERS_FILE"
    else
        echo "暂无订阅者。让用户给机器人发一条消息（如 /start）后再运行本命令"
    fi
}

usage() {
    cat <<EOF
DDNS 一体化脚本

用法: $0 <命令>

  install     交互式配置并安装为 systemd 服务（首次使用运行这个）
  config      重新运行交互式配置
  update      仅把当前公网 IP 同步到 DNS
  change      触发一次换 IP 并更新 DNS
  daemon      前台常驻运行（一般由 systemd 调用）
  status      查看服务状态和最近日志
  tg-subs     TG 广播模式: 手动刷新并查看订阅者列表
  uninstall   停止并卸载
EOF
}

# ---------------- 入口 ----------------
case "${1:-}" in
    install|config) setup_wizard ;;
    update)  check_deps; load_conf; do_update ;;
    change)  check_deps; load_conf; do_change_ip ;;
    daemon)  check_deps; load_conf; do_daemon ;;
    status)  do_status ;;
    tg-subs) check_deps; do_tg_subs ;;
    uninstall) do_uninstall ;;
    "")
        # 无参数：没配置过就进向导，配置过就显示帮助
        if [[ ! -f "$CONF_FILE" ]]; then
            setup_wizard
        else
            usage
        fi
        ;;
    *) usage; exit 1 ;;
esac
