
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
    python3

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
# 7. IPv6 自动获取网关
# ------------------------------------------------------------

log "检查 IPv6 默认路由..."

HAS_DEFAULT_ROUTE=0

if ip -6 route show default | grep -q .; then
    HAS_DEFAULT_ROUTE=1
    log "发现系统已有 IPv6 默认路由"
else
    log "暂未发现默认路由，等待服务商 RA 自动下发..."

    for i in $(seq 1 30); do
        if ip -6 route show default | grep -q .; then
            HAS_DEFAULT_ROUTE=1
            break
        fi
        sleep 1
    done
fi

if [[ "$HAS_DEFAULT_ROUTE" -eq 1 ]]; then
    ip -6 route show default
else
    warn "没有检测到 IPv6 默认路由"
    warn "不会猜测网关，也不会擅自添加 ::1"
    warn "如果服务商使用静态网关，需要按其网络说明配置"
fi

# ------------------------------------------------------------
# 8. IPv6 配置持久化
# ------------------------------------------------------------

log "配置 IPv6 开机自动恢复..."

cat > /etc/sysctl.d/99-hy2-ipv6.conf <<EOF
net.ipv6.conf.all.disable_ipv6=0
net.ipv6.conf.default.disable_ipv6=0
net.ipv6.conf.${NIC}.disable_ipv6=0
net.ipv6.conf.${NIC}.accept_ra=2
EOF

sysctl --system >/dev/null

# 保存网卡和 IPv6 地址
{
    printf 'NIC=%q\n' "$NIC"
    printf 'IPV6_CIDR=%q\n' "$IPV6_CIDR"
} > "$IPV6_ENV"

chmod 600 "$IPV6_ENV"

cat > "$IPV6_APPLY" <<'EOF'
#!/usr/bin/env bash
set -e

source /etc/hy2-ipv6.env

for i in $(seq 1 30); do
    if ip link show dev "$NIC" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

ip link show dev "$NIC" >/dev/null 2>&1 || exit 1

sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null
sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null
sysctl -w "net.ipv6.conf.${NIC}.disable_ipv6=0" >/dev/null
sysctl -w "net.ipv6.conf.${NIC}.accept_ra=2" >/dev/null

ip -6 addr replace "$IPV6_CIDR" dev "$NIC"
EOF

chmod 700 "$IPV6_APPLY"

cat > "$IPV6_SERVICE" <<EOF
[Unit]
Description=Hy2 IPv6 Address Persistence
After=network.target systemd-sysctl.service

[Service]
Type=oneshot
ExecStart=${IPV6_APPLY}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hy2-ipv6.service

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

echo
echo "================================================"
echo "          VPS 初始化完成"
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
echo "TCP: ${SSH_PORT}, 80, 443, 10085"
echo "UDP: 10086, 20000-20500"

echo
echo "【Hy2】"
echo "安装程序已执行"
echo "主端口：UDP ${HY2_PORT}"
echo "证书：${CERT_CRT}"
echo "私钥：${CERT_KEY}"

echo
echo "【防火墙】"
echo "原有规则未清空"
echo "默认策略未修改"
echo "只添加本脚本指定的端口规则"

echo
echo "【Hy2 配置文件】"
echo "本脚本没有生成或覆盖 config.yaml"
echo "请自行配置服务端参数"

echo
echo "【备份目录】"
echo "$BACKUP_DIR"

echo
echo "================================================"
echo "请检查 Hy2 配置后，再启动服务。"
echo "================================================"
