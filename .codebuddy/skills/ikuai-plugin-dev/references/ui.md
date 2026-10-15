# 插件页面 UI：统一用 ikui 套件

## 规则

**插件页一律用 ikui 统一 UI 套件，不要自己写样式、也不要抄爱快前端的样式。**

- 底座：**Element Plus（Vue 3）** + 一套设计令牌，自包含（不依赖爱快前端）。
- 发布物只有两个文件：`ikui.js` / `ikui.css`，合计约 1.6MB。
- 目标：**所有插件长得一样、改一处全局生效**；不追求跟爱快界面一致。

**套件由基础包提供，插件什么都不用带** —— 页面里就两行：

```html
<link rel="stylesheet" href="./ikui.css">
<script src="./ikui.js"></script>
```

这两条相对路径在运行时指向 `/plugins/app/`，那里是基础包发布的软链：

```
/usr/ikuai/www/plugins/app/ikui.js  -> /etc/mnt/.boot/www/ui/ikui.js
/usr/ikuai/www/plugins/app/ikui.css -> /etc/mnt/.boot/www/ui/ikui.css
```

发布由 `lib/plugin.sh` 的 `plugin_web_ui_link()` 在每次开机做（顺序放在
`plugin_web_sync` 与 `plugin_boot` 之后，让基础包这份说了算）。
**软链而不是复制**：根分区常年 100%，1.6MB 拷进去必然 ENOSPC。

`scripts/add-ui.sh` 只在**极特殊**情况下才用（想让插件在没升级基础包的旧设备上
也能跑，自己带一份）—— 带了也会被基础包那份覆盖，一般不需要。

**详细用法（组件清单、`x-template` 那个必须注意的坑、JS 接口、换主题）
见 `<skill>/assets/ui/README.md`，那是唯一权威，本文件不重复。**

## 三条硬约束

1. **模板必须放 `<script type="text/x-template">`，不要直接写在 `<body>` 里。**
   HTML 解析器不认自闭合标签，写在 body 里 `<el-table-column/>` 会把后面的列全吞进去
   （表现：卡片一层套一层、表格塌成一列；都踩过）。
2. **UI 资源平铺在 `www/plugins/app/`，不要再建子目录。**
   根分区空间极紧，框架在 `/usr/ikuai/www/plugins/` 下**建不出新目录**
   （实测 `No space left on device`），但在已存在的 `app/` 里建文件软链可以。
   也正因为如此，发布物才刻意压成两个文件而不是六个。
3. **不要引外部 CDN**（设备在内网），所有资源都随插件包发。

## 为什么不用"对齐爱快原生组件"那套

试过，结论是这条路是精力黑洞：

- 爱快的 **JS 组件库拿不到**（Vue/Element 都打进 webpack，没挂 `window`），
  交互组件只能抄类名 + 手写行为。
- 能抄的是**应用内部实现**（`.line_edit` / `.input_tit` / `.table` / `.title_h3` 这类页面私有类），
  没文档，只能从 DOM 里一个个扒；上下间距、字号、提示样式散落在各处，永远对齐不完。
- 那份 CSS 是**带构建哈希的产物**，还停在 Element 2.0 老调色板（`#20a0ff` 那代）。

## 可选：确实想蹭爱快的样式

有时你就是想让它跟旁边界面像一点（比如嵌在爱快页面里）。可以做，但**要知道代价**
（同上，且爱快改版可能失效）。实测可用的东西：

```css
/* 爱快自己的布局类（从原生页面 DOM 里扒出来的，都在 app.<哈希>.css 里） */
.title_h3  { min-height:42px; padding:10px 20px; background-color:#e9e9e9 }  /* 小节标题栏 */
.box       { padding:0 20px; margin:20px 0 }                                  /* 表单容器 */
.line_edit { position:relative; padding-left:160px; margin-bottom:14px }       /* 表单一行 */
.input_tit { position:absolute; left:0; width:160px; padding:5px }             /* 标签，带全角冒号 */
.table th  { background-color:#4c5366; color:#fff; font-weight:400 }          /* 表头深底白字 */
.table td,.table th { font-size:12px; border-bottom:1px solid #ddd }
```

```html
<link rel="stylesheet" href="/static/css/app.<哈希>.css">   <!-- /static/ 免鉴权 -->
<link rel="stylesheet" href="/static/css/oem.css">
```

- 哈希取法：`ls /usr/ikuai/www/static/css/app.*.css.gz`（本项目固件固定不升级，可直接写死）。
- 色值用爱快这版：主色 `#20a0ff`、成功 `#13ce66`、警告 `#f7ba2a`、危险 `#ff4949`、
  弱化文字 `#8391a5`、边框 `#d1dbe5`/`#ddd`。别用 Element 新版的 `#409eff`/`#67c23a` 那套。
- 想继续扒某个原生页面的类名，在浏览器控制台这么干（找"某段文字"往上数层）：

  ```js
  (function(){var all=document.querySelectorAll('*');
   for(var i=0;i<all.length;i++){ if(all[i].textContent.trim()==='选择网卡：'){
     var out=[],e=all[i]; for(var k=0;k<5&&e;k++){ out.push(e.tagName+'['+e.className+']'); e=e.parentElement; }
     return out.join(' <<< '); } }})()
  ```

- 对照页面：端口转发 `#/service/forward`、内外网设置 `#/network-setting/lan-wan-set?type=wan&id=1`。

真要用这套，**只引 CSS + 用它的类名**即可（不要幻想用它的组件），并且页面骨架按上面那几张
表的规则写。
