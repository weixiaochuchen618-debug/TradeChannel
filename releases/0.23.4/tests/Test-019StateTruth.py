"""0.19.0 "the screen must tell the truth" acceptance checks.

Static web page + a synthetic WebView bridge. No Worker, no real line data, no
network: every snapshot below is hand-written and injected, so a failure always
means the rendering disagrees with the injected state.

Covered (one check per behaviour so a failure names the behaviour):
  * protection card: three states, host sentence, zero-programme special case
  * wait countdown: m:ss from DeadlineUtc only, no digits when the host omits it
  * five transaction outcomes: sentence, tone and next action; no 已恢复 outside
    RolledBack; Completed suppressed while that line is the live connection
  * in-flight: drawer test button and home connect button show elapsed seconds
  * exit evidence: four levels plus the missing-field fallback
  * snapshot heartbeat: stale banner and "状态未知" title
  * empty state: both entry points, no page error
  * degraded snapshot: one honest card instead of a blank page
  * source guards: no wait budget hard-coded in app.js, 45 s budget equals the
    host timeout, no 已恢复 in the outcome copy

Usage:
  python tests/Test-019StateTruth.py --package . --report <dir>
"""
import argparse
import json
from copy import deepcopy
from datetime import datetime, timedelta, timezone
from pathlib import Path
import re
import tempfile

from playwright.sync_api import expect, sync_playwright


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--package', type=Path, default=Path(__file__).resolve().parents[1])
parser.add_argument('--report', type=Path)
args = parser.parse_args()
package = args.package.resolve()
report = args.report or Path(tempfile.mkdtemp(prefix='tradechannel-019-state-'))
report.mkdir(parents=True, exist_ok=True)

checks, failures, external_requests = [], [], []
# Uncaught page errors must always be empty. A caught render failure is allowed
# to log one "render failed" console error: that is the documented fallback.
page_errors, console_errors = [], []

PROTECTED = '交易程序 IPv4/IPv6 直连保护已启用；断开通道后仍保留。'
UNPROTECTED = '交易程序直连保护未完整启用，请检查保护规则。'
UNKNOWN = '交易保护状态暂时无法核实，请检查保护规则。'
# Design §4.1: status -> (host NextAction, result-bar tone). The host owns the
# sentence; the browser must render it and pick the action from NextAction.
DESIGN = {
    'Completed': ('Details', 'outcome-good'),
    'RolledBack': ('Details', 'outcome-warn'),
    'Aborted': ('Connect', 'outcome-neutral'),
    'ResolvedStopped': ('ChooseLine', 'outcome-warn'),
    'NeedsRecovery': ('ReviewOperation', 'outcome-bad'),
}
# What the bar must offer when no PendingOperations entry exists. NeedsRecovery
# deliberately degrades from "review" to "run diagnostics" in that case.
RENDER = {
    'Completed': ('Details', '查看详情'),
    'RolledBack': ('Details', '查看详情'),
    'Aborted': ('Connect', '重新连接'),
    'ResolvedStopped': ('ChooseLine', '重新选择线路'),
    'NeedsRecovery': ('Diagnostics', '运行诊断'),
}
FORBIDDEN = ('Aborted', 'ResolvedStopped', 'NeedsRecovery')
# Host NextAction -> the control the browser must render for it.
DOM = {
    'Details': 'button[data-action="details"]',
    'Connect': 'button[data-action="connect"]',
    'ChooseLine': '[data-page="lines"]',
    'ReviewOperation': 'button[data-action="reviewOperation"]',
    'Diagnostics': 'button[data-action="diagnostics"]',
}
# Design §4.1 wording that must survive whatever sentence the host chooses.
SEMANTICS = {
    'Completed': '出口',
    'RolledBack': '回到切换前',
    'Aborted': '没有开始',
    'ResolvedStopped': '停止',
    'NeedsRecovery': '核对',
}

bridge = """
(() => {
  const listeners = [];
  let sequence = 0;
  window.__stateMessages = [];
  window.__stateSend = payload => {
    const snapshot = structuredClone(payload);
    snapshot.State.Ack = sequence;
    listeners.forEach(listener => listener({data:snapshot}));
  };
  window.chrome = window.chrome || {};
  window.chrome.webview = {
    addEventListener: (name, listener) => listeners.push(listener),
    postMessage: message => {
      sequence = message.Sequence;
      window.__stateMessages.push(structuredClone(message));
    }
  };
})();
"""


def stamp(seconds=0):
    """Whole-second UTC stamp, the format the host is required to send."""
    moment = datetime.now(timezone.utc) + timedelta(seconds=seconds)
    return moment.strftime('%Y-%m-%dT%H:%M:%SZ')


def iso_after(seconds):
    return (datetime.now(timezone.utc) + timedelta(seconds=seconds)).isoformat().replace('+00:00', 'Z')


def check(condition, message):
    if condition:
        checks.append(message)
    else:
        failures.append(message)


def scenario(name, body):
    """Run one scenario; a raised exception becomes one located failure."""
    try:
        body()
    except Exception as error:  # noqa: BLE001 - the report needs the message, not a traceback
        failures.append(f'{name} — 异常: {error}')


def sample():
    return {
        'Version': '0.19.0', 'State': 'Disconnected', 'Running': False,
        'Busy': False, 'ReadOnly': False, 'Guard': 'Protected',
        'GuardSummary': PROTECTED, 'TradeProgramCount': 1,
        'TradeExit': 'hk', 'TradeName': '模拟香港主线', 'ActiveLineId': 'main', 'ActiveProfile': 'Udp',
        'PreferredLineId': 'main', 'Daily': 'Direct', 'Agents': 'Daily',
        'Tasks': [], 'Providers': [],
        'SnapshotAtUtc': stamp(), 'ConnectedSince': None, 'Pending': None,
        'ExitEvidence': {'Verified': False, 'Attribution': 'Unknown', 'Status': 'Unknown', 'Code': '', 'CheckedAtUtc': None},
        'Operation': None,
        'Lines': [
            {'Id': 'main', 'Name': '模拟香港主线', 'Profile': 'Udp', 'Prepared': True, 'Blocked': False,
             'Readiness': {'State': 'Verified', 'Label': '可用', 'Reason': ''}},
            {'Id': 'test', 'Name': '模拟测试线路', 'Profile': 'Tcp', 'Prepared': True, 'Blocked': False,
             'Readiness': {'State': 'Untested', 'Label': '未测试', 'Reason': '还没有测试过'}},
        ],
    }


def connected_sample():
    state = sample()
    state.update({'State': 'Connected', 'Running': True, 'TradeExit': 'hk', 'ActiveLineId': 'main'})
    state['Quality'] = {'LatencyMs': 42, 'Degraded': False, 'History': [{'LatencyMs': 39}, {'LatencyMs': 42}]}
    return state


def source_without_comments(path):
    """Drop comments so a comment that names a forbidden word is not a failure."""
    text = path.read_text(encoding='utf-8')
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    text = re.sub(r'(?m)^\s*#.*$', '', text) if path.suffix == '.ps1' else text
    return re.sub(r'//[^\n]*', '', text)


def host_outcome_copy():
    """Read GetTCWebOutcomeCopy from the host so the browser is tested against
    the sentence the host really sends, not a copy pasted into this test."""
    shell = source_without_comments(package / 'ui' / 'WebShell.ps1')
    block = re.search(r'function GetTCWebOutcomeCopy.*?\n}\n', shell, flags=re.S)
    if block is None:
        raise AssertionError('ui/WebShell.ps1 缺少 GetTCWebOutcomeCopy')
    pattern = re.compile(r"'(?P<status>\w+)'\{return @\{Label='(?P<label>[^']*)';"
                         r"Message='(?P<message>[^']*)';NextAction='(?P<action>\w+)'\}\}")
    copy = {match.group('status'): match.groupdict() for match in pattern.finditer(block.group(0))}
    if set(copy) != set(DESIGN):
        raise AssertionError(f'宿主五终态文案不完整：{sorted(copy)}')
    return copy


def static_guards():
    app = source_without_comments(package / 'web' / 'app.js')
    raw_app = (package / 'web' / 'app.js').read_text(encoding='utf-8')
    check(re.search(r'5\s*\*\s*60|TotalMinutes', app) is None,
          '静态守卫：app.js 不含把 5*60/TotalMinutes 当等待预算')

    # 300 is legitimate as an SVG width; only a time-flavoured 300 is a defect.
    time_words = re.compile(r'秒|BUDGET|SECONDS|TIMEOUT|DEADLINE|MINUTE', re.I)
    offenders = [match.start() for match in re.finditer(r'\b300\b', app)
                 if time_words.search(app[max(0, match.start() - 40):match.end() + 40])]
    check(not offenders, '静态守卫：app.js 未把 300 当作等待预算（秒/毫秒/分钟换算）')

    budget = re.search(r'TEST_BUDGET_SECONDS\s*=\s*(\d+)', app)
    check(budget is not None and budget.group(1) == '45', '静态守卫：app.js 的 TEST_BUDGET_SECONDS 为 45')
    host = (package / 'LineConnectionCheck.psm1').read_text(encoding='utf-8')
    timeout = re.search(r'TimeoutSeconds\s*=\s*(\d+)', host)
    check(timeout is not None and budget is not None and timeout.group(1) == budget.group(1),
          '静态守卫：TEST_BUDGET_SECONDS 与 LineConnectionCheck.psm1 的 TimeoutSeconds 数值一致')

    shell = source_without_comments(package / 'ui' / 'WebShell.ps1')
    copy_block = re.search(r'function GetTCWebOutcomeCopy.*?\n}\n', shell, flags=re.S)
    check(copy_block is not None and '已恢复' not in copy_block.group(0),
          '静态守卫：宿主五终态文案中只有 RolledBack 可声称恢复')
    check('已恢复' not in app, '静态守卫：app.js 源码（去注释）不含「已恢复」')


success, failure = False, ''
try:
    with sync_playwright() as p:
        browser = p.chromium.launch(channel='msedge', headless=True)
        context = browser.new_context(viewport={'width': 1280, 'height': 900}, color_scheme='light')
        context.add_init_script(bridge)

        def reject_external(route):
            external_requests.append(route.request.url)
            route.abort()

        context.route('http://**/*', reject_external)
        context.route('https://**/*', reject_external)
        page = context.new_page()
        page.on('pageerror', lambda error: page_errors.append(str(error)))
        page.on('console', lambda message: console_errors.append(message.text)
                if message.type == 'error' else None)
        page.goto((package / 'web' / 'index.html').as_uri())
        page.wait_for_load_state('networkidle')

        def send(value, target='home', stamp_at=None):
            value = deepcopy(value)
            value['SnapshotAtUtc'] = stamp() if stamp_at is None else stamp_at
            page.evaluate('payload => window.__stateSend(payload)',
                          {'Type': 'snapshot', 'Page': target, 'State': value})
            expect(page.locator('h1')).to_have_count(1)

        def send_raw(value, target='home', stamp_at=None):
            """For snapshots that are expected to degrade: no <h1> may survive."""
            value = deepcopy(value)
            value['SnapshotAtUtc'] = stamp() if stamp_at is None else stamp_at
            page.evaluate('payload => window.__stateSend(payload)',
                          {'Type': 'snapshot', 'Page': target, 'State': value})

        def row(line_id):
            # 0.20: the line table became a card list; the card is the row.
            return page.locator('[data-testid=line-card]').filter(
                has=page.locator(f'.name-button[data-detail="{line_id}"]'))

        def open_detail(line_id):
            page.locator(f'.name-button[data-detail="{line_id}"]').click()
            expect(page.locator('#drawer')).to_be_visible()

        def close_detail():
            page.keyboard.press('Escape')
            expect(page.locator('#drawer')).to_be_hidden()

        def main_text():
            return page.locator('#main').inner_text()

        def no_js_errors(label):
            check(not page_errors and not console_errors,
                  f'{label}：没有未捕获的 JS 报错（pageerror 与控制台 error 均为空）')

        # ---------------------------------------------------------------- 1 guard
        def guard_states():
            for guard, summary, tone in [('Protected', PROTECTED, 'guard-protected'),
                                         ('Unprotected', UNPROTECTED, 'guard-unprotected'),
                                         ('Unknown', UNKNOWN, 'guard-unknown')]:
                state = sample()
                state['Guard'] = guard
                state['GuardSummary'] = summary
                send(state)
                check(page.locator(f'.guard-card.{tone}').count() == 1,
                      f'保护三态：Guard={guard} → .guard-card.{tone}')
                check(page.locator('#guard-title').inner_text() == summary,
                      f'保护三态：Guard={guard} → 标题等于 GuardSummary')

            state = sample()
            state['Guard'] = 'Unknown'
            state.pop('GuardSummary')
            send(state)
            check(page.locator('#guard-title').inner_text() == UNKNOWN,
                  '保护三态：GuardSummary 缺失 → 本地兜底文案，不空白')

            state = sample()
            state['Guard'] = 'Unprotected'
            state['TradeProgramCount'] = 0
            send(state)
            check(page.locator('.guard-card.guard-unknown').count() == 1 and
                  page.locator('.guard-card.guard-unprotected').count() == 0,
                  '零程序特例：TradeProgramCount=0 → guard-unknown，不画成红色故障')
            check(page.locator('#guard-title').inner_text() == '尚未添加受保护的程序',
                  '零程序特例：标题是「尚未添加受保护的程序」')
            check(page.locator('.guard-card [data-action=domains]').count() == 1,
                  '零程序特例：主按钮是「添加交易程序」(domains)')
        scenario('保护三态', guard_states)

        # ----------------------------------------------------------- 2 countdown
        def countdown():
            state = sample()
            state['Pending'] = {'Name': '模拟香港主线', 'SessionId': 's-1',
                                'DeadlineUtc': iso_after(125), 'SecondsRemaining': 125}
            send(state)
            text = page.locator('.countdown').inner_text().strip()
            check(re.fullmatch(r'剩余 2:0\d', text) is not None,
                  f'等待倒计时：DeadlineUtc=now+125s → .countdown 匹配 剩余 2:0\\d（实际「{text}」）')
            check('退出交易软件后会连接「模拟香港主线」' in page.locator('.wait-notice').inner_text(),
                  '等待倒计时：等待条同时说明在等哪个交易软件')

            state['Pending'] = {'Name': '模拟香港主线', 'SessionId': 's-1'}
            before = len(page_errors) + len(console_errors)
            send(state)
            check(page.locator('.countdown').count() == 0,
                  '等待倒计时：DeadlineUtc 缺失 → 不显示数字')
            check('退出交易软件后会连接' in page.locator('.wait-notice').inner_text(),
                  '等待倒计时：DeadlineUtc 缺失 → 仍显示等待提示')
            check(len(page_errors) + len(console_errors) == before, '等待倒计时：DeadlineUtc 缺失 → 不报错')
        scenario('等待倒计时', countdown)

        # ------------------------------------------------------------ 3 outcomes
        def outcomes():
            copy = host_outcome_copy()
            for status, (action, tone) in DESIGN.items():
                entry = copy[status]
                rendered_action, button_label = RENDER[status]
                check(entry['action'] == action,
                      f'五终态 {status}：宿主 NextAction 为 {action}（设计 §4.1）')
                check(SEMANTICS[status] in entry['message'],
                      f'五终态 {status}：宿主文案含「{SEMANTICS[status]}」')
                if status in FORBIDDEN:
                    check('已恢复' not in entry['message'],
                          f'禁用词 {status}：宿主文案不含「已恢复」')

                state = sample()
                state['Lines'][0]['LastOutcome'] = {'Status': status, 'Label': entry['label'],
                                                    'Message': entry['message'],
                                                    'NextAction': entry['action'],
                                                    'ExpiresAtUtc': iso_after(3600)}
                send(state)
                bar = page.locator('.outcome-row .outcome')
                check(bar.count() == 1, f'五终态 {status}：结果条渲染一次')
                check(entry['message'] in bar.inner_text(),
                      f'五终态 {status}：结果条文案等于宿主文案')
                check(tone in (bar.get_attribute('class') or ''),
                      f'五终态 {status}：结果条语气为 {tone}')
                target = bar.locator(DOM[rendered_action])
                check(target.count() == 1, f'五终态 {status}：下一步按钮动作为 {rendered_action}')
                check(target.first.inner_text().strip() == button_label,
                      f'五终态 {status}：下一步按钮文案为「{button_label}」')
                if status in FORBIDDEN:
                    check('已恢复' not in main_text(), f'禁用词 {status}：页面文本不含「已恢复」')

            # NeedsRecovery with a pending connection operation must offer review.
            state = sample()
            state['Lines'][0]['LastOutcome'] = {'Status': 'NeedsRecovery', 'Label': copy['NeedsRecovery']['label'],
                                               'Message': copy['NeedsRecovery']['message'],
                                               'NextAction': 'ReviewOperation', 'ExpiresAtUtc': iso_after(3600)}
            state['PendingOperations'] = [{'Id': 'op-1', 'Kind': 'Connection', 'Message': '切换结果需要核对'}]
            send(state)
            review = page.locator('.outcome-row .outcome [data-action=reviewOperation]')
            check(review.count() == 1 and review.inner_text().strip() == '查看并处理',
                  'NeedsRecovery：有未完成连接操作 → 按钮「查看并处理」(reviewOperation)')

            # Completed on the line that is already connected repeats the status card.
            state = connected_sample()
            state['Lines'][0]['LastOutcome'] = {'Status': 'Completed', 'Label': copy['Completed']['label'],
                                               'Message': copy['Completed']['message'], 'NextAction': 'Details',
                                               'ExpiresAtUtc': iso_after(3600)}
            send(state)
            check(page.locator('.outcome-row').count() == 0,
                  'Completed 去重：同线路已连接 → 不渲染结果条')
            state['Running'] = False
            state['State'] = 'Disconnected'
            send(state)
            check(page.locator('.outcome-row').count() == 1,
                  'Completed 去重：断开后结果条作为上次操作证据出现')
        scenario('五终态结果条', outcomes)

        # ---------------------------------------------------------- 4 in flight
        def in_flight():
            state = sample()
            state['Operation'] = {'Kind': 'Test', 'LineId': 'main', 'Name': '模拟香港主线',
                                  'Message': '正在测速', 'StartedAtUtc': iso_after(-12)}
            send(state)
            check('正在测速' in page.locator('.operation-bar').inner_text(),
                  '进行中：.operation-bar 说明正在测速')
            check(re.search(r'1[2-4] 秒', page.locator('.operation-bar [data-elapsed]').inner_text()) is not None,
                  '进行中：.operation-bar 显示已用秒数')
            open_detail('main')
            test_button = page.locator('#drawer [data-action=testLine]')
            check(test_button.is_disabled(), '进行中：测速按钮 disabled')
            check('12 秒' in test_button.inner_text(), '进行中：测速按钮含「12 秒」')
            close_detail()

            state = sample()
            state['Operation'] = {'Kind': 'Connect', 'LineId': 'main', 'Name': '模拟香港主线',
                                  'Message': '正在连接', 'StartedAtUtc': iso_after(-12)}
            send(state)
            primary = page.locator('.hero [data-action=connect]')
            check(primary.is_disabled(), '进行中：Kind=Connect → 首页主按钮 disabled')
            check('连接中' in primary.inner_text() and '12 秒' in primary.inner_text(),
                  '进行中：Kind=Connect → 首页主按钮含「连接中」与「12 秒」')
        scenario('进行中状态', in_flight)

        # ------------------------------------------------------ 5 exit evidence
        def exit_evidence():
            cases = [
                ({'Verified': True, 'Attribution': 'ServerVerifiedTlsTrace', 'Status': 'Passed',
                  'Code': '', 'CheckedAtUtc': iso_after(-30)}, '出口已核验'),
                ({'Verified': False, 'Attribution': 'InferredNotAuthoritative', 'Status': 'Passed',
                  'Code': '', 'CheckedAtUtc': iso_after(-30)}, '转发已通，归属未验证'),
                ({'Verified': False, 'Attribution': 'SelectedTradeExit', 'Status': 'Failed',
                  'Code': 'TraceFailedOrInconsistent', 'CheckedAtUtc': iso_after(-30)}, '本次核验未通过，请运行诊断'),
                ({'Verified': False, 'Attribution': 'Unknown', 'Status': 'Unknown',
                  'Code': '', 'CheckedAtUtc': None}, '尚未核验'),
            ]
            for evidence, expected in cases:
                state = connected_sample()
                state['ExitEvidence'] = evidence
                send(state)
                check(page.locator('.exit-line .badge').inner_text().strip() == expected,
                      f'出口四级：Status={evidence["Status"]},Verified={evidence["Verified"]} → 徽章「{expected}」')

            state = connected_sample()
            state.pop('ExitEvidence')
            before = len(page_errors) + len(console_errors)
            send(state)
            check(page.locator('.exit-line .badge').inner_text().strip() == '尚未核验',
                  '出口字段缺失：ExitEvidence 缺失 → 徽章「尚未核验」')
            check(len(page_errors) + len(console_errors) == before, '出口字段缺失：不抛错')
        scenario('出口四级', exit_evidence)

        # -------------------------------------------------------- 6 heartbeat
        def heartbeat():
            state = sample()
            send(state, stamp_at=stamp(-12))
            banner = page.locator('.stale-banner')
            check(banner.count() == 1, '心跳：SnapshotAtUtc=now-12s → .stale-banner 出现')
            check('数据过期' in banner.inner_text(), '心跳：.stale-banner 文案含「数据过期」')
            check(page.locator('.hero .signal-title').inner_text().strip() == '状态未知',
                  '心跳：过期的快照不再声称任何连接状态')
            check(banner.locator('[data-action=refresh]').count() == 0,
                  '心跳：首页 banner 不再重复刷新按钮')
            check(page.locator('.hero [data-action=refresh]').count() == 1,
                  '心跳：刷新入口留在状态卡')

            state = sample()
            send(state, stamp_at=stamp(-3))
            check(page.locator('.stale-banner').count() == 0, '心跳：SnapshotAtUtc=now-3s → 不出现 .stale-banner')

            state = sample()
            state.pop('SnapshotAtUtc')
            send(state)
            check(page.locator('.stale-banner').count() == 0,
                  '心跳：SnapshotAtUtc 缺失 → 不误报「状态未知」')
        scenario('心跳', heartbeat)

        # ------------------------------------------------------ 7 empty state
        def empty_state():
            state = sample()
            state['Lines'] = []
            before = len(page_errors) + len(console_errors)
            send(state)
            # 0.21.2: the empty-state primary opens the native add-line page
            # (pairStart) instead of the legacy form (joinLine).
            join = page.locator('.guide-hero [data-action=pairStart]')
            build = page.locator('.guide-hero [data-action=add]')
            check(join.count() == 1 and join.inner_text().strip() == '用邀请码加入',
                  '空状态：主按钮「用邀请码加入」(pairStart)')
            check(build.count() == 1 and build.inner_text().strip() == '自己搭服务器',
                  '空状态：次按钮「自己搭服务器」(add)')
            check(len(page_errors) + len(console_errors) == before, '空状态：没有 JS 报错')

            send(state, target='lines')
            check(page.locator('.guide-card').count() == 1 and '还没有线路' in page.locator('.guide-card').inner_text(),
                  '空状态：线路页用 .guide-card 引导，而不是空白表格')
            send(sample())
        scenario('空状态', empty_state)

        # --------------------------------------------------------- 8 test copy
        def test_copy():
            state = sample()
            send(state)
            open_detail('main')
            label = page.locator('#drawer [data-action=testLine]').inner_text().strip()
            check(label == '测速（最长 45 秒）', f'测速文案：「测速（最长 45 秒）」（实际「{label}」）')
            close_detail()
        scenario('测速文案', test_copy)

        # -------------------------------------------------------- 9 degradation
        def degradation():
            no_js_errors('降级前')
            caught = len(console_errors)

            state = sample()
            state['Lines'] = [None]
            send_raw(state)
            page.wait_for_timeout(50)
            check('界面状态暂时无法显示' in main_text(),
                  '降级：畸形快照（Lines=[null]）→ #main 出现「界面状态暂时无法显示」')
            check(main_text().strip() != '', '降级：畸形快照不白屏')

            state = sample()
            state['Lines'] = None
            send_raw(state)
            page.wait_for_timeout(50)
            text = main_text()
            check('界面状态暂时无法显示' in text,
                  '降级：Lines=null → #main 出现「界面状态暂时无法显示」')
            check(text.strip() != '', '降级：Lines=null 不白屏')
            check(page.locator('#main [data-action=refresh]').count() == 1 and
                  page.locator('#main [data-action=diagnostics]').count() == 1,
                  '降级：降级卡提供「刷新」与「运行诊断」')

            # The fallback must swallow the failure: no uncaught error, and only
            # the one documented console line per failed paint.
            check(not page_errors, '降级：绘制失败被 render() 捕获，没有未捕获异常')
            logged = console_errors[caught:]
            check(len(logged) == 2 and all(item.startswith('render failed') for item in logged),
                  f'降级：每次绘制失败只记一条 render failed（实际 {len(logged)} 条）')

            send(sample())
            check(page.locator('.guard-card').count() == 1, '降级：恢复合法快照后页面重新渲染')

        # ------------------------------------------------------ 10 static guards
        scenario('静态守卫', static_guards)

        # ---------------------------------------------- 11 dark theme smoke pass
        def dark_theme():
            page.emulate_media(color_scheme='dark')
            rollback = host_outcome_copy()['RolledBack']
            state = sample()
            state['Guard'] = 'Unprotected'
            state['GuardSummary'] = UNPROTECTED
            state['Lines'][0]['LastOutcome'] = {'Status': 'RolledBack', 'Label': rollback['label'],
                                               'Message': rollback['message'], 'NextAction': 'Details',
                                               'ExpiresAtUtc': iso_after(3600)}
            send(state)
            check(page.locator('.guard-card.guard-unprotected').count() == 1 and
                  page.locator('.outcome.outcome-warn').count() == 1,
                  '暗色主题：保护卡与结果条同样渲染')
            page.screenshot(path=str(report / 'dark-state-truth.png'), full_page=True)
            page.emulate_media(color_scheme='light')
        scenario('暗色主题', dark_theme)

        page.screenshot(path=str(report / 'light-state-truth.png'), full_page=True)
        no_js_errors('整轮')
        check(not external_requests, '整轮：没有外部网络请求')

        # A degraded snapshot is expected to log once, so it runs last.
        scenario('降级', degradation)
        check(not page_errors, '整轮：没有未捕获的 JS 异常')
        context.close()
        browser.close()
    success = not failures
except Exception as error:
    failure = str(error)
    raise
finally:
    (report / 'result.json').write_text(json.dumps({
        'Passed': success and not failures, 'Checks': len(checks), 'Failed': len(failures),
        'Assertions': checks, 'Failures': failures, 'Failure': failure,
        'PageErrors': page_errors, 'ConsoleErrors': console_errors, 'ExternalRequests': external_requests,
        'ProductionDataAccessed': False, 'Scope': 'Static web page with a synthetic WebView bridge',
    }, ensure_ascii=False, indent=2), encoding='utf-8')
print(json.dumps({'Passed': success and not failures, 'Checks': len(checks),
                  'Failed': len(failures), 'Failures': failures, 'Report': str(report)},
                 ensure_ascii=False))
