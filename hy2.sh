
#!/usr/bin/env bash
set -Eeuo pipefail

# 检查交互终端
if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
    echo "[ERROR] 无法访问交互终端，请使用 SSH 终端运行脚本"
    exit 1
fi

# ============================================================
# Debian VPS 自动初始化
# IPv6 + 指定防火墙端口 + Hysteria 2 + 自签证书
#
# 防火墙规则只添加，不清空、不重置、不修改默认策略
# 不生成、不覆盖 Hy2 config.yaml
# ============================================================

VERSION="1.0.0"

HY2_PORT="10086"
HOP_START="20000"
HOP_END="20500"

BACKUP_DIR="/var/backups/hy2-vps-$(date +%Y%m%d-%H%M%S)"
IPV6_ENV="/etc/hy2-ipv6.env"
IPV6_APPLY="/usr/local/sbin/hy2-ipv6-apply"
IPV6_SERVICE="/etc/systemd/system/hy2-ipv6.service"

CERT_DIR="/etc/hysteria"
CERT_KEY="${CERT_DIR}/server.key"
CERT_CRT="${CERT_DIR}/server.crt"

log()  { echo -e "\033[32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[31m[ERROR]\033[0m $*" >&2; }

fail() {
    err "$*"
    exit 1
}

# ------------------------------------------------------------
# 1. Root 检查
# ------------------------------------------------------------

[[ "$EUID" -eq 0 ]] || fail "请使用 root 运行此脚本"

mkdir -p "$BACKUP_DIR"

log "备份目录：$BACKUP_DIR"

# ------------------------------------------------------------
# 2. 安装基础软件
# ------------------------------------------------------------

log "更新 Debian 软件源并安装基础工具..."

export DEBIAN_FRONTEND=noninteractive

apt-get update


apt-get install -y \
    curl \
    wget \
    sudo \
    openssl \
    iproute2 \
    iptables \
    iptables-persistent \
    ca-certificates \
    python3 \
    qrencode


unset DEBIAN_FRONTEND

# ------------------------------------------------------------
# 3. 自动识别网卡
# ------------------------------------------------------------

DEFAULT_NIC="$(ip -4 route show default 2>/dev/null |
    awk 'NR==1 {print $5}')"

if [[ -z "$DEFAULT_NIC" ]]; then
    DEFAULT_NIC="$(ip -6 route show default 2>/dev/null |
        awk 'NR==1 {print $5}')"
fi

if [[ -z "$DEFAULT_NIC" ]]; then
    DEFAULT_NIC="$(ip -o link show |
        awk -F': ' '$2 != "lo" {print $2; exit}')"
fi

echo
echo "============================================"
echo "        VPS IPv6 + Hy2 自动安装"
echo "============================================"
echo

if [[ -n "$DEFAULT_NIC" ]]; then
    read -r -p "检测到网卡 ${DEFAULT_NIC}，直接回车确认，或输入其他网卡名称：" INPUT_NIC </dev/tty
    NIC="${INPUT_NIC:-$DEFAULT_NIC}"
else
    read -rp "请输入网卡名称：" NIC
fi

ip link show dev "$NIC" >/dev/null 2>&1 ||
    fail "网卡 ${NIC} 不存在"

log "使用网卡：$NIC"

# ------------------------------------------------------------
# 4. 输入 IPv6 地址
# ------------------------------------------------------------

echo
read -r -p "请输入 VPS 分配的 IPv6 地址：" IPV6_INPUT </dev/tty

[[ -n "$IPV6_INPUT" ]] || fail "IPv6 地址不能为空"

# 自动补全 /128；用户明确输入前缀时保留其前缀
if [[ "$IPV6_INPUT" == */* ]]; then
    IPV6_CIDR="$IPV6_INPUT"
else
    IPV6_CIDR="${IPV6_INPUT}/128"
fi

python3 - "$IPV6_CIDR" <<'PY'
import ipaddress
import sys

try:
    ipaddress.IPv6Interface(sys.argv[1])
except Exception as e:
    print("IPv6 地址格式错误：", e)
    sys.exit(1)
PY

[[ $? -eq 0 ]] || fail "IPv6 地址校验失败"

log "IPv6 地址：$IPV6_CIDR"

# ------------------------------------------------------------
# 5. 备份原有配置
# ------------------------------------------------------------

if [[ -f /etc/sysctl.d/99-hy2-ipv6.conf ]]; then
    cp -a /etc/sysctl.d/99-hy2-ipv6.conf \
        "$BACKUP_DIR/sysctl.conf.before"
fi

if [[ -f "$IPV6_ENV" ]]; then
    cp -a "$IPV6_ENV" "$BACKUP_DIR/hy2-ipv6.env.before"
fi

if [[ -f "$IPV6_APPLY" ]]; then
    cp -a "$IPV6_APPLY" "$BACKUP_DIR/hy2-ipv6-apply.before"
fi

if [[ -f "$IPV6_SERVICE" ]]; then
    cp -a "$IPV6_SERVICE" "$BACKUP_DIR/hy2-ipv6.service.before"
fi

# ------------------------------------------------------------
# 6. 启用 IPv6
# ------------------------------------------------------------

log "启用系统 IPv6..."

sysctl -w net.ipv6.conf.all.disable_ipv6=0
sysctl -w net.ipv6.conf.default.disable_ipv6=0
sysctl -w "net.ipv6.conf.${NIC}.disable_ipv6=0"

# 接收 RA；forwarding 开启时 accept_ra=2 也允许接收 RA
sysctl -w "net.ipv6.conf.${NIC}.accept_ra=2"

# 不清空现有 IPv6 地址，只添加或更新用户指定的地址
ip -6 addr replace "$IPV6_CIDR" dev "$NIC"

# ------------------------------------------------------------
# 7. IPv6 网关：默认尝试 IPv6 地址前缀::1，失败后手动输入
# ------------------------------------------------------------

IPV6_GW=""
GW_MODE="manual"

echo
echo "============================================"
echo "          IPv6 网关配置"
echo "============================================"

# 从 IPv6 地址生成默认候选网关
# 例如：
# 2400:8d60:8:0000:0000:0000:67d3:421b/128
# 候选网关：2400:8d60:8::1

DEFAULT_GW="$(
python3 - "$IPV6_CIDR" <<'PY'
import ipaddress
import sys

try:
    interface = ipaddress.IPv6Interface(sys.argv[1])
    network = interface.network

    # /128 地址没有可直接推断的网段前缀。
    # 此处仅按常见 VPS 的 /64 前缀生成 ::1 候选。
    if interface.network.prefixlen == 128:
        network = ipaddress.IPv6Network(
            (interface.ip, 64), strict=False
        )

    print(str(network.network_address + 1))

except Exception as e:
    print("无法生成默认网关：", e, file=sys.stderr)
    sys.exit(1)
PY
)" || fail "无法根据 IPv6 地址生成候选网关"

echo "[INFO] 自动生成的候选 IPv6 网关：$DEFAULT_GW"

# 配置网关并测试
test_ipv6_gateway() {
    local gateway="$1"

    echo
    echo "[INFO] 正在测试 IPv6 网关：$gateway"

    if [[ "${gateway,,}" == fe80:* ]]; then
        ip -6 route replace default via "$gateway" dev "$NIC" || return 1
    else
        ip -6 route replace default via "$gateway" dev "$NIC" onlink || return 1
    fi

    sleep 2

    if ping -6 -c 2 -W 3 2606:4700:4700::1111 >/dev/null 2>&1; then
        echo "[OK] IPv6 网关测试成功"
        return 0
    fi

    echo "[WARN] IPv6 外网连通性测试失败"
    return 1
}

# 首先尝试默认网关
if test_ipv6_gateway "$DEFAULT_GW"; then
    IPV6_GW="$DEFAULT_GW"
    GW_MODE="manual"
    log "默认 IPv6 网关可用：$IPV6_GW"

else
    echo
    warn "默认候选网关不可用，需要手动输入。"

    while true; do
        read -r -p "请输入 VPS 的 IPv6 网关地址：" IPV6_GW </dev/tty

        if [[ -z "$IPV6_GW" ]]; then
            warn "网关不能为空，请输入正确的 IPv6 网关。"
            continue
        fi

        # 校验并规范化 IPv6 地址
        IPV6_GW="$(
        python3 - "$IPV6_GW" <<'PY'
import ipaddress
import sys

try:
    raw = sys.argv[1].split("%")[0]
    addr = ipaddress.IPv6Address(raw)

    if addr.is_unspecified or addr.is_multicast or addr.is_loopback:
        raise ValueError("不能使用该地址作为网关")

    print(addr.compressed)

except Exception as e:
    print("IPv6 网关格式错误：", e, file=sys.stderr)
    sys.exit(1)
PY
        )" || {
            warn "IPv6 地址格式不正确，请重新输入。"
            continue
        }

        if test_ipv6_gateway "$IPV6_GW"; then
            GW_MODE="manual"
            log "手动 IPv6 网关配置成功：$IPV6_GW"
            break
        fi

        warn "这个网关无法通过 IPv6 外网测试，请重新输入。"
    done
fi

# 最终确认默认路由
ip -6 route show default dev "$NIC" | grep -q '^default' \
    || fail "IPv6 默认路由不存在"

echo
log "最终 IPv6 网关：$IPV6_GW"
ip -6 route show default


# ------------------------------------------------------------
# 8. IPv6 配置持久化
# ------------------------------------------------------------

log "配置 IPv6 开机自动恢复..."

# 保存 IPv6 系统参数
cat > /etc/sysctl.d/99-hy2-ipv6.conf <<EOF
net.ipv6.conf.all.disable_ipv6=0
net.ipv6.conf.default.disable_ipv6=0
net.ipv6.conf.${NIC}.disable_ipv6=0
net.ipv6.conf.${NIC}.accept_ra=2
EOF

sysctl --system >/dev/null

# 保存网卡、IPv6 地址、网关和网关配置模式
{
    printf 'NIC=%q\n' "$NIC"
    printf 'IPV6_CIDR=%q\n' "$IPV6_CIDR"
    printf 'IPV6_GW=%q\n' "$IPV6_GW"
    printf 'GW_MODE=%q\n' "$GW_MODE"
} > "$IPV6_ENV"

chmod 600 "$IPV6_ENV"


cat > "$IPV6_APPLY" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

source /etc/hy2-ipv6.env

echo "[INFO] 开始恢复 IPv6 配置..."

for i in $(seq 1 30); do
    if ip link show dev "$NIC" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

ip link show dev "$NIC" >/dev/null 2>&1 || {
    echo "[ERROR] 网卡 $NIC 不存在"
    exit 1
}

# 启用 IPv6
sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null
sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null
sysctl -w "net.ipv6.conf.${NIC}.disable_ipv6=0" >/dev/null
sysctl -w "net.ipv6.conf.${NIC}.accept_ra=2" >/dev/null

# 恢复 IPv6 地址
ip -6 addr replace "$IPV6_CIDR" dev "$NIC"

# 必须使用安装时验证成功的网关
if [[ -z "${IPV6_GW:-}" ]]; then
    echo "[ERROR] IPv6 网关为空"
    exit 1
fi

echo "[INFO] 恢复 IPv6 网关：$IPV6_GW"

if [[ "${IPV6_GW,,}" == fe80:* ]]; then
    ip -6 route replace default via "$IPV6_GW" dev "$NIC"
else
    ip -6 route replace default via "$IPV6_GW" dev "$NIC" onlink
fi

echo "[INFO] IPv6 默认路由恢复完成"
ip -6 route show default
EOF


chmod 700 "$IPV6_APPLY"

# 生成 systemd 服务文件（之前遗漏了这一段）
cat > "$IPV6_SERVICE" <<EOF
[Unit]
Description=Hy2 IPv6 Address Persistence
Wants=network-online.target
After=network-online.target systemd-sysctl.service

[Service]
Type=oneshot
ExecStart=${IPV6_APPLY}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# 重新加载 systemd 并启用 IPv6 恢复服务
systemctl daemon-reload
systemctl enable hy2-ipv6.service
systemctl restart hy2-ipv6.service

# 检查服务状态
systemctl status hy2-ipv6.service --no-pager


log "IPv6 开机自动恢复配置完成"

# ------------------------------------------------------------
# 9. SSH 端口
# ------------------------------------------------------------

SSH_PORT="10085"

log "SSH TCP 端口固定为：${SSH_PORT}"

# ------------------------------------------------------------
# 10. 防火墙规则
#
# 不清空现有规则
# 不修改默认策略
# 不改变其他端口规则
# 使用 -C 检查，避免重复添加
# ------------------------------------------------------------

add_v4_input() {
    if ! iptables -C INPUT "$@" 2>/dev/null; then
        iptables -I INPUT 1 "$@"
    fi
}

add_v6_input() {
    if ! ip6tables -C INPUT "$@" 2>/dev/null; then
        ip6tables -I INPUT 1 "$@"
    fi
}

add_v4_nat() {
    if ! iptables -t nat -C PREROUTING "$@" 2>/dev/null; then
        iptables -t nat -I PREROUTING 1 "$@"
    fi
}

add_v6_nat() {
    if ! ip6tables -t nat -C PREROUTING "$@" 2>/dev/null; then
        ip6tables -t nat -I PREROUTING 1 "$@"
    fi
}

log "添加 IPv4 指定端口规则..."

# SSH
# SSH TCP 10085
add_v4_input -p tcp --dport 10085 -j ACCEPT

# HTTP / HTTPS
for PORT in 80 443; do
    add_v4_input -p tcp --dport "$PORT" -j ACCEPT
done

# UDP Hy2 主端口
add_v4_input -p udp --dport "$HY2_PORT" -j ACCEPT

# UDP 端口跳跃范围
add_v4_input -p udp --dport "${HOP_START}:${HOP_END}" -j ACCEPT

# IPv4 端口跳跃转发到本机 Hy2 端口
add_v4_nat -i "$NIC" \
    -p udp \
    --dport "${HOP_START}:${HOP_END}" \
    -j REDIRECT --to-ports "$HY2_PORT"

log "添加 IPv6 指定端口规则..."

# SSH
# SSH TCP 10085
# add_v6_input -p tcp --dport 10085 -j ACCEPT

# HTTP / HTTPS
for PORT in 80 443; do
    add_v6_input -p tcp --dport "$PORT" -j ACCEPT
done

# UDP Hy2 主端口
add_v6_input -p udp --dport "$HY2_PORT" -j ACCEPT

# UDP 端口跳跃范围
add_v6_input -p udp --dport "${HOP_START}:${HOP_END}" -j ACCEPT

# IPv6 端口跳跃转发到本机 Hy2 端口
add_v6_nat -i "$NIC" \
    -p udp \
    --dport "${HOP_START}:${HOP_END}" \
    -j REDIRECT --to-ports "$HY2_PORT"

# ------------------------------------------------------------
# 11. 持久化防火墙规则
# ------------------------------------------------------------

log "保存现有 IPv4、IPv6 防火墙规则..."

netfilter-persistent save

systemctl enable netfilter-persistent >/dev/null 2>&1 || true

# ------------------------------------------------------------
# 12. 安装 Hysteria 2
# ------------------------------------------------------------

log "开始安装 Hysteria 2..."

HY2_INSTALLER="/tmp/get.hy2.sh"

curl -fsSL https://get.hy2.sh/ -o "$HY2_INSTALLER" ||
    fail "下载 Hy2 官方安装脚本失败"

bash "$HY2_INSTALLER" ||
    fail "Hy2 安装失败"

rm -f "$HY2_INSTALLER"

log "Hy2 安装程序执行完毕"

# ------------------------------------------------------------
# 13. 生成自签证书
# ------------------------------------------------------------

log "生成 Hysteria 2 自签证书..."

mkdir -p "$CERT_DIR"

# 设置 Hy2 配置目录权限
chown root:hysteria "$CERT_DIR"
chmod 750 "$CERT_DIR"

# 如果已有证书，先备份
if [[ -f "$CERT_KEY" ]]; then
    cp -a "$CERT_KEY" "$BACKUP_DIR/server.key.before"
fi

if [[ -f "$CERT_CRT" ]]; then
    cp -a "$CERT_CRT" "$BACKUP_DIR/server.crt.before"
fi

umask 077

openssl req \
    -x509 \
    -nodes \
    -newkey ec:<(openssl ecparam -name prime256v1) \
    -keyout "$CERT_KEY" \
    -out "$CERT_CRT" \
    -subj "/CN=bing.com" \
    -days 36500 ||
    fail "自签证书生成失败"

# 按官方安装后的 hysteria 用户设置权限
if id hysteria >/dev/null 2>&1; then
    chown hysteria "$CERT_KEY"
    chown hysteria "$CERT_CRT"
else
    fail "未找到 hysteria 用户，请检查 Hy2 安装结果"
fi


chmod 600 "$CERT_KEY"
chmod 644 "$CERT_CRT"

# ------------------------------------------------------------
# 动态配置 Hysteria 2 用户账号
# ------------------------------------------------------------

log "开始配置 Hysteria 2 用户认证..."

read -r -p "请输入需要创建的账号数量（1-20）: " USER_COUNT </dev/tty

if [[ ! "$USER_COUNT" =~ ^([1-9]|1[0-9]|20)$ ]]; then
    fail "账号数量必须是 1-20 之间的整数"
fi

declare -A HY2_USERS
HY2_USER_SUMMARY=""

for ((i=1; i<=USER_COUNT; i++)); do
    echo
    echo "===== 配置第 $i 个账号 ====="

    while true; do
        read -r -p "请输入用户名: " USERNAME </dev/tty

        if [[ ! "$USERNAME" =~ ^[A-Za-z0-9_-]{1,32}$ ]]; then
            echo "用户名只能使用字母、数字、下划线和连字符，长度 1-32 位"
            continue
        fi

        if [[ -n "${HY2_USERS[$USERNAME]+exists}" ]]; then
            echo "用户名重复，请重新输入"
            continue
        fi

        break
    done

    while true; do
        read -r -s -p "请输入 $USERNAME 的密码（8-128位）: " PASSWORD </dev/tty
        echo

        if [[ ! "$PASSWORD" =~ ^[A-Za-z0-9_-]{8,128}$ ]]; then
            echo "密码只能使用字母、数字、下划线和连字符，长度 8-128 位"
            continue
        fi

        break
    done

    HY2_USERS["$USERNAME"]="$PASSWORD"
    HY2_USER_SUMMARY+="${USERNAME}: ${PASSWORD}"$'\n'
done

log "正在生成 Hy2 配置文件..."

umask 077

{
    cat << 'EOF'
listen: :10086

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  maxIncomingStreams: 1024
  disablePathMTUDiscovery: false

ignoreClientBandwidth: false
disableUDP: false
udpIdleTimeout: 60s

auth:
  type: userpass
  userpass:
EOF

    for username in "${!HY2_USERS[@]}"; do
        printf '    "%s": "%s"\n' "$username" "${HY2_USERS[$username]}"
    done

    cat << 'EOF'

resolver:
  type: https
  https:
    addr: 1.1.1.1:443
    timeout: 10s
    sni: cloudflare-dns.com
    insecure: false

acl:
  inline:
    - reject(geoip:cn)

masquerade:
  type: proxy
  proxy:
    url: https://bing.com
    rewriteHost: true
EOF
} > "$CERT_DIR/config.yaml"

chown root:hysteria "$CERT_DIR/config.yaml"
chmod 640 "$CERT_DIR/config.yaml"

HY2_USER_NAMES=$(printf '%s\n' "${!HY2_USERS[@]}" | sort)
unset PASSWORD USERNAME

log "Hy2 配置文件生成完成，共创建 ${USER_COUNT} 个账号"


# ------------------------------------------------------------
# 生成并保存 Hy2 证书指纹
# ------------------------------------------------------------

log "生成 Hy2 证书指纹..."

HEX_FP=$(openssl x509 -noout -fingerprint -sha256 -in "$CERT_CRT" \
    | cut -d'=' -f2 | tr -d ':' | tr 'A-F' 'a-f')

# 分享链接使用的大写 SHA256 指纹
HYPER_FP="${HEX_FP^^}"

PUB_B64=$(openssl x509 -in "$CERT_CRT" -pubkey -noout \
    | openssl pkey -pubin -outform der \
    | openssl dgst -sha256 -binary \
    | openssl enc -base64)

cat > "$CERT_DIR/fingerprint.txt" << EOF
通用无冒号指纹 (v2rayN/Shadowrocket/Clash):
$HEX_FP

sing-box 1.14 专用指纹 (certificate_public_key_sha256):
$PUB_B64
EOF

chmod 644 "$CERT_DIR/fingerprint.txt"

log "证书指纹已保存至 $CERT_DIR/fingerprint.txt"

# ------------------------------------------------------------
# 启用 Hy2 开机启动并启动服务
# ------------------------------------------------------------

log "启用 Hy2 开机启动..."

systemctl enable hysteria-server.service

log "启动 Hy2 服务..."

systemctl restart hysteria-server.service

log "检查 Hy2 服务状态..."

systemctl status hysteria-server.service --no-pager

# ------------------------------------------------------------
# 14. IPv6 连通性测试
# ------------------------------------------------------------

echo
log "测试 IPv6 外网连通性..."

if command -v curl >/dev/null 2>&1 &&
   curl -6 -fsS --connect-timeout 8 --max-time 15 \
       https://api64.ipify.org >/tmp/hy2-ipv6-result 2>/dev/null; then

    IPV6_PUBLIC="$(cat /tmp/hy2-ipv6-result)"
    log "IPv6 外网测试成功：${IPV6_PUBLIC}"
else
    warn "IPv6 外网测试失败"
    warn "请检查默认路由、服务商网关及 VPS 面板的 IPv6 配置"
fi

rm -f /tmp/hy2-ipv6-result

# ------------------------------------------------------------
# 15. 输出结果
# ------------------------------------------------------------


# ------------------------------------------------------------
# 15. 输出最终结果
# ------------------------------------------------------------


# ------------------------------------------------------------
# 15. 输出最终结果
# ------------------------------------------------------------

echo
echo "================================================"
echo "              VPS 初始化完成"
echo "================================================"

echo
echo "【网卡】"
echo "$NIC"

echo
echo "【IPv6 地址】"
ip -6 addr show dev "$NIC" scope global

echo
echo "【IPv6 默认路由】"
ip -6 route show default

echo
echo "【SSH】"
echo "TCP ${SSH_PORT}"

echo
echo "【开放端口】"
echo "TCP: ${SSH_PORT}, 80, 443"
echo "UDP: ${HY2_PORT}, ${HOP_START}-${HOP_END}"

echo
echo "【Hy2】"
echo "主端口：UDP ${HY2_PORT}"
echo "配置文件：$CERT_DIR/config.yaml"
echo "证书：$CERT_CRT"
echo "私钥：$CERT_KEY"
echo "服务状态："
systemctl is-active hysteria-server.service || true

echo
echo "【防火墙】"
echo "原有规则未清空"
echo "默认策略未修改"
echo "只添加本脚本指定的端口规则"

echo
echo "【备份目录】"
echo "$BACKUP_DIR"

echo
echo "【Hy2 账号数量】"
echo "$USER_COUNT"

echo
echo "【Hy2 账号及密码】"
echo "$HY2_USER_SUMMARY"

echo
echo "【通用 SHA256 证书指纹】"
echo "$HEX_FP"

echo
echo "【sing-box 1.14 公钥 SHA256 指纹】"
echo "$PUB_B64"

echo
echo "【指纹文件】"
echo "$CERT_DIR/fingerprint.txt"


# ------------------------------------------------------------
# 16. 生成 IPv4 / IPv6 分享链接及二维码
# Apple 小火箭格式 + V2Ray 格式
# ------------------------------------------------------------

log "开始生成 Hy2 IPv4 / IPv6 分享链接及二维码..."

# 获取服务器公网 IPv4
SERVER_IPV4="$(curl -4fsS --connect-timeout 8 --max-time 12 \
    https://api.ipify.org 2>/dev/null || true)"

# 获取服务器 IPv6
SERVER_IPV6="$(python3 - "$IPV6_CIDR" <<'PY'
import ipaddress
import sys

print(ipaddress.IPv6Interface(sys.argv[1]).ip.compressed)
PY
)" || fail "无法获取 IPv6 地址"

# 使用当前证书 SHA256 指纹，大写、无冒号
HYPER_FP="${HEX_FP^^}"

# 二维码图片尺寸：3 比原来的 4 更小
QR_SCALE=3
QR_MARGIN=1

# 检查二维码工具
command -v qrencode >/dev/null 2>&1 ||
    fail "未找到 qrencode，请先安装 qrencode"

# 保存目录
SHARE_DIR="/root/hy2-share"
mkdir -p "$SHARE_DIR"
chmod 700 "$SHARE_DIR"

# 临时文件目录
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# 输出两个二维码并排显示

print_qr_pair() {
    local LEFT_FILE="$1"
    local RIGHT_FILE="$2"
    local LEFT_TITLE="$3"
    local RIGHT_TITLE="$4"

    [[ -s "$LEFT_FILE" ]] || {
        echo "[ERROR] 左侧二维码文件为空：$LEFT_FILE"
        return 1
    }

    [[ -s "$RIGHT_FILE" ]] || {
        echo "[ERROR] 右侧二维码文件为空：$RIGHT_FILE"
        return 1
    }

    python3 - "$LEFT_FILE" "$RIGHT_FILE" \
        "$LEFT_TITLE" "$RIGHT_TITLE" <<'PY'
import sys
import re

left_file, right_file, left_title, right_title = sys.argv[1:]

ansi = re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]')

def read_qr(path):
    with open(path, encoding="utf-8") as f:
        return f.read().splitlines()

left = read_qr(left_file)
right = read_qr(right_file)

# 计算左侧二维码实际显示宽度
def visible_width(line):
    return len(ansi.sub("", line))

left_width = max((visible_width(line) for line in left), default=0)

# 标题分别放在左右二维码正上方
print(left_title + " " * max(1, left_width - len(left_title) + 2)
      + right_title)

# 两边二维码逐行并排显示
rows = max(len(left), len(right))

for i in range(rows):
    l = left[i] if i < len(left) else ""
    r = right[i] if i < len(right) else ""

    padding = max(0, left_width - visible_width(l)) + 2
    print(l + " " * padding + r)
PY
}


echo
echo "================================================"
echo "       Hy2 IPv4 / IPv6 分享链接生成"
echo "================================================"

echo
echo "IPv4：${SERVER_IPV4:-未检测到公网 IPv4}"
echo "IPv6：${SERVER_IPV6}"
echo "Hy2 主端口：${HY2_PORT}"
echo "UDP 跳跃端口：${HOP_START}-${HOP_END}"
echo "证书 SHA256 指纹：${HYPER_FP}"

# 逐个账号生成链接
for USERNAME in "${!HY2_USERS[@]}"; do

    PASSWORD="${HY2_USERS[$USERNAME]}"

    echo
    echo "================================================"
    echo "账号：$USERNAME"
    echo "================================================"

    # ========================================================
    # 1. Apple 小火箭格式
    # ========================================================

    # IPv4
    if [[ -n "$SERVER_IPV4" ]]; then

        URL_IPV4="$(python3 - \
            "$USERNAME" "$PASSWORD" "$SERVER_IPV4" \
            "$HY2_PORT" "$HOP_START" "$HOP_END" "$HYPER_FP" <<'PY'
import sys
from urllib.parse import quote

user, password, host, port, hop_start, hop_end, pin = sys.argv[1:]

auth = quote(user, safe="") + ":" + quote(password, safe="")
remark = quote(user + " IPv4", safe="")

print(
    f"hysteria2://{auth}@{host}:{port}"
    f"?peer=bing.com"
    f"&insecure=1"
    f"&upmbps=50"
    f"&downmbps=100"
    f"&keepalive=60"
    f"&hpkp={pin}"
    f"&fingerprint=Safari26_3"
    f"&mport={hop_start}-{hop_end}"
    f"#{remark}"
)
PY
)" || fail "Apple IPv4 分享链接生成失败"

        printf '%s\n' "$URL_IPV4" \
            > "$SHARE_DIR/${USERNAME}-IPv4.txt"

        qrencode -o "$SHARE_DIR/${USERNAME}-IPv4.png" \
            -s "$QR_SCALE" -m "$QR_MARGIN" "$URL_IPV4"

        qrencode -t ANSIUTF8 "$URL_IPV4" \
            > "$TMP_DIR/${USERNAME}-IPv4.qr"
    fi

    # IPv6
    URL_IPV6="$(python3 - \
        "$USERNAME" "$PASSWORD" "$SERVER_IPV6" \
        "$HY2_PORT" "$HOP_START" "$HOP_END" "$HYPER_FP" <<'PY'
import sys
from urllib.parse import quote

user, password, host, port, hop_start, hop_end, pin = sys.argv[1:]

auth = quote(user, safe="") + ":" + quote(password, safe="")
remark = quote(user + " IPv6", safe="")

print(
    f"hysteria2://{auth}@[{host}]:{port}"
    f"?peer=bing.com"
    f"&insecure=1"
    f"&upmbps=50"
    f"&downmbps=100"
    f"&keepalive=60"
    f"&hpkp={pin}"
    f"&fingerprint=Safari26_3"
    f"&mport={hop_start}-{hop_end}"
    f"#{remark}"
)
PY
)" || fail "Apple IPv6 分享链接生成失败"

    printf '%s\n' "$URL_IPV6" \
        > "$SHARE_DIR/${USERNAME}-IPv6.txt"

    qrencode -o "$SHARE_DIR/${USERNAME}-IPv6.png" \
        -s "$QR_SCALE" -m "$QR_MARGIN" "$URL_IPV6"

    qrencode -t ANSIUTF8 "$URL_IPV6" \
        > "$TMP_DIR/${USERNAME}-IPv6.qr"

    echo
    echo "【Apple 小火箭 IPv4 分享链接】"
    if [[ -n "$SERVER_IPV4" ]]; then
        echo "$URL_IPV4"
    else
        echo "未检测到公网 IPv4，跳过"
    fi

    echo
    echo "【Apple 小火箭 IPv6 分享链接】"
    echo "$URL_IPV6"

    echo
    echo "【Apple 小火箭二维码】"

    if [[ -n "$SERVER_IPV4" ]]; then
        print_qr_pair \
            "$TMP_DIR/${USERNAME}-IPv4.qr" \
            "$TMP_DIR/${USERNAME}-IPv6.qr" \
            "IPv4" "IPv6"
    else
        echo "IPv6"
        cat "$TMP_DIR/${USERNAME}-IPv6.qr"
    fi

    # ========================================================
    # 2. V2Ray 格式
    # ========================================================

    # IPv4
    if [[ -n "$SERVER_IPV4" ]]; then

        URL_V2RAY_IPV4="$(python3 - \
            "$USERNAME" "$PASSWORD" "$SERVER_IPV4" \
            "$HY2_PORT" "$HOP_START" "$HOP_END" "$HYPER_FP" <<'PY'
import sys
from urllib.parse import quote

user, password, host, port, hop_start, hop_end, pin = sys.argv[1:]

# 按示例格式将用户名和密码之间的冒号编码为 %3A
auth = quote(user + ":" + password, safe="")
remark = quote(user + " IPv4", safe="")

print(
    f"hysteria2://{auth}@{host}:{port}"
    f"?security=tls"
    f"&insecure=1"
    f"&mport={hop_start}-{hop_end}"
    f"&pinSHA256={pin}"
    f"&sni=bing.com"
    f"#{remark}"
)
PY
)" || fail "V2Ray IPv4 分享链接生成失败"

        printf '%s\n' "$URL_V2RAY_IPV4" \
            > "$SHARE_DIR/${USERNAME}-V2Ray-IPv4.txt"

        qrencode -o "$SHARE_DIR/${USERNAME}-V2Ray-IPv4.png" \
            -s "$QR_SCALE" -m "$QR_MARGIN" "$URL_V2RAY_IPV4"

        qrencode -t ANSIUTF8 "$URL_V2RAY_IPV4" \
            > "$TMP_DIR/${USERNAME}-V2Ray-IPv4.qr"
    fi

    # IPv6
    URL_V2RAY_IPV6="$(python3 - \
        "$USERNAME" "$PASSWORD" "$SERVER_IPV6" \
        "$HY2_PORT" "$HOP_START" "$HOP_END" "$HYPER_FP" <<'PY'
import sys
from urllib.parse import quote

user, password, host, port, hop_start, hop_end, pin = sys.argv[1:]

auth = quote(user + ":" + password, safe="")
remark = quote(user + " IPv6", safe="")

print(
    f"hysteria2://{auth}@[{host}]:{port}"
    f"?security=tls"
    f"&insecure=1"
    f"&mport={hop_start}-{hop_end}"
    f"&pinSHA256={pin}"
    f"&sni=bing.com"
    f"#{remark}"
)
PY
)" || fail "V2Ray IPv6 分享链接生成失败"

    printf '%s\n' "$URL_V2RAY_IPV6" \
        > "$SHARE_DIR/${USERNAME}-V2Ray-IPv6.txt"

    qrencode -o "$SHARE_DIR/${USERNAME}-V2Ray-IPv6.png" \
        -s "$QR_SCALE" -m "$QR_MARGIN" "$URL_V2RAY_IPV6"

    qrencode -t ANSIUTF8 "$URL_V2RAY_IPV6" \
        > "$TMP_DIR/${USERNAME}-V2Ray-IPv6.qr"

    # ========================================================
    # 3. 输出 V2Ray 链接和二维码
    # ========================================================

    echo
    echo "【V2Ray IPv4 分享链接】"
    if [[ -n "$SERVER_IPV4" ]]; then
        echo "$URL_V2RAY_IPV4"
    else
        echo "未检测到公网 IPv4，跳过"
    fi

    echo
    echo "【V2Ray IPv6 分享链接】"
    echo "$URL_V2RAY_IPV6"

    echo
    echo "【V2Ray 二维码】"

    if [[ -n "$SERVER_IPV4" ]]; then
        print_qr_pair \
            "$TMP_DIR/${USERNAME}-V2Ray-IPv4.qr" \
            "$TMP_DIR/${USERNAME}-V2Ray-IPv6.qr" \
            "IPv4" "IPv6"
    else
        echo "IPv6"
        cat "$TMP_DIR/${USERNAME}-V2Ray-IPv6.qr"
    fi

    # ========================================================
    # 4. 文件权限
    # ========================================================

    chmod 600 "$SHARE_DIR/${USERNAME}"-*.txt
    chmod 600 "$SHARE_DIR/${USERNAME}"-*.png

    echo
    echo "【二维码图片文件】"

    if [[ -n "$SERVER_IPV4" ]]; then
        echo "Apple IPv4：$SHARE_DIR/${USERNAME}-IPv4.png"
        echo "V2Ray IPv4：$SHARE_DIR/${USERNAME}-V2Ray-IPv4.png"
    fi

    echo "Apple IPv6：$SHARE_DIR/${USERNAME}-IPv6.png"
    echo "V2Ray IPv6：$SHARE_DIR/${USERNAME}-V2Ray-IPv6.png"

    echo
done

echo "================================================"
echo "所有账号的分享链接及二维码生成完成"
echo "保存目录：$SHARE_DIR"
echo "================================================"

unset PASSWORD USERNAME

echo
echo "================================================"
echo "        Hysteria 2 安装及配置完成"
echo "================================================"
