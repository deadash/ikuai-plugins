#!/bin/bash

# . /etc/mnt/.boot/lib/common.sh

# # 检查功能是否开启
# is_enabled "remote" || exit 0

# 修改 collection.sh
sed -i '/local res=$(netstat -atnp | awk '"'"'\/ik_rc_client\/{if($6=="ESTABLISHED")print $0}'"'"')/a return' /usr/ikuai/script/utils/collection.sh

# 修改 monitor_process.sh
# 使用 sed 删除指定行及后面4行
sed -i '/## 2nd remote control client/{N;N;N;N;d}' /usr/ikuai/script/utils/monitor_process.sh

# 删除程序
rm -rf /usr/sbin/ik_rc_client
cat > /usr/sbin/ik_rc_client << 'EOF'
#!/bin/sh
exit 0
EOF
pkill ik_rc_client
chmod +x /usr/sbin/ik_rc_client