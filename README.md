# sdk

如果需要自己编译程序，参考 [ikuai-sdk](https://github.com/deadash/ikuai-sdk)

# 支持以下功能

1. 支持ssh直接打开, 便于映射文件和修改
2. 支持cron, 可以定时任务
3. 支持shells, 可以拷贝程序和配置

# 配置如下

在路径 `/etc/mnt/boot_arg` 是配置参数, 等于1是打开，等于0则是关闭

比如关闭ssh，则可以执行 `sed -i "s/^sshd=.*/sshd=0/" /etc/mnt/boot_arg`

打开则相反，`sed -i "s/^sshd=.*/sshd=1/" /etc/mnt/boot_arg`

各配置名称如下

1. ssh, sshd
2. 远程, remote (默认开启并且目前不可修改)
3. 插件, plugins (暂时未打开)
4. cron, cron, cron_test
5. 程序安装, shells

## 配置 cron

在 `/etc/mnt/cron.d` 下新建一个文件，里面写入crontab语句即可重启后生效

如果需要测试cron功能，可以打开 `cron_test=1` 到 `/etc/mnt/boot_arg`

然后查看日志 `tail -f /var/log/crond.log`

其中, 如果想动态测试，则修改 `/etc/crontabs/root` 文件

## 配置 shells

在 `/etc/mnt/shells/bin` 下放应用程序和相关的sh脚本，这些文件会动态链接到 `/usr/sbin` 下，注意，重启后生效，如果测试，请手动链接

在 `/etc/mnt/shells/etc` 下放配置文件，这些文件会动态链接到 `/usr/local/etc` 下，也是重启生效，测试可以手动链接
