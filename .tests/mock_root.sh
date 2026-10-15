#!/bin/bash
#
# 生成一个"模拟系统根目录"，用于在本地(Linux/Git-Bash)离线测试框架脚本，
# 不接触真实设备。
#
# 用法: .tests/mock_root.sh <目标目录>
#
# 说明: 这里只放被改写目标文件的关键片段(与真机 3.7.16 一致)，
#       足够验证 sed/awk 改写逻辑与进程/网络处置逻辑。

set -e

R="${1:?用法: mock_root.sh <目标目录>}"
R="$(cd "$(dirname "$R")" && pwd)/$(basename "$R")"

rm -rf "$R"
mkdir -p "$R"

mkdir -p "$R"/etc/mnt "$R"/etc/crontabs/cron.d "$R"/etc/http_lua "$R"/usr/ikuai/script
mkdir -p "$R"/etc/log/ikguard

# 模拟"从旧版本(装过每分钟守卫)升级上来"的现场: 新版开机要清掉这些遗留,
# 同时不能误删 iKuai 自带的 cron 行
printf '* * * * * /etc/mnt/.boot/bin/backdoor_guard\n' > "$R/etc/crontabs/root"
printf '*/5 * * * * /usr/ikuai/script/iktimer refresh\n' >> "$R/etc/crontabs/root"
printf '*/10 * * * * /etc/mnt/.boot/bin/ikaudit probe >/dev/null 2>&1\n' >> "$R/etc/crontabs/root"
printf '* * * * * /etc/mnt/.boot/bin/backdoor_guard\n' > "$R/etc/crontabs/cron.d/ikblock_guard"
mkdir -p "$R"/usr/ikuai/script/utils "$R"/usr/DTalkInside "$R"/usr/sbin "$R"/usr/bin
mkdir -p "$R"/usr/local/etc "$R"/var/log "$R"/tmp/ikpkg/cre "$R"/tmp/ikpkg/pmd

# ------------------------------------------------------------------ rc
{
    printf '#!/bin/bash /etc/ikcommon\n'
    printf '\n'
    printf 'start_remote_services()\n'
    printf '{\n'
    printf '\tmkdir -p /tmp/ik_lua_files\n'
    printf '\tln -sf /etc/http_lua/ik_lua.data /tmp/ik_lua_files\n'
    printf '\tik_rc_client\n'
    printf '\tpmd\n'
    printf '\tif [ "$OEMNAME" = "zh" ];then\n'
    printf '\t\tln -sf /usr/ikuai/script/cre_client.sh /usr/bin/cre_client\n'
    printf '\t\tcre_client start >/dev/null 2>&1 &\n'
    printf '\tfi\n'
    printf '}\n'
    printf '\n'
    printf 'start_ikuai_services()\n'
    printf '{\n'
    printf '\tiktimerd\n'
    printf '\tiksyslogd\n'
    printf '\tikstats\n'
    printf '\topenresty\n'
    printf '\tcre >/dev/null 2>&1 &\n'
    printf '\tik_kernel_event >/dev/null 2>&1 &\n'
    printf '}\n'
    printf '\n'
    printf 'boot()\n'
    printf '{\n'
    printf '\tboot_load_sync   plugins.sh\n'
    printf '\tstart_ikuai_services\n'
    printf '\tstart_remote_services\n'
    printf '\tboot_load_async  utils/submit.lua\n'
    printf '\tboot_load_async  utils/update_hosts.sh\n'
    printf '\tboot_load_async  utils/collection.sh\n'
    printf '\tboot_load_async  utils/monitor_process.sh\n'
    printf '}\n'
} > "$R/usr/ikuai/script/rc"

# -------------------------------------------------- monitor_process.sh
{
    printf '#!/bin/bash /etc/ikcommon\n'
    printf 'start() {\n'
    printf '\twhile : ;do\n'
    printf '\t\t## pacakge manager daemon\n'
    printf '\t\tif ! __get_process_status pmd ;then\n'
    printf '\t\t\tcgroup_exec pmd  >/dev/null 2>/dev/null &\n'
    printf '\t\tfi\n'
    printf '\n'
    printf '\t\t## 2nd remote control client\n'
    printf '\t\tif ! __get_process_status ik_rc_client ;then\n'
    printf '\t\t\tcgroup_exec ik_rc_client  >/dev/null 2>/dev/null &\n'
    printf '\t\t\tSyslog $(Iecho i18n_sys_event_ik_remote_ikuai)\n'
    printf '\t\tfi\n'
    printf '\n'
    printf '\t\t## collect report engine daemon\n'
    printf '\t\tif ! __get_process_status cre ;then\n'
    printf '\t\t\tcgroup_exec cre  >/dev/null 2>/dev/null &\n'
    printf '\t\t\tSyslog $(Iecho i18n_sys_event_ik_route_collect)\n'
    printf '\t\tfi\n'
    printf '\n'
    printf '\t\t## cre client for ome\n'
    printf '\t\tif [ "$OEM_CRE_MONITOR" ];then\n'
    printf '\t\t\tif ! __get_process_status cre_client ;then\n'
    printf '\t\t\t\tcgroup_exec cre_client start  >/dev/null 2>/dev/null &\n'
    printf '\t\t\tfi\n'
    printf '\t\tfi\n'
    printf '\n'
    printf '\t\t## nginx\n'
    printf '\t\tif ! __get_process_status openresty ;then\n'
    printf '\t\t\topenresty\n'
    printf '\t\tfi\n'
    printf '\n'
    printf '\t\t## 云端审计组件下载器(audit.ikuai8.com), 真机 monitor_process.sh 里就长这样\n'
    printf '\t\tif [ ! -e /tmp/ikaudit_update.lock ];then\n'
    printf '\t\t\tstart-stop-daemon -S -x /usr/ikuai/script/ikaudit_update.sh -b >/dev/null 2>&1\n'
    printf '\t\tfi\n'
    printf '\tdone\n'
    printf '}\n'
} > "$R/usr/ikuai/script/utils/monitor_process.sh"

# ------------------------------------------------- ikaudit_update.sh(云端 .so/二进制下载器)
cat > "$R/usr/ikuai/script/ikaudit_update.sh" <<'EOF'
#!/bin/bash

REST_VER="v2"
AUDIT_HOST="https://audit.ikuai8.com/api"
PUBLISHER_BIN_URL="https://routers.ikuai8.com:6444/audit/publisher/"

while true; do
	plugin_update
	sleep 30
done
EOF

# ------------------------------------------------- collection.sh
cat > "$R/usr/ikuai/script/utils/collection.sh" <<'EOF'
#!/bin/bash /etc/ikcommon

collect_remote_check()
{
	local $(cat $PKG_PATH 2>/dev/null)

	##不管企业版本 还是免费版本， 只要远控异常 24小时候后关闭多线IPv6
	##判断远控连接是否正常建立
	local res=$(netstat -atnp | awk '/ik_rc_client/{if($6=="ESTABLISHED")print $0}')
	if [ "$res" ]; then
		rm /etc/mnt/.ipv6_multi_timeout >/dev/null 2>&1
	else
		echo "timeout=1" > /etc/mnt/.ipv6_multi_timeout
	fi

	return
}

start()
{
	sysstat_get_mem
}
EOF

# ------------------------------------------------- dingtalk.sh
cat > "$R/usr/ikuai/script/dingtalk.sh" <<'EOF'
#!/bin/bash /etc/ikcommon

boot()
{
	[ "$SUPPORT_DTALK" != "true" ]&& return
	/usr/DTalkInside/monidtalk.sh start >/dev/null 2>&1 &
	init
}
EOF

# ------------------------------------------------- monidtalk.sh
cat > "$R/usr/DTalkInside/monidtalk.sh" <<'EOF'
#!/bin/sh

check_dtalkd_process()
{
	killall -q dtalkd
	dtalkd >/dev/null 2>&1 &
}

$1
EOF

# ------------------------------------------------- catcherd.sh
cat > "$R/usr/ikuai/script/catcherd.sh" <<'EOF'
#!/bin/bash /etc/ikcommon

boot() {
	ik_cntl collect enable >/dev/null 2>/dev/null &
}
EOF

# ------------------------------------------------- update_hosts.sh
cat > "$R/usr/ikuai/script/utils/update_hosts.sh" <<'EOF'
#!/bin/bash /etc/ikcommon

start()
{
	local interval=30
	while :;do
		__update_host
		sleep $interval
	done
}

__update_host()
{
	wget -q -O- "https://302.ikuai8.com:32017/get_hosts"
}
EOF

# ------------------------------------------------- submit.lua
cat > "$R/usr/ikuai/script/utils/submit.lua" <<'EOF'
local M = {}

local function monitor()
	ikL_sleep(60)
end

function M:boot()
	ikL_daemon()
	monitor()
end

return M
EOF

# ------------------------------------------------- upgrade.sh
cat > "$R/usr/ikuai/script/upgrade.sh" <<'EOF'
#!/bin/bash /etc/ikcommon

update_auto()
{
	local __types="dpi im domain cache_service"
	__update_auto_upgrade "$type"
	return 0
}

update_file()
{
	echo do_it
}
EOF

# ------------------------------------------------- 程序(与 3.7.16 真机一致: 全是 /usr/sbin 下的实体文件;
#                                                     真机没有 /tmp/ikpkg、/usr/bin/cre_client、地址表目录)
printf '#!/bin/sh\necho real ik_rc_client\n' > "$R/usr/sbin/ik_rc_client"
printf '#!/bin/sh\necho real cre\n'          > "$R/usr/sbin/cre"
printf '#!/bin/sh\necho real pmd\n'          > "$R/usr/sbin/pmd"
printf '#!/bin/sh\necho real dtalkd\n'       > "$R/usr/sbin/dtalkd"
printf '#!/bin/sh\necho real dtalkc\n'       > "$R/usr/sbin/dtalkc"

chmod +x "$R/usr/sbin/ik_rc_client" "$R/usr/sbin/cre" "$R/usr/sbin/pmd" \
         "$R/usr/sbin/dtalkd" "$R/usr/sbin/dtalkc"

# ------------------------------------------------- SSH 加固(与 3.7.16 真机一致)
# 官方 iptables 定义: 公网网卡就是靠这个变量判定的(iKuai 自研 ifaces 扩展, 按接口名前缀匹配)
mkdir -p "$R/usr/ikuai/include"
printf '%s\n' 'IPT_WAN_NO_VPN_IFACE_IN="-m ifaces --ifaces wan*,vwan*,adsl* --dir in"' \
    > "$R/usr/ikuai/include/iptables.sh"

# 官方配置库: SSH 开关/端口(故意用 2222, 用来证明我们是读官方值而不是写死 22)
mkdir -p "$R/etc/mnt/ikuai"
if command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 "$R/etc/mnt/ikuai/config.db" \
        "create table remote_control(id integer primary key, open_sshd int, sshd_port int, sshd_passwd text);
         insert into remote_control values(1,1,2222,'x');" 2>/dev/null
fi

# 官方日志库: iksyslogd 把 dropbear 的 syslog 落进 messages 表(process=dropbear[pid])
mkdir -p "$R/etc/log"
if command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 "$R/etc/log/syslog.db" \
        "create table messages(id integer primary key, timestamp integer, process text, content text);
         insert into messages values(1,1792043147,'dropbear[9962]','Password auth succeeded for sshd from 10.0.2.2:40260');
         insert into messages values(2,1792043148,'dropbear[9962]','Exit (sshd) from <10.0.2.2:40260>: Exited normally');
         insert into messages values(3,1792043149,'dropbear[10490]','Bad password attempt for sshd from 203.0.113.9:46448');
         insert into messages values(4,1792043150,'dropbear[10490]','Child connection from 203.0.113.9:46448');
         insert into messages values(5,1792043151,'kernel','与 SSH 无关的系统日志, 不该出现在 SSH 日志里');" 2>/dev/null
fi

# ------------------------------------------------- 其它
# /etc/hosts 与真机一样: 由 /etc/hosts.d/* 汇总而成(basic.sh:__set_hostname 会重建它) ——
# 域名封锁必须作为片段写在这里, 否则下一个重建它的脚本(basic.sh/function basic/pppoe_server)
# 就把封锁冲掉了
mkdir -p "$R/etc/hosts.d"
printf '127.0.0.1 localhost\n'   > "$R/etc/hosts.d/default"
printf '127.0.0.1 iKuai\n'       > "$R/etc/hosts.d/hostname"
cat "$R/etc/hosts.d"/* > "$R/etc/hosts"
cat > "$R/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/bash
sshd:x:0:0:sshd:/root:/etc/setup/rc
EOF

echo "模拟根目录已生成: $R"
