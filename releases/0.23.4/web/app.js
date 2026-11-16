'use strict';
(() => {
  const $ = selector => document.querySelector(selector);
  const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const pages = {home:'首页', lines:'线路', apps:'应用', settings:'设置', 'add-line':'添加线路', invite:'邀请其他电脑'};
  // 'add-line' is a second-level page of 线路. It is kept out of `pages`'
  // navigation meaning by a separate constant: `pages` is consumed for the label,
  // for the truthiness gate and for the parent lookup, so adding fields there
  // would change three behaviours at once.
  const PAGE_PARENT = {'add-line':'lines', invite:'lines'};
  // The wait budget is owned by the host (ui/WebShell.ps1) and arrives in
  // Pending.DeadlineUtc. Only the test budget is duplicated here; the acceptance
  // test compares it with LineConnectionCheck.psm1 so the two cannot drift.
  const STALE_SNAPSHOT_SECONDS = 10, TICK_MS = 1000, TEST_BUDGET_SECONDS = 45;
  let state = null, page = 'home', selected = '', dialogKey = '', toastKey = '', toastTimer;
  let sequence = 0, pendingIntent = 0, viewKey = '', routeKey = '', drawerFocus = null;
  let historyWindow = 'Day', failureTimer, pickTimer, staleView = false, expiredPendingKey = '', tickTimer;
  // Three-step pairing page. The step itself is local: the host only publishes
  // the phase. Draft values are kept here so a status poll cannot erase what the
  // user typed (the reconcile pass rewrites every non-secret input).
  // pairIgnoreId hides a finished session from this page while the host still
  // publishes it: the entry buttons set it and the host clears the session behind
  // them (0.21.8 A0). It is dropped as soon as that PairId stops arriving.
  let pairStep = 1, pairJoined = false, pairEpoch = null, pairEpochSeen = false, pairHadSession = false, pairIgnoreId = '';
  const pairDraft = {device:'', name:''};
  // 0.22.0 A2 invitation page. `inviteRevealed` is presentation only: the code is
  // never echoed from the snapshot, it arrives once in its own message and lives in
  // the field until the page or the invitation generation changes. `inviteCodeLocal`
  // is why the field survives the next render: the snapshot arrives four times a
  // second and rebuilds #main, so the value has to be re-rendered from here instead
  // of being read back from the DOM.
  let inviteRevealed = false, inviteCodeLocal = '', inviteEpochSeen = null, inviteEpochHadValue = false;
  const inviteCustom = {on:false, amount:'', unit:'Minutes'};
  const pendingFields = new Map();
  const text = (key, fallback = key) => state?.Text?.[key] ?? fallback;
  let theme = localStorage.getItem('theme') || 'system';
  const media = matchMedia('(prefers-color-scheme: dark)');
  function applyTheme() { document.documentElement.dataset.theme = theme === 'system' ? (media.matches ? 'dark' : 'light') : theme; }
  const post = (Type, data = {}, intent = false) => {
    const next = ++sequence;
    if (intent) pendingIntent = next;
    window.chrome?.webview?.postMessage({Type, ...data, Sequence:next});
    return next;
  };
  function syncHostTheme() { post('theme', {Value:document.documentElement.dataset.theme}); }
  applyTheme(); syncHostTheme();
  media.addEventListener('change', () => { if (theme === 'system') { applyTheme(); syncHostTheme(); } });
  const button = (label, action, id = '', cls = '', disabled = false) => `<button class="${cls}" data-action="${action}" data-id="${esc(id)}" ${disabled ? 'disabled' : ''}>${label}</button>`;
  // 0.22.0 B1 悬浮说明。气泡层放在 #main 之外（index.html 的 #hint-layer），
  // reconcile 每 250ms 重画 #main 不会冲掉它；文本只用 textContent 写入。
  const hint = (content, label = '更多说明') =>
    `<button type="button" class="hint" data-hint="${esc(content)}" aria-label="说明：${esc(label)}"><span aria-hidden="true">ⓘ</span></button>`;
  const hintLayer = (() => {
    const HOVER_OPEN_MS = 300, LEAVE_CLOSE_MS = 150;
    let anchor = null, openTimer = 0, closeTimer = 0, nativeAllowed = true;
    const el = () => document.getElementById('hint-layer');
    function canUsePopover(layer) {
      return nativeAllowed && window.__tcNativePopoverAllowed !== false
        && typeof layer.showPopover === 'function' && typeof layer.hidePopover === 'function';
    }
    function useFallback(layer) {
      nativeAllowed = false;
      layer.removeAttribute('popover');
      layer.hidden = true;
    }
    function show(node) {
      const layer = el(); if (!layer || !node) return;
      if (anchor === node && !layer.hidden) return;
      hide();
      anchor = node;
      layer.textContent = node.dataset.hint || '';
      node.setAttribute('aria-describedby', 'hint-layer');
      node.dataset.open = 'true';
      layer.hidden = false;
      if (canUsePopover(layer)) {
        try { layer.showPopover(); } catch (e) { useFallback(layer); layer.hidden = false; }
      } else { useFallback(layer); layer.hidden = false; }
      place();
    }
    function hide() {
      const layer = el(); if (!layer) return;
      if (layer.hidePopover) { try { layer.hidePopover(); } catch (e) { /* 未打开时调用会抛 */ } }
      layer.hidden = true;
      if (anchor) { anchor.removeAttribute('aria-describedby'); delete anchor.dataset.open; }
      anchor = null;
    }
    function place() {
      const layer = el(); if (!layer || !anchor || !anchor.isConnected || layer.hidden) return;
      const rect = anchor.getBoundingClientRect();
      const gap = 6, margin = 8;
      layer.style.setProperty('left', '0px'); layer.style.setProperty('top', '0px');
      const box = layer.getBoundingClientRect();
      let left = rect.left + rect.width / 2 - box.width / 2;
      left = Math.max(margin, Math.min(left, window.innerWidth - box.width - margin));
      let top = rect.top - box.height - gap;                       // 优先上方
      if (top < margin) top = rect.bottom + gap;                   // 不够就翻到下方
      if (top + box.height > window.innerHeight - margin) top = Math.max(margin, window.innerHeight - box.height - margin);
      layer.style.setProperty('left', `${Math.round(left)}px`);
      layer.style.setProperty('top', `${Math.round(top)}px`);
    }
    function open(node) {
      clearTimeout(openTimer); clearTimeout(closeTimer);
      openTimer = setTimeout(() => show(node), node === document.activeElement ? 0 : HOVER_OPEN_MS);
    }
    function scheduleClose() { clearTimeout(openTimer); closeTimer = setTimeout(hide, LEAVE_CLOSE_MS); }
    // 指针从 ⓘ 移进气泡时必须撤销「离开就关」，否则 150ms 后气泡自己消失（WCAG 1.4.13 可移入）。
    function cancelClose() { clearTimeout(closeTimer); }
    function toggle(node) { if (anchor === node && el() && !el().hidden) hide(); else show(node); }
    function maintain() {
      // render() 会重建 #main：锚点被移除就关闭，还在就重新定位。
      if (anchor && !anchor.isConnected) hide(); else place();
    }
    return {show, hide, open, scheduleClose, cancelClose, toggle, maintain, get anchor() { return anchor; }};
  })();
  const busy = () => !!pendingIntent || !!state?.Busy || !!state?.ReadOnly || state?.State === 'ReadUnknown';
  // Adding a line, deploying and the diagnostic tools never touch the running
  // connection, so an unreadable connection state must not lock them: they are
  // the way out of it (0.21.4: a fresh install whose first status read failed
  // had every entry disabled, including 用邀请码加入).
  const entryBusy = () => !!pendingIntent || !!state?.Busy || !!state?.ReadOnly;
  const profile = id => state?.ConnectionMethods?.find(method => method.Id === id)?.DisplayName || (id === 'Udp' ? '标准连接' : id === 'Tcp' ? '兼容连接' : '自动选择');
  const isConnected = () => !!state?.Running && state?.State === 'Connected';
  const line = id => (state?.Lines || []).find(item => item.Id === id);
  const lineInUse = item => !!state?.Running && state.TradeExit === 'hk' && state.ActiveLineId === item.Id;
  // Plan 3.1: three bands only, driven by the backend verdict (never inferred from Prepared).
  const qualityBand = () => ({Good:{label:'很好',cls:'good'},Fair:{label:'一般',cls:'fair'},Poor:{label:'较差',cls:'warn'}})[state?.Quality?.Quality];
  const qualityBadge = () => { const band = isConnected() && latency() !== '—' ? qualityBand() : null; return band ? `<span class="badge quality ${band.cls}">${band.label}</span>` : ''; };
  const latency = () => Number.isFinite(state?.Quality?.LatencyMs) && state.Quality.LatencyMs >= 0 ? `${Math.round(state.Quality.LatencyMs)}` : '—';
  // Host contract: emit RecentConnectionFailure only for the latest failed
  // attempt whose line, selected method and configuration still match. Clear
  // it after success or a configuration/selection change; never infer failure
  // from Prepared. The browser also checks method and UTC expiry on every view.
  function failureExpiry(item) {
    const failure = item.RecentConnectionFailure;
    if (!item.Profile || !failure || failure.ProfileId !== item.Profile || typeof failure.ExpiresAtUtc !== 'string' || !/(?:Z|[+-]00:00)$/i.test(failure.ExpiresAtUtc)) return 0;
    const expires = Date.parse(failure.ExpiresAtUtc);
    return Number.isFinite(expires) && expires > Date.now() ? expires : 0;
  }
  function lineStatus(item) {
    if (lineInUse(item)) return {label:'使用中', tone:'good'};
    // 0.21.2: a blocked line always says why. The host sentence names the actual
    // identity problem (archived / changed / ambiguous record); the fallback only
    // covers older projections that do not carry it.
    if (item.Blocked) return {label:'需要处理', tone:'warn', reason: typeof item.BlockedReason === 'string' && item.BlockedReason ? item.BlockedReason : '服务器身份需要核对，暂不能连接。'};
    if (failureExpiry(item)) return {label:'上次连接未通过', tone:'warn'};
    // Host contract (0.18.4): Readiness is computed by the backend; the browser never infers a label from Prepared.
    const r = item.Readiness;
    // 0.22.0 C-R3 / C-R8：LastConnected 是运行期证据，配色同「可用」；ProviderBackup 是
    // 需要注意的临时状态（交易暂时不在自建线路上）。
    const tone = r && (r.State === 'Verified' || r.State === 'LastConnected') ? 'good'
      : r && (r.State === 'NeedsAction' || r.State === 'TestFailed' || r.State === 'ProviderBackup') ? 'warn' : '';
    if (r && typeof r.Label === 'string' && r.Label) return {label:r.Label, tone, reason:typeof r.Reason === 'string' ? r.Reason : ''};
    return {label:'未测试', tone:'', reason:''};
  }
  // 0.22.0 C-R5：点直选后的「已固定为…」只在卡片上停留 8 秒。
  const PICK_FEEDBACK_MS = 8000;
  function pickFeedbackLive(entry) {
    if (!entry || entry.Kind !== 'Preference' || entry.Status !== 'Succeeded') return false;
    const at = Date.parse(entry.AtUtc || '');
    return Number.isFinite(at) && Date.now() - at < PICK_FEEDBACK_MS;
  }
  function schedulePickFeedbackExpiry() {
    clearTimeout(pickTimer);
    const live = (state?.Lines || []).flatMap(item => item.Feedback || []).filter(pickFeedbackLive)
      .map(entry => Date.parse(entry.AtUtc) + PICK_FEEDBACK_MS);
    if (!live.length) return;
    pickTimer = setTimeout(render, Math.min(2147483647, Math.max(1, Math.min(...live) - Date.now() + 1)));
  }
  function scheduleFailureExpiry() {
    clearTimeout(failureTimer);
    const expires = Math.min(...(state?.Lines || []).map(failureExpiry).filter(Boolean));
    if (Number.isFinite(expires)) failureTimer = setTimeout(render, Math.min(2147483647, Math.max(1, expires - Date.now() + 1)));
  }
  // One second tick: refresh the countdown from the host deadline, refresh the
  // elapsed seconds of the running operation, and flip to "状态未知" when the
  // host has not posted a snapshot for longer than the heartbeat allows.
  function tick() {
    if (!state) return;
    const nextStale = stale();
    if (nextStale !== staleView) { staleView = nextStale; render(); return; }
    const wait = pendingWait();
    if (wait) {
      const left = remainingSeconds(wait), key = waitKey(wait);
      if (left === 0 && expiredPendingKey !== key) { expiredPendingKey = key; render(); return; }
    }
    // The invitation countdown is a second clock on the same tick. When it reaches
    // zero the host is asked once; the answer decides 已过期 or 已被使用.
    document.querySelectorAll('[data-countdown]').forEach(node => {
      const due = Date.parse(node.dataset.deadline || '');
      if (Number.isFinite(due)) node.textContent = `剩余 ${mmss(Math.max(0, Math.round((due - Date.now()) / 1000)))}`;
    });
    const invite = inviteView();
    if (invite && invite.State === 'Open' && !inviteBusy(invite)) {
      const due = Date.parse(invite.ExpiresAtUtc || '');
      const key = `${invite.InviteId || ''}|${invite.ExpiresAtUtc || ''}`;
      if (Number.isFinite(due) && due <= Date.now() && inviteExpiryKey !== key) {
        inviteExpiryKey = key;
        post('invite', {Phase:'Refresh', Id:invite.InviteId || ''}, true);
      }
    }
    document.querySelectorAll('[data-elapsed]').forEach(node => {
      const at = Date.parse(node.dataset.start || '');
      if (Number.isFinite(at)) node.textContent = `${Math.max(0, Math.round((Date.now() - at) / 1000))} 秒`;
    });
    for (const item of state.Lines || []) {
      const outcome = outcomeOf(item), due = Date.parse(outcome?.ExpiresAtUtc || '');
      if (Number.isFinite(due) && due <= Date.now()) { render(); return; }
    }
  }
  // Snapshot heartbeat. The host stamps every snapshot with a whole-second UTC
  // time; an old stamp means the host stopped answering, not that the link is up.
  function snapshotAge() {
    const at = Date.parse(state?.SnapshotAtUtc || '');
    return Number.isFinite(at) ? Math.max(0, (Date.now() - at) / 1000) : null;
  }
  const stale = () => { const age = snapshotAge(); return age !== null && age > STALE_SNAPSHOT_SECONDS; };
  // Three protection states plus one special case. The host decides the state and
  // the sentence; an empty sentence is the only reason to fall back locally.
  function guardView() {
    const count = state?.TradeProgramCount;
    if (count === 0) return {tone:'unknown', title:'尚未添加受保护的程序', note:'没有名单就没有需要阻止的程序；这不是故障。', primary:['添加交易程序','domains'], secondary:['运行诊断','diagnostics']};
    const guard = state?.Guard, summary = state?.GuardSummary;
    if (guard === 'Protected') return {tone:'protected', title:summary || '交易保护已开启', note:'未连接时也会阻止名单内的交易程序直接上网。', primary:['运行诊断','diagnostics']};
    // 需要处理 named the same state differently from the alert on the same screen
    // (「交易保护未完整开启」), so the card and the banner disagreed about what had
    // happened. One state, one name; the note below carries the remedy.
    if (guard === 'Unprotected') return {tone:'unprotected', title:summary || '交易保护未完整开启', note:'修复保护＝重新连接一次，引擎启动时会重新应用阻止规则。', primary:['修复保护', state?.Lines?.length ? 'connect' : 'add'], secondary:['运行诊断','diagnostics']};
    // One action, one name: every button that opens the diagnostics report says
    // 运行诊断. 「检查保护」 only promised one section of a report that covers the
    // whole channel, and it sat next to 「修复保护」 (which actually reconnects),
    // so the two read as opposites of each other rather than as different verbs.
    // 暂时 makes a hard failure sound transient, and 请检查保护规则 repeats what the
    // note below already says. Three protection states, three distinct sentences.
    return {tone:'unknown', title:summary || '交易保护状态无法确认', note:'运行诊断可以查看保护规则的实际读取结果。', primary:['运行诊断','diagnostics']};
  }
  // Waiting for the trading app to exit. DeadlineUtc is the only clock; the
  // browser never keeps its own copy of the budget.
  function pendingWait() {
    const item = state?.Pending;
    if (item && typeof item === 'object' && (item.Name || item.DeadlineUtc)) return item;
    if (state?.PendingConnectionName) return {Name:state.PendingConnectionName, DeadlineUtc:null, SecondsRemaining:null};
    return null;
  }
  function remainingSeconds(wait) {
    if (!wait) return null;
    // DeadlineUtc is the only clock. Without it no number is shown at all: a value
    // taken from a static SecondsRemaining would look alive but never tick, and a
    // frozen counter contradicts "the host owns the budget".
    const due = Date.parse(wait.DeadlineUtc || '');
    return Number.isFinite(due) ? Math.max(0, Math.round((due - Date.now()) / 1000)) : null;
  }
  const mmss = total => `${Math.floor(total / 60)}:${String(total % 60).padStart(2, '0')}`;
  const waitKey = wait => `${wait?.Name || ''}|${wait?.DeadlineUtc || ''}`;
  // In-flight operation published by the host: what is running, on which line,
  // and since when. Queued work has no start time and shows "排队中".
  function operation() {
    const item = state?.Operation;
    return item && item.Kind ? item : null;
  }
  function elapsedSeconds(item) {
    const at = Date.parse(item?.StartedAtUtc || '');
    return Number.isFinite(at) ? Math.max(0, Math.round((Date.now() - at) / 1000)) : null;
  }
  function operationLabel(item) {
    const kind = item?.Kind;
    return kind === 'Connect' ? '正在连接' : kind === 'Switch' ? '正在切换' : kind === 'Disconnect' ? '正在断开' : kind === 'Test' ? '正在测速' : '正在处理';
  }
  // Exit evidence has five levels. "已核验" is reserved for an authoritative
  // server-attribution proof; a working forwarder is never called verified.
  // The two newest sentences come from the host catalog, so the native page and
  // the legacy mirror cannot drift apart.
  function exitView() {
    const evidence = state?.ExitEvidence;
    if (!evidence || typeof evidence !== 'object') return {label:text('ExitNotChecked','尚未核验'), tone:'muted'};
    if (evidence.Verified === true) return {label:text('ExitVerified','出口已核验'), tone:'good'};
    if (evidence.Status === 'Passed') return {label:text('ExitForwardedOnly','转发已通，归属未验证'), tone:''};
    if (evidence.Status === 'Failed') return {label:text('ExitFailed','本次核验未通过，请运行诊断'), tone:'warn'};
    if (evidence.Status === 'Inconclusive') return {label:text('ExitInconclusive','本次核验未完成（会话或配置变化）'), tone:''};
    return {label:text('ExitNotChecked','尚未核验'), tone:'muted'};
  }
  // ---- 30 minute statistics -------------------------------------------------
  // Every number on the home page and the line cards comes from the host's
  // read-only projection Lines[].Quality30m, never from Quality.History (which
  // has no upper bound) or Quality.ThirtyMinutes (which is nulled as soon as the
  // engine stops). Both derived figures are computed here, not by the host.
  function currentLine() { return line(state?.HomeLineId) || line(state?.PreferredLineId) || state?.Lines?.[0] || null; }
  // The band must describe the line that carries trade traffic, not the home
  // default. HomeLineId is a saved preference that survives connecting to another
  // line, so the status card (live Quality.LatencyMs, always the connected line)
  // and this band could report on two different lines under one anonymous title.
  // The band must describe the line that is actually up. 0.20.3 restricted this to
  // self-hosted exits (TradeExit === 'hk') because on a provider line ActiveLineId
  // does not identify the trade exit - true, but the fallback was the *home default*,
  // so the band ended up describing a line the user is not connected through, next to
  // a status card showing the live figure of the line they are. The band now always
  // follows the active line and states, in its title, when that line is not the trade
  // exit - that is the fact the reader needs, not a silent substitution.
  function panelLine() {
    const active = isConnected() ? line(state?.ActiveLineId) : null;
    return active || currentLine();
  }
  // True only when the line above is the one carrying trade traffic. On a provider
  // exit the trade path is the proxy, so the band's numbers are about this line only.
  const panelIsTradeExit = () => isConnected() && state?.TradeExit === 'hk';
  function quality30m() { const item = panelLine(); return item?.Quality30m && typeof item.Quality30m === 'object' ? item.Quality30m : null; }
  function qualitySamples() {
    const samples = quality30m()?.Samples;
    return Array.isArray(samples) ? samples.filter(value => value !== null && Number.isFinite(value)) : [];
  }
  // Standard median: sort with a numeric comparator, then average the two middle
  // values for an even count. Lower median, P50 interpolation and a string sort
  // all produce a different number on the fixtures and are all wrong here.
  function median(values) {
    if (values.length < 2) return null;
    const sorted = values.slice().sort((a, b) => a - b), n = sorted.length;
    return n % 2 ? sorted[(n - 1) / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2;
  }
  // 相邻采样平均变化 was dropped in 0.20.3. It had no threshold, so no value of it
  // could change a decision, and it sat beside 中位 in the same unit, which read as
  // "287 ± 410". 最慢响应 answers the same worry (how bad does it get) on the same
  // axis, with no constant of its own to drift from the host's thresholds.
  const statText = value => value === null ? '—' : String(Math.round(value));
  // 「未响应比例」= 没拿到可用读数的探测 / 有效尝试数。0.20.1 用两行独立输出讲同一件事
  // （「N 次未测得」+「其中 N 次超时」），本版合并成一行，比例和次数一次说完。
  //
  // 分母必须剔除 ControllerUnavailableCount：那是本机引擎自己没跑起来，不是线路问题。
  // 把它算进分母会把引擎故障摊薄成线路失败——引擎挂 10 次、线路失败 3 次会显示 12%，
  // 而真实的线路失败率是 30%。分子同理，其余四种原因（超时/连接失败/读数无效/出口未
  // 返回延迟）都表示「这次没拿到可用数值」，保留在分子里。
  //
  // 本机没有包级测量能力（PacketLossPercent 恒为空），所以这里刻意叫「未响应」而不是
  // 丢包率：请求层没拿到数不等于包丢了。
  // 0.21.1 起这个函数只出三样东西：分子/分母、百分比、以及要折进「测量口径」的
  // 分解说明。原来那句「未响应 N/M（x%）」把标签、数值和比例压进一句话，现在标签
  // 由统计格的 dt 承担，值只留 N/M——同一屏里同一件事只说一次。
  const responseRate = () => {
    const q = quality30m();
    if (!q) return {value:'—', pct:'', split:'', alert:false, diagnose:false};
    // Math.max(0, …) 是防御性的：宿主字段理论上非负，N<0 时按 0 处理（方案 §4.1）。
    const controller = Math.max(0, Number(q.ControllerUnavailableCount) || 0);
    const sample = Math.max(0, Number(q.SampleCount) || 0);
    const unavailable = Math.max(0, Number(q.UnavailableCount) || 0);
    const effective = Math.max(0, sample - controller);   // 有效尝试
    // 宿主按 UnavailableCount = SampleCount − 实测数 计算，所以 N 不可能大于 D；
    // 这里仍然夹住上界：一份写坏的投影若让比例上屏成 150%，比少报更难解释。
    const missed = Math.min(effective, Math.max(0, unavailable - controller)); // 未响应
    const timeout = Math.min(missed, Math.max(0, Number(q.TimeoutCount) || 0));
    // 引擎一次都没跑起来时没有有效尝试，比例无意义；但本机故障不允许静默。
    // 一次采样都没有（空窗口）时不写「本机引擎未完成 0 次」——那是在报告一件没发生的事。
    if (effective === 0) {
      // 引擎一次都没跑起来：不是"没有数据"，是本机没测成，不允许静默。
      if (controller > 0) return {value:'—', pct:'', split:`本机引擎未完成 ${controller} 次，未计入线路判断`, alert:false, diagnose:true};
      // 窗口里确实一次采样都没有。"暂无读数"是断言，"—"是"无从判断"，两者不能混用。
      return {value:'暂无读数', pct:'', split:'', alert:false, diagnose:false};
    }
    // 有效尝试不足 10 次时百分比在撒谎（3 次里失败 1 次 = 33%），比例位改写「样本不足」。
    // N=0 写 0 而不是 0.0：一位小数会让「没有未响应」看起来像有精度。
    const percent = missed === 0 ? '0' : (() => {
      const raw = missed / effective * 100, one = Math.round(raw * 10) / 10;
      // <10% 保留一位小数（1/60 写成 2% 差 20%），≥10% 取整。
      return one < 10 ? one.toFixed(1) : String(Math.round(raw));
    })();
    const value = `${missed}/${effective}`;
    const pct = effective < 10 ? '样本不足' : `${percent}%`;
    // 分解只列非零项：全零时留空，不写「其中超时 0 · 本机引擎未完成 0」，也不写
    // 「无失败」（见下）。这段文字折进「测量口径」，不再占正文。
    // 非超时原因（连接失败 / 读数无效 / 出口未返回延迟）单独归到「其它未响应」，
    // 否则一个只有 DelayUnavailable 的窗口会输出「未响应 2/30 · 其中超时 0」，
    // 读起来像自相矛盾。
    // 但「其它」是残差项：超时为 0 时它等于总数，写出来就是「未响应 6/51（12%）
    // 其它未响应 6」——同一个数在同一行里说两遍。残差只有和别的桶并列时才是分解。
    const parts = [];
    if (timeout > 0) parts.push(`其中超时 ${timeout}`);
    if (timeout > 0 && missed - timeout > 0) parts.push(`其它未响应 ${missed - timeout}`);
    if (controller > 0) parts.push(`本机引擎未完成 ${controller} 次`);
    // 零失败时副行留空，不再写「无失败」：它与 0/M（0%）同义，而且它把"这次探测
    // 拿到了读数"升级成"线路没问题"——一次 6900ms 的探测在它的定义里也算成功。
    // diagnose 单独给出，不再让按钮的显隐依赖副行字符串是否非空。
    return {value, pct, split: parts.join(' · '), alert: missed > 0, diagnose: missed > 0 || controller > 0};
  };
  const dailyName = value => value === 'Trade' ? '使用交易线路' : value === 'Provider' ? '使用代理软件' : '本地直连';
  // Two different failures used to share one word. A stale snapshot is a state we
  // did read that has since gone old (the title keeps 状态未知 because that is still
  // true of the connection), while ReadUnknown is a read that never returned. They
  // need different words because the remedy differs - refresh versus retry the read
  // - and because the banner below has to say 数据过期 without saying 状态未知 twice.
  const title = () => stale() ? '状态未知' : state?.State === 'ReadUnknown' ? text('ReadUnknown','无法读取') : state?.State === 'Disconnecting' ? text('Disconnecting','正在断开') : state?.State === 'Connecting' ? text('Connecting','正在连接') : state?.State === 'Applying' ? text('Switching','正在切换') : isConnected() ? (state?.Quality?.Degraded ? (state.Quality.Quality === 'Unknown' ? '线路质量待检查' : text('Unstable','线路不稳定')) : text('Connected','已连接')) : state?.State === 'Fault' ? text('NeedsAttention','连接需要处理') : text('Disconnected','未连接');
  // An empty list only means "no lines" when the read succeeded. ReadUnknown is a
  // read that never returned and Loading is one still in flight; both used to fall
  // into the empty state, so a failed read looked like a brand new install and the
  // user was invited to add a line that already existed.
  const linesUnread = () => !state?.Lines?.length && ['ReadUnknown','Loading'].includes(state?.State);
  const linesUnreadCopy = () => state?.State === 'Loading'
    ? {title:'正在读取线路列表', body:'稍候；读取完成后这里会显示你的线路。'}
    : {title:'无法读取线路列表', body:'这不代表线路已丢失。刷新可以重试，也可以运行诊断确认。'};
  function head(name, description = '', action = '') {
    // Actions belong in one flex box. Emitted as siblings they became separate
    // columns of a space-between header, so two buttons ended up at opposite
    // edges of the screen looking like unrelated entries.
    return `<header class="page-head"><div><h1>${esc(name)}</h1>${description ? `<p>${esc(description)}</p>` : ''}</div>${action ? `<div class="actions">${action}</div>` : ''}</header>`;
  }
  function cleanupProgress(phase, compact = false) {
    const step = ['Previewing','Checking'].includes(phase) ? 0 : phase === 'Ready' ? 1 : 2;
    const labels = ['检查占用','确认删除','完成处理'];
    return `<div class="cleanup-progress${compact ? ' compact' : ''}" aria-hidden="true"><div class="cleanup-steps">${labels.map((label, index) => `<span class="cleanup-step ${index < step ? 'done' : index === step ? 'current' : ''}"><i>${index < step ? '✓' : index + 1}</i>${label}</span>`).join('')}</div><div class="cleanup-track"><span></span></div></div>`;
  }
  function waitNotice() {
    const wait = pendingWait(); if (!wait) return '';
    const left = remainingSeconds(wait);
    if (left === 0 || (expiredPendingKey && expiredPendingKey === waitKey(wait))) {
      return `<div class="notice warn wait-notice" role="status"><span>等待已结束，请重新选择线路。</span><button class="small ghost" data-page="lines">重新选择线路</button></div>`;
    }
    const counter = left === null ? '' : ` <span class="countdown" data-countdown data-deadline="${esc(wait.DeadlineUtc || '')}">剩余 ${mmss(left)}</span>`;
    return `<div class="notice wait-notice" role="status"><span>退出交易软件后会连接「${esc(wait.Name)}」。${counter}</span>${button('取消等待','cancelWaiting','','small ghost')}</div>`;
  }
  function operationBar() {
    const item = operation(); if (!item) return '';
    const seconds = elapsedSeconds(item);
    return `<div class="operation-bar" role="status" aria-live="polite"><span class="spinner" aria-hidden="true"></span><span>${esc(operationLabel(item))}${item.Name ? '「' + esc(item.Name) + '」' : ''}</span><span class="muted" data-elapsed data-start="${esc(item.StartedAtUtc || '')}">${seconds === null ? '排队中' : seconds + ' 秒'}</span></div>`;
  }
  // The three facts live on the home page only, and a mirrored workflow form
  // replaces that page entirely, so "the fact cards are on screen" is exactly
  // "home page without a form".
  const homeFactsVisible = () => page === 'home' && !state?.Form;
  function notices() {
    let html = '';
    // The banner used to repeat the title's word verbatim. The title already says
    // 状态未知; the banner adds the one thing the title cannot - how old it is, and
    // what the reader is looking at - and offers the fix. On the home page the hero
    // already carries a 刷新 button, so the banner does not grow a second one.
    if (stale()) html += `<div class="notice warn stale-banner" role="status"><span>数据过期（已 ${Math.round(snapshotAge() || 0)} 秒未更新）。</span>${homeFactsVisible() ? '' : button('刷新','refresh','','small ghost',!!state.Busy)}</div>`;
    for (const [message, tone] of [[state.ReadWarning,'warn'], [state.AutoConnectNotice,''], [state.Settings?.Warning,'warn']]) {
      if (message) html += `<div class="notice ${tone}">${esc(message)}</div>`;
    }
    if (isConnected() && state.Quality?.Degraded && state.Settings?.QualityWarning !== false) {
      const candidate = state.Standby?.Recommendation, alternative = candidate && line(candidate.NodeId);
      html += `<div class="notice warn"><div>${esc(state.Quality.NotificationMessage || '线路响应异常，可运行诊断。')}</div>${alternative ? `<div class="recommendation"><span>备用「${esc(alternative.Name)}」服务器可达，响应 ${Math.round(candidate.LatencyMs)} ms。</span>${hint('备用响应不等同于交易延迟；切换时仍会检查实际连接。','备用响应')}${button('检查并切换','connect',alternative.Id,'small',busy())}</div>` : ''}</div>`;
    }
    html += waitNotice();
    html += operationBar();
    const operation = state.DeleteOperation, refresh = state.DeleteRefresh;
    if (operation && !state.Dialog && ['Previewing','Checking','Submitted','Ready','Blocked','OutcomeUnknown','NotApplied'].includes(operation.Phase)) {
      const waiting = ['Previewing','Checking','Submitted'].includes(operation.Phase);
      const action = operation.CanCancel ? button('取消检查','cancelDeletePreview',operation.Id,'small ghost') : operation.CanRetry ? button('重新检查并删除','retryDelete',operation.Id,'small ghost',busy()) : operation.CanCheck ? button(operation.Phase === 'OutcomeUnknown' ? '检查删除结果' : '检查并处理','checkDelete',operation.Id,'small ghost',!!state.ReadOnly) : '';
      html += `<div class="notice cleanup-notice ${waiting ? '' : 'warn'}" role="status"><div class="cleanup-copy"><span>${esc(operation.Message)}</span>${waiting ? cleanupProgress(operation.Phase,true) : ''}</div>${action}</div>`;
    }
    if (refresh && ['Loading','Failed'].includes(refresh.Phase) && !state.Dialog) {
      html += `<div class="notice cleanup-notice ${refresh.Phase === 'Failed' ? 'warn' : ''}" role="status">${refresh.Phase === 'Loading' ? '<span class="spinner" aria-hidden="true"></span>' : ''}<span>${esc(refresh.Message)}</span>${refresh.CanRetry ? button('重试刷新','retryDeleteRefresh',refresh.Id,'small ghost') : ''}</div>`;
    }
    for (const operation of state.PendingOperations || []) {
      if (state.DeleteOperation?.Phase === 'OutcomeUnknown' && operation.Kind === 'Cleanup') continue;
      html += `<div class="notice cleanup-notice warn"><div class="cleanup-copy"><span>${esc(operation.Message)}</span>${isConnected() && ['Local','Cleanup'].includes(operation.Kind) ? '<p class="footnote">当前线路仍在使用。</p>' : ''}</div>${button('查看并处理','reviewOperation',operation.Id,'small ghost')}</div>`;
    }
    // D4: the home page already renders the protection fact card, so the same
    // sentence must not be printed twice on one screen. A mirrored workflow
    // replaces the whole page, so the card only exists while no form is open;
    // every other page keeps the alert.
    if (!homeFactsVisible() && state.Guard === 'Unprotected' && state.TradeProgramCount !== 0) html += `<div class="notice warn guard-alert" role="status"><span>交易保护未完整开启：名单内的交易程序现在可以直接上网。</span>${button('修复保护',state.Lines?.length ? 'connect' : 'add',state.HomeLineId || state.PreferredLineId || state.Lines?.[0]?.Id || '','small',busy())}${button('运行诊断','diagnostics','','small ghost',entryBusy())}</div>`;
    if (state.ReadOnly) html += '<div class="notice">当前窗口只读。</div>';
    if (state.Busy && state.BusyMessage && state.Form) html += `<div class="busy-line" role="status"><span class="spinner"></span>${esc(state.BusyMessage)}</div>`;
    return html;
  }
  function seriesValues(projection, key = 'Samples', span = 60) {
    const samples = (projection ?? quality30m())?.[key];
    if (!Array.isArray(samples)) return [];
    return samples.slice(-span).map(value => Number.isFinite(value) ? value : null);
  }
  function recentValues(projection, span = 60) { return seriesValues(projection, 'Samples', span); }
  // A 30 second bucket is exactly as wide as the probe cadence, so one skipped
  // probe leaves an empty bucket while both neighbours measured fine - the host
  // store shows 1 and 2 empty buckets in a row, never 3, on a window whose
  // 未响应 is 0. Breaking the line on every empty bucket therefore drew a dashed
  // chart on a healthy line: nine holes read as "the line keeps dropping out".
  // Only a real outage breaks it now. Three empty buckets in a row is 90 seconds
  // with no reading at all; one or two is cadence jitter and the polyline spans
  // them, which is what the eye assumes anyway.
  const SPARK_BRIDGE = 2;
  function sparkline(width, height, stroke, label, projection, span = 60) {
    const values = recentValues(projection, span);
    if (values.filter(value => value !== null).length < 2) return '';
    const max = Math.max(150, ...values.filter(value => value !== null));
    const step = values.length > 1 ? width / (values.length - 1) : 0;
    const paths = []; let current = []; let holes = 0;
    values.forEach((value, index) => {
      // Count the hole and keep the segment open: the next real point simply
      // continues it, so the polyline draws a straight line across the gap.
      if (value === null) { holes += 1; return; }
      if (holes > SPARK_BRIDGE) { if (current.length) paths.push(current.join(' ')); current = []; }
      holes = 0;
      current.push(`${(index * step).toFixed(1)},${(height - 5 - value / max * (height - 11)).toFixed(1)}`);
    });
    if (current.length) paths.push(current.join(' '));
    return `<svg viewBox="0 0 ${width} ${height}" preserveAspectRatio="none" role="img" aria-label="${label}">${paths.map(path => `<polyline fill="none" stroke="${stroke}" stroke-width="2" vector-effect="non-scaling-stroke" points="${path}"/>`).join('')}</svg>`;
  }
  // ---- 30 分钟曲线 ----------------------------------------------------------
  // 一条主曲线（P50 实线 + 面积）加一条尾延迟（P95 虚线），带纵轴刻度、时间刻度
  // 和图例。异常采样不再另起一段带时间戳的文字清单：在对应时间点上画一根竖虚线
  // （尖峰再补一个点），位置本身就回答了「什么时候」，逐条明细留给「响应历史」。
  // 纵轴上限按数据取整到 200 的倍数，一次尖峰才不会把整条曲线压平在底部。
  const CHART_W = 600, CHART_H = 132, CHART_PAD = 6;
  const chartTop = values => Math.max(200, Math.ceil(Math.max(...values) / 200) * 200);
  const chartY = (value, top) => CHART_PAD + (CHART_H - CHART_PAD * 2) * (1 - value / top);
  function chartSegments(values, step, top) {
    const out = []; let current = []; let holes = 0;
    values.forEach((value, index) => {
      if (value === null) { holes += 1; return; }
      if (holes > SPARK_BRIDGE) { if (current.length) out.push(current); current = []; }
      holes = 0;
      current.push([+(index * step).toFixed(1), +chartY(value, top).toFixed(1)]);
    });
    if (current.length) out.push(current);
    return out;
  }
  // 两类异常：整段断流（连续 3 桶以上没读数，90 秒没有任何回音）和尾部尖峰
  // （P95 ≥ P50 的 3 倍）。只保留最近 4 处，避免一屏插满标记。
  //
  // 单桶空档不算异常：30 秒一桶与探测节奏等宽，漏一次探测就会留一个空桶，而曲线
  // 本身会跨过去（SPARK_BRIDGE）。给这种空档画竖线，等于曲线说"连着"、标记说
  // "这里断了"，同一张图自相矛盾；而且它正是用户要求删掉的「某个时间点有没有
  // 拿到读数」。门槛与断线门槛同源，两个判断不会打架。
  function chartAnomalies(p50, p95) {
    const marks = []; let run = null;
    const close = () => {
      if (!run) return;
      if (run.end - run.start + 1 > SPARK_BRIDGE) marks.push({index: Math.round((run.start + run.end) / 2), kind: 'miss'});
      run = null;
    };
    p50.forEach((value, index) => {
      if (value === null) { if (run) run.end = index; else run = {start: index, end: index}; return; }
      close();
      const tail = p95[index];
      if (Number.isFinite(tail) && value > 0 && tail >= value * 3) marks.push({index, kind: 'spike', value: tail});
    });
    close();
    return marks.slice(-4);
  }
  function chart(projection) {
    // P50/P95 双线：中位代表"平时多快"，P95 代表"最差的时候"。
    // 宿主没给这两条序列时（旧数据或只有平均值的窗口）退回单线，
    // 这样图表在两种投影下都能画，不会出现空白。
    const q = projection ?? quality30m();
    const p50 = seriesValues(q, 'MedianSamples');
    const p95 = seriesValues(q, 'P95Samples');
    if (p50.filter(value => value !== null).length >= 2 && p95.filter(value => value !== null).length >= 2) {
      const top = chartTop(p50.concat(p95).filter(value => value !== null));
      const step = p50.length > 1 ? CHART_W / (p50.length - 1) : 0;
      const x = index => index * step;
      const seg50 = chartSegments(p50, step, top), seg95 = chartSegments(p95, step, top);
      const poly = (segments, cls) => segments.map(points => `<polyline class="${cls}" fill="none" stroke-linejoin="round" vector-effect="non-scaling-stroke" points="${points.map(point => point.join(',')).join(' ')}"/>`).join('');
      // 面积只铺在两个点以上的段里：单点段没有面积可言。
      const area = seg50.filter(points => points.length > 1).map(points => `<path class="chart-area" d="M ${points[0][0]} ${CHART_H - CHART_PAD} L ${points.map(point => point.join(' ')).join(' L ')} L ${points[points.length - 1][0]} ${CHART_H - CHART_PAD} Z"/>`).join('');
      const rows = [top, top / 2, 0].map(value => `<line class="chart-grid" x1="0" x2="${CHART_W}" y1="${chartY(value, top).toFixed(1)}" y2="${chartY(value, top).toFixed(1)}"/>`).join('');
      const cols = [0, Math.round((p50.length - 1) / 2), p50.length - 1].map(index => `<line class="chart-grid" x1="${x(index).toFixed(1)}" x2="${x(index).toFixed(1)}" y1="${CHART_PAD}" y2="${CHART_H - CHART_PAD}"/>`).join('');
      const marks = chartAnomalies(p50, p95).map(mark => {
        const cx = x(mark.index).toFixed(1);
        const line = `<line class="chart-mark" x1="${cx}" x2="${cx}" y1="${CHART_PAD}" y2="${CHART_H - CHART_PAD}"/>`;
        return mark.kind === 'spike' ? line + `<circle class="chart-dot" cx="${cx}" cy="${chartY(mark.value, top).toFixed(1)}" r="2.4"/>` : line;
      }).join('');
      const last = p50[p50.length - 1];
      const head = last === null ? '' : `<circle class="chart-head" cx="${x(p50.length - 1).toFixed(1)}" cy="${chartY(last, top).toFixed(1)}" r="2.4"/>`;
      // 刻度按桶数算：60 桶就是 30 分钟前 / 15 分钟前 / 现在；刚连上只有几桶时
      // 左端写的是真实回看长度，不会把 2 分钟画成 30 分钟。中段与左端同值时留空，
      // 免得出现「1 分钟前 · 1 分钟前 · 现在」。
      const minutes = Math.max(1, Math.round((p50.length - 1) / 2));
      const half = Math.max(1, Math.round(minutes / 2));
      const legend = '<div class="chart-legend"><span><i class="k-p50"></i>P50 中位</span><span><i class="k-p95"></i>P95 尾延迟</span><span><i class="k-anomaly"></i>异常采样</span></div>';
      return `<div class="chart-plot"><div class="chart-y" aria-hidden="true"><span>${top}</span><span>${top / 2}</span><span>0</span></div>`
        + `<div class="chart-canvas"><svg viewBox="0 0 ${CHART_W} ${CHART_H}" preserveAspectRatio="none" role="img" aria-label="近30分钟线路响应：P50 中位与 P95 尾延迟，超过 1 分钟无读数的区间不连线">`
        + rows + cols + area + poly(seg95, 'chart-p95') + poly(seg50, 'chart-p50') + marks + head + '</svg></div></div>'
        + `<div class="chart-x" aria-hidden="true"><span>${minutes} 分钟前</span><span>${half === minutes ? '' : `${half} 分钟前`}</span><span>现在</span></div>`
        + legend;
    }
    return sparkline(280, 44, '#73d9c2', '近30分钟线路响应，超过 1 分钟无读数的区间不连线', projection) || '<div class="chart-empty">等待采样</div>';
  }
  // The line card shows the last 10 minutes while the band shows 30: the same
  // series drawn twice on one screen was the duplicate, and 96px cannot resolve
  // 60 points anyway. The label must move with the window - a stale "近30分钟"
  // here would tell screen-reader users the wrong time span, and no test can
  // catch it (the string is legal, nothing asserts it).
  function rowTrend(projection) {
    return sparkline(96, 26, 'currentColor', '近10分钟线路响应，超过 1 分钟无读数的区间不连线', projection, 20) || '<span class="muted">等待采样</span>';
  }
  function lineFeedback(item, kind = '', compact = false) {
    return (item.Feedback || []).filter(entry => (!kind || entry.Kind === kind) && (!compact || entry.Status !== 'Succeeded' || pickFeedbackLive(entry))).map(entry => {
      // 卡片上只要一句：已固定为兼容，下次连接生效。
      if (compact && entry.Kind === 'Preference' && entry.Status === 'Succeeded') return `<p class="pick-feedback" role="status" data-feedback="${esc(entry.Id)}">${esc(entry.Message)}</p>`;
      const success = entry.Status === 'Succeeded', info = entry.Status === 'Info';
      const subject = entry.Kind === 'Check' ? `${profile(entry.ProfileId)}测试` : `${profile(entry.ProfileId)}保存`;
      const label = success ? '已完成' : info ? '已更新' : entry.NeedsReview ? '结果待确认' : '未完成';
      const retryLabel = entry.Kind === 'Check' ? '重新测试' : '重试保存';
      const action = entry.NeedsReview ? `<button class="small" data-action="reviewLineAction" data-id="${esc(item.Id)}" data-value="${esc(entry.Id)}" ${busy() ? 'disabled' : ''}>${esc(entry.ReviewLabel || '检查原操作')}</button>` : entry.CanRetry ? `<button class="small" data-action="retryLineAction" data-id="${esc(item.Id)}" data-value="${esc(entry.Id)}" ${busy() ? 'disabled' : ''}>${retryLabel}</button>` : '';
      return `<section class="line-feedback ${success ? 'success' : info ? 'info' : 'attention'}" role="status" aria-live="polite" data-feedback="${esc(entry.Id)}"><div class="feedback-copy"><strong>${compact ? `「${esc(item.Name)}」· ` : ''}${esc(subject)} · ${label}</strong><p>${esc(entry.Message)}</p>${entry.ConnectionMessage ? `<p class="feedback-context">${esc(entry.ConnectionMessage)}</p>` : ''}${entry.Code ? `<details><summary>错误详情</summary><span class="mono">${esc(entry.Code)}</span></details>` : ''}</div>${action || entry.CanDiagnose ? `<div class="actions">${action}${entry.CanDiagnose ? button('运行诊断','diagnostics','','small ghost',entryBusy()) : ''}</div>` : ''}</section>`;
    }).join('');
  }
  function outcomeOf(item) {
    const outcome = item?.LastOutcome;
    if (!outcome || !outcome.Status) return null;
    const expires = Date.parse(outcome.ExpiresAtUtc || '');
    if (Number.isFinite(expires) && expires <= Date.now()) return null;
    // D1: Completed only ever proves "this line switched once". While any line is
    // connected, the status card and the 使用中 badge carry the present tense, so
    // no card (current or not) repeats a 切换已完成 strip; after the connection is
    // gone the same outcome returns as the historical evidence it is. The two 0.19
    // behaviours are kept: same line connected means no strip, disconnected means
    // exactly one strip.
    if (outcome.Status === 'Completed' && isConnected()) return null;
    return outcome;
  }
  function outcomeAction(item, outcome) {
    const pending = (state.PendingOperations || []).find(entry => entry.Kind === 'Connection') || (state.PendingOperations || [])[0];
    switch (outcome.NextAction) {
      case 'Connect': return button('重新连接','connect',item.Id,'small',busy());
      case 'ChooseLine': return '<button class="small" data-page="lines">重新选择线路</button>';
      case 'ReviewOperation': return pending ? button('查看并处理','reviewOperation',pending.Id,'small',busy()) : button('运行诊断','diagnostics','','small ghost',entryBusy());
      case 'Diagnostics': return button('运行诊断','diagnostics','','small ghost',entryBusy());
      default: return button('查看详情','details',item.Id,'small ghost');
    }
  }
  // Only RolledBack may claim a restore. Aborted, ResolvedStopped and
  // NeedsRecovery keep their own sentences and never say 已恢复.
  // D3: while a line is connected, every terminal result is past tense - on the
  // other cards and on the card that is in use. A line cannot be 使用中 and
  // 已回到切换前的状态 at the same time; the host sentence stays authoritative
  // and is never rewritten, only the title gains a 上次切换 prefix and the strip
  // drops to a quiet level.
  const HISTORY_STATUSES = ['RolledBack','Aborted','ResolvedStopped','NeedsRecovery'];
  function outcomeBar(item) {
    const outcome = outcomeOf(item); if (!outcome) return '';
    const tone = outcome.Status === 'NeedsRecovery' ? 'bad' : ['RolledBack','ResolvedStopped'].includes(outcome.Status) ? 'warn' : outcome.Status === 'Completed' ? 'good' : 'neutral';
    const history = isConnected() && HISTORY_STATUSES.includes(outcome.Status);
    // Completed never describes the present (see outcomeOf), so it is always
    // printed as history: neutral strip, muted title, no colour block. Only a
    // terminal result that could be mistaken for "now" needs the prefix.
    const quiet = history || outcome.Status === 'Completed';
    const heading = `${history ? '上次切换：' : ''}${outcome.Label || '上次操作'}`;
    return `<section class="outcome outcome-${tone}${quiet ? ' outcome-history' : ''}" role="status" aria-live="polite" data-testid="line-outcome"><div class="outcome-copy"><strong>${esc(heading)}</strong><p>${esc(outcome.Message || '')}</p></div><div class="actions">${outcomeAction(item,outcome)}</div></section>`;
  }
  // 0.21.0: card protocol pick (R1-R3). Two segments only - 标准(Udp) | 兼容(Tcp) -
  // reusing .seg + .seg-group; 自动 stays a strategy in the drawer, never a segment.
  // Clicking writes a local preference for the NEXT connection only: the setProfile
  // action is in the inPlace list, so no drawer closes, no Connect/Switch
  // transaction starts and IsBusy is never entered. Three meanings stay decoupled
  // on screen: the resolved next-connection protocol is the highlighted segment,
  // the live protocol carries a green 使用中 chip, the pinned default carries a
  // quiet 默认 chip - current Tcp + default Udp must show both chips at once.
  function protocolPick(item, active) {
    const prepared = Array.isArray(item.PreparedProfiles) ? item.PreparedProfiles : [];
    // Single-protocol lines degrade to static text: a disabled option reads as
    // "broken", not as "feature" (Q3: length < 2, so unprepared lines degrade too).
    if (prepared.length < 2) {
      const only = prepared.length === 1 ? (prepared[0] === 'Udp' ? '标准' : '兼容') : '';
      return `<span class="seg-static muted" data-testid="protocol-pick">${only ? `仅支持${only}连接` : '连接方式未准备'}</span>`;
    }
    const pinned = item.ProfileSource === 'UserChoice';
    const off = busy() || item.Pending === 'Saving' || testState(item).running;
    const seg = (label, value) => {
      // 0.22.0 C-R5：自动态两段都不亮（解析结果由旁边的「自动·标准/兼容」说明），
      // 固定态只有固定的那段亮。role=radio 与 aria-checked 是唯一的选中语义，
      // 不再同时挂 aria-pressed（C5-04）。
      const on = pinned && item.Profile === value;
      const live = active && state.ActiveProfile === value;
      // data-current marks the already-pinned value so the click handler can skip
      // re-writing the same preference (R1: 点当前值不重复写).
      return `<button class="seg${on ? ' on' : ''}" role="radio" aria-checked="${on}" data-action="setProfile" data-value="${value}" data-id="${esc(item.Id)}" data-current="${on ? value : ''}" ${off ? 'disabled' : ''}>${label}${live ? '<span class="seg-tag seg-tag-live">使用中</span>' : ''}${on ? '<span class="seg-tag">默认</span>' : ''}</button>`;
    };
    const auto = pinned ? '' : `<span class="seg-auto" data-testid="protocol-auto">自动·${item.Profile === 'Tcp' ? '兼容' : '标准'}</span>`;
    return `<span class="seg-group" role="radiogroup" aria-label="下次连接方式" data-testid="protocol-pick">${seg('标准','Udp')}${seg('兼容','Tcp')}</span>${auto}`;
  }
  // 0.22.0 C-R6: the number is a reading, not a button. The test entry is its own
  // small button with the same disabled rules and the same in-place countdown.
  function standbyMetric(item, response) {
    const test = testState(item);
    const prepared = Array.isArray(item.PreparedProfiles) ? item.PreparedProfiles : [];
    const running = test.running;
    const blocked = !!item.Blocked;
    const failed = !!(failureExpiry(item) || item.Readiness?.State === 'TestFailed');
    const caption = running ? `测速中${test.seconds === null ? '…' : ` · ${test.seconds} 秒`}` : '测速';
    const testButton = blocked || failed ? ''
      : `<button class="small ghost metric-test" data-action="testLine" data-id="${esc(item.Id)}" aria-label="测速这条线路" ${busy() || !!item.Pending || running ? 'disabled' : ''}>${caption}</button>`;
    let figure = '尚未测量', muted = true;
    if (running) figure = '测速中…';
    else if (blocked) figure = '—';
    else if (response !== '—') { figure = `${response}<span class="muted"> ms</span>`; muted = false; }
    else if (!isConnected()) figure = '连接后测量';
    else if (!prepared.includes('Tcp')) figure = '仅测兼容连接';
    const labelHint = '备用线路只对已准备兼容连接（TCP）的线路做服务器建连计时，不经过交易出口；它不等于「当前响应」，两者不能直接比较。';
    return `<div class="metric-block"><div class="metric-head"><span class="line-sub">服务器响应${hint(labelHint, '服务器响应')}</span>${testButton}</div><div class="mono${muted ? ' muted' : ''}" data-testid="line-metric">${figure}</div></div>`;
  }
  // Line cards replaced the 0.19 table. Anchors other surfaces depend on
  // (.outcome-row, .line-feedback, [data-detail]) are kept, but the outer element
  // is a card so a line can carry a reason and its own 30 minute curve.
  function lineCards(items, limit = 0) {
    if (!items.length) {
      if (linesUnread()) {
        const copy = linesUnreadCopy();
        return `<div class="card empty guide-card" role="status"><h2>${copy.title}</h2><p>${copy.body}</p><div class="actions">${button('刷新','refresh','','',!!state?.Busy || !!pendingIntent)}${button('运行诊断','diagnostics','','ghost',!!state?.Busy || !!pendingIntent)}</div><p class="muted">读不到时仍然可以加入已有线路或部署自己的服务器，不会改变当前连接。</p><div class="actions">${button('用邀请码加入','pairStart','','',entryBusy())}${button('自己搭服务器','add','','',entryBusy())}</div></div>`;
      }
      return `<div class="card empty guide-card"><h2>还没有线路</h2><p>用邀请码加入已有线路最快；也可以部署自己的服务器。</p><div class="actions">${button('用邀请码加入','pairStart','','primary',entryBusy())}${button('自己搭服务器','add','','',entryBusy())}</div></div>`;
    }
    const op = operation(), shown = limit ? items.slice(0, limit) : items;
    return `<div class="line-list">${shown.map(item => {
      const active = lineInUse(item), status = lineStatus(item);
      const standby = (state.Standby?.Items || []).find(entry => entry.NodeId === item.Id && entry.Fresh);
      const feedback = lineFeedback(item, '', true), outcome = outcomeBar(item);
      const projection = item.Quality30m && typeof item.Quality30m === 'object' ? item.Quality30m : null;
      // 0.21.0 (R11): the in-use card regains a current figure, read from the same
      // source as the status card (latency() -> state.Quality.LatencyMs) but under
      // a different label - the status card owns 当前响应, this card owns
      // 当前线路响应, so the two are never read as duplicates.
      const response = Number.isFinite(standby?.LatencyMs) && standby.LatencyMs >= 0 ? `${Math.round(standby.LatencyMs)}` : '—';
      const busyHere = !!op && op.LineId === item.Id && ['Connect','Switch'].includes(op.Kind);
      const seconds = busyHere ? elapsedSeconds(op) : null;
      const connectLabel = busyHere ? (op.Kind === 'Switch' ? '切换中' : '连接中') + (seconds === null ? '' : ` · ${seconds} 秒`) : isConnected() ? '切换' : '连接';
      const disconnectLabel = !!op && op.Kind === 'Disconnect' ? '断开中' : '断开';
      // 0.21.0 (R6): the primary action is derived from state, one per card -
      // 断开 when in use, 测速 when untested or last attempt failed (测速中 while
      // it runs), 需要处理 disabled when blocked, otherwise 连接/切换.
      // The host always fills Readiness.Label (WebShell.ps1:142/613 - every line
      // gets 未测试/上次测试未通过/可用/使用中/需要处理), so "no label" is not a
      // usable test for "untested"; read Readiness.State instead, and keep the
      // missing-label case only for older projections.
      const readiness = item.Readiness || {};
      const needsTest = readiness.State === 'Untested' || readiness.State === 'TestFailed' || !readiness.Label;
      const test = testState(item);
      const untested = !item.Blocked && needsTest;
      let primary;
      if (active) primary = button(disconnectLabel,'disconnect','','small',busy());
      // 0.21.2: a blocked line used to get a disabled 需要处理 and nothing else - the
      // repair page (server identity check) was only reachable through the drawer
      // entry 0.21.0 removed. The primary action is now that repair itself.
      else if (item.Blocked) primary = button('核对服务器身份','lineServer',item.Id,'small',busy());
      else if (test.running) primary = button('测速中' + (test.seconds === null ? '…' : ` · ${test.seconds} 秒`),'testLine',item.Id,'small',true);
      else if (untested || failureExpiry(item)) primary = button('测速','testLine',item.Id,'small',busy() || !!item.Pending);
      // 0.22.0 C-R8：交易走代理软件时，这条线路的主按钮是切回来——只切 selector，不重启通道。
      else if (readiness.State === 'ProviderBackup') primary = button('切回此线路','connect',item.Id,'small',busy());
      else primary = button(connectLabel,'connect',item.Id,'small',busy() || busyHere);
      // 0.21.0 (R4): the home line gets a graphic mark in the head, never the word
      // 默认 - that word stays reserved for the pinned-protocol chip in the pick.
      const homeMark = state.HomeLineId === item.Id ? '<span class="home-mark" role="img" aria-label="默认线路" data-testid="home-line-mark">★</span>' : '';
      const live = latency();
      const metrics = active
        ? `<div class="metric-now"><span class="line-sub">当前线路响应</span><div class="mono metric-now-value" data-testid="line-live-latency">${live !== '—' ? `${live}<span class="muted"> ms</span>` : '<span class="muted">暂未测得</span>'}</div></div><div class="trend"><span class="line-sub">近 10 分钟</span>${rowTrend(projection)}</div>`
        : standbyMetric(item, response);
      return `<article class="line-card${active ? ' in-use' : ''}" data-testid="line-card"><div class="line-card-head"><button class="name-button" data-detail="${esc(item.Id)}">${homeMark}<span class="line-name">${esc(item.Name)}</span></button><span class="badge ${status.tone}" data-testid="line-status">${esc(status.label)}</span></div><p class="line-meta muted">${item.ProfileSource === 'UserChoice' ? '已固定' : '自动选择'}</p><p class="line-reason muted" data-testid="line-reason">${esc(status.reason || '')}</p><div class="line-card-metrics">${metrics}</div>${outcome ? `<div class="outcome-row">${outcome}</div>` : ''}${feedback}<div class="actions">${protocolPick(item, active)}<span class="grow" aria-hidden="true"></span>${primary}${button('详情','details',item.Id,'small ghost')}</div></article>`;
    }).join('')}</div>`;
  }
  function guardCard() {
    const view = guardView();
    const targetId = view.primary[1] === 'connect' ? (state.HomeLineId || state.PreferredLineId || state.Lines?.[0]?.Id || '') : '';
    const secondary = view.secondary ? button(view.secondary[0], view.secondary[1], '', 'small ghost', busy()) : '';
    return `<article class="fact fact-${view.tone}" data-testid="fact-guard" aria-labelledby="guard-title"><div class="fact-head"><span class="guard-dot" aria-hidden="true"></span><h3 id="guard-title">${esc(view.title)}</h3></div><p class="fact-note" data-testid="guard-note">${esc(view.note)}</p><div class="actions">${button(view.primary[0], view.primary[1], targetId, 'small', busy())}${secondary}</div></article>`;
  }
  // The exit badge used to exist only while connected. It is now a fact card so a
  // disconnected user can still read what the last check proved.
  function exitFact() {
    const view = exitView(), observed = state?.ExitEvidence?.ObservedIP;
    return `<article class="fact" data-testid="fact-exit"><div class="fact-head"><h3>交易出口</h3></div><span class="badge ${view.tone}">${esc(view.label)}</span>${observed ? `<p class="fact-note muted mono">端点 ${esc(observed)}</p>` : ''}</article>`;
  }
  // ---- 线路响应带 ------------------------------------------------------------
  // 左边一条 30 分钟曲线，右边三格数字，底部一行「测量口径 + ｜ 响应历史 →」。
  // 每个数字都来自宿主的只读投影 Lines[].Quality30m；中位与最慢由本文件算，
  // 宿主不下发。这里不估算丢包率：宿主没有这项测量，写上去就是编的。
  //
  // 0.21.1 的取舍——屏幕上只留「现在要知道的」：
  //   · 逐条时间戳的异常明细（「21:12 尾延迟偏高…」「21:08 这一次没有拿到读数」）
  //     不再上屏。曲线上的竖线已经指出位置，逐条明细进「响应历史」。
  //   · 六行长口径折进「测量口径」，默认收起——一周看一次的解释不该每天占三行。
  //   · 未响应从独立告警色块并进第三格，只留 N/M 与比例；色块把「一个数」讲成
  //     「一个事件」，而这一屏已经有三处入口可以处理它。
  function statCell(label, value, testid, unit) {
    const suffix = unit && value !== '—' ? `<small class="response-unit">${unit}</small>` : '';
    return `<div class="response-stat"><dt>${label}</dt><dd><span class="mono" data-testid="${testid}">${value}</span>${suffix}</dd></div>`;
  }
  function responsePanel() {
    const item = panelLine(), projection = quality30m(), values = qualitySamples(), rate = responseRate();
    // 三个度量格：典型 / 最慢 / 未响应。成功次数与采样次数在 0.20.3 就删了——它们
    // 和「未响应 N/M」是同一个事实（Unavailable = Sample − Measured），原始计数仍在
    // 响应历史里。两个毫秒格都以「至少两个样本」为门槛：只剩一个值时，最慢会退化成
    // 和典型一样的数字，摆在一起像是重复。
    // 状态卡负责「现在是多少」（已连接），断开时的占位说明在首屏文案里，这一带不再
    // 印第二个当前值。
    const pair = values.length >= 2;
    const slowest = pair ? statText(Math.max(...values)) : statText(null);
    const name = item?.Name ? `<span class="response-line">「${esc(item.Name)}」</span>` : '';
    // 断开时这一带刻意保留上次连接的数字；没有语气标记时「未响应 0/55」会被读成
    // 「现在」。走代理时同一个问题反向出现：这一带讲的是在用的那条线，不是交易出口。
    const tense = !isConnected() && values.length ? '<span class="response-tense">· 上次连接</span>'
      : isConnected() && !panelIsTradeExit() ? '<span class="response-tense">· 非交易出口</span>' : '';
    // 测量口径不能声称描述交易路径而交易路径其实是代理。先说清这组数字讲的是什么，
    // 再说常规限制。断开时没有交易出口，「代理接管交易出口」描述的是不存在的状态。
    const scope = !isConnected() ? '连接后开始测量；' : panelIsTradeExit() ? '' : '当前交易出口由代理软件接管，这条线路的读数不代表下单路径；';
    const history = item ? `<button class="history-link" data-detail="${esc(item.Id)}">响应历史 →</button>` : '';
    return `<section class="response" data-testid="quality-panel" aria-labelledby="response-title">`
      + `<div class="response-head"><h2 id="response-title">线路响应${name}${tense}${hint('统计交易出口的 HTTPS 往返，每次新建连接并含加密建连，不等于下单延迟；没拿到读数记作「未响应」。','线路响应')}</h2><span class="response-hint">最近 30 分钟</span></div>`
      + `<div class="response-body"><div class="response-chart" data-testid="quality-chart">${chart(projection)}</div>`
      + '<dl class="response-stats">'
      + statCell('典型响应', statText(median(values)), 'quality-median', 'ms')
      + statCell('最慢响应', slowest, 'quality-worst', 'ms')
      + `<div class="response-stat response-rate${rate.alert ? ' alert' : ''}"><dt>未响应</dt><dd><span class="mono" data-testid="quality-unavailable">${esc(rate.value)}</span><small class="response-pct" data-testid="quality-rate">${esc(rate.pct)}</small></dd></div>`
      + '</dl></div>'
      + `<div class="response-foot"><details class="response-scope"><summary>测量口径</summary><p class="footnote">${scope}按 30 秒一次、最近 30 分钟统计；测量是交易出口的 HTTPS 往返（每次新建连接，含加密建连），不等于下单延迟；没拿到读数记作「未响应」。</p><p class="response-split" data-testid="quality-split">${esc(rate.split)}</p></details>`
      + `<div class="response-links">${rate.diagnose ? button('运行诊断','diagnostics','','small ghost',entryBusy()) : ''}${history}</div></div>`
      + '</section>';
  }
  function flowCard() {
    const current = state.TradeName || line(state.ActiveLineId)?.Name || state.NodeName || '尚未选择线路';
    return `<div class="section-head"><h2>应用走向</h2><button class="ghost small" data-page="apps">调整 →</button></div><div class="card routing-summary"><div class="flow"><span>交易软件</span><span class="to" data-testid="flow-trade">${esc(isConnected() ? current : '尚未连接')}</span></div><div class="flow"><span>日常上网</span><span class="to" data-testid="flow-daily">${dailyName(state.Daily)}</span></div><div class="flow"><span>AI 工具</span><span class="to" data-testid="flow-agents">${state.Agents === 'Trade' ? '使用交易线路' : '跟随日常上网'}</span></div></div>`;
  }
  // "引擎已运行" is the engine start time, not the length of this connection.
  function engineRuntime() {
    const label = text('EngineRunning','引擎已运行');
    const since = Date.parse(state?.ConnectedSince || '');
    if (!Number.isFinite(since)) return `<div class="line-sub muted" data-testid="engine-runtime">${esc(label)} —</div>`;
    const seconds = Math.max(0, Math.round((Date.now() - since) / 1000));
    const hours = Math.floor(seconds / 3600), minutes = Math.floor((seconds % 3600) / 60);
    const span = hours > 0 ? `${hours} 小时 ${minutes} 分` : minutes > 0 ? `${minutes} 分` : `${seconds} 秒`;
    return `<div class="line-sub muted" data-testid="engine-runtime">${esc(label)} ${span}</div>`;
  }
  function home() {
    const connected = isConnected(), next = currentLine();
    const refresh = button('刷新','refresh','','ghost',!!state.Busy || !!pendingIntent);
    if (!state.Lines?.length) {
      // Say what actually happened, then still offer the ways forward. Hiding the
      // invitation on a failed read would strand a first-time user, so the CTAs stay
      // - demoted to a separate card instead of being presented as the only truth.
      if (linesUnread()) {
        const copy = linesUnreadCopy();
        // busy() also reports true while State is ReadUnknown (it is there to freeze
        // the normal pages during a failed read). Reusing it here disabled the very
        // recovery buttons this state is telling the user to press.
        const readBlocked = !!state?.Busy || !!pendingIntent;
        return head('首页','') + notices() +
          `<section class="hero hero-idle guide-hero" aria-label="线路列表状态"><div class="hero-head"><div><div class="signal-title" role="status" aria-live="polite">${copy.title}</div><div class="sub">${copy.body}</div></div><div class="actions">${button('刷新','refresh','','primary',readBlocked)}${button('运行诊断','diagnostics','','ghost',readBlocked)}</div></div></section>` +
          `<div class="section-head"><h2>仍然可以继续</h2></div><div class="card card-pad"><p class="muted">线路列表读不到时，仍然可以用邀请码加入已有线路，或部署自己的服务器。</p><div class="actions">${button('用邀请码加入','pairStart','','',readBlocked)}${button('自己搭服务器','add','','ghost',readBlocked)}</div></div>`;
      }
      return head('首页','',refresh) + notices() + guardCard() +
        `<section class="hero hero-idle guide-hero" aria-label="开始使用"><div class="hero-head"><div><div class="signal-title">还没有线路</div><div class="sub">用邀请码加入已有线路最快；也可以部署自己的服务器。</div></div><div class="actions"><button class="primary" data-action="pairStart" data-testid="empty-primary" ${entryBusy() ? 'disabled' : ''}>用邀请码加入</button><button data-action="add" data-testid="empty-secondary" ${entryBusy() ? 'disabled' : ''}>自己搭服务器</button></div></div></section>`;
    }
    const current = state.TradeName || line(state.ActiveLineId)?.Name || state.NodeName || '尚未选择线路';
    const op = operation(), opSeconds = op ? elapsedSeconds(op) : null;
    const disconnectLabel = op && op.Kind === 'Disconnect' ? '断开中' + (opSeconds === null ? '' : ` · ${opSeconds} 秒`) : '断开连接';
    const connectBusy = op && next && op.LineId === next.Id && ['Connect','Switch'].includes(op.Kind);
    const connectLabel = connectBusy ? (op.Kind === 'Switch' ? '切换中' : '连接中') + (opSeconds === null ? '' : ` · ${opSeconds} 秒`) : '连接';
    // 0.21.2: a blocked default line offers its repair instead of a dead 连接.
    const primary = state.Running ? button(disconnectLabel,'disconnect','','primary',busy() || (op && op.Kind === 'Disconnect')) : next?.Blocked ? button('核对服务器身份','lineServer',next.Id,'primary',busy()) : next ? button(connectLabel,'connect',next.Id,'primary',busy() || connectBusy) : button('添加线路','add','','primary',busy());
    const subtitle = stale() ? '连接状态可能已变化。' : connected ? current : state.State === 'Disconnected' ? (next ? (next.Blocked ? `「${next.Name}」需要先核对服务器身份` : `下次连接：${next.Name}`) : '添加线路后开始连接') : state.State === 'ReadUnknown' ? '请刷新或运行诊断，确认连接状态。' : state.Running ? current : (state.BusyMessage || '请检查连接状态。');
    // The status card keeps the two figures that describe "now" - the response and
    // the method - and nothing else. The 30 minute curve and every figure derived
    // from it live in the response band below, so one screen states each fact once.
    const method = state.TradeExit === 'hk' ? profile(state.ActiveProfile) : '代理软件';
    return head('首页','',refresh) + notices() +
      `<section class="hero ${connected ? '' : 'hero-idle'}" aria-label="连接状态"><div class="hero-head"><div><div class="signal-title" role="status" aria-live="polite"><span class="dot ${connected ? 'good' : ''}" aria-hidden="true"></span>${title()}</div><div class="sub">${esc(subtitle)}</div>${connected ? engineRuntime() : ''}</div><div class="actions">${primary}</div></div>${connected ? `<div class="hero-bottom"><div><div class="hero-label-row"><div class="hero-label">当前响应</div>${hint('当前交易出口的 HTTPS 往返响应，含加密建连耗时，不等同于下单延迟','当前响应')}</div><div class="hero-value metric"><span data-testid="quality-current">${latency()}${latency() !== '—' ? '<small>ms</small>' : ''}</span>${qualityBadge()}</div></div><div><div class="hero-label">连接方式</div><div class="hero-value" data-testid="hero-method">${esc(method)}</div></div></div>` : `<div class="hero-caption"><span>${state.State === 'ReadUnknown' ? '状态确认后显示响应' : '连接后显示响应'}</span></div>`}</section>` +
      // The response band owns the curve and the statistics; the status card above
      // owns the current figure, so neither is printed twice.
      responsePanel() +
      `<div class="facts">${guardCard()}${exitFact()}</div>` +
      flowCard() +
      `<div class="section-head"><h2>线路</h2><button class="ghost small" data-page="lines">管理线路 →</button></div>${lineCards(state.Lines, 3)}`;
  }
  function lines() {
    const tasks = state.Tasks || [], providers = state.Providers || [];
    // 0.22.0 A2 entry 1: 「邀请其他电脑」 sits before 用邀请码加入 because managing a
    // server is the rarer, more deliberate action - and it only exists when at
    // least one line really can invite (exactly one manageable server linked).
    // 只有使用权的电脑 never sees it: that is the A-16 requirement.
    // 0.22.2: the header entry carries no line, so it asks. One invitable target
    // goes straight in; two or more open the 选择线路 screen. A build with none
    // keeps the button and says why - a button that silently disappears is the
    // same "nothing happened" the operator already reported once.
    const targets = inviteTargets();
    const inviteEntry = targets.length
      ? inviteButton('邀请其他电脑','Choose','','','ghost',entryBusy())
      : `<button class="ghost" disabled aria-disabled="true" data-testid="invite-unavailable">邀请其他电脑</button>${hint('邀请需要一条关联到可管理服务器的线路：先在「服务器与设备」里登录并启用管理能力。','为什么不能邀请')}`;
    // "添加线路" is now the native three-step page. The legacy invitation form
    // stays reachable as its own exit, never as the primary path.
    // 0.21.2: 用邀请码加入 opens that same page at step 2. It used to post joinLine,
    // which opened the legacy form - one label, two implementations, and the
    // empty-state primary of a brand new user landed on the legacy one.
    return head('线路','',inviteEntry + button('用邀请码加入','pairStart','','ghost',entryBusy()) + button('＋ 添加线路','pairBeginChoose','','primary',entryBusy())) + notices() + lineCards(state.Lines) +
      (tasks.length ? `<div class="section-head"><h2>未完成的添加</h2></div><div class="card">${tasks.map(task => `<div class="task-row"><div><h3>${esc(task.Name)}</h3><p class="muted">${esc(task.Label)}</p></div>${button('继续','resume',task.Id,'small',busy())}</div>`).join('')}</div>` : '') +
      `<div class="section-head"><h2>代理软件</h2>${button('管理接入','providers','','ghost small',busy())}</div><div class="card">${providers.length ? providers.map(provider => `<div class="task-row"><div><h3>${esc(provider.Name)}</h3><p class="muted">${provider.Applied ? '已接入' : '等待准备'}</p></div><span class="badge">${esc(provider.Kind)}</span></div>`).join('') : '<div class="card-pad muted">尚未接入代理软件。</div>'}</div>`;
  }
  // ---- three-step "add line" page -------------------------------------------
  // The step is local state; the host only publishes Pair.Phase. That keeps the
  // snapshot free of presentation state and keeps the page usable while a job is
  // running (the host still owns every side effect).
  function pairStepOf() {
    const p = pairSession();
    if (p) {
      if (p.Phase === 'Creating') return 2;
      if (p.Phase === 'Failed') return pairJoined ? 3 : 2;
      return 3;
    }
    return pairStep;
  }
  // The session this page should act on. A PairId it has already left (a finished
  // join whose host-side session is still being published) is treated as absent, so
  // the first frame after a click is the new step - never the old result card.
  function pairSession() {
    const p = state?.Pair;
    if (!p) { pairIgnoreId = ''; return null; }
    if (pairIgnoreId && p.PairId === pairIgnoreId) return null;
    if (pairIgnoreId) pairIgnoreId = '';
    return p;
  }
  function pairExpiry(value) {
    const at = Date.parse(value || '');
    if (!Number.isFinite(at)) return '';
    const date = new Date(at);
    const clock = `${String(date.getHours()).padStart(2,'0')}:${String(date.getMinutes()).padStart(2,'0')}`;
    // An invitation may now stay valid for up to 24 hours, so a deadline that is
    // not today would read as "earlier today" without the date.
    const now = new Date();
    const sameDay = date.getFullYear() === now.getFullYear() && date.getMonth() === now.getMonth() && date.getDate() === now.getDate();
    if (sameDay) return clock;
    return `${String(date.getMonth() + 1).padStart(2,'0')}-${String(date.getDate()).padStart(2,'0')} ${clock}`;
  }
  function pairStageText() {
    const p = pairSession();
    if (!p) return '';
    const base = p.StageLabel || '';
    if (!['Creating','Authorizing','Preparing'].includes(p.Phase)) return '';
    const since = Date.parse(p.StageChangedAtUtc || '');
    if (!Number.isFinite(since)) return base;
    const seconds = Math.max(0, Math.round((Date.now() - since) / 1000));
    // A stalled stage says so instead of spinning forever: past 30 seconds the
    // elapsed time is shown, past 300 seconds the user is offered a way out.
    if (seconds > 300) return `${base} · ${text('PairNoResult','还没有结果；你可以取消后重新开始，或改用旧版表单')}`;
    if (seconds > 30) return `${base} · ${text('PairStillWorking','仍在处理，已用')} ${seconds} 秒`;
    return base;
  }
  const PAIR_ACTION_LABEL = {Retry:'重试',Reenter:'重新输入',FixName:'修改电脑名称',ContinueCheck:'继续检查',ContinueJoin:'继续加入',UseLegacyForm:'用旧版表单',Diagnostics:'运行诊断'};
  const PAIR_ACTION_CODE = {Retry:'pairRetry',Reenter:'pairReenter',FixName:'pairReenter',ContinueCheck:'pairContinue',ContinueJoin:'pairContinue',UseLegacyForm:'pairLegacy',Diagnostics:'diagnostics'};
  function pairError() {
    const p = pairSession();
    const local = pairDraft.localError;
    if (!local && (!p || p.Phase !== 'Failed' || !p.ErrorCode)) return '';
    const next = local ? 'Reenter' : (p.NextAction || 'Retry');
    const message = local || p.ErrorMessage || text('PairErrorFallback','这一步没有完成');
    const primary = PAIR_ACTION_CODE[next] ? `<button class="small" data-action="${PAIR_ACTION_CODE[next]}" data-testid="pair-error-primary" ${busy() ? 'disabled' : ''}>${PAIR_ACTION_LABEL[next]}</button>` : '';
    return `<div class="pair-error" role="alert"><p data-testid="pair-error">${esc(message)}</p>${primary ? `<div class="actions">${primary}</div>` : ''}${!local && p?.ErrorCode ? `<details><summary>技术详情</summary><span class="mono">${esc(p.ErrorCode)}</span></details>` : ''}</div>`;
  }
  function addLine() {
    const p = pairSession(), step = pairStepOf();
    const stepper = `<div class="stepper" data-testid="pair-step" data-step="${step}">${[['1','选择方式'],['2','粘贴邀请码'],['3','加入这台电脑']].map(([number,label], index) => `<span class="step${index + 1 === step ? ' current' : ''}${index + 1 < step ? ' done' : ''}"><i>${number}</i>${label}</span>`).join('')}</div>`;
    let body;
    if (step === 1) {
      body = `<div class="pair-choice"><button class="pair-option" data-action="pairChooseCode"><strong>我有邀请码</strong><span>推荐。由管理电脑生成，只能用一次。</span></button><button class="pair-option" data-action="pairChooseBuild"><strong>自己搭一台服务器</strong><span>进阶。需要一台云服务器，部署后本机直接获得线路。</span></button></div>`;
    } else if (step === 2) {
      const checking = p?.Phase === 'Creating';
      body = `<div class="pair-form">${checking ? `<div class="pair-progress" role="status"><span class="spinner" aria-hidden="true"></span><span data-testid="pair-stage">${esc(pairStageText())}</span></div>` : ''}<label class="pair-field"><span>一次性邀请码</span><input id="pair-code" data-testid="pair-code" data-secret="true" data-secret-present="true" data-pair-input="code" type="text" maxlength="2048" autocomplete="off" spellcheck="false" aria-label="一次性邀请码" placeholder="粘贴以 TCI1. 开头的邀请码" ${entryBusy() ? 'disabled' : ''}></label><label class="pair-field"><span>这台电脑的名称${hint('会登记在服务器上，之后可由管理电脑在「服务器与设备」里修改；线路名可以随时在线路页重命名。','这台电脑的名称')}</span><input id="pair-device" data-testid="pair-device" data-pair-input="device" type="text" maxlength="64" aria-label="这台电脑的名称" value="${esc(pairDraft.device || p?.DeviceName || '')}" ${entryBusy() ? 'disabled' : ''}></label><div class="actions">${button(checking ? '正在确认邀请码' : '校验','pairVerify','','primary',entryBusy())}</div>${pairError()}</div>`;
    } else {
      // A join in Preparing is running whoever started it: this page's pairJoined
      // flag is local and starts false after a restart or a re-entry, and a running
      // join must show its progress rather than an 加入这台电脑 button (0.21.8 A0-04).
      const running = ['Authorizing','Preparing'].includes(p?.Phase) && (pairJoined || p.Phase === 'Preparing');
      const finished = !!p && ['Complete','NeedsCheck'].includes(p.Phase);
      const summary = finished ? `${p.Phase === 'Complete' ? '线路已加入。' : '线路已保存，还需要完成这台电脑的连接检查。'}${text('PairNoTakeover','它现在不会接管交易，确认能用之后再切换')}` : '';
      // A finished join keeps both ways forward inside the card (0.21.8 A0): the
      // footer used to offer 取消 right after success, which reads as "undo the line
      // I just added", so users stopped there instead of pressing it.
      const resultActions = finished ? `<div class="actions">${button(p.Phase === 'Complete' ? '去线路页' : '继续检查','pairContinue','','primary',entryBusy())}${button('再添加一条线路','pairBeginChoose','','ghost',entryBusy())}</div>` : '';
      body = `<div class="pair-form">${running ? `<div class="pair-progress" role="status"><span class="spinner" aria-hidden="true"></span><span data-testid="pair-stage">${esc(pairStageText())}</span></div>` : ''}${finished ? `<div class="pair-result"><h3>${p.Phase === 'Complete' ? '线路已加入' : '线路已保存'}</h3><p data-testid="pair-summary">${esc(summary)}</p>${resultActions}</div>` : ''}${!finished && !pairJoined ? `<label class="pair-field"><span>线路名（可以改）</span><input id="pair-name" data-testid="pair-name" data-pair-input="name" type="text" maxlength="64" aria-label="线路名" value="${esc(pairDraft.name || p?.LocalName || p?.NodeName || '加入的线路')}" ${entryBusy() ? 'disabled' : ''}></label><div class="actions">${button('加入这台电脑','pairJoin','','primary',entryBusy())}</div>` : ''}${p?.Host ? `<div class="pair-host"><span class="mono" data-testid="pair-host">${esc(p.Host)}</span>${p.ExpiresAtUtc ? `<span class="muted" data-testid="pair-expires">有效期至 ${esc(pairExpiry(p.ExpiresAtUtc))}</span>` : ''}</div>` : ''}${pairError()}</div>`;
    }
    // The footer follows the session, not the step (0.21.8 A0). 取消 belongs to a
    // running join and to a failed one: nothing was added yet, so abandoning the
    // attempt is honest there. After success it is gone - it read as "undo the line
    // I just added" - and 重置 becomes 再添加一条线路.
    const pairRunning = ['Creating','Authorizing','Preparing'].includes(p?.Phase);
    const pairFinished = ['Complete','NeedsCheck'].includes(p?.Phase);
    const pairCancelButton = `<button class="ghost small" data-action="pairCancel" data-testid="pair-cancel">取消</button>`;
    const pairLegacyButton = `<button class="ghost small" data-action="pairLegacy" data-testid="pair-legacy">遇到问题，用旧版表单</button>`;
    const footer = pairRunning
      ? pairCancelButton
      : pairFinished
        ? `<button class="ghost small" data-action="pairBeginChoose" data-testid="pair-restart">再添加一条线路</button>` + pairLegacyButton
        : (p ? pairCancelButton : '') + `<button class="ghost small" data-action="pairReset" data-testid="pair-reset">重新开始</button>` + pairLegacyButton;
    return `<div class="breadcrumb"><button class="ghost small" data-page="lines">← 返回线路</button></div>` + head('添加线路','') + notices() + stepper + `<section class="card pair-card">${body}</section>` + `<div class="pair-footer">${footer}</div>`;
  }
  function pairField(name) { return document.querySelector(`[data-pair-input=${name}]`); }
  // The legacy join form named the device after this computer; keep that default
  // once, so a name the user clears stays cleared.
  function seedPairDevice() { if (!pairDraft.device && !pairSession()?.DeviceName && typeof state?.PairDeviceDefault === 'string') pairDraft.device = state.PairDeviceDefault.slice(0, 64); }
  function pairAction(action) {
    const p = pairSession();
    if (action === 'pairChooseCode') { pairStep = 2; pairDraft.localError = ''; seedPairDevice(); render(); return; }
    // 0.21.8 A0: both entries ask the host to open a fresh page instead of only
    // navigating. The host silently clears the finished session it was still
    // publishing; until that snapshot arrives pairIgnoreId keeps the old session
    // out of the first frame, so step 1 (or step 2) is what the user sees.
    // 0.21.2: every 用邀请码加入 outside this page lands here, on step 2 of the same
    // native flow that 添加线路 → 我有邀请码 reaches. joinLine (the legacy form)
    // is only posted by the explicit 用旧版表单 exit below.
    if (action === 'pairBeginChoose' || action === 'pairStart') {
      const beginCode = action === 'pairStart';
      const inProgress = !!p && ['Creating','Authorizing','Preparing'].includes(p.Phase);
      // An in-progress join keeps its progress: only a finished session is ignored.
      if (p && !inProgress) pairIgnoreId = p.PairId;
      if (!inProgress) pairJoined = false;
      pairDraft.localError = ''; pairDraft.name = '';
      pairStep = beginCode ? 2 : 1;
      if (beginCode) {
        seedPairDevice();
        const input = pairField('code'); if (input) input.value = '';
      }
      post('pairOnline', {Phase: beginCode ? 'BeginCode' : 'BeginChoose'}, true);
      render(); return;
    }
    if (action === 'pairChooseBuild') { post('add', {}, true); render(); return; }
    if (action === 'pairVerify' || action === 'pairRetry') {
      const code = (pairField('code')?.value || '').trim(), device = (pairField('device')?.value || '').trim();
      // Format is checked here so an obviously wrong paste never costs a round
      // trip; the host still owns every real validation.
      if (!code || !/^TCI1\.[A-Za-z0-9_-]+$/.test(code)) { pairDraft.localError = '请粘贴完整的一次性邀请码'; render(); return; }
      if (!device || device.length > 64) { pairDraft.localError = '电脑名称请使用 1–64 个字符'; render(); return; }
      pairDraft.device = device; pairDraft.localError = ''; pairStep = 2;
      post('pairOnline', {Phase:'Verify', Id:p?.PairId || '', Code:code, Name:device}, true);
      render(); return;
    }
    if (action === 'pairJoin') {
      const name = (pairField('name')?.value || '').trim() || '加入的线路';
      pairDraft.name = name; pairJoined = true;
      post('pairOnline', {Phase:'Join', Id:p?.PairId || '', Name:name}, true);
      render(); return;
    }
    if (action === 'pairCancel' || action === 'pairReset') {
      pairJoined = false; pairStep = 1; pairDraft.localError = ''; pairDraft.name = '';
      post('pairOnline', {Phase: action === 'pairCancel' ? 'Cancel' : 'Reset', Id:p?.PairId || ''}, true);
      render(); return;
    }
    if (action === 'pairReenter') { pairStep = 2; pairJoined = false; pairDraft.localError = ''; render(); return; }
    if (action === 'pairContinue') { post('navigate', {Page:'lines'}, true); return; }
    if (action === 'pairLegacy') { post('joinLine', {}, true); render(); return; }
  }
  // A new session generation must not inherit the previous invitation code. This
  // is the only place in this file that writes input.value directly; it exists
  // because reconcile() deliberately preserves secret fields.
  function syncPairEpoch() {
    const epoch = state?.Pair?.Epoch ?? null;
    if (!pairEpochSeen) { pairEpochSeen = true; pairEpoch = epoch; pairHadSession = epoch !== null; return; }
    if (epoch === pairEpoch) return;
    const previous = pairEpoch; pairEpoch = epoch;
    const firstSession = previous === null && epoch !== null && !pairHadSession;
    if (epoch !== null) pairHadSession = true;
    // The first session of this page is the one the pasted code created, so it
    // must survive. Any later generation (cancel, reset, a new attempt after a
    // finished one) clears the field.
    if (firstSession) return;
    const input = pairField('code'); if (input) input.value = '';
    pairDraft.localError = '';
  }
  // ---- 0.22.0 A2 / 0.22.2 「邀请其他电脑」 page ---------------------------------
  // Four screens, one job each: 选择线路 → 设置 → 已生成 → 已结束. The result is a
  // STATE, not a step, so there is no stepper and no 「上一步」 once a code exists.
  // Everything renders from host state; the only local state is which line the
  // operator picked and whether the cancel confirmation is armed.
  const INVITE_PRESETS = [[600,'10 分钟'],[1800,'30 分钟'],[7200,'2 小时'],[86400,'24 小时']];
  const INVITE_RISK = '邀请码只能用一次。有效期越长，被转发或泄露后可用的时间越长。';
  const INVITE_STAGES = {'Loading':'正在登录服务器','LoggingIn':'正在登录服务器','Creating':'正在生成邀请码','Checking':'正在检查 18443 能否连通'};
  let inviteLifetime = 0, inviteExpiryKey = '', inviteTarget = null, inviteConfirm = false;
  function inviteView() { const view = state?.Invite; return view && typeof view === 'object' ? view : null; }
  function inviteBusy(view) { return ['Loading','LoggingIn','Creating','Checking'].includes(view?.Phase); }
  // A2: an invitation belongs to a server, and a line is how the operator names it.
  // Lines that share one server are ONE choice - offering both would be a choice
  // with two identical outcomes. This is also what keeps 「选择线路」 honest when a
  // server ever carries more than one line.
  function inviteTargets() {
    const groups = new Map();
    for (const item of (state.Lines || [])) {
      if (!item.CanInvite || !item.ServerRecordId) continue;
      let group = groups.get(item.ServerRecordId);
      if (!group) { group = {serverId:item.ServerRecordId, lines:[]}; groups.set(item.ServerRecordId, group); }
      group.lines.push(item);
    }
    return [...groups.values()].map(group => {
      const many = group.lines.length > 1;
      const name = many ? (group.lines[0].ServerName || '这台服务器') : group.lines[0].Name;
      return {
        serverId: group.serverId, lineId: group.lines[0].Id, name,
        label: many ? `${name}（${group.lines.length} 条线路）` : name,
        note: many ? '这台服务器上的线路都可用' : ''
      };
    });
  }
  function inviteStage(view) {
    if (view && view.InviteId && view.State === 'Open') return 'result';
    if (view && view.InviteId && view.State) return 'ended';
    const targets = inviteTargets();
    if (!targets.length) return 'none';
    if (view && view.ServerId && targets.some(item => item.serverId === view.ServerId)) return 'setup';
    if (!inviteTarget && targets.length > 1) return 'choose';
    return 'setup';
  }
  function inviteCurrent(view, targets) {
    // The host's ServerId wins: once the page is open it is the truth, and a pick
    // left over from a previous visit must not relabel this invitation.
    const hit = view?.ServerId ? targets.find(item => item.serverId === view.ServerId) : null;
    return hit || inviteTarget || targets[0] || null;
  }
  function inviteBackLabel(view) { return view?.Origin === 'server' ? '← 返回服务器' : '← 返回线路'; }
  function inviteCustomSeconds() {
    const raw = String(inviteCustom.amount || '').trim();
    if (!/^\d{1,4}$/.test(raw)) return null;
    const value = Number(raw);
    if (inviteCustom.unit === 'Hours') return value >= 1 && value <= 24 ? value * 3600 : null;
    return value >= 10 && value <= 1440 ? value * 60 : null;
  }
  function inviteChosen(view) {
    if (inviteCustom.on) return inviteCustomSeconds();
    const local = Number(inviteLifetime);
    if (Number.isFinite(local) && local > 0) return local;
    const saved = Number(view?.LifetimeSeconds);
    return Number.isFinite(saved) && saved > 0 ? saved : 1800;
  }
  function inviteStateLabel(view) {
    switch (view?.State) {
      case 'Open': return {label:'待使用', tone:'good'};
      case 'Consumed': return {label:'已被使用', tone:''};
      case 'Cancelled': return {label:'已取消', tone:''};
      case 'Expired': return {label:'已过期', tone:'warn'};
      default: return view?.State ? {label:String(view.State), tone:''} : null;
    }
  }
  // A4: the probe describes this computer's network only, so the sentence never
  // claims the invitation is healthy - it says whether 18443 answered from here.
  function inviteReachability(view) {
    const probe = view?.Reachability;
    if (!probe || typeof probe !== 'object') return '';
    const port = Number(probe.Port) || 18443;
    switch (probe.Status) {
      case 'Checking': return `正在检查 ${port} 能否连通`;
      case 'Reachable': return '';
      case 'Refused': return `${port} 连不上（连接被拒绝）：请在云服务器防火墙放行 TCP ${port}`;
      case 'Timeout': return `${port} 没有响应：请检查云服务器防火墙是否放行 TCP ${port}`;
      case 'TlsMismatch': return `${port} 的证书与邀请码不一致：端口可能被其他服务占用，或服务与这张邀请码不匹配`;
      case 'TlsFailed': return `${port} 的加密握手没有完成，请稍后重试`;
      default: return `${port} 检查没有完成，可以先复制邀请码试试`;
    }
  }
  const inviteButton = (label, phase, id = '', value = '', cls = '', disabled = false) =>
    `<button class="${cls}" data-invite="${phase}" data-id="${esc(id)}" data-value="${esc(String(value))}" ${disabled ? 'disabled' : ''}>${label}</button>`;
  function inviteScreen(back, title, description, body, footer = '') {
    return `<div class="breadcrumb"><button class="ghost small" data-invite="Close">${esc(back)}</button></div>`
      + head(title, description) + notices()
      + `<section class="card pair-card invite-card">${body}</section>`
      + (footer ? `<div class="pair-footer split">${footer}</div>` : '');
  }
  function inviteChoose(targets, view) {
    const options = targets.map(item => `<button class="pair-option" data-invite="Target" data-id="${esc(item.lineId)}" data-value="${esc(item.serverId)}"><strong>${esc(item.label)}</strong>${item.note ? `<span>${esc(item.note)}</span>` : ''}</button>`).join('');
    return inviteScreen(inviteBackLabel(view), '邀请其他电脑', '选择这台新电脑要加入的线路。', `<div class="pair-choice">${options}</div>`);
  }
  function inviteNone(view) {
    return inviteScreen(inviteBackLabel(view), '邀请其他电脑', '',
      '<h2>没有可以邀请的线路</h2><p class="muted">邀请需要一条关联到可管理服务器的线路：先在「服务器与设备」里登录并启用管理能力。</p>');
  }
  function inviteLoading(view) {
    return inviteScreen(inviteBackLabel(view), '邀请其他电脑', '',
      '<div class="pair-progress" role="status"><span class="spinner" aria-hidden="true"></span><span>正在读取这条线路的邀请状态…</span></div>');
  }
  function inviteEnded(view, current) {
    const tag = inviteStateLabel(view) || {label:'已结束'};
    const consequence = {
      Consumed: '新电脑已经加入这条线路，可以在线路页看到它。',
      Expired: '这张邀请码已经过期，没有电脑能再用它。',
      Cancelled: '这张邀请码已作废，没有电脑能再用它。'
    }[view.State] || '这张邀请码已经结束。';
    const due = view.ExpiresAtUtc ? ` · ${pairExpiry(view.ExpiresAtUtc)} 失效` : '';
    const body = `<h2>${esc(tag.label === '待使用' ? '邀请已结束' : tag.label)}</h2>`
      + `<p class="invite-line" data-testid="invite-line">${esc(current?.label || '')}${esc(due)}</p>`
      + `<p class="muted" data-testid="invite-consequence">${esc(consequence)}</p>`;
    const footer = view.State === 'Consumed'
      ? inviteButton('再邀请一台','Choose','','','ghost') + inviteButton('完成','Close','','','primary')
      : inviteButton('完成','Close','','','ghost') + inviteButton('再生成一个','CreateNew','','','primary');
    return inviteScreen(inviteBackLabel(view), '邀请其他电脑', '', body, footer);
  }
  function inviteSetup(view, current, targets, busy) {
    const presets = Array.isArray(view.LifetimePresets) && view.LifetimePresets.length ? view.LifetimePresets.map(Number) : INVITE_PRESETS.map(item => item[0]);
    const chosen = inviteChosen(view);
    const label = seconds => (INVITE_PRESETS.find(item => item[0] === seconds) || [0, `${Math.round(seconds / 60)} 分钟`])[1];
    const lineRow = `<div class="detail-row"><span>线路</span><span><span data-testid="invite-line">${esc(current?.label || '未选择')}</span>${targets.length > 1 ? ' ' + inviteButton('更改','Choose','','','small ghost',busy) : ''}</span></div>`;
    const lifetimeRow = `<div class="detail-row"><span>有效期</span><span class="seg-group" role="group" aria-label="邀请码有效期">${presets.map(seconds => `<button class="seg${!inviteCustom.on && chosen === seconds ? ' on' : ''}" data-invite="Lifetime" data-id="" data-value="${seconds}" aria-pressed="${!inviteCustom.on && chosen === seconds}" ${busy || entryBusy() ? 'disabled' : ''}>${label(seconds)}</button>`).join('')}<button class="seg${inviteCustom.on ? ' on' : ''}" data-invite="LifetimeCustom" data-id="" data-value="" aria-pressed="${inviteCustom.on}" ${busy || entryBusy() ? 'disabled' : ''}>自定义</button></span><span data-testid="invite-risk">${hint(INVITE_RISK,'邀请码有效期')}</span></div>`;
    const customRow = inviteCustom.on
      ? `<div class="invite-custom"><input id="invite-amount" data-invite-input="amount" type="number" inputmode="numeric" min="1" max="1440" step="1" value="${esc(inviteCustom.amount)}" aria-label="有效期长度" ${busy ? 'disabled' : ''}><span class="seg-group" role="group" aria-label="单位"><button class="seg${inviteCustom.unit === 'Minutes' ? ' on' : ''}" data-invite="Unit" data-id="" data-value="Minutes" aria-pressed="${inviteCustom.unit === 'Minutes'}">分钟</button><button class="seg${inviteCustom.unit === 'Hours' ? ' on' : ''}" data-invite="Unit" data-id="" data-value="Hours" aria-pressed="${inviteCustom.unit === 'Hours'}">小时</button></span></div>${chosen === null ? '<p class="delete-hint warn-text" data-testid="invite-custom-hint">分钟请填 10–1440，小时请填 1–24 的整数。</p>' : ''}`
      : '';
    const compat = view.CompatNoteVisible ? `<div class="notice" data-testid="invite-compat"><span>超过 30 分钟的邀请码需要新电脑使用 0.22.0 或更高版本；旧版本会提示有效期超过上限。</span></div>` : '';
    const stage = INVITE_STAGES[view.Phase] || '';
    const progress = busy ? `<div class="pair-progress" role="status" data-testid="invite-stage" data-stage="${esc(view.Phase)}"><span class="spinner" aria-hidden="true"></span><span data-testid="invite-stage-label">${esc(view.StageLabel || stage)}</span><span class="muted" data-elapsed data-start="${esc(view.StageChangedAtUtc || '')}">0 秒</span></div>` : '';
    const loginBlocked = view.ErrorCode === 'SavedLoginRequired';
    const body = `${lineRow}${lifetimeRow}${customRow}${compat}${progress}<div class="actions">${inviteButton('生成邀请码','CreateNew','','','primary',entryBusy() || busy || chosen === null || loginBlocked)}</div>${inviteError(view)}`;
    // 顶部面包屑已经是同一个 Close 动作，底部不再重复一个「返回」出口。
    const footer = (targets.length > 1 ? inviteButton('上一步','Choose','','','ghost') : '');
    return inviteScreen(inviteBackLabel(view), '邀请其他电脑', '', body, footer);
  }
  function inviteResult(view, current, busy) {
    const tag = inviteStateLabel(view);
    const due = Date.parse(view.ExpiresAtUtc || '');
    const left = Number.isFinite(due) ? Math.max(0, Math.round((due - Date.now()) / 1000)) : null;
    const when = view.ExpiresAtUtc ? `${pairExpiry(view.ExpiresAtUtc)} 失效` : '';
    const counter = left !== null ? `（还剩 ${mmss(left)}）` : '';
    const meta = `<p class="invite-line" data-testid="invite-expires">${esc(current?.label || '')}${when ? ' · ' + esc(when) : ''}${esc(counter)}</p>`;
    if (!view.CodePresent) {
      const body = `${meta}<p class="muted" data-testid="invite-code-missing">这张邀请码仍然有效，但这台电脑已不再持有它的内容。</p>`
        + `<div class="actions">${inviteButton('作废这张邀请码','Cancel','','','danger-ghost',entryBusy() || busy)}</div>`
        + (inviteConfirm ? inviteCancelConfirm() : '');
      return inviteScreen(inviteBackLabel(view), '邀请码仍有效', '', body, inviteButton('完成','Close','','','primary'));
    }
    const shown = inviteRevealed && inviteCodeLocal ? inviteCodeLocal : (view.CodePreview || '邀请码已生成');
    const reach = inviteReachability(view);
    const body = `${meta}
      <div class="invite-code"><input id="invite-code" class="mono" data-testid="invite-code" data-secret="true" type="text" readonly autocomplete="off" spellcheck="false" aria-label="邀请码" value="${esc(shown)}">${inviteButton('复制邀请码','Copy','','','primary',entryBusy() || busy)}${inviteButton(inviteRevealed ? '隐藏' : '显示','Reveal','','','ghost',entryBusy() || busy)}</div>
      ${reach ? `<p class="invite-reach" data-testid="invite-reach">${esc(reach)}</p>` : ''}
      <details class="invite-more"><summary>新电脑怎么用</summary><p class="footnote">在新电脑上打开 TradeChannel → 添加线路 → 我有邀请码，粘贴后点校验。</p></details>
      <details class="invite-more"><summary>连不上 ${Number(view.Reachability?.Port) || 18443} 怎么办</summary><p class="footnote">确认云服务器防火墙已放行 TCP ${Number(view.Reachability?.Port) || 18443}，再点「重新检查」。仍不通可以改用离线邀请（24 小时，不能在线撤销）。</p><div class="actions">${inviteButton('重新检查','Recheck','','','small ghost',entryBusy() || busy)}${inviteButton('重新开启接收服务','Rearm','','','small ghost',entryBusy() || busy)}${inviteButton('改用离线邀请','Offline','','','small ghost',entryBusy() || busy)}</div></details>
      ${inviteConfirm ? inviteCancelConfirm() : ''}`;
    const footer = inviteButton('取消邀请码','CancelConfirm','','','danger-ghost',entryBusy() || busy) + inviteButton('完成','Close','','','ghost');
    return inviteScreen(inviteBackLabel(view), '邀请码已生成', '', body, footer);
  }
  function inviteCancelConfirm() {
    return `<div class="pair-error" role="alert" data-testid="invite-cancel-confirm"><p>作废这张邀请码？已经拿到它的电脑将无法加入。</p><div class="actions">${inviteButton('继续作废','Cancel','','','danger')}${inviteButton('返回','CancelAbort','','','ghost')}</div></div>`;
  }
  function inviteError(view) {
    if (!view.ErrorCode && !view.ErrorMessage) return '';
    const next = view.NextAction || 'None';
    const loginBlocked = ['SavedLoginRequired','SavedLoginUnavailable','ManagementLoginRequired'].includes(view.ErrorCode);
    const action = next === 'OpenServer'
      ? inviteButton(loginBlocked ? '去登录' : '去服务器页处理','OpenServer','','','small',false)
      : next === 'CancelRetry' ? inviteButton('作废并重新生成','CancelRetry','','','small',entryBusy())
      : next === 'Retry' ? inviteButton('重试','Retry','','','small',entryBusy()) : '';
    return `<div class="pair-error" role="alert"><p data-testid="invite-error">${esc(view.ErrorMessage || '这一步没有完成')}</p>${action ? `<div class="actions">${action}</div>` : ''}${view.ErrorCode ? `<details><summary>技术详情</summary><span class="mono">${esc(view.ErrorCode)}</span></details>` : ''}</div>`;
  }
  function invite() {
    const view = inviteView();
    const stage = inviteStage(view);
    const targets = inviteTargets();
    const current = inviteCurrent(view, targets);
    if (stage === 'choose') return inviteChoose(targets, view);
    if (stage === 'none') return inviteNone(view);
    if (!view) return inviteLoading(view);
    const busy = inviteBusy(view);
    if (!inviteLifetime && Number(view.LifetimeSeconds) > 0) inviteLifetime = Number(view.LifetimeSeconds);
    if (stage === 'result') return inviteResult(view, current, busy);
    if (stage === 'ended') return inviteEnded(view, current);
    return inviteSetup(view, current, targets, busy);
  }
  function inviteField() { return document.getElementById('invite-amount'); }
  // The only place that writes the revealed code: reconcile() deliberately keeps
  // secret fields out of the snapshot round trip.
  function syncInviteEpoch() {
    const view = inviteView();
    const key = `${view?.Epoch ?? ''}|${view?.InviteId || ''}`;
    if (inviteEpochSeen === null) { inviteEpochSeen = key; inviteEpochHadValue = !!view?.InviteId; return; }
    if (key === inviteEpochSeen) return;
    inviteEpochSeen = key;
    inviteEpochHadValue = !!view?.InviteId;
    inviteRevealed = false;
    inviteCodeLocal = '';
    inviteExpiryKey = '';
    const input = document.getElementById('invite-code');
    if (input) input.value = '';
  }
  function inviteAction(action, id, value) {
    if (action === 'Choose') {
      const targets = inviteTargets();
      if (!targets.length) { render(); return; }
      if (targets.length === 1) {
        inviteTarget = targets[0];
        post('invite', {Phase:'Begin', Id:targets[0].lineId}, true);
      } else {
        inviteTarget = null;
        post('navigate', {Page:'invite'}, true);
      }
      render(); return;
    }
    if (action === 'Target') {
      inviteTarget = inviteTargets().find(item => item.serverId === value) || null;
      post('invite', {Phase:'Begin', Value:value}, true);
      render(); return;
    }
    if (action === 'Begin') {
      inviteTarget = inviteTargets().find(item => item.lineId === id) || inviteTarget;
      post('invite', {Phase:'Begin', Id:id || ''}, true);
      render(); return;
    }
    if (action === 'Lifetime') {
      inviteCustom.on = false; inviteLifetime = Number(value) || 0;
      render(); return;
    }
    if (action === 'LifetimeCustom') { inviteCustom.on = true; render(); return; }
    if (action === 'Unit') { inviteCustom.unit = value === 'Hours' ? 'Hours' : 'Minutes'; render(); return; }
    if (action === 'CreateNew') {
      const chosen = inviteChosen(inviteView());
      if (!chosen) { render(); return; }
      inviteConfirm = false;
      post('invite', {Phase:'CreateNew', Value:chosen}, true); render(); return;
    }
    if (action === 'CancelConfirm') { inviteConfirm = true; render(); return; }
    if (action === 'CancelAbort') { inviteConfirm = false; render(); return; }
    const phase = {Copy:'Copy',Reveal:'Reveal',Cancel:'Cancel',CancelRetry:'CancelRetry',Retry:'Retry',Rearm:'Rearm',Refresh:'Refresh',Recheck:'Recheck',OpenServer:'OpenServer',Offline:'Offline',Close:'Close'}[action];
    if (!phase) return;
    if (action === 'Cancel') inviteConfirm = false;
    post('invite', {Phase:phase, Id:id || ''}, true);
    render();
  }
  function select(id, items, value, label, disabled = false) {
    return `<select id="${id}" aria-label="${esc(label)}" ${busy() || disabled ? 'disabled' : ''}>${items.map(([key, text]) => `<option value="${key}" ${key === value ? 'selected' : ''}>${esc(text)}</option>`).join('')}</select>`;
  }
  function apps() {
    // 0.22.0 B5 / C-R9 / C-R11: explanations live in ⓘ, terminology is 日常上网 /
    // AI 工具 / 交易软件, and the AI choice is disabled while daily traffic itself
    // uses the trade line - both would end up on the same exit, so the choice
    // would silently do nothing.
    const global = state.Daily === 'Trade';
    return head('应用') + notices() + `<div class="card group-card" data-testid="apps-group">`
      + `<div class="app-row"><div class="app-icon">↗</div><div><h3>交易软件${hint('行情、订单与交易网站使用交易线路。', '交易软件')}</h3></div><button data-page="lines">选择线路</button></div>`
      + `<div class="app-row"><div class="app-icon">◎</div><div><h3>日常上网${hint('浏览器与日常软件的连接方式。', '日常上网')}</h3></div>${select('daily',[['Direct','本地直连'],['Provider','使用代理软件'],['Trade','使用交易线路']],state.Daily,'日常上网走向')}</div>`
      + `<div class="app-row"><div class="app-icon">✧</div><div><h3>AI 工具${hint('名单中的工具可单独使用交易线路。', 'AI 工具')}</h3>${global ? '<p class="app-description" data-testid="agents-global-note">日常上网走交易线路时，AI 工具也走交易线路。</p>' : ''}</div>${select('agents',[['Daily','跟随日常上网'],['Trade','使用交易线路']],state.Agents,'AI 工具走向',global)}</div></div>`
      + `<div class="section-head"><h2>应用名单</h2></div><div class="grid-two">`
      + `<div class="card card-pad"><h3>交易软件与网站${hint('选择程序与网站，查看当前生效的名单。', '交易软件与网站')}</h3><div class="actions">${button('管理交易名单','domains','','ghost',busy())}</div></div>`
      + `<div class="card card-pad"><h3>AI 工具${hint('选择工具，也可以添加自定义网站。', 'AI 工具名单')}</h3><div class="actions">${button('管理工具名单','agentsList','','ghost',busy())}</div></div></div>`
      + (isConnected() ? '' : '<p class="footnote">未连接时，修改会保存供下次连接使用。</p>');
  }
  function settingSwitch(name, checked, label, disabled = false) {
    return `<button class="switch" role="switch" aria-label="${esc(label)}" aria-checked="${!!checked}" data-setting="${name}" ${busy() || disabled ? 'disabled' : ''}></button>`;
  }
  function settings() {
    // 0.22.0 B5: the description paragraph under each row becomes a ⓘ; only the
    // sentence that describes the current state (自动连接需要保持此项开启) stays
    // on screen.
    const options = state.Settings || {};
    const row = (title, hintText, control, note = '') => `<div class="setting-row"><div><h3>${title}${hintText ? hint(hintText, title) : ''}</h3>${note ? `<p>${note}</p>` : ''}</div>${control}</div>`;
    return head('设置') + notices()
      + `<div class="section-head first"><h2>启动与窗口</h2></div><div class="card group-card" data-testid="settings-group">`
      + row('登录后打开 TradeChannel', '登录 Windows 后打开控制台。', settingSwitch('OpenAtLogin',options.OpenAtLogin,'登录后打开 TradeChannel',!!options.AutoConnectOnLogin), options.AutoConnectOnLogin ? '自动连接需要保持此项开启。' : '')
      + row('登录后自动连接上次线路', '默认关闭。开启后尝试一次；交易软件已打开时暂停连接。', settingSwitch('AutoConnectOnLogin',options.AutoConnectOnLogin,'登录后自动连接上次线路'))
      + row('关闭窗口时', '两种方式都会保留当前连接。', select('close-behavior',[['Tray','收起到托盘'],['ExitInterface','退出界面']],options.CloseBehavior || 'Tray','关闭窗口时'))
      + `</div><div class="section-head"><h2>连接</h2></div><div class="card">`
      + row('自动记住首次服务器身份', '身份变化时拦截。关闭后，首次连接需要确认。', settingSwitch('AutoTrustFirstConnection',options.AutoTrustFirstConnection,'自动记住首次服务器身份'))
      + row('线路变差提醒', '连续多次异常时提醒，由你决定是否换线。关闭后仍可在线路页查看质量。', settingSwitch('QualityWarning',options.QualityWarning !== false,'线路变差提醒'))
      + `</div><div class="section-head"><h2>外观</h2></div><div class="card"><div class="setting-row"><h3>界面主题</h3><select id="theme" aria-label="界面主题"><option value="system" ${theme === 'system' ? 'selected' : ''}>跟随系统</option><option value="light" ${theme === 'light' ? 'selected' : ''}>浅色</option><option value="dark" ${theme === 'dark' ? 'selected' : ''}>深色</option></select></div></div>`
      + `<div class="section-head"><h2>工具</h2></div><div class="tool-grid">${[['diagnostics','运行诊断','查看连接、保护状态与最近事件'],['history','操作记录','查看部署、配置和维护记录'],['maintenance','维护与恢复','处理未完成的连接或代理设置']].map(([action, label, description]) => `<button class="card tool-link" data-action="${action}" ${entryBusy() ? 'disabled' : ''}><span><strong>${label}</strong><small>${description}</small></span><span aria-hidden="true">↗</span></button>`).join('')}</div>`
      + `<div class="settings-footer">${button('创建桌面快捷方式','desktopShortcut','','ghost small',busy())}</div>`;
  }

  // Workflows share one set of accessible controls and the same theme as the
  // four main pages. Only opaque handles issued by the host are actionable.
  // 0.22.0 B2：宿主序列化器下发的 Hint（AutomationProperties.HelpText）统一渲染成
  // 悬浮说明按钮，不再挂原生 title——禁用的控件也能看说明，键盘与触屏同样可达。
  const hintFor = (node, label) => node && node.Hint ? hint(String(node.Hint), String(label || '更多说明')) : '';
  const fieldLabel = node => node.Label || node.Text || node.Name || '输入内容';
  // 与 web/forms.css 的 [data-colspec] 规则一一对应；未登记的形态不加属性，走老 flex 路径。
  // tests/Test-WebForms.ps1 的静态对照断言守着这三份清单（宿主 / CSS / 这里）。
  const COLSPEC = new Set(['*|Auto','*|Auto|Auto','Auto|*|Auto','Auto|*','*|*','Auto|34px|34px',
                           '96px|*','128px|*','*|260px|Auto','*|16px|*|16px|*','*|16px|*','*|32px|*',
                           '*|90px|120px|150px']);
  // Icon() 在宿主侧用 24×24 的 Path 画；这里还原同一份几何，避免另造一套图形。
  const WF_ICONS = {
    trade:'M 3 17 L 9 11 L 13 15 L 21 7 M 15 7 L 21 7 L 21 13',
    globe:'M 21 12 A 9 9 0 1 1 3 12 A 9 9 0 1 1 21 12 M 3 12 L 21 12 M 12 3 C 7 8 7 16 12 21 C 17 16 17 8 12 3',
    shield:'M 12 3 L 19.5 6 L 19 13 C 18.5 17.5 15.5 20 12 21.5 C 8.5 20 5.5 17.5 5 13 L 4.5 6 Z M 8.8 12.2 L 11 14.4 L 15.4 9.8',
    pulse:'M 3 12 L 7 12 L 9.5 6 L 14 18 L 16.5 12 L 21 12',
    server:'M 4 4 L 20 4 L 20 10 L 4 10 Z M 4 14 L 20 14 L 20 20 L 4 20 Z M 7.5 7 L 7.6 7 M 7.5 17 L 7.6 17',
    laptop:'M 5 5 L 19 5 L 19 15 L 5 15 Z M 2.5 19 L 21.5 19',
    key:'M 14.5 3.5 A 5 5 0 1 1 9.5 8.5 A 5 5 0 0 1 14.5 3.5 M 10.5 12.5 L 3.5 19.5 L 3.5 21 L 6.5 21 L 6.5 18.5 L 9 18.5 L 11.5 16',
    folder:'M 3 6.5 L 3 19 L 21 19 L 21 8 L 11.5 8 L 9.5 5 L 3 5 Z',
    document:'M 6 3 L 14.5 3 L 19 7.5 L 19 21 L 6 21 Z M 14.5 3 L 14.5 7.5 L 19 7.5 M 9 12.5 L 16 12.5 M 9 16 L 16 16',
    move:'M 4 8 L 18 8 M 14.5 4.5 L 18 8 L 14.5 11.5 M 20 16 L 6 16 M 9.5 12.5 L 6 16 L 9.5 19.5',
    info:'M 21 12 A 9 9 0 1 1 3 12 A 9 9 0 1 1 21 12 M 12 11 L 12 16.5 M 12 7.6 L 12 7.8',
    alert:'M 12 3.5 L 21.5 20 L 2.5 20 Z M 12 9.5 L 12 14 M 12 17 L 12 17.2',
    check:'M 5 12.5 L 10 17 L 19.5 7',
    power:'M 12 3 L 12 11.5 M 7 6.2 A 7.8 7.8 0 1 0 17 6.2',
    plus:'M 12 5 L 12 19 M 5 12 L 19 12',
    arrow:'M 5 12 L 19 12 M 13.5 6.5 L 19 12 L 13.5 17.5',
    settings:'M 4 7 L 20 7 M 4 17 L 20 17 M 9 4.5 L 9 9.5 M 15 14.5 L 15 19.5',
    agent:'M 4 5 L 20 5 L 20 16 L 11 16 L 6.5 20 L 6.5 16 L 4 16 Z M 8.5 10.5 L 8.6 10.5 M 12 10.5 L 12.1 10.5 M 15.5 10.5 L 15.6 10.5'
  };
  function formNodes(nodes) { return (nodes || []).map(formNode).join(''); }
  function formNode(node) {
    if (!node) return '';
    const kind = String(node.Kind || '').toLowerCase(), id = esc(node.Id || ''), name = esc(node.Name || '');
    // 列坐标从 0.20 起就在投影里，但前端从未读过；不带出来等于布局语义在传输层空转。
    const layout = (node.Column != null ? ` data-col="${Number(node.Column)}"` : '')
      + (node.Row != null ? ` data-row="${Number(node.Row)}"` : '')
      + (Number(node.ColumnSpan) > 1 ? ` data-span="${Number(node.ColumnSpan)}"` : '')
      + (Number(node.RowSpan) > 1 ? ` data-rowspan="${Number(node.RowSpan)}"` : '')
      + (node.Align ? ` data-align="${esc(node.Align)}"` : '');
    const attributes = `data-wf="${id}" data-control-name="${name}"${layout}`;
    const disabled = busy() || node.Disabled ? 'disabled' : '';
    const label = esc(fieldLabel(node)), text = esc(node.Text ?? node.Label ?? '');
    const children = () => formNodes(node.Children);
    switch (kind) {
      case 'hint': return hint(String(node.Text || ''), '说明');
      // data-wf-key 只给 reconcile 用：文本节点此前没有匹配键，兄弟节点增删时按位置配对，
      // 会把「就地打补丁」降级成「替换节点」。不挂 data-wf 是为了不给非交互节点发句柄。
      case 'text': { const tag = node.Level === 2 ? 'h2' : node.Level === 3 ? 'h3' : 'p'; return `<${tag} class="wf-text ${node.Tone === 'muted' ? 'muted' : node.Tone === 'warn' ? 'warn-text' : node.Tone === 'bad' ? 'bad-text' : ''}" data-wf-key="${id}" data-control-name="${name}"${layout}>${text}</${tag}>${hintFor(node, text)}`; }
      case 'button': {
        // The host has always sent Tone=ok|warn|bad|info for notices and buttons.
        // Only 'warn' used to reach the stylesheet, so a red-destructive action and
        // an ordinary link looked the same. Destructive wording is also promoted to
        // danger-ghost when the host did not mark it: the verb is the contract.
        const caption = String(node.Text || node.Label || '').trim();
        const destructive = /^(删除|解除|停用|重置|卸载|清除)/.test(caption);
        const cls = node.Tone === 'bad' ? 'danger'
          : destructive && node.Tone !== 'primary' ? 'danger-ghost'
          : ['primary','danger','ghost'].includes(node.Tone) ? node.Tone : '';
        return `<button ${attributes} data-wf-event="click" class="${cls}" ${disabled}>${text || label}</button>${hintFor(node, caption || label)}`;
      }
      case 'input': return node.Multiline ? `<textarea id="wf-${id}" ${attributes} aria-label="${label}" maxlength="${Number(node.MaxLength) || 8192}" ${node.ReadOnly ? 'readonly' : ''} ${disabled}>${esc(node.Value)}</textarea>${hintFor(node, label)}` : `<input id="wf-${id}" ${attributes} type="text" aria-label="${label}" value="${esc(node.Value)}" maxlength="${Number(node.MaxLength) || 8192}" autocomplete="off" spellcheck="false" ${node.ReadOnly ? 'readonly' : ''} ${disabled}>${hintFor(node, label)}`;
      case 'password': return `<div class="password-field"><input id="wf-${id}" ${attributes} type="password" data-secret="true" data-secret-present="${!!node.SecretPresent}" aria-label="${label}" maxlength="${Number(node.MaxLength) || 4096}" autocomplete="off" ${disabled} placeholder="${node.SecretPresent ? '已填写，重新输入可替换' : ''}"><button type="button" class="ghost small" data-password-toggle="wf-${id}" aria-label="显示密码" ${disabled}>显示</button></div>${hintFor(node, label)}`;
      case 'select': return `<select id="wf-${id}" ${attributes} aria-label="${label}" ${disabled}>${Number(node.Value) < 0 ? '<option value="-1" disabled selected>请选择</option>' : ''}${(node.Items || []).map((item, index) => `<option value="${Number.isInteger(item.Index) ? item.Index : index}" ${Number(node.Value) === (Number.isInteger(item.Index) ? item.Index : index) ? 'selected' : ''} ${item.Disabled ? 'disabled' : ''}>${esc(item.Label)}</option>`).join('')}</select>${hintFor(node, label)}`;
      case 'check': return `<label class="wf-check"><input id="wf-${id}" ${attributes} type="${node.Radio ? 'radio' : 'checkbox'}" aria-label="${label}" ${node.Value ? 'checked' : ''} ${disabled}>${node.HasCaption !== false && text ? `<span>${text}</span>` : ''}</label>${hintFor(node, text || label)}`;
      case 'details': return `<details ${attributes} ${node.Open ? 'open' : ''}><summary>${text || label}</summary><div class="wf-stack">${children()}</div></details>${hintFor(node, text || label)}`;
      case 'card': {
        // ok / bad / info notices used to degrade to plain (or grey nested) cards, so
        // severity survived only in the wording. The host already sends Tone.
        const tone = ['ok','bad','info'].includes(node.Tone) ? ` wf-tone-${node.Tone}` : node.Tone === 'warn' ? ' wf-warning' : '';
        // 角色由宿主显式标注（Tag.TCRole）；未标注的 Border 保持现状 = 普通卡片。
        const role = ['tile','chip','group'].includes(node.Role) ? ` data-role="${node.Role}"` : '';
        const size = role && Number.isInteger(Number(node.Size)) && Number(node.Size) > 0 ? ` data-size="${Number(node.Size)}"` : '';
        return `<section class="card wf-card${tone}"${role}${size}${layout}>${children()}</section>`;
      }
      case 'icon': {
        const glyph = WF_ICONS[String(node.Icon || '')];
        return glyph ? `<svg class="wf-icon" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="${glyph}"/></svg>` : '';
      }
      case 'row': return `<div class="wf-row">${children()}</div>`;
      // 0.22.0 B4：宿主用 Tag='TCTabs' 的 WrapPanel 表达「分段按钮」，序列化为 tabs。
      // 当前分区由宿主用 Tone=primary 标出，这里映射成 role=tab + aria-selected。
      case 'tabs': {
        const tabs = (node.Children || []).map(child => {
          const active = child.Tone === 'primary';
          const caption = esc(child.Text || child.Label || '');
          return `<button type="button" role="tab" class="${active ? 'primary' : 'ghost'}" aria-selected="${active}" data-wf="${esc(child.Id || '')}" data-wf-event="click" ${child.Disabled || busy() ? 'disabled' : ''}>${caption}</button>`;
        }).join('');
        return `<div class="wf-tabs" role="tablist">${tabs}</div>`;
      }
      case 'grid': {
        // 列数只够猜对齐，列宽序列才是布局意图。宿主直读 ColumnDefinitions 下发 Cols；
        // 未登记形态不加 data-colspec，退回今天的 flex 行为（不会出现新故障）。
        const cols = Number(node.Columns) || 0;
        const spec = Array.isArray(node.Cols) ? node.Cols.join('|') : '';
        const specAttr = spec && COLSPEC.has(spec) ? ` data-colspec="${spec}"` : '';
        return `<div class="wf-grid"${cols > 1 ? ` data-cols="${cols}"` : ''}${specAttr}${layout}>${children()}</div>`;
      }
      case 'panel': return `<div class="wf-stack">${children()}</div>`;
      case 'rule': return '<hr class="wf-rule">';
      case 'progress': return `<div class="wf-progress" role="status"><progress ${node.Indeterminate ? '' : `value="${Number(node.Value) || 0}" max="${Number(node.Maximum) || 100}"`}></progress>${text}</div>`;
      case 'menu': return `<details class="wf-menu"><summary>${text || label || '更多操作'}</summary><div class="wf-stack">${children()}</div></details>`;
      default: return children();
    }
  }
  // 页面自己提供的返回按钮（MaintenanceBack / PageBack）提升为页首面包屑。
  // 位置仍在标题上方，但事件继续走 data-wf 控件通道，宿主的返回清理逻辑不变；
  // 正文不再重复渲染它。没有这种按钮的页面完全保持原来的 data-page 面包屑。
  function splitPageBack(nodes) {
    let back = null;
    const walk = list => (list || []).flatMap(node => {
      if (!node) return [];
      const isBack = !back && String(node.Kind || '').toLowerCase() === 'button'
        && (node.Name === 'MaintenanceBack' || node.Name === 'PageBack');
      if (isBack) { back = node; return []; }
      const children = walk(node.Children);
      // 只剩返回按钮的容器（例如详情页的 WrapPanel）不再占一行。
      if (node.Children && node.Children.length && !children.length) return [];
      return [Object.assign({}, node, { Children: children })];
    });
    const pruned = walk(nodes);
    // 必须先走完再读 back：对象字面量的属性按序求值，back 在 walk 之前只是 null。
    return { back, nodes: pruned };
  }
  function workflow() {
    const form = state.Form, parent = pages[form.ParentPage] ? form.ParentPage : page;
    const background = state.CanBackground ? button('后台继续','backgroundDeployment','','',!!state.ReadOnly || !!pendingIntent) : '';
    // Buttons already went grey while busy, but nothing said why. The region is
    // marked busy and a status line explains the wait, so a user who is afraid of
    // clicking twice has something to read.
    const busyNote = state.Busy ? '<div class="busy-line" role="status" aria-live="polite"><span class="spinner" aria-hidden="true"></span>正在处理，请稍候…</div>' : '';
    // 页面操作条（PageActions）与部署专用的 Actions 复用同一个吸底容器：
    // 两者本就不会同时出现，合并只是让新路径不必再建一套结构。
    const actions = [...(form.PageActions || []), ...(form.Actions || [])];
    const lifted = splitPageBack(form.Nodes);
    const crumb = lifted.back
      ? `<div class="breadcrumb"><button class="ghost small" data-wf="${esc(lifted.back.Id || '')}" data-wf-event="click" data-control-name="${esc(lifted.back.Name || '')}" ${state.Busy || lifted.back.Disabled ? 'disabled' : ''}>← ${esc(lifted.back.Text || lifted.back.Label || '返回')}</button></div>`
      : `<div class="breadcrumb"><button class="ghost small" data-page="${parent}" ${state.Busy ? 'disabled' : ''}>← 返回${pages[parent] || '首页'}</button></div>`;
    return crumb + head(form.Title || '详情',form.Description || '',background) + notices() + busyNote + `<div class="workflow"${state.Busy ? ' aria-busy="true"' : ''}>${formNodes(lifted.nodes)}</div>${actions.length ? `<div class="workflow-actions"${state.Busy ? ' aria-busy="true"' : ''}>${formNodes(actions)}</div>` : ''}`;
  }

  // Preserve focused inputs, selection and password fields during status polls.
  // Values are acknowledged by the host before an older snapshot may replace them.
  function reconcile(parent, incoming) {
    const wanted = [...incoming.childNodes];
    const key = element => element.nodeType === 1 ? (element.getAttribute('data-wf') || element.getAttribute('data-wf-key') || element.id || '') : '';
    // 本轮已认领的旧节点。同一个旧节点不能被两个新节点同时认领，否则后一个会把它抢走。
    const claimed = new Set();
    for (let index = 0; index < wanted.length; index++) {
      const fresh = wanted[index]; let old = parent.childNodes[index];
      const freshKey = key(fresh);
      if (freshKey) {
        if (!old || key(old) !== freshKey || claimed.has(old)) {
          // 位置上的节点不是它：在整份旧子节点里找同一个句柄，不能只往后找。
          // 中途插入一个按钮会把后面的文本节点顶掉一位，只往后找是找不到的。
          const match = [...parent.childNodes].find(item => item !== old && !claimed.has(item) && key(item) === freshKey && item.nodeName === fresh.nodeName);
          if (match) { parent.insertBefore(match, old || null); old = match; }
          else {
            // 句柄上一轮不存在 = 新节点。插进去，不要顶掉位置上的旧节点 ——
            // 顶掉等于把它后面整段兄弟全部重建，正好是「就地打补丁」要避免的事。
            const created = fresh.cloneNode(true);
            parent.insertBefore(created, old || null);
            claimed.add(created);
            continue;
          }
        }
        claimed.add(old);
      }
      if (!old) { parent.appendChild(fresh.cloneNode(true)); continue; }
      if (old.nodeType !== fresh.nodeType || old.nodeName !== fresh.nodeName || (freshKey && key(old) !== freshKey)) { old.replaceWith(fresh.cloneNode(true)); continue; }
      if (fresh.nodeType === Node.TEXT_NODE) { if (old.nodeValue !== fresh.nodeValue) old.nodeValue = fresh.nodeValue; continue; }
      if (fresh.nodeType !== Node.ELEMENT_NODE) continue;
      const secret = old.dataset.secret === 'true';
      // details 的 open 是用户当场的选择，不是宿主状态：模板里永远不写它，
      // 严格同步属性会把刚展开的说明（例如「新电脑怎么用」）立刻收回去。
      for (const attribute of [...old.attributes]) {
        const userOpen = old.tagName === 'DETAILS' && attribute.name === 'open';
        if (!userOpen && !fresh.hasAttribute(attribute.name) && !(secret && attribute.name === 'type')) old.removeAttribute(attribute.name);
      }
      for (const attribute of [...fresh.attributes]) if (!(secret && attribute.name === 'type') && old.getAttribute(attribute.name) !== attribute.value) old.setAttribute(attribute.name, attribute.value);
      if (old.matches('input,textarea,select')) {
        if (old.tagName === 'SELECT') reconcile(old,fresh);
        const pending = pendingFields.has(old.dataset.wf);
        if (secret) { if (fresh.dataset.secretPresent === 'false' && !pending) old.value = ''; }
        else if (!pending) { if (old.type === 'checkbox' || old.type === 'radio') old.checked = fresh.checked; else if (old.value !== fresh.value) old.value = fresh.value; }
      } else reconcile(old,fresh);
    }
    while (parent.childNodes.length > wanted.length) parent.lastChild.remove();
  }
  function render() {
    if (!state) return;
    // A malformed snapshot must degrade to one honest card, never a blank page.
    try { paint(); } catch (error) { console.error('render failed', error); paintFallback(); }
  }
  function paintFallback() {
    const main = $('#main'); if (!main) return;
    main.innerHTML = '<div class="card empty"><h2>界面状态暂时无法显示</h2><p>数据已经收到，但这次没能画出来。刷新通常可以恢复。</p><div class="actions"><button class="primary" data-action="refresh">刷新</button><button class="ghost" data-action="diagnostics">运行诊断</button></div></div>';
  }
  function paint() {
    const nextRoute = state.Form ? `form:${state.Form.ViewKey || state.Form.Page}` : page;
    const nextView = state.Form ? `${nextRoute}:${state.Form.Generation}` : page;
    // Every page needs an explicit entry here: a missing key would silently fall
    // back to the home page (the route, the stepper and the breadcrumb would all
    // disappear without an error).
    const html = state.Form ? workflow() : ({home,lines,apps,settings,'add-line':addLine,invite}[page] || home)();
    const template = document.createElement('template'); template.innerHTML = html;
    if (viewKey !== nextView) {
      const sameRoute = routeKey === nextRoute, active = document.activeElement;
      const focusedName = sameRoute && $('#main').contains(active) ? active?.dataset?.controlName : '';
      const retained = new Map();
      if (sameRoute) $('#main').querySelectorAll('[data-secret]').forEach(input => { if (input.value) retained.set(input.dataset.controlName,input.value); });
      $('#main').querySelectorAll('[data-secret]').forEach(input => {input.value = '';});
      $('#main').replaceChildren(template.content); viewKey = nextView;
      $('#main').querySelectorAll('[data-secret][data-secret-present="true"]').forEach(input => { if (retained.has(input.dataset.controlName)) input.value = retained.get(input.dataset.controlName); });
      retained.clear();
      if (sameRoute && focusedName) [...$('#main').querySelectorAll('[data-control-name]')].find(input => input.dataset.controlName === focusedName)?.focus({preventScroll:true});
      if (!sameRoute) {window.scrollTo(0,0); if (!state.Dialog) $('#main').focus({preventScroll:true});}
    } else reconcile($('#main'),template.content);
    routeKey = nextRoute;
    const active = state.Form ? (state.Form.ParentPage || page) : (PAGE_PARENT[page] || page);
    document.querySelectorAll('nav [data-page]').forEach(item => {
      item.classList.toggle('active', item.dataset.page === active);
      if (item.dataset.page === active) item.setAttribute('aria-current','page'); else item.removeAttribute('aria-current');
      item.disabled = !!state.Form && !!state.Busy;
    });
    const deployment = state.Deployments?.find(task => task.Running) || state.Deployments?.find(task => task.State === 'NeedsAttention' || task.State === 'Complete');
    const showSummary = !!state.Form || page !== 'home';
    $('#mini-status').hidden = !showSummary && !deployment;
    $('#mini-status').innerHTML = `${showSummary ? `<div class="mini-connection"><span class="dot ${isConnected() ? 'good' : ''}"></span> ${title()}${isConnected() ? `<div class="line-sub">${esc(state.TradeName || line(state.ActiveLineId)?.Name || state.NodeName)}</div>${latency() !== '—' ? `<div class="line-sub mono">${latency()} ms${qualityBand() ? ' · ' + qualityBand().label : ''}</div>` : ''}` : ''}</div>` : ''}${deployment ? `<button class="background-task" data-action="resumeDeployment" data-id="${esc(deployment.RunId)}"><span>${esc(deployment.Name)}</span><small>${esc(deployment.Summary || (deployment.Running ? '正在部署' : '查看部署结果'))}</small></button>` : ''}`;
    $('#version').textContent = `${state.Version} · 预览版`;
    renderDrawer(); renderDialog();
    hintLayer.maintain();
    if (state.Toast && state.Toast !== toastKey) {
      toastKey = state.Toast; $('#toast').textContent = state.Toast; $('#toast').hidden = false;
      clearTimeout(toastTimer); toastTimer = setTimeout(() => {$('#toast').hidden = true;},4200);
    }
    scheduleFailureExpiry(); schedulePickFeedbackExpiry();
  }
  function testState(item) {
    const op = operation();
    if (op && op.Kind === 'Test' && op.LineId === item.Id) return {running:true, seconds:elapsedSeconds(op)};
    if (item.Pending === 'Testing') return {running:true, seconds:null};
    return {running:false};
  }
  function testLabel(item) {
    const current = testState(item);
    if (current.running) return '测速中' + (current.seconds === null ? '…' : ` · ${current.seconds} 秒`);
    return `测速（最长 ${TEST_BUDGET_SECONDS} 秒）`;
  }
  function renderDrawer() {
    const item = line(selected), root = $('#drawer');
    $('.layout').inert = !!item || !!state?.Dialog;
    document.body.classList.toggle('modal-open', !!item || !!state?.Dialog);
    const wasHidden = root.hidden; root.hidden = !item;
    if (!item) { root.replaceChildren(); return; }
    const active = lineInUse(item), status = lineStatus(item);
    const remove = active ? `<button class="danger" data-action="delete" data-id="${esc(item.Id)}" aria-disabled="true" aria-describedby="line-delete-hint">删除线路</button>` : button('删除线路','delete',item.Id,'danger',busy());
    // 0.21.2: 0.21.0 dropped 更多：连接方式与维护 as a duplicate, but only the method
    // switch and the test were duplicated here. Server and devices (invitation
    // codes, device rename/revoke, identity check) and the local network binding
    // and its rollback had no other web entry, so both come back in the maintain
    // group: lineServer opens the line's server page directly, lineSettings the
    // full connection-method page.
    const template = document.createElement('template');
    template.innerHTML = `<section class="drawer" role="dialog" aria-modal="true" aria-label="线路详情"><button class="ghost" data-close="drawer">← 返回线路</button><h2>${esc(item.Name)}</h2><div class="detail-row"><span>状态</span><span class="${status.tone === 'warn' ? 'warn-text' : ''}">${esc(status.label)}${status.reason ? '：' + esc(status.reason) : ''}</span></div>${outcomeBar(item)}${methodSwitch(item, active)}${lineFeedback(item, "Preference")}<div class="detail-row"><span>当前线路响应</span><span class="${active && isConnected() && latency() !== '—' ? 'mono' : 'muted'}">${active && isConnected() ? (latency() !== '—' ? latency() + ' ms' : '暂未测得') : '连接后显示响应'}</span></div>${qualityHistory(item)}<div class="actions"><div class="action-group" data-group="primary">${item.Blocked && !active ? button('核对服务器身份','lineServer',item.Id,'primary',busy()) : button(active ? '使用中' : '连接这条线路','connect',item.Id,'primary',busy() || active)}</div><div class="action-group" data-group="maintain">${item.CanInvite ? inviteButton('邀请其他电脑','Begin',item.Id,'','ghost',busy()) : ''}${active ? hint('使用中的线路请看首页「线路响应」。','测速') : button(testLabel(item),'testLine',item.Id,'',busy() || !!item.Pending || testState(item).running) + hint('测速会实际发出请求，并更新这条线路的状态。','测速')}${state.HomeLineId === item.Id ? '<span class="muted">首页默认线路</span>' : button('设为默认线路','setHomeLine',item.Id,'ghost',busy())}${button('重命名','rename',item.Id,'ghost',busy())}${button('服务器与设备','lineServer',item.Id,'ghost',busy())}${button('连接方式与网络…','lineSettings',item.Id,'ghost',busy())}</div><div class="action-group" data-group="danger">${remove}</div></div>${lineFeedback(item, "Check")}${active ? '<p class="delete-hint" id="line-delete-hint">断开后可删除</p>' : ''}</section>`;
    reconcile(root,template.content);
    if (wasHidden) root.querySelector('[data-close]')?.focus();
  }
  // All choices are local preferences for the next connection. Auto removes a
  // manual pin; the host binds it to current evidence or asks for a line test.
  function methodSwitch(item, active) {
    const prepared = Array.isArray(item.PreparedProfiles) ? item.PreparedProfiles : [];
    const pinned = item.ProfileSource === 'UserChoice';
    const saving = item.Pending === 'Saving';
    const seg = (label, value, on, off) => `<button class="seg${on ? ' on' : ''}" role="radio" aria-checked="${on}" data-action="setProfile" data-value="${value}" data-id="${esc(item.Id)}" ${off ? 'disabled' : ''}>${label}</button>`;
    const methodNote = saving ? '正在保存…' : item.Pending === 'Testing' ? '正在测试，不影响当前连接…' : !pinned && item.AutomaticNeedsCheck ? '已选自动，请先测试线路以确定下次使用的方式。' : active ? '用于下次连接，当前连接保持。' : '自动会采用这条线路已验证的方式。';
    return `<div class="detail-row"><span>连接方式${pinned ? '' : hint('自动会采用这条线路已验证的方式。','自动')}</span><span class="seg-group" role="radiogroup" aria-label="连接方式">${seg('自动','Auto',!pinned,busy() || saving || !prepared.length)}${seg('标准','Udp',pinned && item.Profile === 'Udp',busy() || saving || !prepared.includes('Udp'))}${seg('兼容','Tcp',pinned && item.Profile === 'Tcp',busy() || saving || !prepared.includes('Tcp'))}</span></div>${saving || item.Pending === 'Testing' || (!pinned && item.AutomaticNeedsCheck) || active ? `<p class="delete-hint" role="status">${esc(methodNote)}</p>` : ''}`;
  }
  function closeDrawer() {
    if(selected) post('qualityHistory',{Id:selected,Value:'Close'});
    selected = ''; renderDrawer();
  }
  function qualityHistory(item) {
    const history = state.QualityHistory?.NodeId === item.Id ? state.QualityHistory : null;
    let body = '<p class="muted">正在读取历史…</p>';
    if (history && !history.Loading) {
      if (history.Reason === 'StoreUnavailable') body = '<p class="muted">历史暂时无法读取，可重新选择时间范围。</p>';
      else if (!history.Series?.length) body = '<p class="muted">这个时间段尚无测量记录。</p>';
      else {
        const values = history.Series.flatMap(series => series.Aggregate.Buckets.map(bucket => bucket.AverageLatencyMs).filter(Number.isFinite));
        const maximum = Math.max(100,...values), legend = new Map();
        let measured = 0, unavailable = 0, total = 0;
        const curves = history.Series.map(series => {
          const aggregate = series.Aggregate, stats = aggregate.Statistics, buckets = aggregate.Buckets || [];
          measured += stats.MeasuredCount; unavailable += stats.UnavailableCount; total += (stats.AverageLatencyMs || 0)*stats.MeasuredCount;
          const route = series.Binding.Exit === 'hk' ? profile(series.Binding.ProfileId) : '代理软件';
          const color = series.Binding.Exit !== 'hk' ? '#a57ce0' : series.Binding.ProfileId === 'Tcp' ? '#25a889' : '#648cf0';
          legend.set(route,color);
          const parts = []; let path = [];
          buckets.forEach((bucket,index) => {
            const value = bucket.MeasuredCount > 0 ? bucket.AverageLatencyMs : null;
            if (!Number.isFinite(value)) { if(path.length) parts.push(path); path = []; }
            else path.push(`${(index / Math.max(1,buckets.length-1)*300).toFixed(1)},${(85-value/maximum*70).toFixed(1)}`);
          });
          if(path.length) parts.push(path);
          return parts.map(points => points.length > 1 ? `<polyline fill="none" stroke="${color}" stroke-width="2" points="${points.join(' ')}"/>` : `<circle fill="${color}" r="2.5" cx="${points[0].split(',')[0]}" cy="${points[0].split(',')[1]}"/>`).join('');
        }).join('');
        const aggregate = history.Series[0].Aggregate;
        const time = value => {const date = new Date(value);return (history.Window === 'Day' ? date.toLocaleDateString('zh-CN',{month:'2-digit',day:'2-digit'})+' ' : '')+date.toLocaleTimeString('zh-CN',{hour:'2-digit',minute:'2-digit'});};
        body = `<div class="history-series"><div class="history-caption"><span class="mono">平均 ${measured ? Math.round(total/measured) : '—'} ms</span><span>${measured} 次成功 · ${unavailable} 次未测得</span></div><svg viewBox="0 0 300 100" role="img" aria-label="线路响应历史，空白表示无测量数据">${curves}</svg><div class="history-caption muted"><span>${time(aggregate.StartAtUtc)}</span><span>${time(aggregate.EndAtUtc)}</span></div><div class="history-legend">${[...legend].map(([label,color]) => `<span class="${color === '#a57ce0' ? 'history-proxy' : color === '#25a889' ? 'history-tcp' : 'history-udp'}">${esc(label)}</span>`).join('')}</div></div>`;
      }
    }
    return `<section class="quality-history"><div class="section-head"><h3>响应历史${hint('按每次连接分别记录。测量包含加密建连耗时，不代表订单延迟。','响应历史')}</h3><div class="range-control" role="group" aria-label="历史时间范围"><button data-history="ThirtyMinutes" class="small ${historyWindow === 'ThirtyMinutes' ? 'selected' : ''}" aria-pressed="${historyWindow === 'ThirtyMinutes'}">30 分钟</button><button data-history="Day" class="small ${historyWindow === 'Day' ? 'selected' : ''}" aria-pressed="${historyWindow === 'Day'}">24 小时</button></div></div>${body}</section>`;
  }
  function renderDialog() {
    const dialog = state.Dialog, root = $('#dialog-root'); root.hidden = !dialog;
    if (!dialog) { dialogKey = ''; root.replaceChildren(); return; }
    if (dialogKey === dialog.Id) return;
    dialogKey = dialog.Id;
    root.innerHTML = `<div class="dialog-backdrop"><section class="dialog${dialog.Progress ? ' cleanup-dialog' : ''}" role="alertdialog" aria-modal="true" aria-labelledby="dialog-title" aria-describedby="dialog-body" ${dialog.Progress ? 'aria-busy="true"' : ''}><h2 id="dialog-title">${esc(dialog.Title)}</h2><p id="dialog-body" ${dialog.Progress ? 'role="status"' : ''}>${esc(dialog.Body)}</p>${dialog.Progress ? cleanupProgress('Previewing') : ''}${dialog.Note ? `<p class="note">${esc(dialog.Note)}</p>` : ''}${dialog.Details ? `<details class="dialog-details"><summary>查看详情</summary><pre>${esc(dialog.Details)}</pre></details>` : ''}<div class="actions">${dialog.Cancel ? button(esc(dialog.Cancel),'cancelDialog',dialog.Id) : ''}${button(esc(dialog.Confirm),'confirmDialog',dialog.Id,dialog.Danger ? 'danger' : 'primary')}</div></section></div>`;
    (root.querySelector('[data-action="cancelDialog"]') || root.querySelector('[data-action="confirmDialog"]'))?.focus();
  }
  function submitForm(control, event, value) {
    if (!state?.Form || control.disabled) return;
    const next = post('form',{Generation:state.Form.Generation,Id:control.dataset.wf,Event:event,Value:value},event === 'click');
    if (event === 'change') pendingFields.set(control.dataset.wf,next);
    if (event === 'click') render();
  }
  document.addEventListener('click',event => {
    const target = event.target.closest('button'); if (!target || target.disabled || target.getAttribute('aria-disabled') === 'true') return;
    // 0.22.0 B1：ⓘ 点击切换并保持打开（键盘用户也能用）。它不带 data-action，
    // 不参与任何业务分发。
    if (target.classList.contains('hint')) { hintLayer.toggle(target); return; }
    if (target.dataset.action && target.dataset.action.startsWith('pair')) { pairAction(target.dataset.action); return; }
    if (target.dataset.invite) { inviteAction(target.dataset.invite, target.dataset.id || '', target.dataset.value || ''); return; }
    if (target.dataset.passwordToggle) {
      const input = document.getElementById(target.dataset.passwordToggle);
      if (input) { const reveal = input.type === 'password'; input.type = reveal ? 'text' : 'password'; target.textContent = reveal ? '隐藏' : '显示'; target.setAttribute('aria-label',reveal ? '隐藏密码' : '显示密码'); }
      return;
    }
    if (target.dataset.wf) { submitForm(target,'click',null); return; }
    // 0.21.2: ＋ 添加线路 always starts at step 1 (choose a method); only the
    // 用邀请码加入 entries (pairStart) skip straight to step 2.
    if (target.dataset.page) { closeDrawer(); if (target.dataset.page !== 'add-line') pairJoined = false; pairStep = 1; if (target.dataset.page !== 'invite') { inviteTarget = null; inviteConfirm = false; } post('navigate',{Page:target.dataset.page},true); render(); return; }
    if (target.dataset.close) { closeDrawer(); drawerFocus?.focus(); return; }
    if (target.dataset.detail || target.dataset.action === 'details') { drawerFocus = target; selected = target.dataset.detail || target.dataset.id; historyWindow = 'Day'; post('qualityHistory',{Id:selected,Value:historyWindow}); renderDrawer(); return; }
    if (target.dataset.history && selected) { historyWindow = target.dataset.history; post('qualityHistory',{Id:selected,Value:historyWindow}); renderDrawer(); return; }
    if (target.dataset.setting) {
      const value = target.getAttribute('aria-checked') !== 'true';
      if (target.dataset.setting === 'OpenAtLogin') post('startup',{Value:value},true);
      else post('setting',{Name:target.dataset.setting,Value:value},true);
      render(); return;
    }
    if (target.dataset.action) {
      // Card protocol pick: clicking the already-pinned value must not re-write
      // the preference (R1). data-current carries that pinned value; an empty
      // data-current means the line is on 自动, so any pick is a real change.
      if (target.dataset.action === 'setProfile' && target.dataset.value && target.dataset.current === target.dataset.value) return;
      const inPlace = ['setProfile','testLine','setHomeLine','retryLineAction','reviewLineAction'].includes(target.dataset.action);
      if (!inPlace) closeDrawer();
      post(target.dataset.action,target.dataset.value ? {Id:target.dataset.id || '',Value:target.dataset.value} : {Id:target.dataset.id || ''},true);
      if (['confirmDialog','cancelDialog'].includes(target.dataset.action)) $('#dialog-root').querySelectorAll('button').forEach(item => {item.disabled = true;});
      else render();
    }
  });
  // 0.22.0 B1 悬浮说明交互（WCAG 1.4.13：可移入、可关闭、持续显示）。
  // 悬停 300ms 打开；聚焦立即打开；离开按钮 150ms 关闭（移入气泡则保持）；
  // Esc/失焦关闭；滚动与窗口变化时重新定位，锚点被重建则关闭；同一时刻只有一个。
  document.addEventListener('mouseover', event => {
    const node = event.target.closest?.('.hint');
    if (node) { hintLayer.open(node); return; }
    if (event.target.closest?.('#hint-layer')) { hintLayer.cancelClose(); return; }
  });
  document.addEventListener('mouseout', event => {
    if (event.target.closest?.('.hint') || event.target.closest?.('#hint-layer')) hintLayer.scheduleClose();
  });
  document.addEventListener('focusin', event => {
    const node = event.target.closest?.('.hint');
    if (node) hintLayer.show(node);
  });
  document.addEventListener('focusout', event => {
    if (event.target.closest?.('.hint')) hintLayer.scheduleClose();
  });
  document.addEventListener('keydown', event => { if (event.key === 'Escape') hintLayer.hide(); });
  window.addEventListener('scroll', () => hintLayer.maintain(), true);
  window.addEventListener('resize', () => hintLayer.maintain());
  document.addEventListener('input',event => {
    const target = event.target;
    // Drafts are echoed into the template so the next reconcile pass finds the
    // same value and leaves the field alone. The invitation code uses the secret
    // branch instead and is never echoed.
    if (target.dataset.pairInput === 'device') { pairDraft.device = target.value; pairDraft.localError = ''; return; }
    if (target.dataset.pairInput === 'name') { pairDraft.name = target.value; return; }
    // The custom lifetime is a draft: it is echoed into the template on the next
    // render, so reconcile finds the same value and leaves the field alone. The
    // render is not optional - it is what enables 生成邀请码 and shows the range
    // hint as soon as the typed number becomes valid.
    if (target.dataset.inviteInput === 'amount') { inviteCustom.amount = target.value; render(); return; }
    if (target.dataset.wf && target.matches('input:not([type=checkbox]):not([type=radio]),textarea')) submitForm(target,'change',target.value);
  });
  document.addEventListener('change',event => {
    const target = event.target;
    if (target.dataset.wf) {
      if (target.type === 'checkbox' || target.type === 'radio') submitForm(target,'change',target.checked);
      else if (target.tagName === 'SELECT') submitForm(target,'change',Number(target.value));
    } else if (target.id === 'theme') { theme = target.value; localStorage.setItem('theme',theme); applyTheme(); syncHostTheme(); }
    else if (['daily','agents','close-behavior'].includes(target.id)) { post(target.id === 'close-behavior' ? 'closeBehavior' : target.id,{Value:target.value},true); render(); }
  });
  // 浏览器读不到被拖文件的完整路径，把 File 交给宿主换取真实路径。
  // 只拦截「拖文件」：WebView2 的 AllowExternalDrop 默认是 true，不拦的话 Chromium
  // 会尝试导航到被拖入的文件，页面可能变成空白。文本等其它拖放必须放行，
  // 否则输入框里就没法拖动文字了。
  // 落点只认交易程序输入框；Target 用宿主侧的 wf-<guid> 句柄（dataset.wf），
  // 不是 DOM 的 id（DOM id 是 wf-wf-<guid>，两者不同）。
  const dropInput = event => event.target instanceof Element ? event.target.closest('input[data-control-name="TradeProgramInput"]') : null;
  const isFileDrag = event => !!(event.dataTransfer && Array.prototype.indexOf.call(event.dataTransfer.types || [], 'Files') >= 0);
  const dropHovers = new Set();
  const setDropHover = node => {
    dropHovers.forEach(item => { if (item !== node) { item.classList.remove('drop-hover'); dropHovers.delete(item); } });
    if (node) { node.classList.add('drop-hover'); dropHovers.add(node); }
  };
  const clearDropHover = () => setDropHover(null);
  document.addEventListener('dragover', event => {
    if (!isFileDrag(event)) return;
    event.preventDefault();
    const input = dropInput(event);
    // 高频事件，但只对变化的节点改 class，幂等且不抖动。
    setDropHover(input);
    event.dataTransfer.dropEffect = input ? 'copy' : 'none';
  }, true);
  document.addEventListener('dragleave', event => {
    const input = dropInput(event);
    if (input) { input.classList.remove('drop-hover'); dropHovers.delete(input); }
    if (!event.relatedTarget) clearDropHover();
  }, true);
  document.addEventListener('drop', event => {
    if (!isFileDrag(event)) return;
    event.preventDefault();
    const input = dropInput(event);
    clearDropHover();
    if (!input) return;
    const files = event.dataTransfer.files;
    if (!files || !files.length) return;
    if (window.chrome && window.chrome.webview && window.chrome.webview.postMessageWithAdditionalObjects) {
      window.chrome.webview.postMessageWithAdditionalObjects({ Type: 'fileDrop', Target: input.dataset.wf || '' }, [files[0]]);
    }
  }, true);
  function findNode(id, nodes) { for (const node of nodes || []) { if (node.Id === id) return node; const found = findNode(id,node.Children); if (found) return found; } return null; }
  document.addEventListener('toggle',event => {
    const target = event.target;
    if (!target.matches('details[data-wf]') || !state?.Form) return;
    const node = findNode(target.dataset.wf,state.Form.Nodes);
    if (node && !!node.Open !== target.open) submitForm(target,'expand',target.open);
  },true);
  document.addEventListener('keydown',event => {
    // The pairing page has no mirrored form, so Enter needs its own branch:
    // step 2 verifies, step 3 joins. Escape goes back to the line list.
    if (page === 'add-line' && !state?.Dialog && !selected) {
      if (event.key === 'Escape') { event.preventDefault(); post('navigate',{Page:'lines'},true); return; }
      if (event.key === 'Enter' && event.target.matches('input')) {
        const action = pairStepOf() === 2 ? 'pairVerify' : 'pairJoin';
        const button = document.querySelector(`#main [data-action=${action}]`);
        if (button && !button.disabled) { event.preventDefault(); button.click(); return; }
      }
    }
    // The invitation page has no mirrored form either: Escape goes back, and Enter
    // in the custom-length box generates (the primary is never destructive here).
    if (page === 'invite' && !state?.Dialog && !selected) {
      if (event.key === 'Escape') { event.preventDefault(); post('navigate',{Page:'lines'},true); return; }
      if (event.key === 'Enter' && event.target.matches('input')) {
        const primary = document.querySelector('#main [data-invite=Create]');
        if (primary && !primary.disabled) { event.preventDefault(); primary.click(); return; }
      }
    }
    if (state?.Form && !state.Dialog && !selected) {
      // A mirrored workflow is keyboard-operable: Enter runs its main action,
      // Escape goes back to the page it came from.
      if (event.key === 'Escape') { event.preventDefault(); $('#main .breadcrumb button')?.click(); return; }
      // Enter must never start something the user cannot see the consequences of.
      // It used to fire the sticky primary from an input OR a select - and on the
      // deployment wizard that primary is 开始部署, which restarts the network
      // services. Confirming a dropdown option with Enter was enough to launch it.
      // Selects are now excluded and destructive actions require an explicit click.
      if (event.key === 'Enter' && event.target.matches('input:not([type=checkbox]):not([type=radio])')) {
        const action = $('#main .workflow-actions button.primary') || $('#main .workflow-actions button');
        const destructive = action && /部署|删除|重置|解除|停用|重启|卸载|断开|清除/.test(action.textContent || '');
        if (action && !action.disabled && !destructive) { event.preventDefault(); action.click(); return; }
      }
    }
    if (event.key === 'Escape') {
      if (state?.Dialog && (state.Dialog.Cancel || state.Dialog.Progress)) post(state.Dialog.Progress ? 'confirmDialog' : 'cancelDialog',{Id:state.Dialog.Id},true);
      else if (selected) {closeDrawer(); drawerFocus?.focus();}
    }
    const root = state?.Dialog ? $('#dialog-root') : selected ? $('#drawer') : null;
    if (event.key === 'Tab' && root) {
      const elements = [...root.querySelectorAll('button:not(:disabled),input:not(:disabled),select:not(:disabled),summary,[tabindex="0"]')];
      const first = elements[0], last = elements.at(-1);
      if (event.shiftKey && document.activeElement === first) {last?.focus(); event.preventDefault();}
      else if (!event.shiftKey && document.activeElement === last) {first?.focus(); event.preventDefault();}
    }
  });
  window.addEventListener('blur',() => {
    document.querySelectorAll('[data-secret]').forEach(input => { input.type = 'password'; });
    document.querySelectorAll('[data-password-toggle]').forEach(item => {item.textContent = '显示'; item.setAttribute('aria-label','显示密码');});
  });
  tickTimer = setInterval(tick, TICK_MS);
  if (window.chrome?.webview) {
    window.chrome.webview.addEventListener('message',event => {
      // A2 Reveal: the one message that carries the code. It is never echoed into
      // the snapshot, and nothing else in this file writes invite-code.value.
      if (event.data?.Type === 'inviteCode') {
        const code = typeof event.data.Code === 'string' ? event.data.Code : '';
        inviteCodeLocal = code;
        if (code) inviteRevealed = true;
        const input = document.getElementById('invite-code');
        if (input) input.value = code;
        return;
      }
      if (event.data?.Type !== 'snapshot') return;
      state = event.data.State;
      if (Number(state.Ack) >= pendingIntent) pendingIntent = 0;
      for (const [key, value] of pendingFields) if (Number(state.Ack) >= value) pendingFields.delete(key);
      syncPairEpoch();
      syncInviteEpoch();
      if (pages[event.data.Page]) page = event.data.Page;
      // Leaving the page drops the revealed code and the picked line; the field is
      // gone with the route, and the next visit must start from the same choice the
      // entry offers (the host keeps the invitation itself, not this).
      if (page !== 'invite') { inviteRevealed = false; inviteCodeLocal = ''; inviteExpiryKey = ''; inviteTarget = null; inviteConfirm = false; }
      render();
    });
    post('ready');
  } else $('#main').innerHTML = '<div class="empty"><h1>请从 TradeChannel 打开</h1><p>连接状态由本机程序提供。</p></div>';
})();
