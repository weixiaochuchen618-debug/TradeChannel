"""Isolated web state/keyboard checks. No Worker, installed app or real line data.

Optional host contract on each Lines entry:
  RecentConnectionFailure = {ProfileId: str, ExpiresAtUtc: ISO UTC timestamp}
The host must omit it unless the latest attempt failed and its line, method and
configuration still match the current selection. The browser checks method and
expiry again; Prepared alone never asserts network availability.
"""
import argparse
from copy import deepcopy
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import tempfile

from playwright.sync_api import expect, sync_playwright


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--package', type=Path, default=Path(__file__).resolve().parents[1])
parser.add_argument('--report', type=Path)
args = parser.parse_args()
package = args.package.resolve()
report = args.report or Path(tempfile.mkdtemp(prefix='tradechannel-web-states-'))
report.mkdir(parents=True, exist_ok=True)
checks, errors, external_requests = [], [], []

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


def utc_after(seconds):
    return (datetime.now(timezone.utc) + timedelta(seconds=seconds)).isoformat().replace('+00:00', 'Z')


def check(condition, message):
    if not condition:
        raise AssertionError(message)
    checks.append(message)


def sample():
    return {
        'Version': '0.18.3', 'State': 'Disconnected', 'Running': False,
        'Busy': False, 'ReadOnly': False, 'Guard': 'Protected', 'TradeProgramCount': 1,
        'TradeExit': 'hk', 'TradeName': '上次使用的线路', 'ActiveLineId': 'main',
        'ActiveProfile': 'Udp', 'PreferredLineId': 'main', 'Daily': 'Direct',
        'Agents': 'Daily', 'Tasks': [], 'Providers': [],
        'Lines': [
            {'Id': 'main', 'Name': '模拟香港主线', 'Profile': 'Udp', 'Prepared': True, 'Blocked': False, 'Readiness': {'State': 'Verified', 'Label': '可用', 'Reason': ''}},
            {'Id': 'test', 'Name': '模拟测试线路', 'Profile': 'Tcp', 'Prepared': True, 'Blocked': False, 'Readiness': {'State': 'Untested', 'Label': '未测试', 'Reason': '还没有测试过'}},
        ],
        # Deliberately include a previous measurement in a stopped snapshot.
        'Quality': {'LatencyMs': 42, 'Degraded': True, 'NotificationMessage': '旧测量警告',
                    'History': [{'LatencyMs': 39}, {'LatencyMs': 42}]},
    }


success, failure = False, ''
try:
    with sync_playwright() as p:
        browser = p.chromium.launch(channel='msedge', headless=True)
        for theme in ['light', 'dark']:
            context = browser.new_context(viewport={'width': 1280, 'height': 900}, color_scheme=theme)
            context.add_init_script(bridge)

            def reject_external(route):
                external_requests.append(route.request.url)
                route.abort()

            context.route('http://**/*', reject_external)
            context.route('https://**/*', reject_external)
            page = context.new_page()
            page.on('pageerror', lambda error: errors.append(str(error)))
            page.on('console', lambda message: errors.append(message.text) if message.type == 'error' else None)
            page.goto((package / 'web' / 'index.html').as_uri())
            page.wait_for_load_state('networkidle')

            def send(value, target='home'):
                page.evaluate('payload => window.__stateSend(payload)',
                              {'Type': 'snapshot', 'Page': target, 'State': deepcopy(value)})
                expect(page.locator('h1')).to_have_count(1)

            def row(line_id):
                return page.locator('.line-table tbody tr').filter(
                    has=page.locator(f'.name-button[data-detail="{line_id}"]'))

            def badge(line_id):
                return row(line_id).locator('.badge')

            def open_detail(line_id):
                page.locator(f'.name-button[data-detail="{line_id}"]').click()
                expect(page.locator('#drawer')).to_be_visible()

            def close_detail():
                page.keyboard.press('Escape')
                expect(page.locator('#drawer')).to_be_hidden()

            def actions(kind):
                return page.evaluate('kind => window.__stateMessages.filter(m => m.Type === kind)', kind)

            prefix = f'{theme}: '

            state = sample()
            send(state)
            check(page.locator('.hero .sub').inner_text() == '下次连接：模拟香港主线', prefix + 'stopped hero names the next line')
            check(page.locator('.hero-bottom,.hero .metric,.hero .chart-empty').count() == 0,
                  prefix + 'stopped hero has no empty metrics or trend')
            check('连接后显示响应' in page.locator('.hero').inner_text(), prefix + 'stopped response is explained in one line')
            check('—' not in page.locator('.hero').inner_text() and 'ms' not in page.locator('.hero').inner_text(),
                  prefix + 'stopped hero does not show a latency placeholder')
            check('响应' not in page.locator('.line-table thead').inner_text(), prefix + 'stopped table omits the measurement column')
            check('旧测量警告' not in page.locator('#main').inner_text(), prefix + 'stopped view ignores old quality alerts')
            check('可连接' not in page.locator('#main').inner_text(), prefix + 'preparation does not promise a usable network')
            check(badge('test').inner_text() == '未测试', prefix + 'prepared line has neutral wording')
            check(page.locator('.guard-card.guard-protected').count() == 1 and '未连接时也会阻止名单内的交易程序直接上网。' in page.locator('.guard-card').inner_text(),
                  prefix + 'protection explains what happens while stopped')
            idle_height = page.locator('.hero').bounding_box()['height']
            check(idle_height < 190, prefix + 'stopped hero stays compact')
            page.screenshot(path=str(report / f'disconnected-{theme}.png'), full_page=True)
            for width in [1280, 960, 768]:
                page.set_viewport_size({'width': width, 'height': 900})
                check(page.evaluate('document.documentElement.scrollWidth <= document.documentElement.clientWidth'),
                      prefix + f'{width}px has no page overflow')
                check(page.locator('.hero button.primary').is_visible(), prefix + f'{width}px keeps the connection action visible')
            page.set_viewport_size({'width': 1280, 'height': 900})


            state['Lines'][1]['RecentConnectionFailure'] = {'ProfileId': 'Tcp', 'ExpiresAtUtc': utc_after(600)}
            send(state)
            check(badge('test').inner_text() == '上次连接未通过' and badge('main').inner_text() == '可用',
                  prefix + 'current failure belongs only to its own line')
            check(row('test').locator('[data-action=connect]').is_enabled(), prefix + 'failed connection can be retried manually')
            open_detail('test')
            check('上次连接未通过' in page.locator('#drawer').inner_text(), prefix + 'details and table use the same failure status')
            check(page.locator('#drawer [data-action=delete]').is_enabled(), prefix + 'stopped history alone does not disable delete')
            close_detail()

            for name, value in [
                ('another method', {'ProfileId': 'Udp', 'ExpiresAtUtc': utc_after(600)}),
                ('expired attempt', {'ProfileId': 'Tcp', 'ExpiresAtUtc': utc_after(-60)}),
                ('invalid expiry', {'ProfileId': 'Tcp', 'ExpiresAtUtc': 'invalid'}),
                ('ambiguous local time', {'ProfileId': 'Tcp', 'ExpiresAtUtc': '2099-01-01T00:00:00'}),
                ('missing expiry', {'ProfileId': 'Tcp'}),
            ]:
                state['Lines'][1]['RecentConnectionFailure'] = value
                send(state)
                check(badge('test').inner_text() == '未测试', prefix + name + ' does not mark the line as failed')

            state['Lines'][1].pop('RecentConnectionFailure')
            send(state)
            check(badge('test').inner_text() == '未测试', prefix + 'host clears the failure after configuration change or success')

            state['Lines'][1]['Profile'] = ''

            state['Lines'][1]['RecentConnectionFailure'] = {'ProfileId': 'Tcp', 'ExpiresAtUtc': utc_after(600)}
            send(state)
            check(badge('test').inner_text() == '未测试', prefix + 'unresolved automatic selection does not inherit another method failure')

            state['Lines'][1]['Profile'] = 'Tcp'

            state['Lines'][1].pop('RecentConnectionFailure')

            state['Lines'][1]['Prepared'] = False
            state['Lines'][1]['Readiness'] = {'State': 'NeedsAction', 'Label': '需要处理', 'Reason': '还没有可用的连接方式'}
            send(state)
            check(badge('test').inner_text() == '需要处理', prefix + 'unprepared line remains distinguishable')

            state['Lines'][1]['Prepared'] = True
            state['Lines'][1]['Readiness'] = {'State': 'Untested', 'Label': '未测试', 'Reason': ''}

            state['Lines'][1]['Blocked'] = True

            state['Lines'][1]['RecentConnectionFailure'] = {'ProfileId': 'Tcp', 'ExpiresAtUtc': utc_after(600)}
            send(state)
            # 0.21.2: the blocked card offers its repair (server identity check)
            # instead of a disabled connect button.
            check(badge('test').inner_text() == '需要处理' and row('test').locator('[data-action=connect]').count() == 0
                  and row('test').locator('[data-action=lineServer]').is_enabled(),
                  prefix + 'identity block takes priority over historical failure')

            state = sample()

            state['Lines'][1]['RecentConnectionFailure'] = {'ProfileId': 'Tcp', 'ExpiresAtUtc': utc_after(1.2)}
            send(state)
            expect(badge('test')).to_have_text('上次连接未通过')
            expect(badge('test')).to_have_text('未测试', timeout=3000)
            check(True, prefix + 'failure expires even without another host snapshot')


            state = sample()

            state['PreferredLineId'] = 'test'
            send(state)
            check(page.locator('.hero .sub').inner_text() == '下次连接：模拟测试线路', prefix + 'chosen next line is unambiguous')
            start = len(actions('connect'))
            page.locator('.hero [data-action=connect]').focus()
            page.keyboard.press('Enter')
            check(len(actions('connect')) == start + 1 and actions('connect')[-1]['Id'] == 'test',
                  prefix + 'keyboard connection targets the displayed next line')

            state['PreferredLineId'] = 'removed-line'
            send(state)
            check(page.locator('.hero [data-action=connect]').get_attribute('data-id') == 'main',
                  prefix + 'missing preference falls back to the line actually displayed')

            state['Lines'][0]['Blocked'] = True
            send(state)
            check(page.locator('.hero [data-action=connect]').count() == 0 and page.locator('.hero [data-action=lineServer]').is_enabled(),
                  prefix + 'hero offers the identity check for a blocked next line')

            state = sample()

            state['Lines'] = []
            send(state)
            check(page.locator('.hero [data-action=add]').is_enabled() and page.locator('.hero [data-detail]').count() == 0,
                  prefix + 'empty list has an add action without stale history links')
            for guard in ['Unprotected', 'Unknown']:
                state = sample()
                state['Guard'] = guard
                send(state)
                check(page.locator('.guard-card.guard-' + ('unprotected' if guard == 'Unprotected' else 'unknown')).count() == 1 and '直连保护已启用' not in page.locator('.guard-card').inner_text(),
                      prefix + guard + ' does not falsely claim protection')


            state = sample()

            state.update({'State': 'Connected', 'Running': True, 'TradeName': '模拟香港主线'})

            state['Quality']['Degraded'] = False
            send(state)
            check(page.locator('.hero-idle').count() == 0 and page.locator('.hero .metric').inner_text() == '42ms',
                  prefix + 'live connection keeps its measured response')
            check(page.locator('.hero svg polyline').count() == 1, prefix + 'live trend still renders')
            check(page.locator('.hero .badge.quality').count() == 0 and page.locator('#mini-status').inner_text().count('很好') == 0,
                  prefix + 'no quality band is shown without a backend verdict')
            for verdict, label in [('Good', '很好'), ('Fair', '一般'), ('Poor', '较差')]:
                state['Quality']['Quality'] = verdict
                send(state)
                check(page.locator('.hero .badge.quality').inner_text() == label and
                      page.locator('#mini-status').is_hidden() and
                      row('main').locator('.badge.quality').inner_text() == label,
                      prefix + verdict + ' shows ' + label + ' on hero and row without a duplicate home status card')
            check(row('main').locator('td.trend svg polyline').count() == 1 and
                  row('test').locator('td.trend svg').count() == 0 and
                  row('test').locator('td.trend').inner_text() == '—',
                  prefix + 'only the active line row shows the 30 minute trend')
            state['Quality']['Quality'] = 'Unknown'
            send(state)
            check(page.locator('.hero .badge.quality').count() == 0, prefix + 'Unknown shows no band')
            del state['Quality']['Quality']
            send(state)
            check(page.locator('.hero').bounding_box()['height'] > idle_height + 40, prefix + 'stopped layout uses substantially less height')
            check(badge('main').inner_text() == '使用中', prefix + 'running line status is explicit')
            page.screenshot(path=str(report / f'connected-{theme}.png'), full_page=True)
            open_detail('main')
            remove = page.locator('#drawer [data-action=delete]')
            check(remove.get_attribute('aria-disabled') == 'true' and
                  page.locator('#line-delete-hint').inner_text() == '断开后可删除' and
                  remove.get_attribute('aria-describedby') == 'line-delete-hint',
                  prefix + 'in-use delete has an accessible reason')
            before = len(actions('delete'))
            remove.focus()
            page.keyboard.press('Enter')
            check(len(actions('delete')) == before and remove.evaluate('element => element === document.activeElement'),
                  prefix + 'unavailable delete is focusable but cannot dispatch')
            for _ in range(9):
                page.keyboard.press('Tab')
                check(page.evaluate('document.querySelector("#drawer").contains(document.activeElement)'),
                      prefix + 'keyboard focus remains inside details')
            close_detail()
            check(page.evaluate('document.activeElement.dataset.detail') == 'main', prefix + 'Escape restores focus to the line')
            before = len(actions('disconnect'))
            page.locator('.hero [data-action=disconnect]').click()
            check(len(actions('disconnect')) == before + 1 and page.locator('#dialog-root').is_hidden(),
                  prefix + 'disconnect dispatches immediately without confirmation')


            state['State'] = 'Disconnecting'
            send(state)
            open_detail('main')
            check(page.locator('#drawer [data-action=delete]').get_attribute('aria-disabled') == 'true',
                  prefix + 'still-running line stays protected during disconnect')
            close_detail()

            state['State'] = 'Disconnected'

            state['Running'] = False
            send(state)
            open_detail('main')
            check(page.locator('#drawer [data-action=delete]').is_enabled() and
                  page.locator('#drawer [data-action=delete]').get_attribute('aria-disabled') is None,
                  prefix + 'stopped line is no longer disabled just because ActiveLineId is retained')
            close_detail()

            state['State'] = 'ReadUnknown'
            send(state)
            check(page.locator('.hero [data-action=connect]').is_disabled() and
                  '下次连接' not in page.locator('.hero .sub').inner_text(),
                  prefix + 'unknown state is not presented as a confirmed stop')

            state = sample()

            state['Busy'] = True

            state['DeleteOperation'] = {'Id': 'delete-operation', 'Phase': 'Previewing',
                                        'Message': '正在检查「模拟测试线路」是否可删除', 'CanCancel': True}
            send(state)
            check(page.locator('[data-action=cancelDeletePreview]').is_enabled(),
                  prefix + 'read-only preview remains cancellable while busy')
            page.locator('[data-action=cancelDeletePreview]').click()
            check(actions('cancelDeletePreview')[-1]['Id'] == 'delete-operation',
                  prefix + 'cancel is bound to the original delete operation')

            state['Dialog'] = {'Id': 'wait-dialog', 'Title': '正在检查「模拟测试线路」是否可删除',
                               'Body': '正在核对本机使用情况。可以取消等待，资料会保留。',
                               'Confirm': '取消检查', 'Cancel': '', 'Progress': True}
            send(state)
            check(page.locator('[role=alertdialog]').get_attribute('aria-busy') == 'true',
                  prefix + 'preview dialog exposes a named busy state')
            check(page.locator('[role=alertdialog] .cleanup-step').count() == 3 and
                  page.locator('[role=alertdialog] .spinner').count() == 0,
                  prefix + 'delete progress has three stable steps without a title spinner')
            page.emulate_media(reduced_motion='reduce')
            check(page.locator('[role=alertdialog] .cleanup-track span').evaluate(
                "element => getComputedStyle(element).animationName") == 'none',
                prefix + 'reduced motion uses a stationary progress track')
            page.emulate_media(reduced_motion='no-preference')
            previous = len(actions('confirmDialog'))
            page.keyboard.press('Escape')
            check(len(actions('confirmDialog')) == previous + 1 and
                  actions('confirmDialog')[-1]['Id'] == 'wait-dialog',
                  prefix + 'Escape cancels waiting rather than submitting deletion')

            state['Busy'] = False

            state['Dialog'] = {'Id': 'delete-confirmation', 'Title': '删除「模拟测试线路」？',
                               'Body': '将移除此电脑上的线路及仅供它使用的资料。服务器上的服务会保留。',
                               'Details': '原连接记录：fixture\n<img onerror="bad()">',
                               'Confirm': '删除线路', 'Cancel': '取消', 'Danger': True}
            send(state)
            check(page.locator('.dialog-details').get_attribute('open') is None,
                  prefix + 'technical evidence is folded by default')
            page.locator('.dialog-details summary').click()
            expect(page.locator('.dialog-details pre')).to_be_visible()
            check('<img onerror=' in page.locator('.dialog-details pre').inner_text() and
                  page.locator('.dialog-details img').count() == 0,
                  prefix + 'folded evidence is displayed as escaped text')
            page.locator('[data-action=cancelDialog]').click()
            check(actions('cancelDialog')[-1]['Id'] == 'delete-confirmation',
                  prefix + 'one confirmation retains a safe cancel action')

            state['Dialog'] = None

            state['DeleteOperation'].update({'Phase': 'Blocked', 'CanCancel': False,
                                              'CanCheck': True, 'Message': '「模拟测试线路」尚未删除，需要检查处理。'})
            send(state)
            page.locator('[data-action=checkDelete]').click()
            check(actions('checkDelete')[-1]['Id'] == 'delete-operation',
                  prefix + 'cross-page blocked notice retains the original target')

            state['DeleteOperation'].update({'Phase': 'NotApplied', 'CanCheck': False,
                                             'CanRetry': True, 'Message': '「模拟测试线路」未删除。'})
            send(state)
            page.locator('[data-action=retryDelete]').click()
            check(actions('retryDelete')[-1]['Id'] == 'delete-operation',
                  prefix + 'a verified not-applied result keeps a target-bound retry entry')

            state['DeleteOperation'] = None

            state['DeleteRefresh'] = {'Id': 'delete-operation', 'Phase': 'Failed', 'CanRetry': True,
            'Message': '已删除「模拟测试线路」，列表暂未刷新。'}
            send(state)
            page.locator('[data-action=retryDeleteRefresh]').click()
            check(actions('retryDeleteRefresh')[-1]['Id'] == 'delete-operation',
                  prefix + 'refresh failure offers a read retry instead of another delete')
            # 0.18.4 line drawer: method switch, test, home default; in-place actions keep the drawer open.
            state = base_state() if 'base_state' in globals() else state
            state['State'] = 'Disconnected'; state['Running'] = False; state['Dialog'] = None
            state['DeleteOperation'] = None; state['DeleteRefresh'] = None
            state['Lines'] = [
                {'Id': 'main', 'Name': 'main-line', 'Profile': 'Udp', 'Prepared': True, 'Blocked': False, 'ProfileSource': 'DeploymentDefault',
                 'PreparedProfiles': ['Udp', 'Tcp'], 'Pending': '', 'Readiness': {'State': 'Untested', 'Label': '未测试', 'Reason': '上次测试没有完成'}},
                {'Id': 'other', 'Name': 'other-line', 'Profile': 'Tcp', 'Prepared': True, 'Blocked': False, 'ProfileSource': 'UserChoice',
                 'PreparedProfiles': ['Udp', 'Tcp'], 'Pending': '', 'Readiness': {'State': 'Verified', 'Label': '可用', 'Reason': ''}}]
            state['PreferredLineId'] = 'main'; state['HomeLineId'] = 'other'
            send(state)
            check(page.locator('.hero .sub').inner_text() == '下次连接：other-line', prefix + 'home default line wins over the routing preference')
            open_detail('main')
            drawer = page.locator('#drawer')
            check('上次测试没有完成' in drawer.inner_text(), prefix + 'status line carries a one-sentence reason')
            check(drawer.locator('[data-action=setProfile]').count() == 3 and drawer.locator('[data-value=Auto]').is_enabled(), prefix + 'method switch has selectable auto/standard/compatible')
            check(drawer.locator('[data-value=Auto]').get_attribute('aria-pressed') == 'true', prefix + 'auto shows as selected for a non-user choice')
            drawer.locator('[data-value=Tcp]').click()
            check(actions('setProfile')[-1] == {'Type': 'setProfile', 'Id': 'main', 'Value': 'Tcp', 'Sequence': actions('setProfile')[-1]['Sequence']}, prefix + 'one click saves the chosen method')
            check(page.locator('#drawer').is_visible(), prefix + 'saving happens in place without closing the drawer')
            state['Busy'] = False
            send(state)
            page.locator('#drawer [data-action=testLine]').click()
            check(actions('testLine')[-1]['Id'] == 'main' and page.locator('#drawer').is_visible(), prefix + 'test line dispatches and keeps the drawer')
            send(state)
            page.locator('#drawer [data-action=setHomeLine]').click()
            check(actions('setHomeLine')[-1]['Id'] == 'main', prefix + 'set default line dispatches setHomeLine')
            state['Lines'][0]['Pending'] = 'Saving'
            send(state)
            check(page.locator('#drawer [data-value=Udp]').is_disabled() and '正在保存' in page.locator('#drawer').inner_text(), prefix + 'saving shows in place')
            context.close()
        browser.close()
    check(not errors, 'No browser or content-security-policy errors')
    check(not external_requests, 'No external network requests')
    success = True
except Exception as error:
    failure = str(error)
    raise
finally:
    (report / 'result.json').write_text(json.dumps({
        'Passed': success, 'Checks': len(checks), 'Assertions': checks, 'Failure': failure,
        'BrowserErrors': errors, 'ExternalRequests': external_requests,
        'ProductionDataAccessed': False, 'Scope': 'Static web with a synthetic WebView bridge',
    }, ensure_ascii=False, indent=2), encoding='utf-8')
print(json.dumps({'Passed': success, 'Checks': len(checks), 'Report': str(report)}, ensure_ascii=False))
