/*
 * ikui —— iKuai 插件统一 UI 套件（装配部分）
 * ============================================================================
 * 依赖（顺序不能变，都是本目录 vendor/ 下的测试过的产物）：
 *
 *   <link rel="stylesheet" href="./ui/element-plus.css">
 *   <link rel="stylesheet" href="./ui/ikui.css">
 *   <script src="./ui/vue.js"></script>
 *   <script src="./ui/element-plus.js"></script>
 *   <script src="./ui/element-plus-zh-cn.js"></script>
 *   <script src="./ui/ikui.js"></script>
 *
 * 页面里就这么写（不用自己 createApp / use / 注册组件）：
 *
 *   <div id="app">
 *     <ik-page title="我的插件" tag="mytool">
 *       <template #actions><el-button @click="load">刷新</el-button></template>
 *       <ik-tiles>
 *         <ik-tile label="状态" :value="st" :tone="ok ? 'ok' : 'warn'"/>
 *       </ik-tiles>
 *       <ik-sec title="配置">
 *         <el-form label-width="110px">
 *           <el-form-item label="间隔"><el-input v-model="n"/></el-form-item>
 *         </el-form>
 *       </ik-sec>
 *     </ik-page>
 *   </div>
 *
 *   <script>
 *   IKUI.mount('#app', {
 *     func: 'mytool',                    // 后端 function/<func_name>
 *     data: function () { return { st: '-', ok: false, n: 1 } },
 *     methods: {
 *       load: function () { var self = this;
 *         this.ik('show', {TYPE:'data'}).then(function (d) { self.st = d.status }); }
 *     },
 *     mounted: function () { this.load() }
 *   })
 *   </script>
 * ============================================================================
 */
(function (global) {
  'use strict';

  var IKUI = {};
  IKUI.version = '1.0.0';

  /* ------------------------------------------------------------------ 后端调用 */

  /* 调插件后端：POST /Action/call，一次封装好三种返回码。
   * 30002 = 命令跑完了但进程往 stderr 写了东西（X 的告警那种噪声），不算失败。 */
  IKUI.api = function (func, action, param) {
    return fetch('/Action/call', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ func_name: func, action: action, param: param || {} })
    }).then(function (r) { return r.json(); }).then(function (j) {
      if (j.Result === 30002) { return j.Data || {}; }
      if (j.Result !== 30000) { throw new Error(j.ErrMsg || ('错误码 ' + j.Result)); }
      return j.Data || {};
    });
  };

  /* 浮层提示（右下角那种）—— 比页面上挂一行文字干净，也不用每页自己维护状态 */
  IKUI.toast = function (text, type) {
    if (global.ElementPlus && global.ElementPlus.ElMessage) {
      global.ElementPlus.ElMessage({
        message: text, type: type || 'info', duration: 2500, showClose: true
      });
      return;
    }
    console.log('[ikui]', text);
  };

  /* 确认框，返回 Promise<boolean> */
  IKUI.confirm = function (text, title) {
    if (!(global.ElementPlus && global.ElementPlus.ElMessageBox)) {
      return Promise.resolve(global.confirm(text));
    }
    return global.ElementPlus.ElMessageBox.confirm(text, title || '确认', {
      confirmButtonText: '确定', cancelButtonText: '取消', type: 'warning'
    }).then(function () { return true; }).catch(function () { return false; });
  };

  /* ------------------------------------------------------------------ 内置组件 */

  /* 页面外壳：标题 + 标签 + 右上角操作 */
  var IkPage = {
    name: 'IkPage',
    props: {
      title: { type: String, default: '' },
      tag: { type: String, default: '' },
      sub: { type: String, default: '' }
    },
    template:
      '<div class="ik-page">' +
      '  <div class="ik-hd" v-if="title">' +
      '    <h1 class="ik-hd__title">{{ title }}</h1>' +
      '    <el-tag v-if="tag" size="small" effect="plain" type="info">{{ tag }}</el-tag>' +
      '    <span class="ik-hd__sub" v-if="sub">{{ sub }}</span>' +
      '    <span class="ik-hd__spacer"></span>' +
      '    <slot name="actions"></slot>' +
      '  </div>' +
      '  <slot></slot>' +
      '</div>'
  };

  /* 小节：白卡 + 独立标题栏，页面的主要分块单元 */
  var IkSec = {
    name: 'IkSec',
    props: {
      title: { type: String, default: '' },
      desc: { type: String, default: '' }
    },
    template:
      '<div class="ik-sec">' +
      '  <div class="ik-sec__hd" v-if="title || $slots.actions">' +
      '    <h3 class="ik-sec__title">{{ title }}</h3>' +
      '    <span class="ik-sec__desc" v-if="desc">{{ desc }}</span>' +
      '    <span class="ik-sec__spacer"></span>' +
      '    <slot name="actions"></slot>' +
      '  </div>' +
      '  <div class="ik-sec__bd"><slot></slot></div>' +
      '</div>'
  };

  /* 指标卡。tone: ok / warn / err / mut；size: big / sm；mono 用等宽字体（识别码那类） */
  var IkTile = {
    name: 'IkTile',
    props: {
      label: { type: String, default: '' },
      value: { type: [String, Number], default: '' },
      tone: { type: String, default: '' },
      size: { type: String, default: '' },
      mono: { type: Boolean, default: false },
      wide: { type: Boolean, default: false }
    },
    computed: {
      /* 宽卡片要作用在**卡片根节点**上（grid-column），挂到数值上不会生效（踩过） */
      rootCls: function () { return this.wide ? 'ik-tile ik-tile--wide' : 'ik-tile'; },
      cls: function () {
        var c = [];
        if (this.tone) { c.push('ik-' + this.tone); }
        if (this.size) { c.push('ik-tile__v--' + this.size); }
        if (this.mono) { c.push('ik-tile__v--mono'); }
        return c;
      }
    },
    template:
      '<div :class="rootCls">' +
      '  <div class="ik-tile__k">{{ label }}</div>' +
      '  <div class="ik-tile__v" :class="cls"><slot>{{ value }}</slot></div>' +
      '</div>'
  };

  /* 指标卡的网格容器。
   *
   * 两种用法：
   *   :items="[{k:'上线状态', v:'在线', tone:'ok', size:'big', mono:true}, ...]"   <- 推荐
   *   <ik-tile ...></ik-tile> 若干子节点                                            <- 要自定义卡片内容时
   *
   * 注意：**自定义组件不能写自闭合**（`<ik-tile/>`）。HTML 解析器不认自闭合标签，
   * 会把它当开标签，后面的节点全被套进这张卡里（踩过：卡片一层套一层）。
   * 所以要么用 :items，要么老老实实写 </ik-tile>。 */
  var IkTiles = {
    name: 'IkTiles',
    props: { items: { type: Array, default: null } },
    template:
      '<div class="ik-tiles">' +
      '  <template v-if="items">' +
      '    <ik-tile v-for="(it, i) in items" :key="i"' +
      '             :label="it.k" :value="it.v" :tone="it.tone"' +
      '             :size="it.size" :mono="!!it.mono" :wide="!!it.wide"></ik-tile>' +
      '  </template>' +
      '  <slot v-else></slot>' +
      '</div>'
  };

  /* ------------------------------------------------------------------ 装配 */

  /* 建 Vue 应用：装好 Element Plus(中文) + 注册 ik-* 组件 + 注入 this.ik() 方法。
   * opts.func 是这个插件后端 function/<func_name> 的名字。 */
  IKUI.createApp = function (opts) {
    if (!global.Vue || !global.ElementPlus) {
      throw new Error('ikui: 没有找到 Vue 或 Element Plus，检查 vendor 那几个 <script> 顺序');
    }
    var o = {};
    for (var k in opts) { if (Object.prototype.hasOwnProperty.call(opts, k)) { o[k] = opts[k]; } }
    var func = o.func || '';
    delete o.func;

    var baseMethods = {
      /* 页面里直接 this.ik('show', {TYPE:'data'}) */
      ik: function (action, param) { return IKUI.api(func, action, param); },
      toast: function (text, type) { IKUI.toast(text, type); },
      confirm: function (text, title) { return IKUI.confirm(text, title); }
    };
    o.methods = Object.assign(baseMethods, o.methods || {});

    var app = global.Vue.createApp(o);
    app.use(global.ElementPlus, {
      locale: global.ElementPlusLocaleZhCn || undefined
    });
    app.component('ik-page', IkPage);
    app.component('ik-sec', IkSec);
    app.component('ik-tile', IkTile);
    app.component('ik-tiles', IkTiles);
    return app;
  };

  /* 一步到位：建 + 挂载。
   *
   * **强列推荐用 tpl 指向一个 <script type="text/x-template">**，而不是把模板直接写在
   * <body> 里。原因是 HTML 解析器的坑：
   *
   *   <el-table-column .../>      自闭合标签 HTML 不认，会被当成"开标签"，
   *   <ik-tile .../>              后面的节点全被套进它里面 —— 表现就是
   *                               "卡片一层套一层"、"表格塌成一列"。
   *
   * <script> 里的内容是**原始文本**，解析器不碰，自闭合和大小写都能原样保留，
   * 交给 Vue 自己的编译器处理就正常了。
   *
   *   <script type="text/x-template" id="tpl"> ...页面模板... <\/script>
   *   <div id="app"></div>
   *   <script>IKUI.mount('#app', { tpl: '#tpl', func: 'mytool', ... })<\/script>
   */
  IKUI.mount = function (selector, opts) {
    var el = (typeof selector === 'string') ? document.querySelector(selector) : selector;
    if (!el) { throw new Error('ikui: 找不到挂载点 ' + selector); }
    opts = opts || {};
    if (opts.tpl && !opts.template) {
      var t = document.querySelector(opts.tpl);
      if (!t) { throw new Error('ikui: 找不到模板 ' + opts.tpl); }
      opts.template = t.innerHTML;
    }
    el.innerHTML = '';       /* 容器里残留的静态副本清掉，免得未编译的模板闪一下 */
    return IKUI.createApp(opts).mount(el);
  };

  global.IKUI = IKUI;
})(window);
