# ikui —— 插件统一 UI 套件

给 iKuai 插件页用的**统一、好看**的界面基础。目标：**所有插件长得一样，改一处全局生效**。

- 底座是 **Element Plus（Vue 3）** + 一套设计令牌，**完全自带**，不依赖爱快前端的样式表
  （所以不受它构建哈希、内部类名变化的影响）。
- 对外就**两个文件**：`ikui.js`（Vue + Element Plus + 中文包 + 装配层）、`ikui.css`（样式 + 令牌）。
  合计约 1.6MB，放插件包里本地加载，秒开。
- **不追求跟爱快界面一样**，追求插件之间统一、观感好。

```
assets/ui/
  ikui.js        ← 发布用（由 src/ 打出来的）
  ikui.css       ← 发布用
  build.sh       从 src/ 重新打包（升级 Vue / Element Plus 版本时用）
  smoke.html     两文件版的冒烟测试页（本地起个 http 服务就能看）
  src/           原始产物：vue.js / element-plus.js / element-plus.css /
                 element-plus-zh-cn.js / ikui.js(装配层) / ikui.css(令牌)
```

## 套件从哪来（重要）

**套件由基础包提供，插件不带**。基础包把本目录的两个产物放在 `www/ui/`，
开机时由 `lib/plugin.sh` 的 `plugin_web_ui_link()` **软链**到：

```
/usr/ikuai/www/plugins/app/ikui.js  -> /etc/mnt/.boot/www/ui/ikui.js
/usr/ikuai/www/plugins/app/ikui.css -> /etc/mnt/.boot/www/ui/ikui.css
```

所以插件页里写 `./ikui.css` / `./ikui.js`（跟页面同在 `app/` 目录）就能引到。

- **为什么软链不复制**：根分区常年 100%，1.6MB 拷进去必然 ENOSPC。
- **为什么平铺在 `app/`**：框架在 `/usr/ikuai/www/plugins/` 下**已经建不出新目录**
  （实测 `No space left on device`），但往已存在的 `app/` 里建文件软链没问题。
- **顺序**：`plugin_web_ui_link` 放在 `plugin_web_sync`（会清空目录）和 `plugin_boot`
  （插件自带的同名文件）**之后**，让基础包这份说了算，避免被插件的旧版本盖掉。

### 本目录是"源"，基础包那份是"产物"

升级 Vue / Element Plus 时：改 `src/` → `bash build.sh` → 把产出的 `ikui.js`/`ikui.css`
拷进基础包仓库的 `www/ui/` → 重新 `bash .tools/build.sh` 签名打包。

`scripts/add-ui.sh` 只在**极特殊**情况下用（想让插件在没升级基础包的旧设备上也能跑，
自己带一份）—— 带了也会被基础包那份覆盖，一般不需要。

## 接入（一步）

### 页面

```html
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<title>我的插件</title>
<link rel="stylesheet" href="./ikui.css">
</head>
<body>

<!-- 模板放 <script type="text/x-template"> 里，不要直接写在 body（原因见下） -->
<script type="text/x-template" id="tpl">
  <ik-page title="我的插件" tag="mytool">
    <template #actions>
      <el-button size="small" @click="load">刷新</el-button>
    </template>

    <ik-tiles :items="tiles"></ik-tiles>

    <ik-sec title="配置" desc="改完点保存">
      <el-form label-width="110px">
        <el-form-item label="采集间隔">
          <el-input v-model.number="interval" style="width:180px"></el-input>
        </el-form-item>
        <el-form-item>
          <el-button type="primary" @click="save">保存</el-button>
        </el-form-item>
      </el-form>
    </ik-sec>

    <ik-sec title="输出">
      <pre class="ik-pre">{{ out }}</pre>
    </ik-sec>
  </ik-page>
</script>

<div id="app"></div>

<script src="./ikui.js"></script>
<script>
IKUI.mount('#app', {
  tpl: '#tpl',
  func: 'mytool',                    // 对应 function/mytool
  data: function () {
    return { interval: 60, out: '', tiles: [] };
  },
  methods: {
    load: function () {                          // this.ik() 就是调后端 action
      var self = this;
      this.ik('show', { TYPE: 'data' }).then(function (d) {
        self.tiles = [
          { k: '采集进程', v: d.running ? '运行中' : '未运行', tone: d.running ? 'ok' : 'err' },
          { k: '采样条数', v: d.samples }
        ];
      }).catch(function (e) { IKUI.toast(e.message, 'error'); });
    },
    save: function () {
      var self = this;
      this.ik('seting', { key: 'interval', value: String(this.interval) })
        .then(function () { IKUI.toast('已保存', 'success'); self.load(); })
        .catch(function (e) { IKUI.toast(e.message, 'error'); });
    }
  },
  mounted: function () { this.load(); }
});
</script>
</body>
</html>
```

## ⚠️ 模板必须放 `x-template`，不要写在 body 里

HTML 解析器**不认自闭合标签**。直接写在 `<body>` 里：

```html
<ik-tile label="状态" value="在线"/>        <!-- ✗ 被当成开标签 -->
<el-table-column prop="a" label="A"/>      <!-- ✗ 后面的列全被吞进去 -->
```

表现就是**卡片一层套一层**、**表格塌成一列**（都踩过）。
`<script type="text/x-template">` 里是**原始文本**，解析器不碰，交给 Vue 自己的编译器处理，
自闭合和大小写都正常。

（要写在 body 里也行，但每个自定义组件都必须老实写 `</ik-tile>`、`</el-table-column>` 闭合标签。）

## 内置组件

| 组件 | 说明 |
| --- | --- |
| `ik-page` | 页面外壳。`title` `tag` `sub`；`#actions` 插槽放右上角按钮 |
| `ik-sec` | 小节白卡。`title` `desc`；`#actions` 插槽放小节右上角按钮 |
| `ik-tiles` | 指标卡网格。**推荐 `:items="[{k,v,tone,size,mono,wide}]"`**，也可放 `<ik-tile>` 子节点 |
| `ik-tile` | 单个指标卡。`label` `value` `tone(ok/warn/err/mut)` `size(big/sm)` `mono` `wide` |

其它一律用 **Element Plus 原生组件**（`el-button` / `el-input` / `el-form` / `el-table` /
`el-select` / `el-switch` / `el-dialog` / `el-tabs` / `el-descriptions` / `el-alert` …），
不要自己写样式。

## JS 接口

| 接口 | 说明 |
| --- | --- |
| `this.ik(action, param)` | 调本插件后端 action（`func` 由 `mount` 的 opts 给出） |
| `IKUI.api(func, action, param)` | 同上，函数式调用 |
| `IKUI.toast(text, type)` | 浮层提示，type: `success`/`warning`/`error`/`info` |
| `IKUI.confirm(text, title)` | 确认框，返回 `Promise<boolean>` |

返回码已封装：`30000` 正常、`30002` 正常（进程有 stderr 输出，如 X 的告警）、其它抛错。

## CSS 工具类

`ik-ok` `ik-warn` `ik-err` `ik-mut`（语义文字色）、`ik-dot`（状态点）、`ik-code`（行内代码）、
`ik-pre`（代码块）、`ik-toolbar`（按钮条）、`ik-tip`（说明文字）、`ik-msg`（行内状态文字）。

## 换主题

**只改 `ikui.css` 里的 `--ik-*` 令牌**，Element Plus 的变量已经接到同一套上，
组件和自研部分会一起变：

```css
:root {
  --ik-brand: #2f6fed;    /* 主色，改这一行整套主色就换了 */
  --ik-radius: 8px;
}
```

想让插件主色跟爱快后台一致，把 `--ik-brand` 设成它的值即可
（爱快这版是 `#20a0ff`，从 `/usr/ikuai/www/static/css/app.*.css.gz` 里取）。

## 版本约定

`ikui.js` / `ikui.css` 是**所有插件共用同一个文件名**（"统一"的前提）。
要升级 Vue / Element Plus，改 `src/` 后跑 `build.sh`，然后每个插件重新
`add-ui.sh` 一次、重装即可。真需要两个版本共存时，再加版本后缀区分。
