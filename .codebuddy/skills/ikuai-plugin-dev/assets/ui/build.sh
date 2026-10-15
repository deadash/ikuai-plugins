#!/bin/bash
# 把 src/ 里的原始产物打成一堆两件：ikui.js（Vue + Element Plus + 中文包 + 装配层）
# 和 ikui.css（Element Plus 样式 + ikui 设计令牌）。
#
# 为什么合并成一个 JS / 一个 CSS：**根分区空间紧张，框架每发布一个文件就要在
# /usr/ikuai/www/plugins/ 下建一个软链条目**，能少一个是一个（实测目录建不出来）。
# 顺带插件接入也简单：两行。
set -e
cd "$(dirname "$0")"

: > ikui.js
for f in src/vue.js src/element-plus.js src/element-plus-zh-cn.js src/ikui.js; do
    printf '\n/* ===== %s ===== */\n' "$(basename "$f")" >> ikui.js
    cat "$f" >> ikui.js
done

: > ikui.css
printf '\n/* ===== element-plus.css ===== */\n' >> ikui.css
cat src/element-plus.css >> ikui.css
printf '\n/* ===== ikui.css（设计令牌，放最后才能覆盖上面） ===== */\n' >> ikui.css
cat src/ikui.css >> ikui.css

ls -la ikui.js ikui.css | awk '{printf "  %8.0f KB  %s\n", $5/1024, $9}'
