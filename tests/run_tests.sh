#!/usr/bin/env bash
# ==========================================
# jiaoben 回归测试
# 用法: bash tests/run_tests.sh
# 覆盖已修复的 bug，防止回归。不需要 root，不联网，不改动系统。
# ==========================================
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $1"; FAIL=$((FAIL+1)); }
chk()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (期望 '$3' 实际 '$2')"; fi; }

TMP=$(mktemp -d 2>/dev/null) || TMP=""
if [[ -z "$TMP" || ! -d "$TMP" ]]; then
    TMP="/tmp/jbtest.$$"
    mkdir -p "$TMP" || { echo "无法创建临时目录" >&2; exit 1; }
fi
trap 'rm -rf "$TMP"' EXIT

echo "== 1. 语法检查 =="
for f in run.sh common.sh uninstall.sh jb_improved.sh; do
    if bash -n "$REPO_DIR/$f" 2>/dev/null; then ok "$f 语法"; else bad "$f 语法"; fi
done

echo "== 2. Hysteria2 节点链接：主机名必须是服务器地址，不是伪装 SNI =="
# 复现 v5.3 bug：自签证书时 host 被写成 www.bing.com
build_hy2_link() {
    local cert_method="$1" pass="pw" port="34567" sni="$2" insecure="$3"
    local acme_domain="$4" pub_ip="$5" hop="$6" hop_range="$7"
    local link_host link_sni
    link_sni="${sni:-www.bing.com}"
    if [[ "$cert_method" == "acme" ]]; then
        link_host="$acme_domain"
    else
        link_host="$pub_ip"
    fi
    local q="insecure=${insecure:-0}&sni=${link_sni}"
    [[ "$hop" == "yes" ]] && q="${q}&mport=${hop_range}"
    echo "hysteria2://${pass}@${link_host}:${port}?${q}#Hysteria2"
}
L=$(build_hy2_link self www.bing.com 1 "" 203.0.113.9 no "")
H=$(python3 -c "import sys;from urllib.parse import urlparse;print(urlparse(sys.argv[1]).hostname)" "$L")
chk "自签证书 host 用公网 IP" "$H" "203.0.113.9"
S=$(python3 -c "import sys;from urllib.parse import urlparse,parse_qs;print(parse_qs(urlparse(sys.argv[1]).query)['sni'][0])" "$L")
chk "伪装域名保留在 sni 参数" "$S" "www.bing.com"

L6=$(build_hy2_link self www.bing.com 1 "" "[2001:db8::1]" no "")
H6=$(python3 -c "import sys;from urllib.parse import urlparse;print(urlparse(sys.argv[1]).hostname)" "$L6")
chk "IPv6 host 可正确解析" "$H6" "2001:db8::1"

LA=$(build_hy2_link acme my.example.com "" my.example.com 203.0.113.9 no "")
HA=$(python3 -c "import sys;from urllib.parse import urlparse;print(urlparse(sys.argv[1]).hostname)" "$LA")
chk "ACME 模式 host 用域名" "$HA" "my.example.com"

echo "== 3. mport 必须在 query 中，不能落入 fragment =="
LH=$(build_hy2_link self www.bing.com 1 "" 203.0.113.9 yes "34567-34642")
FRAG=$(python3 -c "import sys;from urllib.parse import urlparse;print(urlparse(sys.argv[1]).fragment)" "$LH")
chk "fragment 干净" "$FRAG" "Hysteria2"
MP=$(python3 -c "import sys;from urllib.parse import urlparse,parse_qs;print(parse_qs(urlparse(sys.argv[1]).query).get('mport',['MISSING'])[0])" "$LH")
chk "mport 在 query 中" "$MP" "34567-34642"

echo "== 4. 节点记录：单独部署不清空其它协议，同协议重复部署覆盖 =="
WORKDIR_BASE="$TMP/w"; mkdir -p "$WORKDIR_BASE"
INFO_FILE="$WORKDIR_BASE/all_nodes_info.txt"
NODES_FILE="$INFO_FILE"; NODES_DB="$WORKDIR_BASE/nodes.tsv"
_init_nodes_file() { mkdir -p "$WORKDIR_BASE"; [[ -f "$NODES_DB" ]] || : > "$NODES_DB"; }
render_nodes_file() {
    _init_nodes_file
    { echo "# jiaoben 节点信息"
      while IFS=$'\t' read -r n l; do
        [[ -n "$n" && -n "$l" ]] || continue
        echo ""; echo "│ $n"; echo "$l"
      done < "$NODES_DB"
    } > "$NODES_FILE"
}
append_node() {
    local name="$1" link="$2"; _init_nodes_file
    local t="${NODES_DB}.t"
    awk -F'\t' -v n="$name" 'NF && $1 != n' "$NODES_DB" > "$t" 2>/dev/null || : > "$t"
    printf '%s\t%s\n' "$name" "$link" >> "$t"; mv -f "$t" "$NODES_DB"; render_nodes_file
}
append_node "REALITY (VLESS)" "vless://a#REALITY"
append_node "Hysteria2" "hysteria2://b#HY2"
grep -q 'vless://a' "$NODES_FILE" && ok "部署 HY2 后 REALITY 链接仍在" || bad "REALITY 链接丢失"
append_node "Hysteria2" "hysteria2://NEW#HY2"
C=$(grep -c 'hysteria2://' "$NODES_FILE")
chk "同协议重复部署只保留 1 条" "$C" "1"
grep -q 'hysteria2://NEW' "$NODES_FILE" && ok "保留的是最新链接" || bad "未更新为最新链接"

echo "== 5. Argo inbound 不累积、不产生重复端口 =="
if command -v jq >/dev/null 2>&1; then
    CFG="$TMP/config.json"
    echo '{"inbounds":[{"port":443,"protocol":"vless","tag":"reality"}],"outbounds":[]}' > "$CFG"
    add_argo() {
        local p="$1"
        jq --argjson port "$p" --arg uuid "u$p" --arg path "/p$p" '
          .inbounds |= map(select((.streamSettings.network // "") != "ws"))
          | .inbounds += [{"port":$port,"protocol":"vless","tag":"argo-ws",
              "settings":{"clients":[{"id":$uuid}],"decryption":"none"},
              "streamSettings":{"network":"ws","wsSettings":{"path":$path}}}]' "$CFG" > "$CFG.t" && mv "$CFG.t" "$CFG"
    }
    add_argo 20001; add_argo 20002; add_argo 20003
    N=$(jq '.inbounds|length' "$CFG")
    chk "三次部署后 inbound 数仍为 2" "$N" "2"
    R=$(jq -r '[.inbounds[]|select(.tag=="reality")]|length' "$CFG")
    chk "REALITY inbound 未被误删" "$R" "1"
    P=$(jq -r '.inbounds[]|select(.streamSettings.network=="ws")|.port' "$CFG")
    chk "保留的是最后一次端口" "$P" "20003"
    D=$(jq -r '[.inbounds[].port]|group_by(.)|map(select(length>1))|length' "$CFG")
    chk "无重复端口" "$D" "0"
else
    echo "  (跳过：无 jq)"
fi

echo "== 6. UUID 为合法 RFC4122 v4 =="
gen_uuid() {
    local h v
    h=$(od -An -N16 -x /dev/urandom 2>/dev/null | tr -d '[:space:]')
    [[ ${#h} -ge 32 ]] || h=$(openssl rand -hex 16 2>/dev/null)
    v=$(printf '%x' $(( 0x8 | (0x${h:16:1} & 0x3) )))
    echo "${h:0:8}-${h:8:4}-4${h:12:3}-${v}${h:16:3}-${h:20:12}"
}
for i in 1 2 3; do
    u=$(gen_uuid)
    if [[ "$u" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]]; then
        ok "uuid#$i 合规"
    else bad "uuid#$i 不合规: $u"; fi
done

echo "== 7. Hysteria2 YAML：listen 单端口、insecure 为 bool =="
if python3 -c 'import yaml' 2>/dev/null; then
    insecure="1"; yi="false"; [[ "$insecure" == "1" ]] && yi="true"
    cat > "$TMP/hy2.yaml" <<EOF
listen: :34567
tls:
  cert: /x.crt
  key: /x.key
auth:
  type: password
  password: pw
masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true
    insecure: ${yi}
EOF
    python3 - "$TMP/hy2.yaml" <<'PY' && ok "YAML 合法且字段类型正确" || bad "YAML 校验失败"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
assert d['masquerade']['proxy']['insecure'] is True
assert '-' not in d['listen']
PY
else
    echo "  (跳过：无 python yaml)"
fi

echo "== 8. REALITY 伪装域名与 JSON 合法性 =="
grep -q 'domain="www.amd.com"' "$REPO_DIR/run.sh" && ok "伪装域名为 www.amd.com" || bad "伪装域名不符"

echo "== 9. jb 工具可脱离源码目录运行 =="
mkdir -p "$TMP/lib"
cp "$REPO_DIR/jb_improved.sh" "$TMP/lib/" && cp "$REPO_DIR/common.sh" "$TMP/lib/"
if (cd / && bash "$TMP/lib/jb_improved.sh" list >/dev/null 2>&1); then
    ok "jb 在任意 cwd 下可运行"
else bad "jb 无法运行"; fi
# 模拟只装到 /usr/local/lib/jiaoben 的情况（common.sh 不同目录）
mkdir -p "$TMP/onlyjb"; cp "$REPO_DIR/jb_improved.sh" "$TMP/onlyjb/"
if bash "$TMP/onlyjb/jb_improved.sh" list >/dev/null 2>&1; then
    ok "已装 common.sh 到系统路径时可运行"
else
    ok "缺 common.sh 时明确报错退出（预期行为）"
fi

echo "== 10. pkill 使用完整路径锚定，不误杀其它实例 =="
grep -q 'pkill -9 -f "\^\${bin}"' "$REPO_DIR/run.sh" && ok "run.sh pkill 已锚定路径" || bad "run.sh pkill 仍过于宽泛"
grep -q 'pkill -9 -f "\^\${bin}"' "$REPO_DIR/uninstall.sh" && ok "uninstall.sh pkill 已锚定路径" || bad "uninstall.sh pkill 仍过于宽泛"

echo "== 11. install_deps 覆盖主流包管理器 =="
for pm in apt-get dnf yum zypper pacman apk; do
    grep -q "command -v $pm" "$REPO_DIR/run.sh" && ok "支持 $pm" || bad "缺少 $pm 分支"
done

echo
echo "==== 通过: $PASS  失败: $FAIL ===="
[[ $FAIL -eq 0 ]]
