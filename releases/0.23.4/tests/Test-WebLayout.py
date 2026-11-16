"""Visual/keyboard checks using isolated snapshots, never the installed product."""
import argparse
import json
from pathlib import Path
from playwright.sync_api import sync_playwright

parser = argparse.ArgumentParser()
parser.add_argument('--package', required=True)
parser.add_argument('--snapshots', required=True)
parser.add_argument('--report', required=True)
args = parser.parse_args()
package = Path(args.package).resolve()
snapshots = Path(args.snapshots).resolve()
report = Path(args.report).resolve()
report.mkdir(parents=True, exist_ok=True)
checks = []
errors = []

bridge = """
(() => {
  const callbacks = [];
  window.__layoutSnapshot = null;
  window.__layoutMessages = [];
  window.__layoutSequence = 0;
  window.__layoutSend = data => {
    window.__layoutSnapshot = structuredClone(data);
    window.__layoutSnapshot.State.Ack = window.__layoutSequence;
    callbacks.forEach(callback => callback({data: window.__layoutSnapshot}));
  };
  window.chrome = window.chrome || {};
  window.chrome.webview = {
    addEventListener: (name, callback) => callbacks.push(callback),
    postMessage: message => {
      window.__layoutSequence = message.Sequence;
      window.__layoutMessages.push({Type: message.Type, Id: message.Id});
      if (window.__layoutSnapshot && message.Type === 'navigate') {
        const next = structuredClone(window.__layoutSnapshot);
        next.Page = message.Page; next.State.Form = null;
        setTimeout(() => window.__layoutSend(next), 0);
      }
    }
  };
})();
"""

def check(condition, message):
    if not condition:
        raise AssertionError(message)
    checks.append(message)

cases = ['01-home', '02-settings', '03-diagnostics', '05-history',
         '06-maintenance', '07-websites', '08-ai-tools', '09-providers',
         '10-add-line', '13-connection-methods']
success = False
failure = ''
try:
    with sync_playwright() as p:
        browser = p.chromium.launch(channel='msedge', headless=True)
        for theme in ['light', 'dark']:
            context = browser.new_context(viewport={'width': 1280, 'height': 900}, color_scheme=theme)
            context.add_init_script(bridge)
            page = context.new_page()
            page.on('pageerror', lambda error: errors.append(str(error)))
            page.on('console', lambda message: errors.append(message.text) if message.type == 'error' else None)
            page.goto((package / 'web' / 'index.html').as_uri())
            page.wait_for_load_state('networkidle')
            for case in cases:
                payload = json.loads((snapshots / f'{case}.snapshot.json').read_text(encoding='utf-8-sig'))
                payload['State']['Toast'] = ''
                for width in [1280, 960]:
                    page.set_viewport_size({'width': width, 'height': 900})
                    page.evaluate('data => window.__layoutSend(data)', payload)
                    page.locator('h1').wait_for()
                    check(page.locator('h1').count() == 1, f'{case}/{theme}/{width}: one page title')
                    check(page.evaluate('document.documentElement.scrollWidth <= document.documentElement.clientWidth'),
                          f'{case}/{theme}/{width}: no horizontal overflow')
                    check(page.locator('input:not([aria-label]),textarea:not([aria-label]),select:not([aria-label])').count() == 0,
                          f'{case}/{theme}/{width}: form inputs have accessible names')
                    check(page.locator('button').evaluate_all('(buttons) => buttons.every(b => b.textContent.trim() || b.getAttribute("aria-label"))'),
                          f'{case}/{theme}/{width}: buttons have names')
                    if case == '10-add-line':
                        submit = page.locator('[data-control-name=ProductDeployInspect]').bounding_box()
                        password = page.locator('[data-control-name=DeployPassword]').bounding_box()
                        check(bool(submit and password and submit['y'] + submit['height'] <= 900 and password['y'] < 900),
                              f'{case}/{theme}/{width}: basic inputs and submit fit the viewport')
                    if width == 1280 and case in ['01-home','02-settings','03-diagnostics','10-add-line']:
                        page.screenshot(path=str(report / f'{case}-{theme}.png'), full_page=True)
            home = json.loads((snapshots / '01-home.snapshot.json').read_text(encoding='utf-8-sig'))
            page.set_viewport_size({'width':1280,'height':900})
            page.evaluate('data => window.__layoutSend(data)', home)
            page.locator('[data-detail]').first.click()
            check(page.locator('.layout').evaluate('element => element.inert'), f'{theme}: drawer isolates background controls')
            check(page.locator('#drawer .action-group[data-group=maintain] [data-action=lineSettings]').count() == 1
                  and page.locator('#drawer .action-group[data-group=maintain] [data-action=lineServer]').count() == 1,
                  f'{theme}: maintain group restores connection-method and server entries (0.21.2)')
            check(page.locator('#drawer .action-group').count() == 3, f'{theme}: drawer actions split into three groups (R12)')
            page.locator('[data-action=rename]').focus()
            page.evaluate('data => window.__layoutSend(data)', home)
            check(page.evaluate('document.activeElement.dataset.action') == 'rename', f'{theme}: refresh preserves drawer keyboard focus')
            for _ in range(8):
                page.keyboard.press('Tab')
                check(page.evaluate('document.querySelector("#drawer").contains(document.activeElement)'), f'{theme}: Tab remains inside the drawer')
            page.keyboard.press('Escape')
            check(page.locator('#drawer').is_hidden(), f'{theme}: Escape closes the drawer')
            context.close()
        browser.close()
    check(not errors, 'No browser or content-security-policy errors')
    success = True
except Exception as error:
    failure = str(error)
    raise
finally:
    (report / 'result.json').write_text(json.dumps({
        'Passed':success, 'Checks':len(checks), 'Assertions':checks,
        'Failure':failure, 'BrowserErrors':errors, 'NetworkChanged':False,
        'Scope':'Playwright layout and keyboard checks using isolated WebView workflow snapshots'
    }, ensure_ascii=False, indent=2), encoding='utf-8')
print(json.dumps({'Passed':success,'Checks':len(checks),'BrowserErrors':errors}))
