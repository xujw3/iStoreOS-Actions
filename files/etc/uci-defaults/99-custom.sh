#!/bin/sh
# 仅首次运行 iStoreOS 时，会执行以下脚本。重启后消失

LOGFILE="/etc/config/uci-defaults-log.txt"
NETWORK_MODE="__NETWORK_SETTINGS__"
STATIC_IPADDR="__STATIC_IPADDR__"
STATIC_GATEWAY="__STATIC_GATEWAY__"
STATIC_NETMASK="255.255.255.0"
STATIC_DNS="223.5.5.5"

[ "$NETWORK_MODE" = "__NETWORK_SETTINGS__" ] && NETWORK_MODE="dhcp"
[ "$STATIC_IPADDR" = "__STATIC_IPADDR__" ] && STATIC_IPADDR="192.168.5.88"
[ "$STATIC_GATEWAY" = "__STATIC_GATEWAY__" ] && STATIC_GATEWAY="192.168.5.1"

log() {
    echo "$*" >>"$LOGFILE"
}

find_uci_section_by_name() {
    config="$1"
    wanted="$2"
    uci -q show "$config" | sed -n "s/^$config\.\([^.=]*\)\.name='$wanted'$/\1/p" | head -n 1
}

first_uci_section() {
    config="$1"
    uci -q show "$config" | sed -n "s/^$config\.\([^.=]*\)=.*$/\1/p" | head -n 1
}

configure_lan_firewall() {
    # 只放开 LAN 区域的入口访问，避免依赖 @zone[1] 顺序误改 WAN。
    lan_zone=$(find_uci_section_by_name firewall lan)
    if [ -n "$lan_zone" ]; then
        uci set "firewall.$lan_zone.input=ACCEPT"
        uci commit firewall
        log "Updated firewall zone '$lan_zone' input policy to ACCEPT."
    else
        log "Warning: cannot find firewall zone named 'lan'."
    fi
}

configure_static_network() {
    log "Configuring static network: ip=$STATIC_IPADDR gateway=$STATIC_GATEWAY."
    uci set network.lan.proto='static'
    uci set network.lan.ipaddr="$STATIC_IPADDR"
    uci set network.lan.netmask="$STATIC_NETMASK"
    uci set network.lan.gateway="$STATIC_GATEWAY"
    uci set network.lan.dns="$STATIC_DNS"
    uci commit network
}

configure_dhcp_network() {
    ifnames=""
    for iface in /sys/class/net/*; do
        iface_name=$(basename "$iface")
        if [ -e "$iface/device" ] && echo "$iface_name" | grep -Eq '^eth|^en'; then
            ifnames="$ifnames $iface_name"
        fi
    done
    ifnames=$(echo "$ifnames" | awk '{$1=$1};1')

    count=$(echo "$ifnames" | wc -w)
    log "Detected physical interfaces: $ifnames"
    log "Interface count: $count"

    board_name=$(cat /tmp/sysinfo/board_name 2>/dev/null || echo "unknown")
    log "Board detected: $board_name"

    wan_ifname=""
    lan_ifnames=""
    case "$board_name" in
        "radxa,e20c"|"friendlyarm,nanopi-r5c")
            wan_ifname="eth1"
            lan_ifnames="eth0"
            log "Using $board_name mapping: WAN=$wan_ifname LAN=$lan_ifnames"
            ;;
        *)
            wan_ifname=$(echo "$ifnames" | awk '{print $1}')
            lan_ifnames=$(echo "$ifnames" | cut -d ' ' -f2-)
            log "Using default mapping: WAN=$wan_ifname LAN=$lan_ifnames"
            ;;
    esac

    if [ "$count" -eq 1 ]; then
        # 单网口设备：LAN 使用 DHCP，方便从上级路由获取地址。
        uci set network.lan.proto='dhcp'
        uci -q delete network.lan.ipaddr
        uci -q delete network.lan.netmask
        uci -q delete network.lan.gateway
        uci -q delete network.lan.dns
        uci commit network
    elif [ "$count" -gt 1 ]; then
        # 多网口设备：第一个网口作为 WAN，其余网口加入 br-lan。
        uci set network.wan=interface
        uci set network.wan.device="$wan_ifname"
        uci set network.wan.proto='dhcp'

        uci set network.wan6=interface
        uci set network.wan6.device="$wan_ifname"
        uci set network.wan6.proto='dhcpv6'

        section=$(find_uci_section_by_name network br-lan)
        if [ -z "$section" ]; then
            log "Warning: cannot find device 'br-lan', creating network.br_lan."
            section="br_lan"
            uci set network.$section='device'
            uci set network.$section.name='br-lan'
            uci set network.$section.type='bridge'
        fi

        uci -q delete "network.$section.ports"
        for port in $lan_ifnames; do
            uci add_list "network.$section.ports=$port"
        done
        log "Updated br-lan ports: $lan_ifnames"

        uci set network.lan.proto='static'
        uci set network.lan.ipaddr='192.168.100.1'
        uci set network.lan.netmask='255.255.255.0'
        uci commit network
    else
        log "Warning: no physical eth/en interfaces detected, skip DHCP network customization."
    fi
}

configure_remote_access() {
    ttyd_section=$(first_uci_section ttyd)
    if [ -n "$ttyd_section" ]; then
        uci -q delete "ttyd.$ttyd_section.interface"
        uci commit ttyd
        log "Updated ttyd to listen on all interfaces."
    else
        log "Warning: ttyd config section not found."
    fi

    dropbear_section=$(first_uci_section dropbear)
    if [ -n "$dropbear_section" ]; then
        uci set "dropbear.$dropbear_section.Interface="
        uci commit dropbear
        log "Updated dropbear to listen on all interfaces."
    else
        log "Warning: dropbear config section not found."
    fi
}

restore_banner() {
    if [ -f /etc/banner1/banner ]; then
        cp /etc/banner1/banner /etc/banner
        rm -rf /etc/banner1
    else
        log "Warning: /etc/banner1/banner not found."
    fi
}

update_release_description() {
    file_path="/etc/openwrt_release"
    new_description="iStoreOS 版本号"
    if [ -f "$file_path" ]; then
        sed -i "s/DISTRIB_DESCRIPTION='[^']*'/DISTRIB_DESCRIPTION='$new_description'/" "$file_path"
    else
        log "Warning: $file_path not found."
    fi
}

log "Starting 99-custom.sh at $(date), network mode: $NETWORK_MODE"

configure_lan_firewall

# 设置主机名映射，解决安卓原生 TV 无法联网的问题。
uci add dhcp domain
uci set "dhcp.@domain[-1].name=time.android.com"
uci set "dhcp.@domain[-1].ip=203.107.6.88"
uci commit dhcp

# 设置主机名、时区和默认语言。
uci set system.@system[0].hostname='iStoreOS'
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci set luci.main.lang='zh_cn'
uci commit system
uci commit luci

case "$NETWORK_MODE" in
    static)
        configure_static_network
        ;;
    dhcp)
        configure_dhcp_network
        ;;
    *)
        log "Warning: unknown network mode '$NETWORK_MODE', fallback to dhcp."
        configure_dhcp_network
        ;;
esac

configure_remote_access
restore_banner
update_release_description

exit 0
