// Headless acceptance harness for web/app.js (0.20).
//
// No npm dependencies: it drives chrome-headless-shell through the DevTools
// protocol over Node's built-in WebSocket. The page is served over http://127.0.0.1
// so the document CSP ("script-src 'self'") is satisfied exactly as in WebView2.
//
// Usage: node tests/harness/run-ui.js --web <web dir> --report <json path> [--chrome <exe>]
'use strict';
const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawn } = require('child_process');

const args = process.argv.slice(2);
const arg = (name, fallback) => { const i = args.indexOf('--' + name); return i >= 0 ? args[i + 1] : fallback; };
const WEB = path.resolve(arg('web', path.join(__dirname, '..', '..', 'web')));
const REPORT = path.resolve(arg('report', path.join(os.tmpdir(), 'tc-ui-report.json')));
const CHROME = arg('chrome', 'C:/Users/ExampleUser/AppData/Local/ms-playwright/chromium_headless_shell-1223/chrome-headless-shell-win64/chrome-headless-shell.exe');

const MIME = {'.html':'text/html; charset=utf-8','.js':'text/javascript; charset=utf-8','.css':'text/css; charset=utf-8','.svg':'image/svg+xml','.png':'image/png'};

// 变异版页面：只用于 §6.3 断言 G 的 mutation check。
// 几何断言的守护力全靠「把被测修复摘掉之后它必须变红」来证明；靠人手跑一次不算数，
// 所以这里把变异体也做成一次常驻断言 —— 将来谁把这段改回去，正向断言会继续绿，
// 变异断言会立刻红。
//   prereconcile = S1 之前的行为：句柄对不上就顶掉位置上的节点（而不是插入新节点）。
//                  顶掉等于把它后面整段兄弟全部重建，「就地打补丁」就降级成「重建」。
//                  同时摘掉 data-wf-key，还原到当时连句柄都没有的状态。
const MUTANTS = {
  inviteentry: source => source
    .replace("inviteButton('邀请其他电脑','Choose','','','ghost',entryBusy())", "inviteButton('邀请其他电脑','Begin','','','ghost',entryBusy())"),
  prereconcile: source => source
    .replace(/ data-wf-key="\$\{id\}"/g, '')
    .replace('parent.insertBefore(created, old || null);', 'if (old) old.replaceWith(created); else parent.appendChild(created);')
};

function serve() {
  const server = http.createServer((req, res) => {
    const [rawPath, query] = req.url.split('?');
    const rel = decodeURIComponent(rawPath);
    const mutation = new URLSearchParams(query || '').get('mutation');
    // /index.html?mutation=x  → 同一份 index.html，但脚本换成 /app.js?mutation=x
    if (rel === '/' || rel === '/index.html' || rel === '/index-mutant.html') {
      let html = fs.readFileSync(path.join(WEB, 'index.html'), 'utf8');
      if (rel === '/index-mutant.html') html = html.replace('src="app.js"', 'src="app.js?mutation=' + (mutation || '') + '"');
      res.writeHead(200, {'Content-Type': MIME['.html'], 'Cache-Control':'no-store'});
      res.end(html); return;
    }
    const file = path.join(WEB, rel);
    if (!file.startsWith(WEB) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) { res.writeHead(404); res.end('not found'); return; }
    if (mutation && MUTANTS[mutation] && rel === '/app.js') {
      const mutated = MUTANTS[mutation](fs.readFileSync(file, 'utf8'));
      res.writeHead(200, {'Content-Type': MIME['.js'], 'Cache-Control':'no-store'});
      res.end(mutated); return;
    }
    res.writeHead(200, {'Content-Type': MIME[path.extname(file)] || 'application/octet-stream', 'Cache-Control':'no-store'});
    fs.createReadStream(file).pipe(res);
  });
  return new Promise(resolve => server.listen(0, '127.0.0.1', () => resolve(server)));
}

const sleep = ms => new Promise(r => setTimeout(r, ms));

async function waitJson(url, attempts = 100) {
  for (let i = 0; i < attempts; i++) {
    try { const r = await fetch(url); if (r.ok) return await r.json(); } catch {}
    await sleep(100);
  }
  throw new Error('devtools endpoint not ready: ' + url);
}

class Cdp {
  constructor(ws) { this.ws = ws; this.id = 0; this.pending = new Map(); }
  static async connect(url) {
    const ws = new WebSocket(url);
    await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject; });
    const cdp = new Cdp(ws);
    ws.onmessage = event => {
      const msg = JSON.parse(event.data);
      if (msg.id && cdp.pending.has(msg.id)) { const { resolve, reject } = cdp.pending.get(msg.id); cdp.pending.delete(msg.id); msg.error ? reject(new Error(msg.error.message)) : resolve(msg.result); }
    };
    return cdp;
  }
  send(method, params = {}) {
    const id = ++this.id;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params }));
      setTimeout(() => { if (this.pending.has(id)) { this.pending.delete(id); reject(new Error('CDP timeout: ' + method)); } }, 15000);
    });
  }
  async evaluate(expression) {
    const result = await this.send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
    if (result.exceptionDetails) throw new Error('evaluate failed: ' + (result.exceptionDetails.exception?.description || result.exceptionDetails.text) + '\n' + expression.slice(0, 200));
    return result.result.value;
  }
}

// ---- fixtures ---------------------------------------------------------------
const LINE_A = '11111111-1111-1111-1111-111111111111';
const LINE_B = '22222222-2222-2222-2222-222222222222';

function baseState(over = {}) {
  return Object.assign({
    Text:{}, Ack:999999, Version:'0.20.0', Form:null, State:'Disconnected', Running:false, Busy:false, BusyMessage:'',
    ReadOnly:false, NinjaRunning:false, PendingConnectionName:'', NodeName:'', TradeName:'', TradeExit:'',
    ActiveLineId:'', ActiveProfile:'', PreferredLineId:LINE_A, HomeLineId:LINE_A, Guard:'Protected', GuardSummary:'',
    TradeProgramCount:1, Daily:'Direct', Agents:'Daily', Lines:[], Providers:[], Tasks:[], Deployments:[], CanBackground:false,
    Quality:null, Standby:null, QualityHistory:null, Settings:{AutoTrustFirstConnection:true,AutoConnectOnLogin:false,OpenAtLogin:false,CloseBehavior:'Tray',Warning:''},
    ReadWarning:'', AutoConnectNotice:'', Dialog:null, Toast:'', SnapshotAtUtc:new Date().toISOString().replace(/\.\d+Z$/,'Z'),
    ConnectedSince:null, GuardSummary:'', Pending:null, ExitEvidence:{Verified:false,Attribution:'Unknown',Status:'Unknown',Code:'',CheckedAtUtc:null,ObservedIP:null},
    Operation:null, Pair:null, ConnectionMethods:[{Id:'Udp',DisplayName:'标准连接'},{Id:'Tcp',DisplayName:'兼容连接'}]
  }, over);
}

function lineState(over = {}) {
  return Object.assign({ Id:LINE_A, Name:'我的主线路', Profile:'Udp', Prepared:true,
    Readiness:{State:'Verified',Label:'可用',Reason:''}, ProfileSource:'UserChoice', AutomaticNeedsCheck:false,
    PreparedProfiles:['Udp','Tcp'], Pending:'', Feedback:[], Blocked:false, LastOutcome:null,
    RecentConnectionFailure:null, DeleteAvailability:{CanDelete:true,State:'NeedsCheck',Message:''}, Quality30m:null }, over);
}

function samplesFixture(kind) {
  if (kind === 'a') { // 22 valid 120..540 step 20, 3 nulls
    const raw = []; for (let i = 0; i < 22; i++) raw.push(120 + i * 20);
    [2, 5, 8].forEach(index => raw.splice(index, 0, null));
    return {SampleCount:25,MeasuredCount:22,UnavailableCount:3,TimeoutCount:3,ControllerUnavailableCount:0,Samples:raw,AtUtc:new Date().toISOString()};
  }
  if (kind === 'b') { const raw = []; for (let i = 0; i < 21; i++) raw.push(120 + i * 20); [1,4,7].forEach(i => raw.splice(i,0,null)); return {SampleCount:24,MeasuredCount:21,UnavailableCount:3,TimeoutCount:3,ControllerUnavailableCount:0,Samples:raw,AtUtc:new Date().toISOString()}; }
  if (kind === 'c') return {SampleCount:8,MeasuredCount:5,UnavailableCount:3,TimeoutCount:0,ControllerUnavailableCount:3,Samples:[120,140,null,null,null,160,180,200],AtUtc:new Date().toISOString()};
  if (kind === 'one') return {SampleCount:1,MeasuredCount:1,UnavailableCount:0,TimeoutCount:0,ControllerUnavailableCount:0,Samples:[120],AtUtc:new Date().toISOString()};
  if (kind === 'three') return {SampleCount:3,MeasuredCount:3,UnavailableCount:0,TimeoutCount:0,ControllerUnavailableCount:0,Samples:[120,140,160],AtUtc:new Date().toISOString()};
  if (kind === 'even') return {SampleCount:2,MeasuredCount:2,UnavailableCount:0,TimeoutCount:0,ControllerUnavailableCount:0,Samples:[300,400],AtUtc:new Date().toISOString()};
  if (kind === 'gap') return {SampleCount:3,MeasuredCount:2,UnavailableCount:1,TimeoutCount:0,ControllerUnavailableCount:0,Samples:[null,120,800],AtUtc:new Date().toISOString()};
  if (kind === 'unsorted') return {SampleCount:3,MeasuredCount:3,UnavailableCount:0,TimeoutCount:0,ControllerUnavailableCount:0,Samples:[1000,900,80],AtUtc:new Date().toISOString()};
  // 0.20.8：宿主现在同时下发逐桶 P50/P95 序列，图表改画两条线。
  // 这里刻意放一个未响应桶（6）和一个尾部尖峰（12：P95 = 4×P50），
  // 用来验证"异常事件列表"两类都能列出来。
  if (kind === 'dual') {
    const p50 = [], p95 = [], raw = [];
    for (let i = 0; i < 20; i++) { const base = 300 + (i % 3) * 10; p50.push(base); p95.push(base + 40); raw.push(base + 20); }
    p50[6] = null; p95[6] = null; raw[6] = null;
    p95[12] = p50[12] * 4;
    return {SampleCount:20,MeasuredCount:19,UnavailableCount:1,TimeoutCount:1,ControllerUnavailableCount:0,Samples:raw,MedianSamples:p50,P95Samples:p95,MedianLatencyMs:310,P95LatencyMs:350,AtUtc:new Date().toISOString()};
  }
  if (kind === 'flat') return {SampleCount:10,MeasuredCount:10,UnavailableCount:0,TimeoutCount:0,ControllerUnavailableCount:0,Samples:new Array(10).fill(500),AtUtc:new Date().toISOString()};
  if (kind === 'empty') return {SampleCount:0,MeasuredCount:0,UnavailableCount:0,TimeoutCount:0,ControllerUnavailableCount:0,Samples:[],AtUtc:new Date().toISOString()};
  if (kind === 'allnull') return {SampleCount:3,MeasuredCount:0,UnavailableCount:3,TimeoutCount:3,ControllerUnavailableCount:0,Samples:[null,null,null],AtUtc:new Date().toISOString()};
  if (kind === 'five') return {SampleCount:5,MeasuredCount:5,UnavailableCount:0,TimeoutCount:0,ControllerUnavailableCount:0,Samples:[120,140,160,180,200],AtUtc:new Date().toISOString()};
  // Real shape measured on a live window: 60 buckets, 51 readings, 0 unavailable,
  // and 9 empty buckets that are all isolated (1 bucket wide). A skipped probe is
  // cadence jitter, not data loss, so the curve must stay in one piece.
  if (kind === 'sparse') {
    const raw = []; for (let i = 0; i < 60; i++) raw.push(200 + (i % 7) * 30);
    [3, 6, 9, 14, 22, 31, 40, 47, 55].forEach(index => { raw[index] = null; });
    return {SampleCount:51,MeasuredCount:51,UnavailableCount:0,TimeoutCount:0,ControllerUnavailableCount:0,Samples:raw,AtUtc:new Date().toISOString()};
  }
  // 4 empty buckets in a row = two minutes with no reading at all. That is a real
  // outage and the curve must still show it.
  if (kind === 'outage') {
    const raw = []; for (let i = 0; i < 60; i++) raw.push(200 + (i % 7) * 30);
    [28, 29, 30, 31].forEach(index => { raw[index] = null; });
    return {SampleCount:56,MeasuredCount:56,UnavailableCount:0,TimeoutCount:0,ControllerUnavailableCount:0,Samples:raw,AtUtc:new Date().toISOString()};
  }
  return null;
}

// ---- 0.22.0 几何层夹具 -------------------------------------------------------
// 字段名逐个对着 tests/Test-WebForms.ps1 的节点白名单来；宿主侧（Cols / Role / Size /
// Icon / Align 真的会下发）由那条测试守着，这里守的是另一半：同一份 schema 到了真浏览器、
// 在 style-src 'self' 之下，能不能排成宿主想要的样子。两边合起来才是完整的契约。
const wfid = seed => 'wf-' + String(seed).padEnd(32, '0').slice(0, 32);
const wfNode = (kind, seed, over = {}) => Object.assign(
  {Kind:kind, Id:wfid(seed), Name:'', Text:'', Label:'', Disabled:false, Tone:'idle', Children:[]}, over);

// ui/Pages.ps1::AgentRow —— Grid @('Auto','*')，没有按钮。
// 标题行是 Stack 'Horizontal'（→ row），装了名字和一粒状态 Pill（→ card[data-role=chip]）。
function wfAgentRow(index, name, pill) {
  const title = wfNode('row', 'r-agent-' + index, {Children:[wfNode('text', 't-agent-' + index, {Text:name, Level:0})]});
  if (pill) title.Children.push(wfNode('card', 'chip-agent-' + index, {Role:'chip', Tone:pill === '运行中' ? 'ok' : 'idle',
    Children:[wfNode('text', 'chip-text-' + index, {Text:pill, Level:0})]}));
  return wfNode('grid', 'g-agent-' + index, {Columns:2, Cols:['Auto','*'], Children:[
    wfNode('check', 'c-agent-' + index, {Name:'Agent'+index, Label:name, Text:name, HasCaption:true, Value:index % 2 === 0}),
    wfNode('panel', 'p-agent-' + index, {Column:1, Children:[
      title,
      wfNode('text', 'd-agent-' + index, {Text:'桌面程序 · 跟随线路', Level:0, Tone:'muted'})
    ]})
  ]});
}

// ui/Pages.ps1::CustomAgentRow —— Grid @('Auto','*','Auto')，第 3 列是移除按钮。
// 第 1 列是 38×38 的图标位（Tag.TCRole='tile'），Margin 右 28 在投影里变成列间距，
// 所以跨行按钮左边缘能不能对齐，取决于 Auto 列有没有真的按内容定宽。
function wfCustomRow(index, label, removed) {
  return wfNode('grid', 'g-custom-' + index, {Columns:3, Cols:['Auto','*','Auto'], Children:[
    wfNode('card', 'tile-' + index, {Column:0, Role:'tile', Size:38, Tone:'idle', Children:[
      wfNode('icon', 'ic-' + index, {Icon:index % 2 ? 'globe' : 'laptop'})
    ]}),
    wfNode('panel', 'p-custom-' + index, {Column:1, Children:[
      wfNode('text', 't-custom-' + index, {Text:label, Level:0}),
      wfNode('text', 'd-custom-' + index, {Text:removed ? '保存后移除' : '网址 · 所有程序访问它时都随名单', Level:0, Tone:'muted'})
    ]}),
    wfNode('button', 'b-remove-' + index, {Name:'RemoveAgent'+index, Text:removed ? '撤销移除' : '移除',
      Label:removed ? '撤销移除' : '移除', Column:2, Tone:'ghost'})
  ]});
}

// ui/Pages.ps1::AgentListCard —— 完整一屏，含 SectionLabel 的右对齐状态文字。
function wfAgentListForm(generation, options = {}) {
  const opt = Object.assign({draftCount:0, customCount:2, rows:4, removed:false, buttons:2, counterLast:false, alignProbe:false}, options);
  const nodes = [];
  const hint = opt.draftCount ? `${opt.draftCount} 项改动未保存` : '名单当前跟随日常上网';
  // SectionLabel：Grid @('*','Auto')，Hint 的 HorizontalAlignment=Right → Align='end'。
  nodes.push(wfNode('grid', 'g-section', {Columns:2, Cols:['*','Auto'], Children:[
    wfNode('panel', 'p-section', {Column:0, Children:[wfNode('text', 't-section', {Text:'AI 工具名单', Level:0})]}),
    wfNode('text', 't-hint', {Name:'AgentsSectionHint', Text:hint, Level:0, Column:1, Align:'end'})
  ]}));
  nodes.push(wfNode('button', 'b-recommend', {Name:'RecommendedAgents', Text:'勾选常用 AI 工具', Label:'勾选常用 AI 工具', Tone:'ghost'}));
  const body = [wfNode('text', 't-lead', {Text:'勾选要跟随线路的工具，改完点保存，一次生效。', Level:0, Tone:'muted'})];
  // 对齐探针：把一个右对齐文字放进 * 轨道。SectionLabel 的提示在 Auto 轨道里，
  // 那个位置贴着内容、justify-self 是空操作，测不出 Align 有没有生效。
  if (opt.alignProbe) body.push(wfNode('grid', 'g-align', {Columns:2, Cols:['*','Auto'], Children:[
    wfNode('text', 't-align', {Name:'AlignProbe', Text:'对齐探针', Level:0, Column:0, Align:'end'}),
    wfNode('button', 'b-align', {Name:'AlignProbeAnchor', Text:'锚点', Label:'锚点', Column:1})
  ]}));
  body.push(wfNode('text', 't-group-app', {Text:'桌面程序', Level:0, Tone:'muted'}));
  for (let i = 0; i < opt.rows; i++) body.push(wfAgentRow(i, ['Claude','ChatGPT','Cursor','Copilot'][i % 4], i === 0 ? '运行中' : i === 1 ? '已安装' : ''));
  body.push(wfNode('text', 't-group-custom', {Text:'自定义', Level:0, Tone:'muted'}));
  for (let i = 0; i < opt.customCount; i++) {
    const gone = opt.removed === true || (opt.removed === 'first' && i === 0);
    body.push(wfCustomRow(i, ['cursor.exe','perplexity.ai'][i % 2], gone));
  }
  // 添加行：Grid @('*','Auto','Auto')，输入框 + 两个按钮。
  body.push(wfNode('grid', 'g-add', {Columns:3, Cols:['*','Auto','Auto'], Children:[
    wfNode('input', 'i-add', {Name:'AgentSiteInput', Column:0}),
    wfNode('button', 'b-add-site', {Name:'AddAgentSite', Text:'添加网址', Label:'添加网址', Column:1}),
    wfNode('button', 'b-add-app', {Name:'AddAgentProgram', Text:'添加程序…', Label:'添加程序…', Column:2})
  ]}));
  nodes.push(wfNode('card', 'card-list', {Tone:'idle', Children:[wfNode('panel', 'p-list', {Children:body})]}));
  return { Title:'AI 工具名单', Description:'', Page:'apps', ParentPage:'apps',
    ViewKey:'nodes|AI 工具名单|apps|' + generation + '||', Generation:generation, Nodes:nodes, Actions:[],
    PageActions: wfActionBar(opt.draftCount, opt.buttons, opt.counterLast) };
}

// ui/Pages.ps1::AddAgentActionBar —— 吸底条走 PageActions，不进 Nodes。
// counterLast：把计数文本挪到按钮【之后】。产品里计数排在最前，那个位置天然稳定，
// 拿它测 data-wf-key 会永远通过（0.20.10 那条补丁就是这么假的）；挪到后面，
// 按钮增删才会把它的索引挤开，断言才有守护力。见 §6.3 断言 G 的 mutation check。
function wfActionBar(draftCount, buttonCount, counterLast) {
  const bar = wfNode('text', 't-count', {Name:'AgentsDraftCount', Text:draftCount ? `${draftCount} 项改动未保存` : '没有未保存的改动', Level:0});
  const buttons = [
    wfNode('button', 'b-save', {Name:'AgentsSaveButton', Text:'保存', Label:'保存', Tone:'primary'}),
    wfNode('button', 'b-discard', {Name:'AgentsDiscardButton', Text:'放弃修改', Label:'放弃修改', Tone:'ghost'})
  ];
  // buttonCount 用来构造「按钮数变化」：0 = 只有计数，1 = 只有保存，2 = 保存 + 放弃。
  const total = buttonCount === undefined ? 2 : buttonCount;
  const shown = buttons.slice(0, total);
  return counterLast ? shown.concat([bar]) : [bar].concat(shown);
}

// ---- assertions -------------------------------------------------------------
const results = [];
function check(name, passed, detail = '') {
  results.push({Name:name, Passed:!!passed, Detail:String(detail).slice(0, 300)});
  if (process.env.TC_VERBOSE) process.stderr.write(`${passed ? 'PASS' : 'FAIL'}  ${name}${passed ? '' : '  <- ' + String(detail).slice(0, 160)}\n`);
}
async function equals(name, actual, expected) { check(name, actual === expected, `expected ${JSON.stringify(expected)} got ${JSON.stringify(actual)}`); }

(async () => {
  const server = await serve();
  const port = server.address().port;
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'tc-ui-'));
  const debugPort = 9600 + Math.floor(Math.random() * 300);
  // --no-sandbox is required in this environment: without it the renderer never
  // starts, the DevTools socket accepts the connection and then stays silent.
  const chrome = spawn(CHROME, ['--headless', '--no-sandbox', '--disable-gpu', '--disable-extensions',
    '--user-data-dir=' + profile, '--remote-debugging-port=' + debugPort, 'about:blank'], {stdio:'ignore'});
  let cdp;
  try {
    const version = await waitJson(`http://127.0.0.1:${debugPort}/json/version`);
    const targets = await waitJson(`http://127.0.0.1:${debugPort}/json/list`);
    const page = targets.find(t => t.type === 'page');
    cdp = await Cdp.connect(page.webSocketDebuggerUrl);
    await cdp.send('Runtime.enable');
    await cdp.send('Page.enable');
    // Installed before any document script runs: the app only subscribes when
    // window.chrome.webview exists, exactly like WebView2.
    await cdp.send('Page.addScriptToEvaluateOnNewDocument', { source: `
      window.__posted = []; window.__host = {handler:null};
      window.chrome = { webview: {
        postMessage: message => { window.__posted.push(message); },
        addEventListener: (type, handler) => { if (type === 'message') window.__host.handler = handler; }
      } };
      window.__host.send = (data, page) => { window.__host.handler({data}); if (page) window.__host.page = page; };
    `});
    await cdp.send('Page.navigate', { url: `http://127.0.0.1:${port}/index.html` });
    for (let i = 0; i < 100; i++) { if (await cdp.evaluate('!!window.__host.handler')) break; await sleep(50); }
    check('harness: message bridge installed', await cdp.evaluate('!!window.__host.handler'));

    const send = async (state, page = 'home') => { await cdp.evaluate(`window.__host.send(${JSON.stringify({Type:'snapshot', State:state, Page:page})})`); await sleep(30); };
    const text = sel => cdp.evaluate(`(()=>{const n=document.querySelector(${JSON.stringify(sel)});return n?n.textContent.trim():null})()`);
    const attr = (sel, name) => cdp.evaluate(`(()=>{const n=document.querySelector(${JSON.stringify(sel)});return n?n.getAttribute(${JSON.stringify(name)}):null})()`);
    const count = sel => cdp.evaluate(`document.querySelectorAll(${JSON.stringify(sel)}).length`);
    const click = sel => cdp.evaluate(`(()=>{const n=document.querySelector(${JSON.stringify(sel)});if(!n)return 'missing';n.click();return 'ok'})()`);
    const posted = () => cdp.evaluate('window.__posted.slice()');

    // ---------- W1-01 status title (12 rows) ----------
    const titleCases = [
      ['W1-01-01 状态未知（11 秒）', {SnapshotAtUtc:new Date(Date.now()-11400).toISOString(), Running:true, State:'Connected', Quality:{Degraded:false}}, '状态未知'],
      ['W1-01-02 无法读取', {State:'ReadUnknown'}, '无法读取'],
      ['W1-01-03 正在断开', {State:'Disconnecting'}, '正在断开'],
      ['W1-01-04 正在连接', {State:'Connecting'}, '正在连接'],
      ['W1-01-05 正在切换', {State:'Applying'}, '正在切换'],
      ['W1-01-06 线路质量待检查', {Running:true, State:'Connected', Quality:{Degraded:true, Quality:'Unknown'}}, '线路质量待检查'],
      ['W1-01-07 线路不稳定', {Running:true, State:'Connected', Quality:{Degraded:true, Quality:'Poor'}}, '线路不稳定'],
      ['W1-01-08 已连接', {Running:true, State:'Connected', Quality:{Degraded:false}}, '已连接'],
      ['W1-01-09 连接需要处理', {State:'Fault'}, '连接需要处理'],
      ['W1-01-10 未连接', {State:'Disconnected'}, '未连接'],
      ['W1-01-11 Unconfigured 落兜底桶', {State:'Unconfigured'}, '未连接']
    ];
    const seen = [];
    for (const [name, over, expected] of titleCases) {
      await send(baseState(Object.assign({Lines:[lineState()]}, over)));
      const value = await text('.signal-title');
      await equals(name, value, expected); seen.push(value);
    }
    check('W1-01 前 10 行两两互异', new Set(seen.slice(0, 10)).size === 10, JSON.stringify(seen));
    check('W1-01 第 10 与第 11 行相等（同属兜底桶）', seen[9] === seen[10], seen[9] + ' / ' + seen[10]);
    await send(baseState(Object.assign({Lines:[lineState()], Text:{Connected:'链路正常'}}, {Running:true, State:'Connected', Quality:{Degraded:false}})));
    await equals('W1-01-12 目录优先于硬编码', await text('.signal-title'), '链路正常');

    // ---------- W1-02 guard card (10 rows) ----------
    const guardCases = [
      ['W1-02-01 count=0', {TradeProgramCount:0, Guard:'Unknown', GuardSummary:''}, '尚未添加受保护的程序', '没有名单就没有需要阻止的程序；这不是故障。'],
      ['W1-02-02 Protected + 摘要', {TradeProgramCount:1, Guard:'Protected', GuardSummary:'交易程序 IPv4/IPv6 直连保护已启用；断开通道后仍保留。'}, '交易程序 IPv4/IPv6 直连保护已启用；断开通道后仍保留。', '未连接时也会阻止名单内的交易程序直接上网。'],
      ['W1-02-03 Protected 空摘要', {TradeProgramCount:1, Guard:'Protected', GuardSummary:''}, '交易保护已开启', '未连接时也会阻止名单内的交易程序直接上网。'],
      ['W1-02-04 Unprotected + 摘要', {TradeProgramCount:3, Guard:'Unprotected', GuardSummary:'交易程序直连保护未完整启用，请检查保护规则。'}, '交易程序直连保护未完整启用，请检查保护规则。', '修复保护＝重新连接一次，引擎启动时会重新应用阻止规则。'],
      ['W1-02-05 Unprotected 空摘要', {TradeProgramCount:3, Guard:'Unprotected', GuardSummary:''}, '交易保护未完整开启', '修复保护＝重新连接一次，引擎启动时会重新应用阻止规则。'],
      ['W1-02-06 Unknown', {TradeProgramCount:2, Guard:'Unknown', GuardSummary:''}, '交易保护状态无法确认', '运行诊断可以查看保护规则的实际读取结果。'],
      ['W1-02-07 Unknown + 摘要', {TradeProgramCount:2, Guard:'Unknown', GuardSummary:'交易保护状态无法确认'}, '交易保护状态无法确认', '运行诊断可以查看保护规则的实际读取结果。'],
      ['W1-02-08 count=-1 哨兵', {TradeProgramCount:-1, Guard:'Unknown', GuardSummary:''}, '交易保护状态无法确认', '运行诊断可以查看保护规则的实际读取结果。'],
      ['W1-02-09 count=-1 + Protected', {TradeProgramCount:-1, Guard:'Protected', GuardSummary:'交易程序 IPv4/IPv6 直连保护已启用；断开通道后仍保留。'}, '交易程序 IPv4/IPv6 直连保护已启用；断开通道后仍保留。', '未连接时也会阻止名单内的交易程序直接上网。'],
      ['W1-02-10 矛盾输入 count=0 + Protected', {TradeProgramCount:0, Guard:'Protected', GuardSummary:'交易程序 IPv4/IPv6 直连保护已启用；断开通道后仍保留。'}, '尚未添加受保护的程序', '没有名单就没有需要阻止的程序；这不是故障。']
    ];
    for (const [name, over, title, note] of guardCases) {
      await send(baseState(Object.assign({Lines:[lineState()]}, over)));
      await equals(name + ' · 标题', await text('#guard-title'), title);
      await equals(name + ' · 说明', await text('[data-testid=guard-note]'), note);
    }
    const minusOne = await cdp.evaluate("document.querySelector('#main').textContent.match(/-1\\s*(个)?\\s*程序/) === null");
    check('W1-02 界面不出现负数程序数', minusOne);

    // ---------- W1-03 exit evidence (10 rows) ----------
    const exitCases = [
      ['W1-03-01 已核验', {Verified:true, Status:'Passed'}, true, '出口已核验'],
      ['W1-03-02 转发已通', {Verified:false, Status:'Passed'}, true, '转发已通，归属未验证'],
      ['W1-03-03 核验未通过', {Verified:false, Status:'Failed'}, true, '本次核验未通过，请运行诊断'],
      ['W1-03-04 核验未完成', {Verified:false, Status:'Inconclusive'}, true, '本次核验未完成（会话或配置变化）'],
      ['W1-03-05 Status=Unknown', {Verified:false, Status:'Unknown'}, true, '尚未核验'],
      ['W1-03-06 空对象', {}, true, '尚未核验'],
      ['W1-03-07 null', null, true, '尚未核验'],
      ['W1-03-08 整键缺失', 'MISSING', true, '尚未核验'],
      ['W1-03-09 未连接也渲染', {Verified:true, Status:'Passed'}, false, '出口已核验'],
      ['W1-03-10 服务商形态（无 Status 键）', {Verified:false, Code:'ExitNotChecked'}, false, '尚未核验']
    ];
    for (const [name, evidence, running, expected] of exitCases) {
      const over = {Running:running, State:running ? 'Connected' : 'Disconnected'};
      if (evidence !== 'MISSING') over.ExitEvidence = evidence;
      await send(baseState(Object.assign({Lines:[lineState()]}, over)));
      await equals(name, await text('[data-testid=fact-exit] .badge'), expected);
    }
    await send(baseState(Object.assign({Lines:[lineState()], Text:{ExitFailed:'本次核验未通过，请运行诊断', ExitInconclusive:'本次核验未完成（会话或配置变化）'}}, {Running:true, State:'Connected', ExitEvidence:{Verified:false, Status:'Inconclusive'}})));
    await equals('W1-03-04 读宿主目录而非硬编码', await text('[data-testid=fact-exit] .badge'), '本次核验未完成（会话或配置变化）');

    // ---------- W1-04 30 minute statistics ----------
    const quality = async (projection, over = {}) => send(baseState(Object.assign({Lines:[lineState({Quality30m:projection})]}, over)));
    await quality(samplesFixture('a'));
    await equals('W1-04-02 F-3a 标准中位', await text('[data-testid=quality-median]'), '330');
    await equals('W1-04-03 F-3a 最慢响应', await text('[data-testid=quality-worst]'), '540');
    await equals('W1-04-04 F-3a 未响应', await text('[data-testid=quality-unavailable]'), '3/25');
    // 0.21.1: 未响应从独立告警色块并进第三格统计，值只剩 N/M，比例单独一格。
    await equals('W1-04-04 F-3a 未响应比例', await text('[data-testid=quality-rate]'), '12%');
    // 0.20.3: 成功次数/采样次数 与 未响应 N/M 是同一个事实（Unavailable = Sample −
    // Measured），两个计数格已删除。断言"不再上屏"，而不是改写那条假恒等式——
    // 恒等式现在由宿主独立统计，属于 LineQuality 的单测。
    await equals('W1-04-05 计数格不再上屏', (await count('[data-testid=quality-samples]')) + (await count('[data-testid=quality-total]')), 0);
    await equals('W1-04-05 面板恰好三个度量格', await count('.response-stats .response-stat'), 3);
    await quality(samplesFixture('one'));
    await equals('W1-04-06 单样本中位为 —', await text('[data-testid=quality-median]'), '—');
    await equals('W1-04-06 单样本最慢也为 —', await text('[data-testid=quality-worst]'), '—');
    await quality(samplesFixture('three'));
    await equals('W1-04-07 三样本中位', await text('[data-testid=quality-median]'), '140');
    await equals('W1-04-07 三样本最慢', await text('[data-testid=quality-worst]'), '160');
    await quality(samplesFixture('a'), {Running:false, State:'Disconnected'});
    await equals('W1-04-08 断开态标注上次连接', await cdp.evaluate("document.querySelector('#response-title').textContent.includes('上次连接')"), true);
    await equals('W1-04-08 断开态仍显示中位', await text('[data-testid=quality-median]'), '330');
    await equals('W1-04-08 断开态不退化等待采样', await count('[data-testid=quality-chart] .chart-empty'), 0);
    await send(baseState({Lines:[lineState({Quality30m:samplesFixture('a')})], HomeLineId:LINE_A}));
    await equals('W1-04-09 当前线路 A 中位', await text('[data-testid=quality-median]'), '330');
    await send(baseState({Lines:[lineState({Quality30m:samplesFixture('a')}), lineState({Id:LINE_B,Name:'备用线路',Quality30m:samplesFixture('flat')})], HomeLineId:LINE_B}));
    await equals('W1-04-09 切到 B 后中位', await text('[data-testid=quality-median]'), '500');
    // 0.20.3 面板归属：连接中必须跟随 ActiveLineId。HomeLineId 是保存的偏好，
    // 用户连着 A、首页默认 B 时，面板曾经拿 B 的统计给 A 的连接背书。
    await send(baseState(Object.assign({Lines:[lineState({Quality30m:samplesFixture('a')}), lineState({Id:LINE_B,Name:'备用线路',Quality30m:samplesFixture('flat')})]}, {HomeLineId:LINE_B, Running:true, State:'Connected', TradeExit:'hk', ActiveLineId:LINE_A, ActiveProfile:'Udp', Quality:{LatencyMs:330,Quality:'Fair',Degraded:false}})));
    await equals('W1-04-17 连接中跟随实际线路而非首页默认', await text('[data-testid=quality-median]'), '330');
    await equals('W1-04-17 标题写明是哪条线路', await cdp.evaluate("document.querySelector('#response-title').textContent.includes('我的主线路')"), true);
    await equals('W1-04-17 连接中不标上次连接', await cdp.evaluate("document.querySelector('#response-title').textContent.includes('上次连接')"), false);
    // 服务商线路上 ActiveLineId 不代表交易出口（lineInUse 同判）。0.20.6 起面板仍跟随
    // 在用的那条线（与状态卡的实时数字同源），但标题必须写明它不是交易出口——回退首页
    // 默认会让面板和状态卡说两条不同的线，且没有任何标记。
    await send(baseState(Object.assign({Lines:[lineState({Quality30m:samplesFixture('a')}), lineState({Id:LINE_B,Name:'备用线路',Quality30m:samplesFixture('flat')})]}, {HomeLineId:LINE_B, Running:true, State:'Connected', TradeExit:'Provider', ActiveLineId:LINE_A, ActiveProfile:'Udp', Quality:{LatencyMs:330,Quality:'Fair',Degraded:false}})));
    await equals('W1-04-17 代理线路仍跟随在用线路', await text('[data-testid=quality-median]'), '330');
    await equals('W1-04-17 代理线路标注非交易出口', await cdp.evaluate("document.querySelector('#response-title').textContent.includes('非交易出口')"), true);
    await equals('W1-04-17 代理线路脚注说明不代表下单路径', await cdp.evaluate("(()=>{const p=document.querySelector('[data-testid=quality-panel] .footnote');return !!p && p.textContent.includes('不代表下单路径')})()"), true);
    // 自建出口下不得出现这条标记：它只解释"面板讲的不是下单路径"，别的时候是噪音。
    await send(baseState(Object.assign({Lines:[lineState({Quality30m:samplesFixture('a')})]}, {HomeLineId:LINE_A, Running:true, State:'Connected', TradeExit:'hk', ActiveLineId:LINE_A, ActiveProfile:'Udp', Quality:{LatencyMs:330,Quality:'Fair',Degraded:false}})));
    await equals('W1-04-17 自建出口不标非交易出口', await cdp.evaluate("document.querySelector('#response-title').textContent.includes('非交易出口')"), false);
    await equals('W1-04-17 自建出口脚注无代理说明', await cdp.evaluate("(()=>{const p=document.querySelector('[data-testid=quality-panel] .footnote');return !!p && p.textContent.includes('不代表下单路径')})()"), false);
    await quality(null);
    await equals('W1-04-10 无投影中位为 —', await text('[data-testid=quality-median]'), '—');
    await equals('W1-04-10 无投影未响应为 —', await text('[data-testid=quality-unavailable]'), '—');
    await quality(samplesFixture('even'));
    await equals('W1-04-11 偶数样本取中间两值平均', await text('[data-testid=quality-median]'), '350');
    await quality(samplesFixture('gap'));
    await equals('W1-04-12 null 不参与排序', await text('[data-testid=quality-median]'), '460');
    await quality(samplesFixture('unsorted'));
    await equals('W1-04-13 数值比较器', await text('[data-testid=quality-median]'), '900');
    await quality(samplesFixture('a'));
    check('W1-04-14 F-3a 不得取到 320', (await text('[data-testid=quality-median]')) !== '320');
    await quality(samplesFixture('b'));
    await equals('W1-04-15 F-3b 奇数取 s[10]', await text('[data-testid=quality-median]'), '320');
    await quality(samplesFixture('c'));
    await equals('W1-04-16 引擎故障窗口 · 中位', await text('[data-testid=quality-median]'), '160');
    // D-01 的回归：这一屏原来同时出现「采样 8 / 成功 5」与「未响应 0/5」，
    // 8−5=3 却写 0。删掉计数格后，5+3=8 由副行自己合上，屏幕上不出现 8。
    await equals('W1-04-16 引擎故障窗口 · 未响应', await text('[data-testid=quality-unavailable]'), '0/5');
    await equals('W1-04-16 引擎故障窗口 · 样本不足不上比例', await text('[data-testid=quality-rate]'), '样本不足');
    await equals('W1-04-16 引擎故障窗口 · 本机故障单列', await text('[data-testid=quality-split]'), '本机引擎未完成 3 次');
    await equals('W1-04-16 不再出现原始采样数', await cdp.evaluate("document.querySelector('#main').textContent.includes('采样次数')"), false);
    const jitterWord = await cdp.evaluate("document.querySelector('#main').textContent.includes('抖动')");
    check('W1-04 界面文案不含「抖动」', !jitterWord);

    // ---------- W1-05 chart ----------
    await send(baseState({Lines:[lineState({Quality30m:null})], Running:false}));
    await equals('W1-05-01 无数据等待采样', await text('.chart-empty'), '等待采样');
    await equals('W1-05-01 无数据不画曲线', await count('[data-testid=quality-chart] svg'), 0);
    await send(baseState({Lines:[lineState({Quality30m:samplesFixture('empty')})]}));
    await equals('W1-05-02 空样本等待采样', await text('.chart-empty'), '等待采样');
    await send(baseState({Lines:[lineState({Quality30m:samplesFixture('allnull')})]}));
    await equals('W1-05-03 全超时等待采样', await text('.chart-empty'), '等待采样');
    await send(baseState({Lines:[lineState({Quality30m:samplesFixture('five')})], Running:true, State:'Connected', Quality:{LatencyMs:120,Quality:'Good',Degraded:false,History:[]}}));
    const points = await cdp.evaluate("(()=>{const p=document.querySelector('[data-testid=quality-chart] polyline');return p?p.getAttribute('points').trim().split(/\\s+/).length:0})()");
    check('W1-05-04 五样本画出一条曲线', (await count('[data-testid=quality-chart] polyline')) === 1 && points >= 5, 'points=' + points);
    // 0.20.4: an empty bucket is a skipped probe, not missing data. Breaking the
    // line there drew a dashed chart on a window whose 未响应 is 0 - nine holes
    // read as "the line keeps dropping out". Only >=3 consecutive empty buckets
    // (90s with no reading) may break it.
    await send(baseState({Lines:[lineState({Quality30m:samplesFixture('sparse')})], Running:true, State:'Connected', Quality:{LatencyMs:200,Quality:'Good',Degraded:false,History:[]}}));
    await equals('W1-05-05 孤立空桶不再断线', await count('[data-testid=quality-chart] polyline'), 1);
    await equals('W1-05-05 空桶不丢点', await cdp.evaluate("(()=>{const p=document.querySelector('[data-testid=quality-chart] polyline');return p?p.getAttribute('points').trim().split(/\\s+/).length:0})()"), 51);
    await send(baseState({Lines:[lineState({Quality30m:samplesFixture('outage')})], Running:true, State:'Connected', Quality:{LatencyMs:200,Quality:'Good',Degraded:false,History:[]}}));
    await equals('W1-05-06 连续 4 个空桶仍然断线', await count('[data-testid=quality-chart] polyline'), 2);
    await equals('W1-05-06 断线两侧点数合计', await cdp.evaluate("Array.from(document.querySelectorAll('[data-testid=quality-chart] polyline')).reduce((n,p)=>n+p.getAttribute('points').trim().split(/\\s+/).length,0)"), 56);
    await equals('W1-05-07 无障碍标签说明断线条件', await cdp.evaluate("(document.querySelector('[data-testid=quality-chart] svg')||{}).getAttribute('aria-label')"), '近30分钟线路响应，超过 1 分钟无读数的区间不连线');

    // ---------- W1-07 P50/P95 双线与异常事件（0.20.8） ----------
    // 宿主下发 MedianSamples/P95Samples 时，图表从"逐桶平均线"改成两条线；
    // 没下发时（旧数据）必须继续走上面的单线，不能白屏。
    await send(baseState({Lines:[lineState({Quality30m:samplesFixture('dual')})], Running:true, State:'Connected', Quality:{LatencyMs:120,Quality:'Good',Degraded:false,History:[]}}));
    await equals('W1-07-01 P50 与 P95 各画一条', await count('[data-testid=quality-chart] polyline'), 2);
    await equals('W1-07-02 双线无障碍标签', await cdp.evaluate("(document.querySelector('[data-testid=quality-chart] svg')||{}).getAttribute('aria-label')"), '近30分钟线路响应：P50 中位与 P95 尾延迟，超过 1 分钟无读数的区间不连线');
    // 0.21.1: 异常不再以带时间戳的文字清单出现，改为曲线上的标记——一根竖虚线
    // 标位置，尖峰再补一个点。逐条明细交给「响应历史」，同一事实不在屏幕上说两遍。
    // dual 只有一处单桶空档（第 6 桶）和一处尖峰（第 12 桶）：空档是漏一次探测，
    // 曲线自己会跨过去，不许再画一根"这里断了"的竖线。
    await equals('W1-07-03 单桶空档不标异常', await count('[data-testid=quality-chart] .chart-mark'), 1);
    await equals('W1-07-04 尖峰标一根线一个点', (await count('[data-testid=quality-chart] .chart-dot')) === 1, true);
    await equals('W1-07-05 异常清单不再上屏', await count('[data-testid=quality-events]'), 0);
    await equals('W1-07-05 不再印时间戳式异常行', await cdp.evaluate("(()=>{const t=document.querySelector('[data-testid=quality-panel]').textContent;return t.includes('没有拿到读数')||t.includes('尾延迟偏高')})()"), false);
    // 连续 3 桶（90 秒）没有回音才算断流，合并成一根标记，且不带尖峰点。
    const outage = samplesFixture('dual');
    [6, 7, 8].forEach(index => { outage.MedianSamples[index] = null; outage.P95Samples[index] = null; });
    outage.P95Samples[12] = outage.MedianSamples[12] + 40;
    await send(baseState({Lines:[lineState({Quality30m:outage})], Running:true, State:'Connected', Quality:{LatencyMs:120,Quality:'Good',Degraded:false,History:[]}}));
    await equals('W1-07-06 连续 3 桶断流合并成一根标记', await count('[data-testid=quality-chart] .chart-mark'), 1);
    await equals('W1-07-06 断流标记不带点', await count('[data-testid=quality-chart] .chart-dot'), 0);
    // 没有 P50/P95 序列时不得凭空造标记（旧投影只有 Samples）。
    await send(baseState({Lines:[lineState({Quality30m:samplesFixture('a')})]}));
    await equals('W1-07-07 旧投影不出异常标记', await count('[data-testid=quality-chart] .chart-mark'), 0);
    await equals('W1-07-07 旧投影仍为单线', await count('[data-testid=quality-chart] polyline'), 1);
    // Percentages are no longer banned outright: what is banned is a percentage
    // with no denominator. Every "%" must sit within 12 characters of an N/M
    // structure, so a bare "0.0%" can never be written again.
    const percentStructured = await cdp.evaluate("(() => { const t = document.querySelector('#main').textContent; for (let i = 0; i < t.length; i++) { if (t[i] !== '%') continue; if (!/\\d+\\s*\\/\\s*\\d+/.test(t.slice(Math.max(0, i - 12), i))) return false; } return true; })()");
    check('W1-05 每个百分比都带分母', percentStructured);

    // ---------- W1-06 heartbeat ----------
    const heartbeat = async seconds => {
      const over = {Running:true, State:'Connected', Quality:{Degraded:false}, Lines:[lineState()]};
      over.SnapshotAtUtc = seconds === null ? '' : new Date(Date.now() - (seconds + 0.4) * 1000).toISOString();
      await send(baseState(over));
    };
    // Host stamps are whole seconds and the threshold is "age > 10", so a stamp
    // 10.4 s old is always stale: the 10 s row in the plan cannot be produced by
    // a real snapshot. The boundary is proved with 9 s / 10 s exactly / 12 s.
    await heartbeat(9); await equals('W1-06-01 9 秒不 stale', await count('.stale-banner'), 0); await equals('W1-06-01 标题', await text('.signal-title'), '已连接');
    await cdp.evaluate("(()=>{const t=Math.floor(Date.now()/1000)*1000-10000;window.__stamp=new Date(t).toISOString().replace(/\.\d+Z$/,'Z')})()");
    await send(baseState({Running:true, State:'Connected', Quality:{Degraded:false}, Lines:[lineState()], SnapshotAtUtc:await cdp.evaluate('window.__stamp')}));
    await equals('W1-06-02 整 10 秒即 stale（阈值 >10）', await count('.stale-banner'), 1);
    await heartbeat(12); await equals('W1-06-03 12 秒 stale', await count('.stale-banner'), 1); await equals('W1-06-03 标题', await text('.signal-title'), '状态未知');
    await heartbeat(60); await equals('W1-06-04 60 秒 stale', await count('.stale-banner'), 1);
    await heartbeat(null); await equals('W1-06-05 空戳不判 stale', await count('.stale-banner'), 0); await equals('W1-06-05 标题', await text('.signal-title'), '已连接');

    // ---------- W1-07 line cards ----------
    const states = [['InUse','使用中',''],['NeedsAction','需要处理','还没有可用的连接方式'],['TestFailed','上次测试未通过','连接时会自动重试，不通会自动恢复原状态'],['Verified','可用',''],['Untested','未测试','还没有测过']];
    for (const [state, label, reason] of states) {
      await send(baseState({Lines:[lineState({Readiness:{State:state,Label:label,Reason:reason}})]}));
      await equals(`W1-07 ${state} 徽章`, await text('[data-testid=line-status]'), label);
      await equals(`W1-07 ${state} 原因`, await text('[data-testid=line-reason]'), reason);
    }
    await send(baseState({Lines:[lineState({Readiness:{State:'Untested',Label:'未测试',Reason:'上次测试没有完成'}})]}));
    await equals('W1-07 Untested 第二组原因', await text('[data-testid=line-reason]'), '上次测试没有完成');

    // ---------- D1 / D3: one screen must not carry two current truths ----------
    // Reported defect: while connected to A, another card still printed a green
    // "切换已完成" strip, so the same screen said "in use" and "just switched".
    // Completed is history only, and a terminal failure that belongs to a line the
    // user is not on is past tense.
    const FUTURE = new Date(Date.now() + 600000).toISOString();
    const completed = {Status:'Completed',Label:'切换已完成',Message:'切换已完成，实际出口验证通过。',NextAction:'Details',ExpiresAtUtc:FUTURE};
    const rolledBack = {Status:'RolledBack',Label:'连接检查未通过',Message:'连接检查未通过，已回到切换前的状态。',NextAction:'Connect',ExpiresAtUtc:FUTURE};
    const lineB = extra => lineState(Object.assign({Id:LINE_B,Name:'浪云主线',Readiness:{State:'Untested',Label:'未测试',Reason:''}}, extra));
    const liveOnA = {Running:true,State:'Connected',TradeExit:'hk',ActiveLineId:LINE_A,ActiveProfile:'Udp',HomeLineId:LINE_A,PreferredLineId:LINE_A,Quality:{LatencyMs:330,Quality:'Fair',Degraded:false,History:[]}};
    const cardOutcomeCount = index => cdp.evaluate(`document.querySelectorAll('[data-testid=line-card]')[${index}].querySelectorAll('.outcome').length`);
    const cardOutcomeText = (index, selector) => cdp.evaluate(`(()=>{const card=document.querySelectorAll('[data-testid=line-card]')[${index}];const node=card?card.querySelector(${JSON.stringify(selector)}):null;return node?node.textContent.trim():null})()`);
    const cardOutcomeClass = index => cdp.evaluate(`(()=>{const card=document.querySelectorAll('[data-testid=line-card]')[${index}];const node=card?card.querySelector('.outcome'):null;return node?node.className:''})()`);
    await send(baseState(Object.assign({Lines:[lineState({LastOutcome:completed}), lineB({LastOutcome:completed})]}, liveOnA)));
    await equals('D1-01 已连接时当前线路不渲染 Completed', await cardOutcomeCount(0), 0);
    await equals('D1-02 已连接时非当前线路不渲染 Completed', await cardOutcomeCount(1), 0);
    await equals('D1-02 已连接时全屏没有结果条', await count('#main .outcome'), 0);
    await equals('D1-02 非当前线路徽章仍是未测试', await cdp.evaluate("document.querySelectorAll('[data-testid=line-card]')[1].querySelector('[data-testid=line-status]').textContent.trim()"), '未测试');
    await send(baseState({Lines:[lineState({LastOutcome:completed}), lineB({LastOutcome:completed})]}));
    await equals('D1-03 断开后当前线路恢复 1 条', await cardOutcomeCount(0), 1);
    await equals('D1-04 断开后非当前线路恢复 1 条', await cardOutcomeCount(1), 1);
    await equals('D1-04 断开后用的是宿主句子', await cardOutcomeText(1, '.outcome strong'), '切换已完成');

    await send(baseState(Object.assign({Lines:[lineState({LastOutcome:rolledBack}), lineB({LastOutcome:rolledBack})]}, liveOnA)));
    const historyTitle = await cardOutcomeText(1, '.outcome strong');
    check('D3-01 非当前线路的结果条带过去时前缀', (historyTitle || '').startsWith('上次切换：'), historyTitle);
    check('D3-02 非当前线路不再复用现在时标题', historyTitle !== rolledBack.Label, historyTitle);
    check('D3-03 非当前线路的结果条降到历史样式', (await cardOutcomeClass(1)).includes('outcome-history'), await cardOutcomeClass(1));
    await equals('D3-04 宿主句子原样保留', await cardOutcomeText(1, '.outcome p'), rolledBack.Message);
    // A line cannot be 使用中 and 已回到切换前的状态 at the same time, so the card
    // that is in use is past tense too - same defect class as the reported one.
    await equals('D3-05 当前线路上的终态也只讲过去', await cardOutcomeText(0, '.outcome strong'), '上次切换：' + rolledBack.Label);
    await equals('D3-05 当前线路也降到历史样式', (await cardOutcomeClass(0)).includes('outcome-history'), true);
    const stripTitles = await cdp.evaluate("Array.from(document.querySelectorAll('#main .outcome strong')).map(n=>n.textContent.trim())");
    check('D3-06 连接期间没有现在时的结果标题', stripTitles.length === 2 && stripTitles.every(title => title.startsWith('上次切换：')), JSON.stringify(stripTitles));

    // ---------- D4: the protection sentence is printed once ----------
    await send(baseState(Object.assign({Lines:[lineState()]}, {Guard:'Unprotected',GuardSummary:'',TradeProgramCount:2})));
    await equals('D4-01 首页不再输出保护告警条', await count('.guard-alert'), 0);
    await equals('D4-02 首页仍渲染保护事实卡', await count('[data-testid=fact-guard]'), 1);
    const guardSentences = await cdp.evaluate("(document.querySelector('#main').textContent.match(/交易保护需要处理|交易保护状态暂时无法核实|交易保护未完整开启/g)||[]).length");
    await equals('D4-03 首页只出现一处保护文案', guardSentences, 1);
    await send(baseState(Object.assign({Lines:[lineState()]}, {Guard:'Unprotected',GuardSummary:'',TradeProgramCount:2})), 'lines');
    await equals('D4-04 其它页面保留保护告警条', await count('.guard-alert'), 1);

    // ---------- 线路响应 band (0.20.1) ----------
    const bandState = over => baseState(Object.assign({Lines:[lineState({Quality30m:samplesFixture('a')})]}, liveOnA, over));
    await send(bandState({}));
    await equals('R-01 F-3a 中位', await text('[data-testid=quality-median]'), '330');
    await equals('R-02 F-3a 最慢响应', await text('[data-testid=quality-worst]'), '540');
    await equals('R-03 计数格不再上屏', (await count('[data-testid=quality-samples]')) + (await count('[data-testid=quality-total]')), 0);
    await equals('R-05 当前响应', await text('[data-testid=quality-current]'), '330ms');
    await equals('R-06 未响应', await text('[data-testid=quality-unavailable]'), '3/25');
    await equals('R-06 未响应比例', await text('[data-testid=quality-rate]'), '12%');
    await equals('R-06 未响应拆分', await text('[data-testid=quality-split]'), '其中超时 3');
    await equals('R-06 有未响应时状态条进入告警态', await cdp.evaluate("document.querySelector('.response-rate').classList.contains('alert')"), true);
    await equals('R-06 有未响应时给出诊断入口', await count('.response-foot [data-action=diagnostics]'), 1);
    // 0.21.1 版式（对齐用户给的参考图）：三格竖排、纵轴与时间刻度各三档、图例三项，
    // 口径折进默认收起的「测量口径」。
    await equals('R-17 三格统计', await count('.response-stats .response-stat'), 3);
    await equals('R-17 未响应是第三格', await cdp.evaluate("document.querySelectorAll('.response-stats .response-stat')[2].classList.contains('response-rate')"), true);
    await equals('R-17 口径默认收起', await cdp.evaluate("document.querySelector('.response-scope').open"), false);
    await equals('R-17 口径折叠后可展开', await cdp.evaluate("(()=>{const d=document.querySelector('.response-scope');d.open=true;const h=d.querySelector('.footnote').getBoundingClientRect().height;d.open=false;return h>0})()"), true);
    // 坐标轴与图例只在双线投影下存在：只有 Samples 的旧投影仍走单线，画不出刻度。
    await send(bandState({Lines:[lineState({Quality30m:samplesFixture('dual')})]}));
    await equals('R-17 纵轴三档刻度', await count('.chart-y span'), 3);
    await equals('R-17 时间刻度三档', await count('.chart-x span'), 3);
    await equals('R-17 图例三项', await count('.chart-legend span'), 3);
    await send(bandState({}));
    await equals('R-17 单线投影不出坐标轴', await count('.chart-y'), 0);
    const figureCounts = await cdp.evaluate("({median:document.querySelectorAll('[data-testid=quality-median]').length,worst:document.querySelectorAll('[data-testid=quality-worst]').length})");
    check('R-07 两个度量格全屏各出现一次', figureCounts.median === 1 && figureCounts.worst === 1, JSON.stringify(figureCounts));
    // 健康窗口：状态条退回安静，副行留空，「无失败」不再出现，诊断入口消失。
    await send(bandState({Lines:[lineState({Quality30m:samplesFixture('flat')})]}));
    await equals('R-16 零失败时不进入告警态', await cdp.evaluate("document.querySelector('.response-rate').classList.contains('alert')"), false);
    await equals('R-16 零失败时没有诊断按钮', await count('.response-foot [data-action=diagnostics]'), 0);
    await equals('R-16 零失败时副行留空', await text('[data-testid=quality-split]'), '');
    await equals('R-16 全屏不再出现「无失败」', await cdp.evaluate("document.querySelector('#main').textContent.includes('无失败')"), false);
    await send(bandState({}));
    check('R-08 面板在状态卡之下、事实卡之上', await cdp.evaluate("(()=>{const hero=document.querySelector('.hero'),panel=document.querySelector('[data-testid=quality-panel]'),facts=document.querySelector('.facts');if(!hero||!panel||!facts)return false;const after=(a,b)=>(a.compareDocumentPosition(b)&Node.DOCUMENT_POSITION_FOLLOWING)>0;return after(hero,panel)&&after(panel,facts)})()"));
    check('R-09 面板画出曲线', (await count('[data-testid=quality-chart] polyline')) >= 1, String(await count('[data-testid=quality-chart] polyline')));
    const bandText = await text('#main');
    const bandBanned = ['丢包','抖动','健康度','128','在线时长'].filter(word => bandText.includes(word));
    check('R-10 面板与首页文案不含禁用词', bandBanned.length === 0, bandBanned.join(','));
    check('R-11 面板给出统计口径', bandText.includes('按 30 秒一次、最近 30 分钟统计'), bandText.slice(0, 120));
    // One screen states each fact once: the status card keeps 当前响应, the band
    // keeps the curve and every 30 minute figure, and neither repeats the other.
    await equals('R-13 状态卡里没有曲线', await count('.hero svg'), 0);
    await equals('R-13 全屏只有一条 30 分钟曲线', await count('[data-testid=quality-chart] svg'), 1);
    await equals('R-13 线路卡缩略图标注 10 分钟', await cdp.evaluate("(()=>{const svg=document.querySelector('.line-card-metrics .trend svg');return !!svg && svg.getAttribute('aria-label').includes('10分钟')})()"), true);
    await equals('R-14 已连接时当前响应只出现一次', await count('[data-testid=quality-current]'), 1);
    await equals('R-14 当前响应在状态卡里', await cdp.evaluate("!!document.querySelector('.hero [data-testid=quality-current]')"), true);
    // Scoped counting, not testid counting. 0.20.2's R-14 passed while the in-use
    // line card printed the same number under the same label, because that copy had
    // no testid. 0.21.0 R11 deliberately reverses the dedup: the line page has no
    // status card, so removing the figure removed the only number. The duplicate
    // this guards against was the SAME LABEL, and that stays forbidden - the card
    // owns 当前线路响应, the status card owns 当前响应. So: no 当前响应 text in the
    // card, exactly one non-seg numeric cell in its metrics, and the figure must
    // read the same source as the status card (same value, different label).
    await equals('R-14 在用线路卡不再重复状态卡标签', await cdp.evaluate("(()=>{const c=document.querySelector('.line-card.in-use');if(!c)return 'no-card';if(/当前响应/.test(c.innerText))return 'dup-label';return 'ok'})()"), 'ok');
    await equals('R-14 在用卡指标区只多出一个数字', await cdp.evaluate("(()=>{const c=document.querySelector('.line-card.in-use');if(!c)return 'no-card';const m=[...c.querySelectorAll('.line-card-metrics .mono')];return m.length===1?'ok':'mono:'+m.length})()"), 'ok');
    await equals('R-14 在用卡数字就是当前线路响应', await cdp.evaluate("(()=>{const c=document.querySelector('.line-card.in-use');if(!c)return 'no-card';const m=c.querySelector('.line-card-metrics .mono');return m&&m.dataset.testid==='line-live-latency'?'ok':'wrong:'+(m&&m.dataset.testid)})()"), 'ok');
    await equals('R-14 在用卡标签与状态卡不同名', await cdp.evaluate("(()=>{const l=document.querySelector('.line-card.in-use .metric-now .line-sub');const h=document.querySelector('.hero .hero-label');if(!l||!h)return 'missing';return l.textContent.trim()+'|'+h.textContent.trim()})()"), '当前线路响应|当前响应');
    await equals('R-14 在用卡数字与状态卡值同源', await cdp.evaluate("(()=>{const c=document.querySelector('.line-card.in-use [data-testid=line-live-latency]');const h=document.querySelector('.hero [data-testid=quality-current]');if(!c||!h)return 'missing';const n=t=>(t.match(/\\d+/)||[])[0];return n(c.textContent)===n(h.textContent)?'same':n(c.textContent)+'/'+n(h.textContent)})()"), 'same');
    await equals('R-14 在用线路卡只留 10 分钟趋势', await cdp.evaluate("(()=>{const c=document.querySelector('.line-card.in-use');return !!c && !!c.querySelector('.line-card-metrics .trend svg')})()"), true);
    // Edge case: connected but this round produced no number. The status card
    // still owns the anchor, so the band must not add a second one.
    await send(baseState(Object.assign({Lines:[lineState({Quality30m:samplesFixture('a')})]}, liveOnA, {Quality:{LatencyMs:null, Quality:'Unknown', Degraded:true}})));
    await equals('R-15 测量失败时当前响应仍只出现一次', await count('[data-testid=quality-current]'), 1);
    await equals('R-15 测量失败时显示 —', await text('[data-testid=quality-current]'), '—');
    check('R-15 测量失败时不出现 0 ms', !/\b0\s*ms\b/.test(await text('#main')));
    await send(baseState({Lines:[lineState({Quality30m:samplesFixture('a')})], Running:false, State:'Disconnected'}));
    await equals('R-12 断开态面板不再交代当前响应', await count('[data-testid=quality-panel] [data-testid=quality-current]'), 0);
    await equals('R-12 断开态仍显示中位', await text('[data-testid=quality-median]'), '330');
    await equals('R-12 断开态仍有曲线', await count('[data-testid=quality-chart] svg'), 1);
    await equals('R-12 断开态不退化等待采样', await count('[data-testid=quality-chart] .chart-empty'), 0);
    await equals('R-14 断开时全屏没有当前响应节点', await count('[data-testid=quality-current]'), 0);
    await equals('R-14 状态卡不再重复响应历史入口', await count('.hero-caption .history-link'), 0);

    // ---------- V: 未响应比例 (0.20.2) ----------
    // D = SampleCount - ControllerUnavailableCount, N = UnavailableCount - same.
    // The local engine's own failures must never enter either side: they are not
    // a line problem, and counting them dilutes a 30% line failure into 12%.
    const rate = (sample, measured, unavailable, timeout, controller, samples) =>
      ({SampleCount:sample, MeasuredCount:measured, UnavailableCount:unavailable, TimeoutCount:timeout, ControllerUnavailableCount:controller, Samples:samples || [], AtUtc:new Date().toISOString()});
    await quality(rate(25,22,3,3,0,new Array(22).fill(300)));
    await equals('V-01 主行', await text('[data-testid=quality-unavailable]'), '3/25');
    await equals('V-01 比例', await text('[data-testid=quality-rate]'), '12%');
    await equals('V-01 副行', await text('[data-testid=quality-split]'), '其中超时 3');
    await quality(rate(3,0,3,3,0,[null,null,null]));
    await equals('V-02 样本不足不显示比例', await text('[data-testid=quality-unavailable]'), '3/3');
    await equals('V-02 比例位写样本不足', await text('[data-testid=quality-rate]'), '样本不足');
    await equals('V-02 副行', await text('[data-testid=quality-split]'), '其中超时 3');
    await quality(rate(5,0,5,0,5,[null,null,null,null,null]));
    await equals('V-03 全本机故障主行为 —', await text('[data-testid=quality-unavailable]'), '—');
    await equals('V-03 全本机故障副行', await text('[data-testid=quality-split]'), '本机引擎未完成 5 次，未计入线路判断');
    await equals('V-03 本机故障不允许静默', await count('.response-foot [data-action=diagnostics]'), 1);
    await quality(rate(10,10,0,0,0,new Array(10).fill(300)));
    await equals('V-04 全成功主行', await text('[data-testid=quality-unavailable]'), '0/10');
    await equals('V-04 全成功比例写 0%', await text('[data-testid=quality-rate]'), '0%');
    await equals('V-04 全成功副行留空', await text('[data-testid=quality-split]'), '');
    await quality(rate(60,59,1,1,0,new Array(59).fill(300)));
    await equals('V-05 小于 10% 保留一位小数', await text('[data-testid=quality-rate]'), '1.7%');
    await equals('V-05 主行', await text('[data-testid=quality-unavailable]'), '1/60');
    await equals('V-05 副行', await text('[data-testid=quality-split]'), '其中超时 1');
    await quality(null);
    await equals('V-06 无投影主行', await text('[data-testid=quality-unavailable]'), '—');
    await equals('V-06 无投影副行', await text('[data-testid=quality-split]'), '');
    await quality(rate(25,22,3,3,0,new Array(22).fill(300)), {Running:false, State:'Disconnected'});
    await equals('V-07 断连不降级', await text('[data-testid=quality-unavailable]'), '3/25');
    await equals('V-07 断连副行不变', await text('[data-testid=quality-split]'), '其中超时 3');
    // Mixed fixture: 3 controller failures out of 8 leave 5 effective attempts and
    // no line failure at all. The ratio must read 0/5, not 3/8, and the split must
    // still own up to the engine failures.
    await quality(rate(8,5,3,0,3,[120,140,null,null,null,160,180,200]));
    await equals('V-10 剔除本机故障后分子归零', await text('[data-testid=quality-unavailable]'), '0/5');
    await equals('V-10 比例位写样本不足', await text('[data-testid=quality-rate]'), '样本不足');
    await equals('V-10 本机故障仍在副行', await text('[data-testid=quality-split]'), '本机引擎未完成 3 次');
    const mainText = await text('#main');
    check('V-08 主区不含丢包类禁用词', ['丢包','抖动','健康度','128'].every(word => !mainText.includes(word)), mainText.slice(0, 120));
    const allStructured = await cdp.evaluate("(() => { const t = document.querySelector('#main').textContent; for (let i = 0; i < t.length; i++) { if (t[i] !== '%') continue; if (!/\\d+\\s*\\/\\s*\\d+/.test(t.slice(Math.max(0, i - 12), i))) return false; } return true; })()");
    check('V-08 所有百分比都在 N/M（x%）结构里', allStructured);
    await equals('V-09 未响应主行全屏恰好 1 个', await count('[data-testid=quality-unavailable]'), 1);
    // Empty window: no samples at all, no engine failure either. "暂无读数" is an
    // assertion (we looked and found none); "—" would mean we cannot tell.
    await quality(rate(0,0,0,0,0,[]));
    await equals('V-11 空窗口主行为暂无读数', await text('[data-testid=quality-unavailable]'), '暂无读数');
    await equals('V-11 空窗口副行为空', await text('[data-testid=quality-split]'), '');
    // A corrupt projection must never print a percentage above 100.
    await quality(rate(10,0,15,15,0,[]));
    await equals('V-12 分子超过分母时夹到 100%', await text('[data-testid=quality-rate]'), '100%');
    // Only non-timeout reasons (DelayUnavailable / Failed / Invalid). The old
    // split would have said "其中超时 0" right after "未响应 2/30". 0.20.5 goes one
    // step further: when every miss has the same reason the residual IS the total,
    // so printing 「其它未响应 2」 under 「未响应 2/30（6.7%）」 says 2 twice.
    await quality(rate(30,28,2,0,0,new Array(28).fill(300)));
    await equals('V-13 非超时原因主行', await text('[data-testid=quality-unavailable]'), '2/30');
    await equals('V-13 非超时原因比例', await text('[data-testid=quality-rate]'), '6.7%');
    await equals('V-13 单一原因时副行留空', await text('[data-testid=quality-split]'), '');
    // Two reasons in one window: now the split is a real breakdown and must appear.
    await quality(rate(30,27,3,1,0,new Array(27).fill(300)));
    await equals('V-13b 两种原因时列出分解', await text('[data-testid=quality-split]'), '其中超时 1 · 其它未响应 2');

    // ---------- D2: a badge hugs its text inside a column flex card ----------
    await send(baseState(Object.assign({Lines:[lineState({Quality30m:samplesFixture('a')})]}, liveOnA)));
    const badgeBox = await cdp.evaluate("(()=>{const card=document.querySelector('[data-testid=fact-exit]');const badge=card.querySelector('.badge');return {card:card.getBoundingClientRect().width,badge:badge.getBoundingClientRect().width}})()");
    check('D2-01 事实卡徽章不拉满整行', badgeBox.badge < badgeBox.card - 10, JSON.stringify(badgeBox));
    const lineBadgeBox = await cdp.evaluate("(()=>{const card=document.querySelector('[data-testid=line-card]');const badge=card.querySelector('[data-testid=line-status]');return {card:card.getBoundingClientRect().width,badge:badge.getBoundingClientRect().width}})()");
    check('D2-02 线路卡徽章同样不被拉伸', lineBadgeBox.badge < lineBadgeBox.card - 10, JSON.stringify(lineBadgeBox));
    check('D2-03 线路卡响应行不被压扁', (await cdp.evaluate("(()=>{const n=document.querySelector('.line-card-metrics .trend svg');return n?n.getBoundingClientRect().width:0})()")) > 40);

    // ---------- green budget: one filled block per screen ----------
    // Three green blocks used to share one screen (protection card, exit strip,
    // result strip) while meaning three different things. The filled block now
    // belongs to the protection fact alone; a result strip is evidence, not state.
    await send(baseState({Lines:[lineState({LastOutcome:completed})], Guard:'Protected', GuardSummary:'交易程序 IPv4/IPv6 直连保护已启用；断开通道后仍保留。', TradeProgramCount:1}));
    const greenBudget = await cdp.evaluate("(()=>{const fact=document.querySelector('[data-testid=fact-guard]');const fill=getComputedStyle(fact).backgroundColor;const strips=Array.from(document.querySelectorAll('#main .outcome')).map(n=>getComputedStyle(n).backgroundColor);const blocks=Array.from(document.querySelectorAll('#main *')).filter(n=>!n.classList.contains('badge')&&n!==fact&&!fact.contains(n)&&getComputedStyle(n).backgroundColor===fill).map(n=>String(n.className));return {fill,strips,blocks}})()");
    check('G-01 结果条不再整块绿底', greenBudget.strips.length === 1 && greenBudget.strips[0] !== greenBudget.fill, JSON.stringify(greenBudget));
    check('G-02 整块绿底只留给保护事实卡', greenBudget.blocks.length === 0, JSON.stringify(greenBudget.blocks));
    await equals('G-03 出口徽章仍是 badge 级', await cdp.evaluate("document.querySelector('[data-testid=fact-exit] .badge').className.includes('badge')"), true);

    // ---------- W1-08 empty state ----------
    await send(baseState({Lines:[]}));
    await equals('W1-08 空状态主入口', await text('[data-testid=empty-primary]'), '用邀请码加入');
    await equals('W1-08 空状态次入口', await text('[data-testid=empty-secondary]'), '自己搭服务器');
    await click('[data-testid=empty-primary]');
    const emptyPost = (await posted()).slice(-1)[0];
    // 0.21.2: the empty-state primary opens the native add-line page at step 2
    // instead of posting joinLine (the legacy form).
    // 0.21.8 A0: it now asks the host to open a fresh page (BeginCode) instead of
    // plain navigate, so the host can clear a finished session it still publishes.
    check('W1-08 主入口进入添加线路页（0.21.2/0.21.8）', emptyPost && emptyPost.Type === 'pairOnline' && emptyPost.Phase === 'BeginCode', JSON.stringify(emptyPost));
    await send(baseState({Lines:[]}), 'add-line');
    await equals('W1-08 主入口直接到第 2 步（粘贴邀请码）', await attr('[data-testid=pair-step]', 'data-step'), '2');
    check('W1-08 第 2 步有邀请码输入框', (await count('[data-testid=pair-code]')) === 1);
    await click('.breadcrumb [data-page=lines]');
    await send(baseState({Lines:[]}), 'lines');

    // ---------- W1-10 flow ----------
    await send(baseState({Lines:[lineState()], Daily:'Direct', Agents:'Daily'}));
    await equals('W1-10 交易软件未连接', await text('[data-testid=flow-trade]'), '尚未连接');
    await equals('W1-10 其他上网', await text('[data-testid=flow-daily]'), '本地直连');
    await equals('W1-10 AI 工具', await text('[data-testid=flow-agents]'), '跟随日常上网');

    // ---------- W2 add-line page ----------
    await send(baseState({Lines:[lineState()]}), 'lines');
    await click('[data-action=pairBeginChoose]');
    const navPost = (await posted()).slice(-1)[0];
    // 0.21.8 A0: ＋ 添加线路 asks the host to start a fresh page (BeginChoose).
    check('W2-14 添加线路入口发 pairOnline BeginChoose', navPost && navPost.Type === 'pairOnline' && navPost.Phase === 'BeginChoose', JSON.stringify(navPost));
    await send(baseState({Lines:[lineState()]}), 'add-line');
    await equals('W2-01 第 1 步', await attr('[data-testid=pair-step]', 'data-step'), '1');
    await equals('W2-01 侧栏高亮仍在线路', await attr('nav [data-page=lines]', 'aria-current'), 'page');
    check('W2-01 导航 DOM 未被改写', (await count('nav [data-page]')) === 4);
    await click('[data-action=pairChooseCode]');
    await equals('W2-01 进入第 2 步', await attr('[data-testid=pair-step]', 'data-step'), '2');
    check('W2-02 邀请码输入四要素', (await cdp.evaluate("(()=>{const n=document.querySelector('[data-testid=pair-code]');return !!n && n.dataset.secret==='true' && n.dataset.secretPresent==='true' && n.id==='pair-code' && n.dataset.pairInput==='code'})()")));
    check('W2-02 设备名输入存在', (await count('[data-testid=pair-device]')) === 1);

    // Local interception: an obviously wrong paste never reaches the host.
    const before = (await posted()).length;
    await cdp.evaluate("(()=>{const n=document.querySelector('[data-testid=pair-code]');n.value='abc';n.dispatchEvent(new Event('input',{bubbles:true}));document.querySelector('[data-action=pairVerify]').click();})()");
    await sleep(50);
    await equals('W2-03 本地拦截不发消息', (await posted()).length, before);
    await equals('W2-03 本地拦截提示', await text('[data-testid=pair-error]'), '请粘贴完整的一次性邀请码');

    // Keepalive: paste, wait three seconds while snapshots keep arriving.
    const code = 'TCI1.' + 'A'.repeat(40);
    await cdp.evaluate(`(()=>{const n=document.querySelector('[data-testid=pair-code]');n.value=${JSON.stringify(code)};n.dispatchEvent(new Event('input',{bubbles:true}));})()`);
    for (let i = 0; i < 4; i++) { await send(baseState({Lines:[lineState()]}), 'add-line'); await sleep(800); }
    await equals('W2-04 粘贴 3 秒后值仍在', await cdp.evaluate("document.querySelector('[data-testid=pair-code]').value"), code);
    await cdp.evaluate("(()=>{const n=document.querySelector('[data-testid=pair-device]');n.value='交易机-01';n.dispatchEvent(new Event('input',{bubbles:true}));})()");
    await send(baseState({Lines:[lineState()]}), 'add-line');
    await equals('W2-04 设备名不被快照抹掉', await cdp.evaluate("document.querySelector('[data-testid=pair-device]').value"), '交易机-01');

    // Verify posts the exact contract.
    await cdp.evaluate("document.querySelector('[data-action=pairVerify]').click()");
    const verifyPost = (await posted()).slice(-1)[0];
    check('W2-05 Verify 报文', verifyPost && verifyPost.Type === 'pairOnline' && verifyPost.Phase === 'Verify' && verifyPost.Code === code && verifyPost.Name === '交易机-01' && Number.isInteger(verifyPost.Sequence), JSON.stringify(verifyPost));
    check('W2-05 校验中按钮禁用', (await attr('[data-action=pairVerify]', 'disabled')) !== null);

    // Host confirms: phase Creating then the resting Authorizing phase.
    const pairState = over => Object.assign({PairId:'a'.repeat(32),Epoch:0,Phase:'Creating',StageLabel:'正在确认邀请码',DeploymentCompleteness:'Unknown',Host:'',Port:0,ExpiresAtUtc:null,DeviceName:'交易机-01',LocalName:'',ErrorCode:'',ErrorMessage:'',NextAction:'None',AtUtc:new Date().toISOString(),StageChangedAtUtc:new Date().toISOString()}, over);
    await send(baseState({Lines:[lineState()], Ack:verifyPost.Sequence, Pair:pairState({})}), 'add-line');
    const creatingStage = await text('[data-testid=pair-stage]');
    await equals('W2-06 校验中阶段文案', creatingStage, '正在确认邀请码');
    await send(baseState({Lines:[lineState()], Ack:verifyPost.Sequence, Pair:pairState({Phase:'Authorizing',StageLabel:'邀请码已确认，可以加入这台电脑',Host:'203.0.113.9',Port:18443,ExpiresAtUtc:new Date(Date.now()+600000).toISOString()})}), 'add-line');
    await equals('W2-06 进入第 3 步', await attr('[data-testid=pair-step]', 'data-step'), '3');
    await equals('W2-06 显示主机', await text('[data-testid=pair-host]'), '203.0.113.9');
    check('W2-06 显示有效期', (await text('[data-testid=pair-expires]') || '').startsWith('有效期至'));
    check('W2-06 显示线路名输入', (await count('[data-testid=pair-name]')) === 1);
    await cdp.evaluate("(()=>{const n=document.querySelector('[data-testid=pair-name]');n.value='香港主线';n.dispatchEvent(new Event('input',{bubbles:true}));})()");
    await cdp.evaluate("document.querySelector('[data-action=pairJoin]').click()");
    const joinPost = (await posted()).slice(-1)[0];
    check('W2-07 Join 报文', joinPost && joinPost.Type === 'pairOnline' && joinPost.Phase === 'Join' && joinPost.Name === '香港主线' && joinPost.Id === 'a'.repeat(32), JSON.stringify(joinPost));
    await send(baseState({Lines:[lineState()], Ack:joinPost.Sequence, Pair:pairState({Phase:'Preparing',StageLabel:'正在设置并测试线路',Host:'203.0.113.9',LocalName:'香港主线'})}), 'add-line');
    await equals('W2-07 阶段文案', await text('[data-testid=pair-stage]'), '正在设置并测试线路');
    await send(baseState({Lines:[lineState()], Ack:joinPost.Sequence, Pair:pairState({Phase:'Complete',StageLabel:'线路已加入',DeploymentCompleteness:'Complete',Host:'203.0.113.9',LocalName:'香港主线',NextAction:'None'})}), 'add-line');
    const summary = await text('[data-testid=pair-summary]');
    check('W2-08 完成文案含「不会接管交易」', (summary || '').includes('它现在不会接管交易，确认能用之后再切换'), summary);

    // Error table: 22 codes, each rendered verbatim.
    const errorRows = [
      ['InvalidOnlineInput','这张邀请码不是本产品生成的，请让给你的人重新生成。','重新输入'],
      ['InvalidOnlineCode','邀请码不完整或已损坏，请复制完整的一次性邀请码。','重新输入'],
      ['InvalidOnlineJson','邀请码内容无法识别，请重新复制完整的一次性邀请码。','重新输入'],
      ['InvalidOnlineHost','邀请码里的服务器地址无效，请让管理员重新生成。','重新输入'],
      ['OnlineInviteExpired','邀请码已过期，请让管理电脑重新生成（可以设更长的有效期）。','重新输入'],
      ['InviteConsumed','这张邀请码已经被用过了，请在原申请电脑上重试或索取新码。','重新输入'],
      ['OnlineInviteIdentityMismatch','邀请码与本机原申请不匹配，请使用同一张邀请码重试。','继续加入'],
      ['PairingBusy','本机正在完成这个申请，请稍后再试。','重试'],
      ['InvalidDeviceName','这台电脑的名称必须是 1–64 个字符，首尾不能有空格。','修改电脑名称'],
      ['OnlineEnrollmentConflict','这台电脑上同一张邀请码已有多份申请，请先恢复原申请再试。','用旧版表单'],
      ['InvalidOnlineResponse','服务器返回的登记结果无法核对，本次没有登记成功。','重试'],
      ['OnlineAuthorizationMismatch','服务器给的授权不属于这台电脑的申请，没有采用。','重试'],
      ['InvalidOnlineEnrollment','本机的在线申请记录损坏，需要重新开始一次申请。','用旧版表单'],
      ['OnlineSourceMissing','这台电脑缺少在线登记所需的组件，请修复安装后重试。','运行诊断'],
      ['OnlineSourceTooLarge','在线登记组件超出大小限制，请修复安装后重试。','运行诊断'],
      ['InvalidOnlineSshReply','服务器返回的结果无法对应本次邀请码操作，没有采用。','重试'],
      ['OnlineOperationFailed','服务器没有完成这次邀请码操作；重试会沿用原申请。','重试'],
      ['EnrollmentMismatch','本机保存的申请、密钥或签名身份与服务器返回不一致，没有采用。','重试'],
      ['AuthorizationUnavailable','本机没有可恢复的已验签授权，请重新取得一次服务器返回。','重试'],
      ['OnlineInvitationUnavailable','这一步没有完成。','重试'],
      ['OnlineEnrollmentIncomplete','这台电脑的线路还没有设置完。','继续加入'],
      ['WorkerStepFailed','需要联网才能校验邀请码；请检查网络后重试。','重试']
    ];
    const nextAction = {InvalidOnlineInput:'Reenter',InvalidOnlineCode:'Reenter',InvalidOnlineJson:'Reenter',InvalidOnlineHost:'Reenter',OnlineInviteExpired:'Reenter',InviteConsumed:'Reenter',OnlineInviteIdentityMismatch:'ContinueJoin',PairingBusy:'Retry',InvalidDeviceName:'FixName',OnlineEnrollmentConflict:'UseLegacyForm',InvalidOnlineResponse:'Retry',OnlineAuthorizationMismatch:'Retry',InvalidOnlineEnrollment:'UseLegacyForm',OnlineSourceMissing:'Diagnostics',OnlineSourceTooLarge:'Diagnostics',InvalidOnlineSshReply:'Retry',OnlineOperationFailed:'Retry',EnrollmentMismatch:'Retry',AuthorizationUnavailable:'Retry',OnlineInvitationUnavailable:'Retry',OnlineEnrollmentIncomplete:'ContinueJoin',WorkerStepFailed:'Retry'};
    for (const [code, message, action] of errorRows) {
      await send(baseState({Lines:[lineState()], Pair:pairState({Phase:'Failed',StageLabel:'这一步没有完成',ErrorCode:code,ErrorMessage:message,NextAction:nextAction[code]})}), 'add-line');
      await equals(`W2-09 ${code} 文案`, await text('[data-testid=pair-error]'), message);
      await equals(`W2-09 ${code} 主按钮`, await text('[data-testid=pair-error-primary]'), action);
      const details = await cdp.evaluate("(()=>{const d=document.querySelector('.pair-error details');return d?d.textContent.includes(arguments0):false})()".replace('arguments0', JSON.stringify(code)));
      check(`W2-09 ${code} 技术详情含原始码`, details);
    }
    await equals('W2-09 PairingBusy 主按钮为「重试」', await text('[data-testid=pair-error-primary]'), '重试');

    // Cancel / reset post the right phase and clear the code on the next epoch.
    await cdp.evaluate("document.querySelector('[data-action=pairCancel]').click()");
    const cancelPost = (await posted()).slice(-1)[0];
    check('W2-10 取消报文', cancelPost && cancelPost.Type === 'pairOnline' && cancelPost.Phase === 'Cancel' && cancelPost.Id === 'a'.repeat(32), JSON.stringify(cancelPost));
    await send(baseState({Lines:[lineState()], Ack:cancelPost.Sequence, Pair:null}), 'add-line');
    await equals('W2-10 取消后回到第 1 步', await attr('[data-testid=pair-step]', 'data-step'), '1');
    await click('[data-action=pairChooseCode]');
    await cdp.evaluate(`(()=>{const n=document.querySelector('[data-testid=pair-code]');n.value=${JSON.stringify(code)};n.dispatchEvent(new Event('input',{bubbles:true}));})()`);
    await send(baseState({Lines:[lineState()], Ack:cancelPost.Sequence, Pair:pairState({Epoch:1,Phase:'Failed',ErrorCode:'PairingBusy',ErrorMessage:'本机正在完成这个申请，请稍后再试。',NextAction:'Retry'})}), 'add-line');
    await equals('W2-11 Epoch 变化后清空邀请码', await cdp.evaluate("document.querySelector('[data-testid=pair-code]').value"), '');
    await click('[data-action=pairReset]');
    const resetPost = (await posted()).slice(-1)[0];
    check('W2-11 重置报文', resetPost && resetPost.Type === 'pairOnline' && resetPost.Phase === 'Reset', JSON.stringify(resetPost));

    // Legacy exit stays reachable.
    await send(baseState({Lines:[lineState()], Pair:null}), 'add-line');
    await click('[data-testid=pair-legacy]');
    const legacyPost = (await posted()).slice(-1)[0];
    check('W2-12 旧版表单出口', legacyPost && legacyPost.Type === 'joinLine', JSON.stringify(legacyPost));

    // ---------- V2 (0.21.2): one join path, blocked lines get their repair ----------
    await send(baseState({Lines:[lineState()]}), 'lines');
    await click('#main .page-head [data-action=pairStart]');
    const headerJoin = (await posted()).slice(-1)[0];
    // 0.21.8 A0: 用邀请码加入 posts BeginCode (host clears a finished session first).
    check('V2-01 线路页「用邀请码加入」进入添加线路页', headerJoin && headerJoin.Type === 'pairOnline' && headerJoin.Phase === 'BeginCode', JSON.stringify(headerJoin));
    await send(baseState({Lines:[lineState()], Pair:null}), 'add-line');
    await equals('V2-02 落在第 2 步（粘贴邀请码）', await attr('[data-testid=pair-step]', 'data-step'), '2');
    await equals('V2-03 页面主体不再有发 joinLine 的入口（旧版只留页脚出口）', await count('#main [data-action=joinLine]'), 0);
    await click('.breadcrumb [data-page=lines]');
    await send(baseState({Lines:[lineState()]}), 'lines');
    await equals('V2-04 线路页不再有发 joinLine 的入口', await count('#main [data-action=joinLine]'), 0);
    // ＋ 添加线路 keeps its own start: step 1, even right after a pairStart visit.
    await click('#main .page-head [data-action=pairStart]');
    await send(baseState({Lines:[lineState()], Pair:null}), 'add-line');
    await click('.breadcrumb [data-page=lines]');
    await send(baseState({Lines:[lineState()]}), 'lines');
    await click('#main .page-head [data-action=pairBeginChoose]');
    await send(baseState({Lines:[lineState()], Pair:null}), 'add-line');
    await equals('V2-04b「＋ 添加线路」从第 1 步开始', await attr('[data-testid=pair-step]', 'data-step'), '1');
    await click('.breadcrumb [data-page=lines]');
    // The legacy form named the device after this computer; the unified flow keeps
    // that default once, and a name the user clears stays cleared.
    const setDevice = v => cdp.evaluate(`(()=>{const n=document.querySelector('[data-testid=pair-device]');n.value=${JSON.stringify(v)};n.dispatchEvent(new Event('input',{bubbles:true}));})()`);
    const deviceValue = () => cdp.evaluate("document.querySelector('[data-testid=pair-device]')?.value");
    await send(baseState({Lines:[lineState()]}), 'lines');
    await click('#main .page-head [data-action=pairStart]');
    await send(baseState({Lines:[lineState()], Pair:null}), 'add-line');
    await setDevice('');
    await click('.breadcrumb [data-page=lines]');
    await send(baseState({Lines:[lineState()], PairDeviceDefault:'TC-TEST-PC'}), 'lines');
    await click('#main .page-head [data-action=pairStart]');
    await send(baseState({Lines:[lineState()], Pair:null, PairDeviceDefault:'TC-TEST-PC'}), 'add-line');
    await equals('V2-04c 电脑名称默认填本机名（与旧版表单一致）', await deviceValue(), 'TC-TEST-PC');
    await setDevice('');
    await send(baseState({Lines:[lineState()], Pair:null, PairDeviceDefault:'TC-TEST-PC'}), 'add-line');
    await equals('V2-04d 用户清空的名称不被默认值回填', await deviceValue(), '');
    await click('.breadcrumb [data-page=lines]');

    // ---------- V3 (0.21.4): an unreadable connection state locks only connection changes ----------
    const unreadable = (over = {}) => baseState(Object.assign({State:'ReadUnknown', ReadWarning:'连接状态暂未刷新，将自动重试；当前显示保留上次结果。'}, over));
    await send(unreadable({Lines:[lineState()]}), 'lines');
    check('V3-01 无法读取时线路页「用邀请码加入」可点', (await count('#main .page-head [data-action=pairStart]:not([disabled])')) === 1);
    check('V3-02 无法读取时「＋ 添加线路」可点', (await count('#main .page-head [data-action=pairBeginChoose]:not([disabled])')) === 1);
    check('V3-03 无法读取时卡片上的连接/断开仍被锁住', (await count('.line-card [data-action=connect]:not([disabled]), .line-card [data-action=disconnect]:not([disabled])')) === 0);
    await click('#main .page-head [data-action=pairStart]');
    await send(unreadable({Lines:[lineState()], Pair:null}), 'add-line');
    check('V3-04 无法读取时添加线路页的邀请码输入和校验可用', (await count('[data-testid=pair-code]:not([disabled])')) === 1 && (await count('[data-action=pairVerify]:not([disabled])')) === 1);
    await click('.breadcrumb [data-page=lines]');
    await send(unreadable({Lines:[]}), 'lines');
    check('V3-05 全新安装且无法读取时空状态的两个入口可点', (await count('#main [data-action=pairStart]:not([disabled])')) >= 1 && (await count('#main [data-action=add]:not([disabled])')) >= 1);
    await send(unreadable({Lines:[]}), 'settings');
    check('V3-06 无法读取时设置页的诊断、操作记录、维护可点', (await count('.tool-link[data-action=diagnostics]:not([disabled]), .tool-link[data-action=history]:not([disabled]), .tool-link[data-action=maintenance]:not([disabled])')) === 3);
    await send(baseState({Lines:[lineState()], Busy:true, BusyMessage:'正在处理'}), 'lines');
    check('V3-07 真正忙碌时入口照常锁住', (await count('#main .page-head [data-action=pairStart]:not([disabled])')) === 0);
    await send(baseState({Lines:[lineState()]}), 'lines');

    // ---------- V4 (0.21.8 A0): a finished join no longer owns the add-line page ----------
    // The host clears its session when either entry is pressed; pairIgnoreId covers
    // the race window where an older snapshot still carries the finished Pair.
    const pairA = 'a'.repeat(32), pairB = 'b'.repeat(32);
    const completedPair = pairState({PairId:pairB, Phase:'Complete', StageLabel:'线路已加入', DeploymentCompleteness:'Complete', Host:'203.0.113.9', LocalName:'香港主线', NextAction:'None'});
    // Control: entering the page without an entry click still shows the result card.
    await send(baseState({Lines:[lineState()], Pair:completedPair}), 'add-line');
    await equals('V4-00 未点击入口时完成态仍停在第 3 步', await attr('[data-testid=pair-step]', 'data-step'), '3');
    await click('.breadcrumb [data-page=lines]');
    await send(baseState({Lines:[lineState()], Pair:completedPair}), 'lines');

    // A0-01: ＋ 添加线路 after a finished join.
    await click('#main .page-head [data-action=pairBeginChoose]');
    const beginChoosePost = (await posted()).slice(-1)[0];
    check('A0-01 点击发 pairOnline BeginChoose', beginChoosePost && beginChoosePost.Type === 'pairOnline' && beginChoosePost.Phase === 'BeginChoose', JSON.stringify(beginChoosePost));
    await send(baseState({Lines:[lineState()], Pair:completedPair}), 'add-line');
    await equals('A0-01 第一帧就是第 1 步（旧会话仍在快照里）', await attr('[data-testid=pair-step]', 'data-step'), '1');
    check('A0-01 第 1 步两个选项都在', (await count('[data-action=pairChooseCode]')) === 1 && (await count('[data-action=pairChooseBuild]')) === 1);
    check('A0-01 看不到上一次的结果摘要', (await count('[data-testid=pair-summary]')) === 0);
    await send(baseState({Lines:[lineState()], Pair:null}), 'add-line');
    await equals('A0-01 宿主清空会话后仍是第 1 步', await attr('[data-testid=pair-step]', 'data-step'), '1');

    // A0-03: step 1 自己搭一台服务器 still posts add.
    await click('[data-action=pairChooseBuild]');
    const buildPost = (await posted()).slice(-1)[0];
    check('A0-03 第 1 步「自己搭一台服务器」发 add', buildPost && buildPost.Type === 'add', JSON.stringify(buildPost));

    // A0-02: 用邀请码加入 after a finished join → step 2, empty code, machine name.
    await click('.breadcrumb [data-page=lines]');
    await send(baseState({Lines:[lineState()], Pair:completedPair, PairDeviceDefault:'TC-TEST-PC'}), 'lines');
    await click('#main .page-head [data-action=pairStart]');
    const beginCodePost = (await posted()).slice(-1)[0];
    check('A0-02 点击发 pairOnline BeginCode', beginCodePost && beginCodePost.Type === 'pairOnline' && beginCodePost.Phase === 'BeginCode', JSON.stringify(beginCodePost));
    await send(baseState({Lines:[lineState()], Pair:completedPair, PairDeviceDefault:'TC-TEST-PC'}), 'add-line');
    await equals('A0-02 落在第 2 步', await attr('[data-testid=pair-step]', 'data-step'), '2');
    await equals('A0-02 邀请码框为空', await cdp.evaluate("document.querySelector('[data-testid=pair-code]').value"), '');
    await equals('A0-02 电脑名称为本机名', await deviceValue(), 'TC-TEST-PC');

    // A0-04: a running join is kept and still shows its progress.
    const preparingPair = pairState({PairId:pairA, Phase:'Preparing', StageLabel:'正在设置并测试线路', Host:'203.0.113.9', LocalName:'香港主线'});
    await click('.breadcrumb [data-page=lines]');
    await send(baseState({Lines:[lineState()], Pair:preparingPair}), 'lines');
    await click('#main .page-head [data-action=pairBeginChoose]');
    const busyBeginPost = (await posted()).slice(-1)[0];
    check('A0-04 进行中点添加线路仍发 BeginChoose（会话由宿主保留）', busyBeginPost && busyBeginPost.Type === 'pairOnline' && busyBeginPost.Phase === 'BeginChoose', JSON.stringify(busyBeginPost));
    await send(baseState({Lines:[lineState()], Pair:preparingPair}), 'add-line');
    await equals('A0-04 进行中停在第 3 步', await attr('[data-testid=pair-step]', 'data-step'), '3');
    check('A0-04 显示进行中的进度', ((await text('[data-testid=pair-stage]')) || '').includes('正在设置并测试线路'), await text('[data-testid=pair-stage]'));
    check('A0-04 页脚只有取消', (await count('[data-testid=pair-cancel]')) === 1 && (await count('[data-testid=pair-restart]')) === 0);
    const joinedPair = pairState({PairId:pairA, Phase:'Complete', StageLabel:'线路已加入', DeploymentCompleteness:'Complete', Host:'203.0.113.9', LocalName:'香港主线'});
    await send(baseState({Lines:[lineState()], Pair:joinedPair}), 'add-line');
    await equals('A0-04 完成后停在第 3 步结果', await count('[data-testid=pair-summary]'), 1);
    await click('.breadcrumb [data-page=lines]');
    await send(baseState({Lines:[lineState()], Pair:joinedPair}), 'lines');
    await click('#main .page-head [data-action=pairBeginChoose]');
    await send(baseState({Lines:[lineState()], Pair:joinedPair}), 'add-line');
    await equals('A0-04 完成后再点进入第 1 步', await attr('[data-testid=pair-step]', 'data-step'), '1');
    // The host's clear arrives: the ignore id is dropped with the session.
    await send(baseState({Lines:[lineState()], Pair:null}), 'add-line');

    // A0-05: after a failed join, 用邀请码加入 clears the error and the same code
    // continues the application already registered on disk (host side).
    const failedPair = pairState({PairId:pairA, Phase:'Failed', StageLabel:'这一步没有完成', ErrorCode:'PairJoinUnfinished', ErrorMessage:'这次加入还没有完成，请在有效期内重新粘贴同一张邀请码。', NextAction:'Reenter'});
    await send(baseState({Lines:[lineState()], Pair:failedPair}), 'add-line');
    await equals('A0-05 失败态有错误提示', await count('[data-testid=pair-error]'), 1);
    await click('.breadcrumb [data-page=lines]');
    await send(baseState({Lines:[lineState()], Pair:failedPair, PairDeviceDefault:'TC-TEST-PC'}), 'lines');
    await click('#main .page-head [data-action=pairStart]');
    await send(baseState({Lines:[lineState()], Pair:failedPair, PairDeviceDefault:'TC-TEST-PC'}), 'add-line');
    await equals('A0-05 回到第 2 步', await attr('[data-testid=pair-step]', 'data-step'), '2');
    await equals('A0-05 旧错误已清', await count('[data-testid=pair-error]'), 0);
    await cdp.evaluate(`(()=>{const n=document.querySelector('[data-testid=pair-code]');n.value=${JSON.stringify(code)};n.dispatchEvent(new Event('input',{bubbles:true}));})()`);
    await cdp.evaluate("document.querySelector('[data-action=pairVerify]').click()");
    const retryVerify = (await posted()).slice(-1)[0];
    check('A0-05 同一张码重新校验且不带旧 PairId', retryVerify && retryVerify.Type === 'pairOnline' && retryVerify.Phase === 'Verify' && retryVerify.Code === code && !retryVerify.Id, JSON.stringify(retryVerify));

    // A0-06: the success card owns both ways forward and no longer offers 取消.
    await send(baseState({Lines:[lineState()], Pair:completedPair}), 'add-line');
    await equals('A0-06 成功态第 3 步', await attr('[data-testid=pair-step]', 'data-step'), '3');
    check('A0-06 有「再添加一条线路」', (await count('[data-testid=pair-restart]')) === 1);
    check('A0-06 没有「取消」', (await count('[data-testid=pair-cancel]')) === 0);
    check('A0-06 结果卡内有「去线路页」', (await count('[data-action=pairContinue]')) === 1);
    await click('[data-testid=pair-restart]');
    await equals('A0-06「再添加一条线路」回到第 1 步', await attr('[data-testid=pair-step]', 'data-step'), '1');
    await send(baseState({Lines:[lineState()], Pair:null}), 'lines');

    const blockedReason = '关联服务器公钥与此线路不一致，请先核对服务器身份。';
    const blockedLine = lineState({Id:LINE_B, Name:'重装过的线路', Blocked:true, BlockedReason:blockedReason, Readiness:{State:'NeedsAction',Label:'需要处理',Reason:blockedReason}});
    const blockedCard = `.line-card:has([data-detail="${LINE_B}"])`;
    await send(baseState({Lines:[lineState(), blockedLine]}), 'lines');
    await equals('V2-05 身份变化线路主按钮是「核对服务器身份」', await text(blockedCard + ' [data-action=lineServer]'), '核对服务器身份');
    await equals('V2-06 该按钮可点', await cdp.evaluate(`document.querySelector(${JSON.stringify(blockedCard + ' [data-action=lineServer]')}).disabled`), false);
    await equals('V2-07 卡片写明原因', await text(blockedCard + ' [data-testid=line-reason]'), blockedReason);
    await equals('V2-08 卡片不再有失效的连接按钮', await count(blockedCard + ' [data-action=connect]'), 0);
    await click(blockedCard + ' [data-action=lineServer]');
    const repairPost = (await posted()).slice(-1)[0];
    check('V2-09 点击发 lineServer 并带线路 Id', repairPost && repairPost.Type === 'lineServer' && repairPost.Id === LINE_B, JSON.stringify(repairPost));
    const legacyBlocked = lineState({Id:LINE_B, Name:'重装过的线路', Blocked:true});
    await send(baseState({Lines:[lineState(), legacyBlocked]}), 'lines');
    await equals('V2-10 旧投影没有原因字段时给出兜底说明', await text(blockedCard + ' [data-testid=line-reason]'), '服务器身份需要核对，暂不能连接。');
    await send(baseState({Lines:[lineState(), blockedLine]}), 'lines');
    await click(`[data-detail="${LINE_B}"]`); await sleep(80);
    await equals('V2-11 抽屉主操作是「核对服务器身份」', await text('#drawer .action-group[data-group=primary] [data-action=lineServer]'), '核对服务器身份');
    await equals('V2-12 抽屉主操作组没有失效的连接按钮', await count('#drawer .action-group[data-group=primary] [data-action=connect]'), 0);
    await click('[data-close=drawer]'); await sleep(80);
    await send(baseState({Lines:[blockedLine], HomeLineId:LINE_B, PreferredLineId:LINE_B}), 'home');
    await equals('V2-13 首页默认线路身份变化时大按钮是「核对服务器身份」', await text('.hero [data-action=lineServer]'), '核对服务器身份');
    await equals('V2-14 首页大按钮可点', await cdp.evaluate("document.querySelector('.hero [data-action=lineServer]').disabled"), false);
    check('V2-15 首页副标题说明原因', ((await text('.hero .sub')) || '').includes('需要先核对服务器身份'), await text('.hero .sub'));
    await send(baseState({Lines:[lineState()], HomeLineId:LINE_A}), 'home');
    await equals('V2-16 正常线路首页仍是「连接」', await text('.hero [data-action=connect]'), '连接');

    // ---------- W3 app / settings ----------
    await send(baseState({Lines:[lineState()]}), 'apps');
    check('W3-05 应用分组存在', (await count('[data-testid=apps-group]')) === 1);
    await send(baseState({Lines:[lineState()]}), 'settings');
    check('W3-05 设置分组存在', (await count('[data-testid=settings-group]')) === 1);
    const settingsText = await text('#main');
    check('W3-05 设置项集合不变', ['登录后打开 TradeChannel','登录后自动连接上次线路','关闭窗口时','自动记住首次服务器身份','线路变差提醒','界面主题'].every(item => settingsText.includes(item)), settingsText.slice(0, 120));

    // 0.22.5: 「线路变差提醒」从写死的徽章改成真开关（默认开启，可关闭）。
    await equals('W3-06 线路变差提醒是可操作开关', await count('[data-setting=QualityWarning]'), 1);
    await equals('W3-06 默认开启', await attr('[data-setting=QualityWarning]','aria-checked'), 'true');
    const beforeQuality = (await posted()).length;
    await click('[data-setting=QualityWarning]');
    const qualityPosts = (await posted()).slice(beforeQuality);
    check('W3-06 点击发出 SetUserSetting', qualityPosts.length === 1 && qualityPosts[0].Type === 'setting' && qualityPosts[0].Name === 'QualityWarning' && qualityPosts[0].Value === false, JSON.stringify(qualityPosts));
    await send(baseState(Object.assign({Lines:[lineState()]}, {Settings:Object.assign({}, baseState().Settings, {QualityWarning:false})})), 'settings');
    await equals('W3-06 关闭后回读为关', await attr('[data-setting=QualityWarning]','aria-checked'), 'false');
    const degradedState = over => baseState(Object.assign({Lines:[lineState()]}, liveOnA, {Quality:{LatencyMs:900,Quality:'Poor',Degraded:true,History:[],NotificationMessage:'线路连续多次响应异常。'}}, over));
    await send(degradedState({Settings:Object.assign({}, baseState().Settings, {QualityWarning:true})}), 'home');
    check('W3-06 开启时显示线路变差提醒', (await text('#main')).includes('线路连续多次响应异常'));
    await send(degradedState({Settings:Object.assign({}, baseState().Settings, {QualityWarning:false})}), 'home');
    check('W3-06 关闭后不再显示线路变差提醒', !(await text('#main')).includes('线路连续多次响应异常'));

    // ---------- 0.21.0 线路页快捷动作（PRD §5.4 验收门） ----------
    // One in-use default line plus one untested standby line: the two states that
    // carry the whole change set (home mark, live figure, protocol pick, derived
    // primary action, drawer groups).
    const qaState = baseState(Object.assign({
      Lines:[lineState({Quality30m:samplesFixture('a')}),
             lineState({Id:LINE_B,Name:'备用线路',Profile:'Tcp',ProfileSource:'Automatic',
                        Readiness:{State:'Untested',Label:'未测试',Reason:'还没有测过'}})]
    }, liveOnA));
    await send(qaState, 'lines');
    await equals('Q-01 默认标记恰好 1 张卡（R4）', await count('[data-testid=line-card] [data-testid=home-line-mark]'), 1);
    await equals('Q-02 默认标记是只读图形且 aria-label 正确（R4）',
      await cdp.evaluate("(()=>{const n=document.querySelector('[data-testid=home-line-mark]');return n?[n.getAttribute('role'),n.getAttribute('aria-label'),n.textContent.trim()].join('|'):'missing'})()"),
      'img|默认线路|★');
    await equals('Q-03 默认标记落在默认线路那张卡上（R4）',
      await cdp.evaluate("(()=>{const m=document.querySelector('[data-testid=home-line-mark]');if(!m)return 'no-mark';const card=m.closest('.line-card');const name=card&&card.querySelector('.name-button');return name?name.textContent.replace('★','').trim():'no-card'})()"),
      '我的主线路');
    await equals('Q-04 卡片内不再出现「默认」二字（G3）',
      await cdp.evaluate("[...document.querySelectorAll('[data-testid=line-card]')].filter(c=>c.querySelector('.line-card-head').textContent.includes('默认')).length"), 0);
    await equals('Q-05 每张卡都有直选槽位（R1/R2）',
      await cdp.evaluate("document.querySelectorAll('[data-testid=line-card]').length===document.querySelectorAll('[data-testid=line-card] [data-testid=protocol-pick]').length"), true);
    await equals('Q-06 双协议线路渲染两段 radio（R1）',
      await count('[data-testid=line-card] [data-testid=protocol-pick] [role=radio]'), 4);
    // 0.22.0 C-R5：选中语义只剩 aria-checked（C5-04 不允许再挂 aria-pressed）。
    await equals('Q-07 直选段只用 role=radio + aria-checked（C5-04）',
      await cdp.evaluate("(()=>{const s=[...document.querySelectorAll('[data-testid=line-card] .seg')];if(s.some(b=>b.hasAttribute('aria-pressed')))return 'has-aria-pressed';return s.every(b=>b.getAttribute('role')==='radio'&&b.getAttribute('aria-checked')===String(b.classList.contains('on')))?'ok':'mismatch'})()"), 'ok');
    await equals('Q-08 单协议线路退化为静态文字而非禁用控件（R2）',
      await cdp.evaluate("(()=>{const c=document.querySelectorAll('[data-testid=line-card]')[1];return c?c.querySelector('[data-testid=protocol-pick]').tagName:'no-card'})()"), 'SPAN');
    await equals('Q-09 纯静态直选区没有 radio（R2）',
      await count('[data-testid=line-card] [data-testid=protocol-pick].seg-static [role=radio]'), 0);
    await equals('Q-10 卡片内 setHomeLine=0（R5）', await count('[data-testid=line-card] [data-action=setHomeLine]'), 0);
    await equals('Q-11 在用卡内 testLine 计数=0（R8）', await count('[data-testid=line-card].in-use [data-action=testLine]'), 0);
    // C-R6: the number is a reading again; a separate small 测速 button carries the
    // same disabled rules and its own countdown.
    await equals('Q-12 备用卡测速按钮独立于数字（C-R6）', await count('[data-testid=line-card]:not(.in-use) .metric-test[data-action=testLine]'), 1);
    await equals('Q-12b 备用卡数字不再是可点入口（C-R6）', await count('[data-testid=line-card]:not(.in-use) .metric-link[data-action=testLine]'), 0);
    await equals('Q-12c 测速按钮有可读名（C-R6）',
      await cdp.evaluate("(()=>{const b=document.querySelector('[data-testid=line-card]:not(.in-use) .metric-test');return b?b.getAttribute('aria-label')+'|'+b.textContent.trim():'missing'})()"), '测速这条线路|测速');
    await equals('Q-13 在用卡主动作=断开（R6 行 1）',
      await cdp.evaluate("(()=>{const c=document.querySelector('.line-card.in-use .actions button:not(.seg)');return c?c.textContent.trim():'missing'})()"), '断开');
    await equals('Q-14 未测试卡主动作=测速（R6 行 2）',
      await cdp.evaluate("(()=>{const c=document.querySelectorAll('[data-testid=line-card]')[1].querySelector('.actions button:not(.seg)');return c?c.textContent.trim():'missing'})()"), '测速');
    // R6 row 3. The host labels a failed line 上次测试未通过 through
    // Readiness.State=TestFailed (GetTCWebLineReadiness), so the derived action has
    // to read Readiness, not only the client-side RecentConnectionFailure window.
    await send(baseState({Lines:[lineState({Readiness:{State:'TestFailed',Label:'上次测试未通过',Reason:'连接时会自动重试，不通会自动恢复原状态'}})]}), 'lines');
    await equals('Q-14b 上次未通过卡主动作=测速（R6 行 3）',
      await cdp.evaluate("(()=>{const c=document.querySelector('[data-testid=line-card] .actions button:not(.seg)');return c?c.textContent.trim():'missing'})()"), '测速');
    await equals('Q-14c 上次未通过卡没有常驻测速入口（R6 行 3：指标不可点）', await count('[data-testid=line-card] .metric-link[data-action=testLine]'), 0);
    await equals('Q-14d 上次未通过卡也没有独立测速按钮（C-R6）', await count('[data-testid=line-card] .metric-test[data-action=testLine]'), 0);
    await send(qaState, 'lines');
    await equals('Q-15 动作行 nowrap（R10）',
      await cdp.evaluate("getComputedStyle(document.querySelector('.line-card .actions')).flexWrap"), 'nowrap');
    await equals('Q-16 动作行高度 40px（R10）',
      await cdp.evaluate("Math.round(document.querySelector('.line-card .actions').getBoundingClientRect().height)"), 40);
    await equals('Q-17 直选控件 40px = .seg 32 + 外衬 3x2 + 描边 1x2（R10）',
      await cdp.evaluate("(()=>{const g=document.querySelector('.line-card .seg-group');const cs=getComputedStyle(g);const seg=g.querySelector('.seg');return Math.round(g.getBoundingClientRect().height)+'|'+Math.round(seg.getBoundingClientRect().height)+'|'+parseInt(cs.paddingTop)+'|'+parseInt(cs.borderTopWidth)})()"),
      '40|32|3|1');
    await equals('Q-18 抽屉关闭时首页 .primary ≤ 1（R12）', await cdp.evaluate("document.querySelectorAll('#main .primary').length<=1"), true);
    await click('[data-detail]'); await sleep(80);
    await equals('Q-19 抽屉动作分三组（R12）', await count('#drawer .action-group'), 3);
    await equals('Q-20 组序 primary/maintain/danger（R12）',
      await cdp.evaluate("[...document.querySelectorAll('#drawer .action-group')].map(g=>g.dataset.group).join('>')"), 'primary>maintain>danger');
    // 0.21.2 reverses R9: the entry was not a duplicate (server and devices,
    // network binding and its rollback had no other web entry).
    await equals('Q-21 维护组含「连接方式与网络…」（0.21.2）', await count('#drawer .action-group[data-group=maintain] [data-action=lineSettings]'), 1);
    await equals('Q-21b 维护组含「服务器与设备」（0.21.2）', await count('#drawer .action-group[data-group=maintain] [data-action=lineServer]'), 1);
    await equals('Q-22 危险组只含一个 danger（R12）', await count('#drawer .action-group[data-group=danger] .danger'), 1);
    await equals('Q-23 抽屉内 .primary ≤ 1（R12）', await cdp.evaluate("document.querySelectorAll('#drawer .primary').length<=1"), true);
    await equals('Q-24 三组间距一致（§3.7）',
      await cdp.evaluate("(()=>{const g=[...document.querySelectorAll('#drawer .action-group')];const b=g.map(n=>n.getBoundingClientRect());const gaps=b.slice(1).map((r,i)=>Math.round(r.top-b[i].bottom));return gaps.every(v=>v===gaps[0])?'equal:'+gaps[0]:'uneven:'+gaps.join('/')})()").then(v=>v.startsWith('equal:')), true);
    await click('[data-close=drawer]'); await sleep(80);
    await send(qaState, 'lines');
    await click('[data-detail="'+LINE_B+'"]'); await sleep(80);
    await equals('Q-25 非默认线路抽屉内 setHomeLine=1（R5）', await count('#drawer [data-action=setHomeLine]'), 1);
    // 0.21.2: + 服务器与设备 + 连接方式与网络… (5 → 7).
    // The 7-action contract counts actions, not the C-R7 ⓘ (a <button class="hint">).
    await equals('Q-26 非默认线路抽屉 7 个动作（R12 + 0.21.2 维护入口）', await count('#drawer .actions button:not(.hint)'), 7);
    await equals('Q-26b 抽屉测速旁挂一个说明入口（C-R7）', await count('#drawer .action-group[data-group=maintain] .hint[data-hint]'), 1);
    await equals('Q-27 抽屉动作区无指向旧版页面的入口（G2）',
      await cdp.evaluate("(()=>[...document.querySelectorAll('#drawer .actions button')].some(b=>/连接方式与维护|更多/.test(b.textContent))?'found':'none')()"), 'none');
    await click('[data-close=drawer]'); await sleep(80);
    // R1 boundary: a pick writes a preference only - no connect/switch transaction.
    await send(qaState, 'lines');
    const pickBefore = (await posted()).length;
    await click('[data-testid=line-card] .seg-group .seg:nth-child(2)'); await sleep(80);
    const pickPosts = (await posted()).slice(pickBefore);
    check('Q-28 点直选只发 setProfile 偏好报文（R1）',
      pickPosts.length === 1 && pickPosts[0].Type === 'setProfile' && pickPosts[0].Value === 'Tcp',
      JSON.stringify(pickPosts));
    check('Q-29 点直选不产生连接事务也进不了 IsBusy（R1）',
      pickPosts.every(m => !['connect','switch','disconnect','testLine','confirmDialog'].includes(m.Type)),
      JSON.stringify(pickPosts.map(m => m.Type)));
    check('Q-30 点直选不打开抽屉（R1）', !(await cdp.evaluate("!!document.querySelector('#drawer') && !document.querySelector('#drawer').hidden")));
    await send(baseState({Lines:[lineState()]}), 'lines');

    // ---------- I (0.22.0 A2 / 0.22.2) 邀请其他电脑 ----------
    // 0.22.2 把页面拆成四屏（选择线路 / 设置 / 已生成 / 已结束），结果不再和表单
    // 同屏。快照仍然不带码，只有打码预览 + CodePresent；下面每条都只说页面必须
    // 对这份快照做出什么反应。
    const INVITE_CODE = 'TCI1.' + 'Z'.repeat(40);
    const postedBase = (await posted()).length;
    const INVITE_FUTURE = new Date(Date.now() + 3600000).toISOString();
    const inviteViewState = over => Object.assign({
      Epoch:3, InviteSessionId:'s1', Phase:'Idle', StageLabel:'', StageChangedAtUtc:null, ServerId:'server-a',
      LifetimeSeconds:0, LifetimePresets:[600,1800,7200,86400], LifetimeMin:600, LifetimeMax:86400,
      InviteId:'', State:'', ExpiresAtUtc:null, RetryUntilUtc:null, Reachability:null,
      CodePresent:false, CodePreview:'', CompatNoteVisible:false,
      Servers:[{Id:'server-a',Name:'Singapore A'},{Id:'server-f',Name:'Tokyo F'}],
      Origin:'lines',
      ErrorCode:'', ErrorMessage:'', NextAction:'None'
    }, over);
    const inviteLine = over => lineState(Object.assign({Id:LINE_A, Name:'模拟香港主线', CanInvite:true, ServerRecordId:'server-a', ServerName:'Singapore A'}, over));
    const inviteLineF = over => lineState(Object.assign({Id:'line-f', Name:'Tokyo F 线路', CanInvite:true, ServerRecordId:'server-f', ServerName:'Tokyo F'}, over));
    const liveInvite = over => inviteViewState(Object.assign({
      Phase:'Open', InviteId:'invite-1', State:'Open', ExpiresAtUtc:INVITE_FUTURE, CodePresent:true,
      CodePreview:'TCI1.\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022AB12',
      Reachability:{Status:'Reachable', CheckedAtUtc:new Date().toISOString(), Port:18443}
    }, over));

    // I-01 A-06：页面里只有打码预览，完整码只在 Reveal 那一条消息里。
    await send(baseState({Lines:[inviteLine()], Invite:liveInvite()}), 'invite');
    await equals('I-01 标题是「邀请码已生成」', await text('#main .page-head h1'), '邀请码已生成');
    await equals('I-01 只显示打码预览（A-06）', await cdp.evaluate("document.querySelector('[data-testid=invite-code]').value"), 'TCI1.\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022AB12');
    check('I-01 页面里没有完整邀请码（A-06）',
      !/TCI1\.[A-Za-z0-9_-]{20,}/.test(await cdp.evaluate("document.querySelector('#main').innerHTML")));
    await equals('I-01 输入框标为密文', await attr('[data-testid=invite-code]', 'data-secret'), 'true');

    // I-02 线路页标题栏：一条可邀请线路直接进；两条先选。
    await send(baseState({Lines:[inviteLine()]}), 'lines');
    const headOrder = await cdp.evaluate("[...document.querySelectorAll('#main .page-head .actions button')].map(b=>b.textContent.trim())");
    check('I-02 标题栏邀请入口排在「用邀请码加入」之前',
      headOrder.indexOf('邀请其他电脑') >= 0 && headOrder.indexOf('邀请其他电脑') < headOrder.indexOf('用邀请码加入'), JSON.stringify(headOrder));
    const beforeBegin = (await posted()).length;
    await click('#main .page-head [data-invite=Choose]');
    const beginPosts = (await posted()).slice(beforeBegin);
    check('I-02 一条线路直接带 Id 进入',
      beginPosts.length === 1 && beginPosts[0].Type === 'invite' && beginPosts[0].Phase === 'Begin' && beginPosts[0].Id === LINE_A, JSON.stringify(beginPosts));

    // I-03 A-16：只有使用权时两个入口都不出现，但按钮不再静默消失（给原因）。
    await send(baseState({Lines:[lineState({CanInvite:false, ServerRecordId:''})]}), 'lines');
    await equals('I-03 只有使用权时没有可点的邀请入口（A-16）', await count('#main [data-invite=Choose]'), 0);
    await equals('I-03 不可邀请时按钮保留并禁用', await count('#main [data-testid=invite-unavailable]'), 1);
    check('I-03 禁用按钮带说明', (await count('#main .page-head .hint')) >= 1);
    await click('[data-detail]'); await sleep(60);
    await equals('I-03 抽屉维护组也没有邀请入口（A-16）', await count('#drawer .action-group[data-group=maintain] [data-invite=Begin]'), 0);
    await click('[data-close=drawer]'); await sleep(60);

    // I-04 A2：抽屉里是维护组第一个动作，并带上这条线路。
    await send(baseState({Lines:[inviteLine()]}), 'lines');
    await click('[data-detail]'); await sleep(60);
    await equals('I-04 抽屉维护组第一个是邀请入口',
      await cdp.evaluate("(()=>{const g=document.querySelector('#drawer .action-group[data-group=maintain]');const b=g&&g.querySelector('button');return b?b.textContent.trim()+'|'+b.dataset.invite:'missing'})()"),
      '邀请其他电脑|Begin');
    const beforeDrawer = (await posted()).length;
    await click('#drawer [data-invite=Begin]');
    const drawerPosts = (await posted()).slice(beforeDrawer);
    check('I-04 抽屉入口带上这条线路的 ID',
      drawerPosts.length === 1 && drawerPosts[0].Type === 'invite' && drawerPosts[0].Phase === 'Begin' && drawerPosts[0].Id === LINE_A, JSON.stringify(drawerPosts));
    await click('[data-close=drawer]'); await sleep(60);

    // I-05 多线路：标题栏只发 navigate，页面第一屏是「选择线路」。
    await send(baseState({Lines:[inviteLine(), inviteLineF()]}), 'lines');
    const beforeChoose = (await posted()).length;
    await click('#main .page-head [data-invite=Choose]');
    const choosePosts = (await posted()).slice(beforeChoose);
    check('I-05 两条线路时先进入选择屏，不直接发 Begin',
      choosePosts.length === 1 && choosePosts[0].Type === 'navigate' && choosePosts[0].Page === 'invite', JSON.stringify(choosePosts));
    await send(baseState({Lines:[inviteLine(), inviteLineF()], Invite:inviteViewState({ServerId:''})}), 'invite');
    await equals('I-05 选择屏列出两条线路', await count('.pair-option'), 2);
    await equals('I-05 选择屏没有有效期', await count('[data-invite=Lifetime]'), 0);
    const beforeTarget = (await posted()).length;
    await click('.pair-option[data-value="server-f"]');
    const targetPosts = (await posted()).slice(beforeTarget);
    check('I-05 选中线路后按服务器 ID 进入',
      targetPosts.length === 1 && targetPosts[0].Phase === 'Begin' && targetPosts[0].Value === 'server-f', JSON.stringify(targetPosts));

    // I-06 设置屏：线路一行 + 有效期 + 一个主按钮。
    await send(baseState({Lines:[inviteLine()], Invite:inviteViewState({})}), 'invite');
    await equals('I-06 页面标题', await text('#main .page-head h1'), '邀请其他电脑');
    await equals('I-06 线路行显示这条线路', await text('[data-testid=invite-line]'), '模拟香港主线');
    await equals('I-06 有效期四段预设', await count('[data-invite=Lifetime]'), 4);
    await equals('I-06 自定义是第五段', await count('[data-invite=LifetimeCustom]'), 1);
    await equals('I-06 默认选中 30 分钟', await attr('[data-invite=Lifetime][data-value="1800"]', 'aria-pressed'), 'true');
    await equals('I-06 卡片里只有一个主按钮', await cdp.evaluate("document.querySelectorAll('.invite-card .primary').length"), 1);
    await equals('I-06 设置屏没有服务器单选（选择已在线路行）', await count('[data-invite=SelectServer]'), 0);
    await click('[data-invite=LifetimeCustom]');
    await cdp.evaluate("(()=>{const n=document.getElementById('invite-amount');n.value='5';n.dispatchEvent(new Event('input',{bubbles:true}));})()");
    await equals('I-06 自定义 5 分钟判为无效', await count('[data-testid=invite-custom-hint]'), 1);
    check('I-06 无效输入时生成按钮禁用', (await attr('[data-invite=CreateNew]', 'disabled')) !== null);
    await cdp.evaluate("(()=>{const n=document.getElementById('invite-amount');n.value='45';n.dispatchEvent(new Event('input',{bubbles:true}));})()");
    const beforeCreate = (await posted()).length;
    await click('[data-invite=CreateNew]');
    const createPosts = (await posted()).slice(beforeCreate);
    check('I-06 自定义 45 分钟按秒发出',
      createPosts.length === 1 && createPosts[0].Type === 'invite' && createPosts[0].Phase === 'CreateNew' && Number(createPosts[0].Value) === 2700, JSON.stringify(createPosts));
    await send(baseState({Lines:[inviteLine()], Invite:inviteViewState({})}), 'invite');
    await click('[data-invite=Lifetime][data-value="7200"]');
    const beforePreset = (await posted()).length;
    await click('[data-invite=CreateNew]');
    const presetPosts = (await posted()).slice(beforePreset).filter(item => item.Phase === 'CreateNew');
    check('I-06 预设 2 小时按 7200 秒发出',
      presetPosts.length === 1 && Number(presetPosts[0].Value) === 7200, JSON.stringify(presetPosts));

    // I-07 三段进度留在设置屏（不能与结果同屏）。
    const stageRows = [['Loading','正在登录服务器'], ['LoggingIn','正在登录服务器'], ['Creating','正在生成邀请码'], ['Checking','正在检查 18443 能否连通']];
    for (const [phase, label] of stageRows) {
      await send(baseState({Lines:[inviteLine()], Invite:inviteViewState({Phase:phase, StageLabel:'', StageChangedAtUtc:new Date().toISOString()})}), 'invite');
      await equals(`I-07 ${phase} 阶段文案`, await text('[data-testid=invite-stage-label]'), label);
      await equals(`I-07 ${phase} 进度标出阶段`, await attr('[data-testid=invite-stage]', 'data-stage'), phase);
      check(`I-07 ${phase} 期间生成按钮禁用`, (await attr('[data-invite=CreateNew]', 'disabled')) !== null);
      await equals(`I-07 ${phase} 期间没有结果区`, await count('[data-testid=invite-expires]'), 0);
    }
    await equals('I-07 阶段带已用时间', await count('[data-testid=invite-stage] [data-elapsed]'), 1);

    // I-08 A-16 的反面：结果屏与表单互斥。
    await send(baseState({Lines:[inviteLine()], Invite:liveInvite()}), 'invite');
    await equals('I-08 已生成时没有有效期选择', await count('[data-invite=Lifetime]'), 0);
    await equals('I-08 已生成时没有「生成邀请码」', await count('[data-invite=CreateNew]'), 0);
    await equals('I-08 已生成时邀请码控件只有一个', await count('[data-testid=invite-code]'), 1);
    await equals('I-08 卡片里只有一个主按钮（复制）', await cdp.evaluate("document.querySelectorAll('.invite-card .primary').length"), 1);
    await equals('I-08 主按钮是复制邀请码', await text('.invite-card .primary'), '复制邀请码');

    // I-09 结果屏的一行说清线路与到期（24 小时档必须带日期）。
    const meta = await text('[data-testid=invite-expires]');
    check('I-09 结果行带线路名', (meta || '').includes('模拟香港主线'), meta);
    check('I-09 结果行带到期与剩余时间', (meta || '').includes('失效') && (meta || '').includes('还剩'), meta);
    const tomorrow = new Date(Date.now() + 30 * 3600 * 1000).toISOString();
    await send(baseState({Lines:[inviteLine()], Invite:liveInvite({ExpiresAtUtc:tomorrow})}), 'invite');
    const meta2 = await text('[data-testid=invite-expires]');
    check('I-09 跨天的到期必须带日期', /[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9] 失效/.test(meta2 || ''), meta2);

    // I-10 页脚：已生成是「取消邀请码 + 完成」，没有「上一步」。
    await equals('I-10 已生成页脚有取消邀请码', await count('.pair-footer [data-invite=CancelConfirm]'), 1);
    await equals('I-10 已生成页脚有完成', await text('.pair-footer [data-invite=Close]'), '完成');
    await equals('I-10 已生成页脚没有上一步', await count('.pair-footer [data-invite=Choose]'), 0);
    await send(baseState({Lines:[inviteLine()], Invite:inviteViewState({})}), 'invite');
    await equals('I-10 设置屏页脚没有取消邀请码', await count('.pair-footer [data-invite=CancelConfirm]'), 0);

    // I-11 取消邀请码要二次确认，默认不动作。
    await send(baseState({Lines:[inviteLine()], Invite:liveInvite()}), 'invite');
    const beforeConfirm = (await posted()).length;
    await click('[data-invite=CancelConfirm]');
    await equals('I-11 第一次点取消只展开确认', await count('[data-testid=invite-cancel-confirm]'), 1);
    check('I-11 第一次点取消不发报文', (await posted()).length === beforeConfirm);
    const beforeCancel = (await posted()).length;
    await click('[data-testid=invite-cancel-confirm] [data-invite=Cancel]');
    const cancelPosts = (await posted()).slice(beforeCancel);
    check('I-11 确认后才发 Cancel',
      cancelPosts.length === 1 && cancelPosts[0].Phase === 'Cancel', JSON.stringify(cancelPosts));

    // I-12 18443：成功不占位，失败才出现一行；恢复动作收进折叠区。
    await equals('I-12 可连接时不显示 18443 行', await count('[data-testid=invite-reach]'), 0);
    await send(baseState({Lines:[inviteLine()], Invite:liveInvite({Reachability:{Status:'Refused', CheckedAtUtc:new Date().toISOString(), Port:18443}})}), 'invite');
    await equals('I-12 被拒时给出一行', await text('[data-testid=invite-reach]'), '18443 连不上（连接被拒绝）：请在云服务器防火墙放行 TCP 18443');
    await equals('I-12 恢复动作不在主路径', await count('.invite-card > .actions [data-invite=Recheck]'), 0);
    await equals('I-12 恢复动作在折叠区内', await count('details.invite-more [data-invite=Recheck]'), 1);
    await equals('I-12 离线邀请出口仍在', await count('details.invite-more [data-invite=Offline]'), 1);

    // I-13 结束态：过期/取消给「再生成一个」，已使用不给。
    await send(baseState({Lines:[inviteLine()], Invite:liveInvite({State:'Expired', Reachability:null, CodePresent:false, CodePreview:''})}), 'invite');
    await equals('I-13 过期标题', await text('#main .pair-card h2'), '已过期');
    await equals('I-13 过期给「再生成一个」', await count('.pair-footer [data-invite=CreateNew]'), 1);
    await equals('I-13 过期没有取消', await count('[data-invite=CancelConfirm]'), 0);
    await send(baseState({Lines:[inviteLine()], Invite:liveInvite({State:'Consumed', Reachability:null, CodePresent:false, CodePreview:''})}), 'invite');
    await equals('I-13 已使用不给「再生成一个」', await count('.pair-footer [data-invite=CreateNew]'), 0);
    await equals('I-13 已使用给「再邀请一台」', await count('.pair-footer [data-invite=Choose]'), 1);

    // I-14 本机不再持有邀请码（重启后最常遇到的一屏）。
    await send(baseState({Lines:[inviteLine()], Invite:liveInvite({CodePresent:false, CodePreview:''})}), 'invite');
    await equals('I-14 明确说明本机不持有', await count('[data-testid=invite-code-missing]'), 1);
    await equals('I-14 不显示空的邀请码输入框', await count('[data-testid=invite-code]'), 0);
    await equals('I-14 给作废入口', await count('[data-invite=Cancel]'), 1);

    // I-15 Reveal 只发一条消息；码写进字段，刷新仍在，离开即清。
    await send(baseState({Lines:[inviteLine()], Invite:liveInvite()}), 'invite');
    const beforeReveal = (await posted()).length;
    await click('[data-invite=Reveal]');
    const revealPosts = (await posted()).slice(beforeReveal);
    check('I-15 显示完整邀请码只发一条 Reveal',
      revealPosts.length === 1 && revealPosts[0].Type === 'invite' && revealPosts[0].Phase === 'Reveal', JSON.stringify(revealPosts));
    await cdp.evaluate(`window.__host.handler({data:{Type:'inviteCode', Id:'invite-1', Code:${JSON.stringify(INVITE_CODE)}}})`);
    await equals('I-15 码写进只读输入框', await cdp.evaluate("document.querySelector('[data-testid=invite-code]').value"), INVITE_CODE);
    await send(baseState({Lines:[inviteLine()], Invite:liveInvite()}), 'invite');
    await equals('I-15 快照刷新后码仍在', await cdp.evaluate("document.querySelector('[data-testid=invite-code]').value"), INVITE_CODE);
    check('I-15 网页从不把码发回宿主（A-06）',
      !/TCI1\.[A-Za-z0-9_-]{20,}/.test((await posted()).slice(postedBase).map(m => JSON.stringify(m)).join('|')));
    await send(baseState({Lines:[inviteLine()]}), 'lines');
    await send(baseState({Lines:[inviteLine()], Invite:liveInvite()}), 'invite');
    await equals('I-15 离开页面后不再显示码', await cdp.evaluate("document.querySelector('[data-testid=invite-code]').value"), 'TCI1.\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022AB12');

    // I-16 复制与「没有保存登录资料」的出口。
    await send(baseState({Lines:[inviteLine()], Invite:liveInvite()}), 'invite');
    const beforeCopy = (await posted()).length;
    await click('[data-invite=Copy]');
    const copyPosts = (await posted()).slice(beforeCopy);
    check('I-16 复制邀请码发 Copy',
      copyPosts.length === 1 && copyPosts[0].Type === 'invite' && copyPosts[0].Phase === 'Copy', JSON.stringify(copyPosts));
    await send(baseState({Lines:[inviteLine()], Invite:inviteViewState({Phase:'Idle', ErrorCode:'SavedLoginRequired', ErrorMessage:'这台服务器没有保存登录资料', NextAction:'OpenServer', Servers:[{Id:'server-a',Name:'Singapore A',Host:'192.0.2.10',Lines:['主线'],SavedLogin:false}]})}), 'invite');
    await equals('I-16 没有保存登录资料在生成前显示', await text('[data-testid=invite-error]'), '这台服务器没有保存登录资料');
    await equals('I-16 唯一出口是去登录', await text('[data-invite=OpenServer]'), '去登录');
    check('I-16 没有保存资料时生成入口禁用', (await attr('[data-invite=CreateNew]', 'disabled')) !== null);

    // I-17 服务器与设备入口：副标题不再承诺「这条线路」，返回按来源走。
    await send(baseState({Lines:[inviteLine()], Invite:inviteViewState({Origin:'server'})}), 'invite');
    await equals('I-17 服务器入口的返回写明回服务器', await text('#main .breadcrumb button'), '← 返回服务器');
    await send(baseState({Lines:[inviteLine()], Invite:inviteViewState({})}), 'invite');
    await equals('I-17 线路入口的返回写明回线路', await text('#main .breadcrumb button'), '← 返回线路');
    const beforeClose = (await posted()).length;
    await click('#main .breadcrumb button');
    const closePosts = (await posted()).slice(beforeClose);
    check('I-17 返回发 Close 而不是硬跳线路',
      closePosts.length === 1 && closePosts[0].Phase === 'Close', JSON.stringify(closePosts));
    await send(baseState({Lines:[inviteLine()], Invite:inviteViewState({Phase:'Idle', ErrorCode:'SavedLoginRequired', ErrorMessage:'这台服务器没有保存登录资料', NextAction:'OpenServer', Servers:[{Id:'server-a',Name:'Singapore A',Host:'192.0.2.10',Lines:['主线'],SavedLogin:false}]})}), 'invite');
    await equals('I-18 邀请页只有一个 Close 出口（顶部面包屑）', await count('[data-invite=Close]'), 1);

    // ---------- J 组：页首返回提升（0.22.5）----------
    // 页面自己提供的 MaintenanceBack 被提升到面包屑位置：同一个控件句柄、同一个
    // wf 动作，正文不再重复渲染；没有这种按钮的页面仍走原来的 data-page 面包屑。
    const backForm = {Title:'登录这台服务器', Description:'正在准备登录…', ParentPage:'invite', Generation:11, Nodes:[
      wfNode('panel','p-back',{Children:[wfNode('button','wf-back',{Name:'MaintenanceBack', Text:'返回邀请其他电脑', Label:'返回邀请其他电脑', Tone:'ghost'})]}),
      wfNode('text','t-loading',{Text:'正在读取服务器记录，完成后在本页选择登录方式。'})
    ], Actions:[]};
    await send(baseState(Object.assign({Lines:[lineState()]}, {Form:backForm, Busy:false})), 'lines');
    await equals('J-01 页首只有一个返回出口', await count('#main .breadcrumb button'), 1);
    await equals('J-01 面包屑文案写目的地', await text('#main .breadcrumb button'), '← 返回邀请其他电脑');
    await equals('J-02 正文不再重复返回按钮', await count('.workflow [data-control-name="MaintenanceBack"]'), 0);
    await equals('J-02 只剩返回按钮的容器不再留下可点元素', await count('.workflow button'), 0);
    await equals('J-03 面包屑沿用原控件句柄', await attr('#main .breadcrumb button','data-wf'), backForm.Nodes[0].Children[0].Id);
    const beforeBack = (await posted()).length;
    await click('#main .breadcrumb button');
    const backPosts = (await posted()).slice(beforeBack);
    check('J-04 返回走 wf 控件动作而不是硬跳页',
      backPosts.length === 1 && backPosts[0].Type === 'form' && backPosts[0].Id === backForm.Nodes[0].Children[0].Id && backPosts[0].Event === 'click', JSON.stringify(backPosts));
    const plainForm = {Title:'部署', Description:'', ParentPage:'lines', Generation:12, Nodes:[
      wfNode('text','t-plain',{Text:'没有页面返回按钮的普通投影页'})
    ], Actions:[]};
    await send(baseState(Object.assign({Lines:[lineState()]}, {Form:plainForm, Busy:false})), 'lines');
    await equals('J-05 无返回按钮时仍用父页面面包屑', await attr('#main .breadcrumb button','data-page'), 'lines');
    await equals('J-05 默认面包屑文案不变', await text('#main .breadcrumb button'), '← 返回线路');
    await equals('J-05 普通投影页正文不被提取', await count('.workflow [data-wf-key="'+plainForm.Nodes[0].Id+'"]'), 1);

    // ---------- K 组：折叠说明在快照刷新后保持展开（0.22.5）----------
    // details 的 open 是用户当场的选择，快照每秒刷新一次；属性严格同步会把
    // 刚展开的「新电脑怎么用」立刻收回去，指引等于没写。
    await send(baseState({Lines:[inviteLine()], Invite:liveInvite()}), 'invite');
    await equals('K-01 邀请结果页有两个折叠说明', await count('.invite-more'), 2);
    await cdp.evaluate("document.querySelectorAll('.invite-more summary')[0].click()");
    await cdp.evaluate("document.querySelectorAll('.invite-more summary')[1].click()");
    await equals('K-01 两个说明都能展开', await cdp.evaluate("document.querySelectorAll('.invite-more')[0].open && document.querySelectorAll('.invite-more')[1].open"), true);
    await send(baseState({Lines:[inviteLine()], Invite:liveInvite()}), 'invite');
    await sleep(60);
    await equals('K-01 快照刷新后第一个仍展开', await cdp.evaluate("document.querySelectorAll('.invite-more')[0].open"), true);
    await equals('K-01 快照刷新后第二个仍展开', await cdp.evaluate("document.querySelectorAll('.invite-more')[1].open"), true);
    await equals('K-01 刷新后说明正文仍可见', await cdp.evaluate("document.querySelectorAll('.invite-more')[0].querySelector('p').textContent.length > 5"), true);
    await cdp.evaluate("document.querySelectorAll('.invite-more summary')[0].click()");
    await send(baseState({Lines:[inviteLine()], Invite:liveInvite()}), 'invite');
    await sleep(40);
    await equals('K-01 用户主动收起后刷新不会被重新打开', await cdp.evaluate("document.querySelectorAll('.invite-more')[0].open"), false);

    // ---------- H 组：悬浮说明（0.22.0 B1 / B2）----------
    await cdp.evaluate("window.__csp=[];document.addEventListener('securitypolicyviolation',e=>window.__csp.push(e.violatedDirective+' '+e.blockedURI))");
    await send(baseState(Object.assign({Lines:[lineState()]}, {Running:true, State:'Connected', Quality:{Degraded:false}})));
    const hintSel = '.hero .hint';
    await equals('H-01 首页「当前响应」有 ⓘ', await count(hintSel), 1);
    await equals('H-01 ⓘ 不再用原生 title', await attr(hintSel, 'title'), null);
    const rectOf = sel => cdp.evaluate(`(()=>{const n=document.querySelector(${JSON.stringify(sel)});if(!n)return null;const r=n.getBoundingClientRect();return {x:r.left+r.width/2,y:r.top+r.height/2}})()`);
    const hover = (x, y) => cdp.send('Input.dispatchMouseEvent', {type:'mouseMoved', x, y, button:'none'});
    const layerOpen = () => cdp.evaluate("(()=>{const n=document.getElementById('hint-layer');return !!n && !n.hidden && n.textContent.length>0})()");
    const layerText = () => cdp.evaluate("document.getElementById('hint-layer').textContent");
    const pressEscape = async () => {
      await cdp.send('Input.dispatchKeyEvent', {type:'keyDown', key:'Escape', code:'Escape', windowsVirtualKeyCode:27, nativeVirtualKeyCode:27});
      await cdp.send('Input.dispatchKeyEvent', {type:'keyUp', key:'Escape', code:'Escape', windowsVirtualKeyCode:27, nativeVirtualKeyCode:27});
    };
    const heroPoint = await rectOf(hintSel);
    await hover(heroPoint.x, heroPoint.y); await sleep(120);
    await equals('H-01 悬停 120ms 还不出现', await layerOpen(), false);
    await sleep(280);
    await equals('H-01 悬停 300ms 后出现', await layerOpen(), true);
    await equals('H-01 文字来自 data-hint', await layerText(), '当前交易出口的 HTTPS 往返响应，含加密建连耗时，不等同于下单延迟');
    await equals('H-01 aria-describedby 指向气泡', await attr(hintSel, 'aria-describedby'), 'hint-layer');
    const bubblePoint = await cdp.evaluate("(()=>{const r=document.getElementById('hint-layer').getBoundingClientRect();return {x:r.left+r.width/2,y:r.top+r.height/2}})()");
    await hover(bubblePoint.x, bubblePoint.y); await sleep(300);
    await equals('H-01 指针移进气泡后保持打开', await layerOpen(), true);
    await pressEscape(); await sleep(40);
    await equals('H-01 Esc 关闭', await layerOpen(), false);
    await equals('H-01 关闭后移除 aria-describedby', await attr(hintSel, 'aria-describedby'), null);
    await cdp.evaluate("document.querySelector('.hero .hint').focus()"); await sleep(30);
    await equals('H-01 键盘聚焦立即出现', await layerOpen(), true);
    await click(hintSel); await sleep(40);
    await equals('H-01 点击切换为关闭', await layerOpen(), false);
    await click(hintSel); await sleep(40);
    await equals('H-01 再次点击打开', await layerOpen(), true);

    // 表单镜像：Hint 字段与 hint 节点（B2），禁用控件旁的 ⓘ 仍可用（B-03）
    const hintForm = {Title:'部署', Description:'', ParentPage:'lines', Generation:7, Nodes:[
      {Kind:'button', Id:'wf-a', Text:'开始部署', Disabled:true, Hint:'部署会重启网络服务，连接会中断约 30 秒。'},
      {Kind:'button', Id:'wf-b', Text:'保存', Hint:'只保存到本机，不影响当前连接。'},
      {Kind:'hint', Id:'', Text:'这是一段只读说明，没有可执行句柄。'}
    ], Actions:[]};
    await send(baseState(Object.assign({Lines:[lineState()]}, {Form:hintForm, Busy:false})), 'lines');
    await equals('H-02 表单 Hint 渲染成 ⓘ（两个 Hint + 一个 hint 节点）', await count('.workflow .hint'), 3);
    await equals('H-02 hint 节点不渲染成按钮句柄', await count('.workflow [data-wf=""]'), 0);
    await equals('H-02 hint 节点文字可见', await cdp.evaluate("(()=>{const n=[...document.querySelectorAll('.workflow .hint')].find(x=>x.dataset.hint.includes('只读说明'));return n?n.dataset.hint:null})()"), '这是一段只读说明，没有可执行句柄。');
    const disabledPoint = await rectOf('button[data-wf="wf-a"] + .hint');
    await equals('H-03 禁用按钮旁有 ⓘ', !!disabledPoint, true);
    await hover(disabledPoint.x, disabledPoint.y); await sleep(360);
    await equals('H-03 禁用控件旁的 ⓘ 仍能打开', await layerOpen(), true);
    await equals('H-03 说明内容正确', await layerText(), '部署会重启网络服务，连接会中断约 30 秒。');
    const otherPoint = await rectOf('button[data-wf="wf-b"] + .hint');
    await hover(otherPoint.x, otherPoint.y); await sleep(360);
    await equals('H-01 同一时间只显示一个（切到新锚点）', await layerText(), '只保存到本机，不影响当前连接。');
    await equals('H-01 页面上只有一个气泡层', await count('#hint-layer'), 1);
    // B-02：快照刷新（reconcile）不闪不丢；锚点消失则关闭
    const hintTextBefore = await layerText();
    await send(baseState(Object.assign({Lines:[lineState()]}, {Form:hintForm, Busy:false})), 'lines');
    await sleep(80);
    await equals('H-02 快照刷新后气泡仍在且文字不变', (await layerOpen()) && (await layerText()) === hintTextBefore, true);
    await send(baseState(Object.assign({Lines:[lineState()]})), 'home');
    await sleep(80);
    await equals('H-02 锚点被移除后自动关闭', await layerOpen(), false);
    // B-04：深浅色对比度（文字 4.5:1、边框 3:1）
    const contrast = () => cdp.evaluate(`(()=>{const s=getComputedStyle(document.getElementById('hint-layer'));
      const rgb=c=>(c.match(/[0-9.]+/g)||[]).slice(0,3).map(Number);
      const lum=v=>{const f=x=>{x/=255;return x<=0.03928?x/12.92:Math.pow((x+0.055)/1.055,2.4)};return 0.2126*f(v[0])+0.7152*f(v[1])+0.0722*f(v[2])};
      const ratio=(a,b)=>{const x=lum(a),y=lum(b);return Math.round(((Math.max(x,y)+0.05)/(Math.min(x,y)+0.05))*100)/100};
      return {text:ratio(rgb(s.color),rgb(s.backgroundColor)),border:ratio(rgb(s.borderTopColor),rgb(s.backgroundColor))}})()`);
    const openHeroHint = async () => {
      await send(baseState(Object.assign({Lines:[lineState()]}, {Running:true, State:'Connected', Quality:{Degraded:false}})));
      const p = await rectOf(hintSel); await hover(p.x, p.y); await sleep(360);
    };
    await openHeroHint();
    const lightRatio = await contrast();
    await equals('H-04 浅色文字对比度 ≥4.5:1', lightRatio.text >= 4.5, true);
    await equals('H-04 浅色边框对比度 ≥3:1', lightRatio.border >= 3, true);
    await cdp.evaluate("document.documentElement.dataset.theme='dark'"); await sleep(60);
    const darkRatio = await contrast();
    await equals('H-04 深色文字对比度 ≥4.5:1', darkRatio.text >= 4.5, true);
    await equals('H-04 深色边框对比度 ≥3:1', darkRatio.border >= 3, true);
    await cdp.evaluate("document.documentElement.dataset.theme='light'"); await sleep(60);
    // B-05：定位只用 CSSOM，不产生 CSP 违规
    await equals('H-05 无 CSP 违规', await cdp.evaluate('window.__csp.length'), 0);

    // B1 强制无 popover：宿主的版本闸门把它置为 false，说明层必须退回普通 div。
    // 先关掉当前气泡并把指针移开，否则 show() 会因为「同一锚点且已显示」早退，
    // 断言只是在检查上一次原生 popover 的残留状态。
    await pressEscape(); await sleep(40);
    await hover(10, 10); await sleep(200);
    await equals('H-06 前置：进入回退前气泡已关闭', await layerOpen(), false);
    await equals('H-06 前置：进入回退前仍是原生 popover 层',
      await cdp.evaluate("document.getElementById('hint-layer').hasAttribute('popover')"), true);
    await cdp.evaluate("window.__tcNativePopoverAllowed=false");
    await openHeroHint();
    await equals('H-06 无 popover 回退仍打开说明', await layerOpen(), true);
    await equals('H-06 回退层已经摘掉 popover 属性',
      await cdp.evaluate("document.getElementById('hint-layer').hasAttribute('popover')"), false);
    await equals('H-06 回退层没有进入原生 popover 状态',
      await cdp.evaluate("document.getElementById('hint-layer').matches(':popover-open')"), false);
    await equals('H-06 回退层仍使用普通固定定位',
      await cdp.evaluate("getComputedStyle(document.getElementById('hint-layer')).position"), 'fixed');
    await equals('H-06 回退层仍显示同一段说明', await layerText(),
      '当前交易出口的 HTTPS 往返响应，含加密建连耗时，不等同于下单延迟');
    await pressEscape(); await sleep(40);
    await equals('H-06 回退层 Esc 关闭', await layerOpen(), false);
    await equals('H-06 回退路径无 CSP 违规', await cdp.evaluate('window.__csp.length'), 0);

    // ---------- 0.22.0 C 组：审查遗留（C-R3 / C-R5 / C-R6 / C-R7 / C-R8 / C-R9） ----------
    // C-R3：断开后主线路用运行期证据说话，不再退回「未测试」。
    const lastConnected = lineState({ ProfileSource:'Automatic', Profile:'Udp',
      Readiness:{State:'LastConnected',Label:'上次连接正常',Reason:'上次连接于 10-23 09:12'} });
    await send(baseState({Lines:[lastConnected], HomeLineId:LINE_A}), 'lines');
    await equals('C3-01 上次连接正常的卡显示标签', await text('[data-testid=line-status]'), '上次连接正常');
    await equals('C3-01 上次连接正常的卡主按钮是「连接」', await text('[data-testid=line-card] .actions button[data-action=connect]'), '连接');
    check('C3-01 状态行带上次连接时间', (await text('[data-testid=line-reason]')).includes('上次连接于'), await text('[data-testid=line-reason]'));
    await send(baseState({Lines:[lineState({ Readiness:{State:'Untested',Label:'未测试',Reason:'还没有测试过'} })], HomeLineId:LINE_A}), 'lines');
    await equals('C3-02 未测试卡主按钮是「测速」', await text('[data-testid=line-card] .actions button[data-action=testLine]'), '测速');
    await send(baseState({Lines:[lineState({ Readiness:{State:'TestFailed',Label:'上次测试未通过',Reason:'连接时会自动重试，不通会自动恢复原状态'} })], HomeLineId:LINE_A}), 'lines');
    await equals('C3-04 测试失败优先于上次成功', await text('[data-testid=line-status]'), '上次测试未通过');

    // C-R5：卡片直选统一成 radiogroup，自动态不点亮任何一段。
    const autoLine = lineState({ ProfileSource:'Automatic', Profile:'Tcp', Readiness:{State:'Verified',Label:'可用',Reason:''} });
    const pinnedLine = lineState({ Id:LINE_B, Name:'备用线路', Profile:'Udp', ProfileSource:'UserChoice' });
    await send(baseState({Lines:[autoLine, pinnedLine], HomeLineId:LINE_A}), 'lines');
    await equals('C5-01 自动态两段都不亮', await count('[data-testid=line-card]:first-child .seg.on'), 0);
    await equals('C5-01 自动态旁边标出解析结果', await text('[data-testid=line-card] [data-testid=protocol-auto]'), '自动·兼容');
    await equals('C5-01 固定态只有固定那段亮',
      await cdp.evaluate("(()=>{const c=document.querySelectorAll('[data-testid=line-card]')[1];const on=c.querySelectorAll('.seg.on');return on.length+'|'+on[0].textContent.replace('默认','').trim()})()"), '1|标准');
    await equals('C5-01 固定态没有自动标签', await count('[data-testid=line-card] [data-testid=protocol-auto]'), 1);
    await equals('C5-04 没有元素同时带 role=radio 与 aria-pressed', await count('[role=radio][aria-pressed]'), 0);
    await equals('C5-04 卡片直选是 radiogroup', await count('[data-testid=protocol-pick][role=radiogroup]'), 2);
    // C5-02：固定成功后卡片出现一句「已固定为…」，8 秒后消失（用 9 秒前的记录反证）。
    const feedbackEntry = at => ({Id:'fb'+at,Kind:'Preference',ProfileId:'Tcp',Status:'Succeeded',AtUtc:new Date(at).toISOString(),
      Message:'已固定为兼容连接，下次连接生效。',Code:'',CanRetry:false,NeedsReview:false,CanDiagnose:false,ReviewLabel:'',ConnectionMessage:''});
    await send(baseState({Lines:[lineState(), lineState({Id:LINE_B,Name:'备用线路',Profile:'Udp',ProfileSource:'Automatic',Feedback:[feedbackEntry(Date.now()-1000)]})], HomeLineId:LINE_A}), 'lines');
    check('C5-02 固定成功后卡片出现「已固定为…」', (await text('[data-testid=line-card] .pick-feedback')).startsWith('已固定为'), await text('[data-testid=line-card] .pick-feedback'));
    await equals('C5-02 这句是 role=status', await cdp.evaluate("document.querySelector('[data-testid=line-card] .pick-feedback').getAttribute('role')"), 'status');
    await send(baseState({Lines:[lineState(), lineState({Id:LINE_B,Name:'备用线路',Profile:'Udp',ProfileSource:'Automatic',Feedback:[feedbackEntry(Date.now()-9000)]})], HomeLineId:LINE_A}), 'lines');
    await equals('C5-02 超过 8 秒的固定反馈不再显示', await count('.pick-feedback'), 0);
    // C5-05：在用卡点击后「使用中」仍在原协议上。
    await send(baseState(Object.assign({Lines:[lineState({Feedback:[]}), lineState({Id:LINE_B,Name:'备用线路',Profile:'Tcp'})]}, liveOnA)), 'lines');
    await equals('C5-05 使用中标记在原协议上',
      await cdp.evaluate("(()=>{const c=document.querySelector('[data-testid=line-card].in-use');const t=c.querySelector('.seg-tag-live');return t?t.closest('.seg').textContent.replace('使用中','').replace('默认','').trim():'missing'})()"), '标准');
    await click('[data-testid=line-card].in-use .seg-group .seg:nth-child(2)'); await sleep(80);
    await equals('C5-05 点击后使用中标记仍在原协议上',
      await cdp.evaluate("(()=>{const c=document.querySelector('[data-testid=line-card].in-use');const t=c.querySelector('.seg-tag-live');return t?t.closest('.seg').textContent.replace('使用中','').replace('默认','').trim():'missing'})()"), '标准');

    // C-R6：数字只读，测速入口独立，三种读数各就各位。
    await send(baseState({Lines:[lineState({Readiness:{State:'Verified',Label:'可用',Reason:''}}), lineState({Id:LINE_B,Name:'备用线路',Profile:'Tcp',ProfileSource:'Automatic'})], HomeLineId:LINE_A}), 'lines');
    await equals('C6-01 数字不是可点控件', await count('[data-testid=line-metric][data-action]'), 0);
    await equals('C6-01 数字里没有按钮', await count('[data-testid=line-metric] button'), 0);
    await equals('C6-02 断开时写「连接后测量」', await text('[data-testid=line-card]:not(.in-use) [data-testid=line-metric]'), '连接后测量');
    await send(baseState(Object.assign({Lines:[lineState(), lineState({Id:LINE_B,Name:'备用线路',Profile:'Tcp',ProfileSource:'Automatic',PreparedProfiles:['Udp']})]}, liveOnA)), 'lines');
    await equals('C6-03 只支持标准连接的备用卡写「仅测兼容连接」', await text('[data-testid=line-card]:not(.in-use) [data-testid=line-metric]'), '仅测兼容连接');
    await equals('C6-03 这个读数有 ⓘ 解释', await count('[data-testid=line-card]:not(.in-use) .metric-head .hint'), 1);
    await send(baseState(Object.assign({Lines:[lineState(), lineState({Id:LINE_B,Name:'备用线路',Profile:'Tcp',ProfileSource:'Automatic'})], Operation:{Kind:'Test',LineId:LINE_B,StartedAtUtc:new Date(Date.now()-3000).toISOString()}}, liveOnA)), 'lines');
    check('C6-04 测速中按钮带倒计时且禁用',
      await cdp.evaluate("(()=>{const b=document.querySelector('[data-testid=line-card]:not(.in-use) .metric-test');return b?(b.disabled?'disabled':'enabled')+'|'+b.textContent.trim():'missing'})()").then(v=>/^disabled\|测速中 · \d+ 秒$/.test(v)), await cdp.evaluate("(()=>{const b=document.querySelector('[data-testid=line-card]:not(.in-use) .metric-test');return b?b.textContent.trim():'missing'})()"));

    // C-R7：在用线路的抽屉里不再有测速，改放一句指路说明。
    await send(baseState(Object.assign({Lines:[lineState(), lineState({Id:LINE_B,Name:'备用线路',Profile:'Tcp'})]}, liveOnA)), 'lines');
    await click('[data-detail="'+LINE_A+'"]'); await sleep(80);
    await equals('C7-01 在用线路抽屉没有测速按钮', await count('#drawer [data-action=testLine]'), 0);
    await equals('C7-01 在用线路抽屉给出指路说明', await count('#drawer .hint[data-hint*="线路响应"]'), 1);
    await click('[data-close=drawer]'); await sleep(80);

    // C-R8：交易走代理软件时，原线路卡片说清楚，并且主按钮是切回来。
    await send(baseState({Lines:[lineState({Readiness:{State:'ProviderBackup',Label:'交易暂走代理软件',Reason:'切回这条线路不需要重启通道'}})], Running:true, State:'Connected', TradeExit:'Provider', ActiveLineId:LINE_A, ActiveProfile:'Udp', Quality:{LatencyMs:330,Quality:'Fair',Degraded:false}}), 'lines');
    await equals('C8-01 交易走代理软件时的标签', await text('[data-testid=line-status]'), '交易暂走代理软件');
    await equals('C8-01 主按钮是「切回此线路」', await text('[data-testid=line-card] .actions button[data-action=connect]'), '切回此线路');
    await equals('C8-01 这张卡不算在用', await count('[data-testid=line-card].in-use'), 0);

    // C-R9：全局模式下 AI 选择被禁用并说明原因。
    await send(baseState({Lines:[lineState()], Daily:'Trade'}), 'apps');
    await equals('C9-01 全局模式下 AI 下拉框禁用', await cdp.evaluate("document.querySelector('#agents').disabled"), true);
    await equals('C9-01 并直接显示原因', await text('[data-testid=agents-global-note]'), '日常上网走交易线路时，AI 工具也走交易线路。');
    await send(baseState({Lines:[lineState()], Daily:'Direct'}), 'apps');
    await equals('C9-02 退出全局模式后下拉框恢复', await cdp.evaluate("document.querySelector('#agents').disabled"), false);
    await equals('C9-02 原因说明随之消失', await count('[data-testid=agents-global-note]'), 0);

    // ---------- 0.22.0 几何层：S1 列宽 / S2 角色与尺寸 / S3 图标 ----------
    // 这一组必须在真浏览器里量：要证明的是「CSS 到底有没有把宿主的布局意图排出来」。
    // 页面走 http://127.0.0.1、CSP 仍是 style-src 'self'，与 WebView2 完全一致 ——
    // 下面任何一条能过，都不是靠 inline style 摆出来的。
    // 夹具按 ui/Pages.ps1 的真实投影形态搭；宿主那一半（Cols / Role / Size / Align 真的
    // 会下发）由 tests/Test-WebForms.ps1 守着，两边合起来才是完整契约。
    const GEO_GEN = 'e'.repeat(32);
    const geometry = async (options, width) => {
      await cdp.send('Emulation.setDeviceMetricsOverride', {width, height: 900, deviceScaleFactor: 1, mobile: false});
      await send(baseState({Form: wfAgentListForm(GEO_GEN, options)}), 'apps');
    };
    // 断言 A：同一网格内按钮右边缘极差。AgentRow / CustomAgentRow 每行都是独立网格，
    // 「同一网格内」按字面只剩一个按钮，极差恒为 0 —— 这条是 0.20.10 的原口径锚点，
    // 真正的守护力在 A2（按钮 vs 网格右缘）与 B（跨行左边缘）。这里限定「按钮全在末列」
    // 的网格，避免把添加行（两个按钮分处两列）误算进来。
    const withinGrid = async () => cdp.evaluate(`[...document.querySelectorAll('.wf-grid[data-colspec]')].map(g=>{
      const cells=[...g.children], buttons=cells.filter(c=>c.matches('button'));
      if(!buttons.length) return null;
      const lastCol=Math.max(...buttons.map(b=>Number(b.dataset.col||0)));
      if(!buttons.every(b=>Number(b.dataset.col||0)===lastCol)) return null;
      const rights=buttons.map(b=>b.getBoundingClientRect().right);
      return Math.round(Math.max(...rights)-Math.min(...rights));
    }).filter(v=>v!==null)`);
    // 断言 A2：末列按钮右边缘 = 网格右缘（0.20.10 的原始验收口径）。
    const lastColGap = async () => cdp.evaluate(`[...document.querySelectorAll('.wf-grid[data-colspec]')].map(g=>{
      const last=[...g.children].filter(c=>c.matches('button')).pop();
      if(!last) return null;
      return Math.round(g.getBoundingClientRect().right-last.getBoundingClientRect().right);
    }).filter(v=>v!==null)`);
    const removeLefts = async () => cdp.evaluate(`[...document.querySelectorAll('[data-control-name^=RemoveAgent]')].map(b=>b.getBoundingClientRect().left)`);
    const removeRights = async () => cdp.evaluate(`[...document.querySelectorAll('[data-control-name^=RemoveAgent]')].map(b=>b.getBoundingClientRect().right)`);

    for (const width of [1180, 960, 760]) {
      // 均匀态：三行「移除」，用来量跨行左边缘。
      await geometry({draftCount:3, customCount:3, removed:false}, width);
      const a = await withinGrid();
      check(`A[${width}] 同一网格内按钮右边缘极差 ≤ 1px`, a.length > 0 && a.every(d => d <= 1), JSON.stringify(a));
      const a2 = await lastColGap();
      check(`A2[${width}] 末列按钮右边缘与网格右缘极差 ≤ 1px`, a2.length > 0 && a2.every(d => Math.abs(d) <= 1), JSON.stringify(a2));
      const lefts = await removeLefts();
      check(`B[${width}] 跨行移除按钮左边缘极差 ≤ 1px（${lefts.length} 行）`,
        lefts.length >= 2 && Math.max(...lefts) - Math.min(...lefts) <= 1,
        JSON.stringify(lefts.map(v => Math.round(v))));

      // 混排态：第一行是「撤销移除」，按钮更宽。此时左边缘本来就该错开（右对齐 + 宽度不同），
      // 真正不能错的是右边缘 —— 这才是 0.20.10 想守住的「锯齿」。
      await geometry({draftCount:3, customCount:3, removed:'first'}, width);
      const mixedRights = await removeRights();
      check(`A2'[${width}] 混排态（移除/撤销移除）右边缘仍齐平`,
        mixedRights.length >= 2 && Math.max(...mixedRights) - Math.min(...mixedRights) <= 1,
        JSON.stringify(mixedRights.map(v => Math.round(v))));
      const mixedGap = await lastColGap();
      check(`A2'[${width}] 混排态末列按钮仍贴网格右缘`, mixedGap.every(d => Math.abs(d) <= 1), JSON.stringify(mixedGap));

      // 断言 C：网格真的是 grid，列数与 data-colspec 段数一致。
      const cols = await cdp.evaluate(`[...document.querySelectorAll('.wf-grid[data-colspec]')].map(g=>[
        getComputedStyle(g).display,
        getComputedStyle(g).gridTemplateColumns.split(' ').filter(Boolean).length,
        g.dataset.colspec.split('|').length])`);
      check(`C[${width}] display:grid 且列数与 data-colspec 一致`,
        cols.length > 0 && cols.every(([d, actual, expected]) => d === 'grid' && actual === expected),
        JSON.stringify(cols.filter(([d, actual, expected]) => d !== 'grid' || actual !== expected)));
      check(`C[${width}] 夹具里至少有 8 个带 data-colspec 的网格`, cols.length >= 8, String(cols.length));

      // 断言 D：没有网格换行 —— 所有子项落在同一个 grid row。
      // 判据用「纵向区间有交集」而不是「top 全相等」：子项高度不同时会被居中
      // （38px 图标位 vs 55px 两行文案），top 天然差几像素，那是对齐不是换行；
      // 真换行时后一项的 top 会落在前一项的 bottom 之下，交集为空。
      const noWrap = await cdp.evaluate(`[...document.querySelectorAll('.wf-grid[data-colspec]')].map(g=>{
        const boxes=[...g.children].map(c=>c.getBoundingClientRect());
        if(boxes.length<2) return null;
        return Math.round(Math.min(...boxes.map(b=>b.bottom))-Math.max(...boxes.map(b=>b.top)));
      }).filter(v=>v!==null)`);
      check(`D[${width}] 网格内子项不换行（纵向区间有交集）`, noWrap.length > 0 && noWrap.every(overlap => overlap > 0), JSON.stringify(noWrap));

      // 断言 E：chip（Pill）高度上限 —— 未标注角色时它会继承 .wf-card 的 16px 内边距，撑成一块砖。
      const chipH = await cdp.evaluate(`[...document.querySelectorAll('.wf-card[data-role=chip]')].map(c=>c.getBoundingClientRect().height)`);
      check(`E[${width}] chip 高度 ≤ 30px（${chipH.length} 粒）`, chipH.length >= 2 && chipH.every(h => h <= 30), JSON.stringify(chipH.map(v => Math.round(v))));

      // 断言 F：tile 是正方形，且边长等于 data-size。
      const tiles = await cdp.evaluate(`[...document.querySelectorAll('.wf-card[data-role=tile]')].map(t=>{
        const r=t.getBoundingClientRect(); return [r.width, r.height, Number(t.dataset.size)]})`);
      check(`F[${width}] tile 正方形且边长 = data-size`,
        tiles.length >= 2 && tiles.every(([w, h, size]) => Math.abs(w - h) <= 1 && Math.abs(w - size) <= 1),
        JSON.stringify(tiles.map(([w, h, s]) => [Math.round(w), Math.round(h), s])));

      // S3：图标用宿主同一份 24×24 几何还原，不是另造图形。
      const icons = await cdp.evaluate(`[...document.querySelectorAll('.wf-card[data-role=tile] > svg.wf-icon')].map(s=>{
        const r=s.getBoundingClientRect(); const p=s.querySelector('path');
        return [s.getAttribute('viewBox'), p ? p.getAttribute('d').length : 0, Math.round(r.width), Math.round(r.height)]})`);
      check(`S3[${width}] 图标位里是真的 SVG path`, icons.length >= 2 && icons.every(([vb, d, w, h]) => vb === '0 0 24 24' && d > 10 && w > 0 && h > 0), JSON.stringify(icons));
    }

    // 断言 B2：SectionLabel 右侧状态文字贴右，两种长度各测一次（3 字 / 12 字）。
    // 诚实的边界：实测新路径与老 flex 路径在这里都是 0 间隙（老路径的
    // `.wf-grid:not([data-colspec]) > .wf-stack{flex:1 1 260px}` 会把左列撑开，
    // 提示自然被顶到右缘），所以这条守的是**结果**不是机制 —— 它的回归形态是
    // 「提示掉到下一行」或「和标题挤在一起」，因此额外断言同一行。
    // 机制（data-align 到底有没有生效）由下面的 Align 探针守。
    for (const width of [1180, 960]) {
      for (const draftCount of [3, 12]) {
        await geometry({draftCount, customCount:2}, width);
        const caption = `${draftCount} 项改动未保存`;
        const probe = await cdp.evaluate(`(()=>{
          const p=[...document.querySelectorAll('.wf-grid[data-colspec] > .wf-text')]
            .find(n=>n.textContent.trim()===${JSON.stringify(caption)});
          if(!p) return null;
          const grid=p.closest('.wf-grid');
          const title=grid.firstElementChild;
          return {gap:Math.round(grid.getBoundingClientRect().right-p.getBoundingClientRect().right),
                  sameRow:Math.round(p.getBoundingClientRect().top-grid.getBoundingClientRect().top)<=1,
                  apart:Math.round(p.getBoundingClientRect().left-title.getBoundingClientRect().right)};
        })()`);
        check(`B2[${width}] 状态文字贴右（${caption.length} 字）`, probe !== null && Math.abs(probe.gap) <= 1, JSON.stringify(probe));
        check(`B2[${width}] 状态文字与标题同一行且不相邻（${caption.length} 字）`,
          probe !== null && probe.sameRow && probe.apart >= 8, JSON.stringify(probe));
      }
    }

    // Align 自己也要有一条有守护力的断言：放在 * 轨道里才看得出 justify-self 有没有生效。
    // （SectionLabel 的提示在 Auto 轨道，那个位置贴着内容，摘不摘 data-align 都是 0 间隙。）
    await geometry({draftCount:3, customCount:2, alignProbe:true}, 1180);
    const alignGap = await cdp.evaluate(`(()=>{
      const p=document.querySelector('[data-control-name=AlignProbe]');
      if(!p) return null;
      const grid=p.closest('.wf-grid');
      const before=Math.round(p.getBoundingClientRect().left-grid.getBoundingClientRect().left);
      p.removeAttribute('data-align');
      const after=Math.round(p.getBoundingClientRect().left-grid.getBoundingClientRect().left);
      return {before, after};
    })()`);
    check('Align 生效：* 轨道里的右对齐文字被推到轨道末端', alignGap !== null && alignGap.before > 100, JSON.stringify(alignGap));
    check('Align 反向：摘掉 data-align 后回到轨道起点', alignGap !== null && alignGap.after < 20, JSON.stringify(alignGap));

    // 断言 G：按钮数变化时，计数文本节点的 DOM 身份必须保住。
    // 守护的是两处：`case 'text'` 补的 data-wf-key（让文本节点有句柄），以及 reconcile
    // 在「句柄对不上」时改成插入新节点、而不是顶掉位置上的旧节点。
    // 只做前者不够 —— 实测：句柄对不上时，旧代码的 replaceWith 会把计数节点连同它后面的
    // 兄弟一起重建，isSameNode 直接变 false。这一点由下面的 mutation check 常驻守着。
    // 计数排在最前时索引天然稳定，测不出东西；这里用 counterLast 把它挪到按钮之后，
    // 让「保存」按钮的增删把它的索引从 1 挤到 2。
    const identityProbe = async () => {
      await cdp.send('Emulation.setDeviceMetricsOverride', {width: 1180, height: 900, deviceScaleFactor: 1, mobile: false});
      await send(baseState({Form: wfAgentListForm(GEO_GEN, {draftCount:3, customCount:2, buttons:1, counterLast:true})}), 'apps');
      await cdp.evaluate(`window.__counter = document.querySelector('[data-control-name=AgentsDraftCount]')`);
      await send(baseState({Form: wfAgentListForm(GEO_GEN, {draftCount:3, customCount:2, buttons:2, counterLast:true})}), 'apps');
      return cdp.evaluate(`(()=>{
        const now=document.querySelector('[data-control-name=AgentsDraftCount]');
        return {exists: !!now, same: !!window.__counter && window.__counter.isSameNode(now),
                connected: !!window.__counter && window.__counter.isConnected,
                index: now ? [...now.parentNode.children].indexOf(now) : -1,
                barButtons: document.querySelectorAll('.workflow-actions button').length};
      })()`);
    };
    const identity = await identityProbe();
    check('G 计数文本节点在按钮数变化后未被替换（isSameNode）', identity.same === true, JSON.stringify(identity));
    check('G 旧引用仍挂在文档上（isConnected）', identity.connected === true, JSON.stringify(identity));
    // 场景有效性：索引必须真的被挤开过，否则上面两条永远是绿的。
    check('G 场景有效：计数节点索引从 1 移到 2', identity.index === 2, String(identity.index));
    check('G 场景有效：吸底条确实变成两个按钮', identity.barButtons === 2, String(identity.barButtons));

    // ---------- static guards ----------
    const source = fs.readFileSync(path.join(WEB, 'app.js'), 'utf8');
    // 0.22.0 B1: the ban is on inline *style attributes* (CSP style-src 'self'),
    // not on CSSOM. The hint layer must position itself with
    // el.style.setProperty() precisely because it may not emit style="...".
    const styleAssign = (source.match(/\.style\./g) || []).length;
    const cssomOnly = (source.match(/\.style\.(?!setProperty|removeProperty|length|item)/g) || []).length;
    check('CSP: app.js 只用 CSSOM 定位（setProperty）', cssomOnly === 0, `all=${styleAssign} bad=${cssomOnly}`);
    check('CSP: 无 style= 属性', !/\sstyle="/.test(source));
    check('CSP: 无 setAttribute(style)', !/setAttribute\(\s*['"]style['"]/.test(source));
    check('R-01: data-secret 出现至少两次', (source.match(/data-secret/g) || []).length >= 2);
    const forbidden = ['已恢复', '丢包', '抖动', '128 次采样', '健康度', '在线时长', '本次连接时长'];
    const visible = source.replace(/\/\/[^\n]*/g, '');
    const hits = forbidden.filter(word => visible.includes(word));
    check('7.1 禁用词零命中（app.js 可见文案）', hits.length === 0, hits.join(','));
    // The "%" ban was narrowed in 0.20.2: a percentage with a denominator is
    // verifiable, a percentage without one is a made-up conclusion. Only a "%"
    // glued to a digit and with no N/M in front of it counts as bare. Modulus
    // operators ("total % 60") are separated by a space and never match.
    const barePercent = [...visible.matchAll(/(\S)%/g)]
      .filter(m => /\d/.test(m[1]) && !/\d+\s*\/\s*\d+/.test(visible.slice(Math.max(0, m.index - 12), m.index)));
    check('7.1 百分比必须带分母（app.js）', barePercent.length === 0, barePercent.map(m => visible.slice(Math.max(0, m.index - 16), m.index + 1)).join(' | '));
    // C-R11-01：产品代码里不再出现「其他上网」「AI 助手」。
    const legacyTerms = ['其他上网', 'AI 助手', 'AI助手'].filter(term => visible.includes(term));
    check('C11-01 术语零命中（app.js）', legacyTerms.length === 0, legacyTerms.join(','));
    check('testid 属性数 >= 33', (source.match(/data-testid=/g) || []).length >= 33, String((source.match(/data-testid=/g) || []).length));

    // 断言 H：句柄全换（= 宿主重新 Render 出新 Generation）时，页面不能翻倍。
    // reconcile 现在「未知句柄就插入」，插入的节点要靠尾部裁剪收掉；如果裁剪失效，
    // 每次刷新都会多出一份内容 —— 那是比错位严重得多的故障，必须有断言盯着。
    const resalt = (form, salt) => {
      const clone = JSON.parse(JSON.stringify(form));
      const walk = node => { node.Id = 'wf-' + salt + String(node.Id).slice(4); (node.Children || []).forEach(walk); };
      (clone.Nodes || []).forEach(walk); (clone.PageActions || []).forEach(walk);
      return clone;
    };
    await cdp.send('Emulation.setDeviceMetricsOverride', {width: 1180, height: 900, deviceScaleFactor: 1, mobile: false});
    const baseForm = wfAgentListForm(GEO_GEN, {draftCount:3, customCount:2});
    await send(baseState({Form: baseForm}), 'apps');
    const elementsBefore = await count('#main *');
    const gridsBefore = await count('.wf-grid[data-colspec]');
    await send(baseState({Form: resalt(baseForm, 'x')}), 'apps');
    const elementsAfter = await count('#main *');
    const gridsAfter = await count('.wf-grid[data-colspec]');
    check('H 句柄全换后节点数不翻倍', elementsAfter === elementsBefore, `${elementsBefore} -> ${elementsAfter}`);
    check('H 句柄全换后网格数不变', gridsAfter === gridsBefore, `${gridsBefore} -> ${gridsAfter}`);
    await equals('H 句柄全换后提示文字只有一份', await count('[data-control-name=AgentsSectionHint]'), 1);
    await send(baseState({Form: resalt(resalt(baseForm, 'y'), 'z')}), 'apps');
    await equals('H 连续两次全换句柄仍不累积', await count('#main *'), elementsBefore);

    // ---------- 断言 G 的 mutation check ----------
    // 把 reconcile 退回 S1 之前的行为（句柄对不上就顶掉位置上的节点），重跑同一个场景，
    // 它必须变红。变不红说明场景构造错了，这条断言就没有守护力 —— 0.20.10 那条补丁
    // 正是这么假掉的。变异体由本地 server 现场生成（/app.js?mutation=prereconcile），
    // 不碰发布文件；做成常驻断言而不是人手跑一次。
    await cdp.send('Page.navigate', {url: `http://127.0.0.1:${port}/index-mutant.html?mutation=prereconcile`});
    for (let i = 0; i < 100; i++) { if (await cdp.evaluate('!!window.__host.handler')) break; await sleep(50); }
    check('G-mutation 变异页加载成功', await cdp.evaluate('!!window.__host.handler'));
    // 页面里 fetch 会被 connect-src 'none' 挡掉，变异体成色从 Node 侧核对。
    const mutatedSource = await (await fetch(`http://127.0.0.1:${port}/app.js?mutation=prereconcile`)).text();
    const emittedKeys = (mutatedSource.match(/ data-wf-key="\$\{id\}"/g) || []).length;
    check('G-mutation 变异体确实退回了 S1 之前的行为',
      emittedKeys === 0 && mutatedSource.includes('old.replaceWith(created)') && !mutatedSource.includes('parent.insertBefore(created, old || null)'),
      `keys=${emittedKeys}`);
    const mutated = await identityProbe();
    check('G-mutation 退回 S1 之前后节点身份丢失（断言确实有守护力）',
      mutated.exists === true && mutated.same === false, JSON.stringify(mutated));
    check('G-mutation 变异体下索引同样被挤开（场景一致）', mutated.index === 2, String(mutated.index));


    // ---------- I-mutation: entry reverted to 0.22.1 (no line) ----------
    await cdp.send('Page.navigate', {url: `http://127.0.0.1:${port}/index-mutant.html?mutation=inviteentry`});
    for (let i = 0; i < 100; i++) { if (await cdp.evaluate('!!window.__host.handler')) break; await sleep(50); }
    check('I-mutation 变异页加载成功', await cdp.evaluate('!!window.__host.handler'));
    await send(baseState({Lines:[inviteLine(), inviteLineF()]}), 'lines');
    const beforeMutant = (await posted()).length;
    await click('#main .page-head [data-invite=Begin]');
    const mutantPosts = (await posted()).slice(beforeMutant);
    check('I-mutation 退回旧入口后多条线路只发空 Id 的 Begin（断言确有守护力）',
      mutantPosts.length === 1 && mutantPosts[0].Phase === 'Begin' && !mutantPosts[0].Id, JSON.stringify(mutantPosts));
  } catch (error) {
    check('harness crashed', false, error && error.stack || String(error));
  } finally {
    try { await cdp?.send('Browser.close'); } catch {}
    try { chrome.kill(); } catch {}
    server.close();
  }
  const failed = results.filter(r => !r.Passed);
  fs.mkdirSync(path.dirname(REPORT), { recursive: true });
  fs.writeFileSync(REPORT, JSON.stringify({ Suite:'Test-020UI', Assertions:results.length, Passed:results.length - failed.length, Failed:failed.length, Checks:results }, null, 2));
  for (const item of results) console.log(`${item.Passed ? 'PASS' : 'FAIL'}  ${item.Name}${item.Passed ? '' : '  <- ' + item.Detail}`);
  console.log(`\n${results.length - failed.length}/${results.length} passed`);
  process.exit(failed.length ? 1 : 0);
})();
