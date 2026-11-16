"""Isolated inline feedback and chrome density checks with no production data."""
import argparse
from copy import deepcopy
import json
from pathlib import Path
from playwright.sync_api import sync_playwright, expect

parser=argparse.ArgumentParser()
parser.add_argument('--package',type=Path,required=True)
parser.add_argument('--report',type=Path,required=True)
args=parser.parse_args();args.report.mkdir(parents=True,exist_ok=True)
checks=[];errors=[];external=[];passed=False;failure=''
bridge="""(() => {
 const listeners=[];let seq=0;window.messages=[];
 window.send=s=>{s.State.Ack=seq;listeners.forEach(f=>f({data:s}));};
 window.chrome=window.chrome||{};window.chrome.webview={
 addEventListener:(n,f)=>listeners.push(f),postMessage:m=>{seq=m.Sequence;window.messages.push(m);}
 };
})();"""
def check(ok,name):
 if not ok: raise AssertionError(name)
 checks.append(name)
def fixture():
 return {'Version':'0.18.9','State':'Connected','Running':True,'ReadOnly':False,'Busy':False,
 'TradeName':'主线路','TradeExit':'hk','ActiveLineId':'main','ActiveProfile':'Udp','HomeLineId':'main',
 'TradeProgramCount':1,'Guard':'Protected','Daily':'Direct','Agents':'Daily','Tasks':[],'Providers':[],
 'Quality':{'LatencyMs':42,'Quality':'Good','History':[{'LatencyMs':40},{'LatencyMs':42}]},
 'Lines':[{'Id':'main','Name':'主线路','Profile':'Udp','ProfileSource':'UserChoice','Prepared':True,'PreparedProfiles':['Udp','Tcp'],'Feedback':[]},
 {'Id':'backup','Name':'备用线路','Profile':'Tcp','ProfileSource':'UserChoice','Prepared':True,'PreparedProfiles':['Udp','Tcp'],'Feedback':[]}]}
try:
 with sync_playwright() as p:
  browser=p.chromium.launch(channel='msedge',headless=True)
  for theme in ['light','dark']:
   context=browser.new_context(viewport={'width':1280,'height':900},color_scheme=theme,reduced_motion='reduce')
   context.add_init_script(bridge)
   def reject(route):external.append(route.request.url);route.abort()
   context.route('https://**/*',reject);context.route('http://**/*',reject)
   page=context.new_page();page.on('pageerror',lambda e:errors.append(str(e)))
   page.goto((args.package.resolve()/'web/index.html').as_uri())
   def send(s,target='home'):page.evaluate('s=>window.send(s)',{'Type':'snapshot','Page':target,'State':deepcopy(s)})
   def count(kind):return page.evaluate('k=>window.messages.filter(m=>m.Type===k).length',kind)
   s=fixture();send(s)
   check(page.locator('#mini-status').is_hidden(),theme+': homepage has one full connection summary')
   check(page.locator('#version').count()==1 and page.locator('#version').inner_text()=='0.18.9 · 预览版',theme+': version has a single location')
   s['Deployments']=[{'RunId':'deployment-1','Name':'添加备用','Running':True,'Summary':'正在准备'}];send(s)
   check(page.locator('#mini-status .background-task').is_visible() and page.locator('#mini-status .mini-connection').count()==0,theme+': hiding home summary preserves background task entry')
   s['Deployments']=[];send(s,'lines')
   check(page.locator('#mini-status .mini-connection').is_visible() and '42 ms · 很好' in page.locator('#mini-status').inner_text(),theme+': other pages retain compact live state and response')
   f={'Id':'feedback-one','Kind':'Preference','ProfileId':'Tcp','Status':'Failed','Message':'所选兼容连接未保存，请重试。','ConnectionMessage':'当前仍连接「主线路」。','Code':'PreferenceWriteFailed','CanRetry':True,'NeedsReview':False}
   s['Lines'][1]['Feedback']=[f];send(s,'lines')
   check(page.locator('.feedback-row').count()==1 and '备用线路' in page.locator('.feedback-row').inner_text(),theme+': list feedback names its own target')
   page.locator('[data-detail=backup]').click()
   expect(page.locator('#drawer')).to_be_visible()
   check(page.locator('.feedback-row').is_hidden(),theme+': open details hide the repeated list feedback')
   check(page.locator('#drawer [data-value=Tcp]').get_attribute('aria-pressed')=='true',theme+': failed save keeps the last persisted choice')
   check(page.locator('#drawer .line-feedback').count()==1 and page.locator('#dialog-root').is_hidden(),theme+': failed save is inline without a popup')
   before=count('retryLineAction');page.locator('#drawer [data-action=retryLineAction]').click()
   check(count('retryLineAction')==before+1 and page.locator('#drawer').is_visible(),theme+': retry dispatches once and keeps the drawer open')
   message=page.evaluate('window.messages.filter(m=>m.Type==="retryLineAction").at(-1)')
   check(message['Id']=='backup' and message['Value']=='feedback-one',theme+': retry binds both line and feedback identity')
   check(page.locator('#drawer [data-action=retryLineAction]').is_disabled(),theme+': acknowledgement barrier disables duplicate clicks')
   send(s,'lines');f.update({'Id':'feedback-done','Status':'Succeeded','CanRetry':False,'Message':'已保存兼容连接，下次连接时生效。'});send(s,'lines')
   check(page.locator('#drawer [data-action=retryLineAction]').count()==0 and page.locator('.feedback-row').count()==0,theme+': confirmed success removes obsolete retry and list error')
   f.update({'Id':'check-failure','Kind':'Check','Status':'Inconclusive','CanRetry':True,'Message':'检查超时，请重试。','Code':'ProbeTimeout'});send(s,'lines')
   check(page.locator('#drawer [data-action=retryLineAction]').inner_text()=='重新测试' and '兼容连接测试' in page.locator('#drawer .line-feedback').inner_text(),theme+': timed-out test names the tested method and offers test retry')
   page.screenshot(path=str(args.report/f'inline-test-failed-{theme}.png'),full_page=True)
   f.update({'Id':'unknown-one','Status':'NeedsReview','CanRetry':False,'NeedsReview':True,'CanDiagnose':True,'ReviewLabel':'检查原操作','Message':'结果还没有确认，请先检查原操作。'});send(s,'lines')
   check(page.locator('#drawer [data-action=retryLineAction]').count()==0 and page.locator('#drawer [data-action=reviewLineAction]').is_visible(),theme+': unknown result offers review rather than replay')
   check(page.locator('#drawer [data-action=diagnostics]').is_visible(),theme+': unresolved result retains an independent diagnostic entry')
   page.locator('#drawer [data-action=reviewLineAction]').click()
   check(count('reviewLineAction')==1 and page.locator('#drawer').is_visible(),theme+': original operation review dispatches without losing target context')
   send(s,'lines');page.screenshot(path=str(args.report/f'inline-unknown-{theme}.png'),full_page=True)
   f.update({'Message':'<img src="https://invalid.example/leak" onerror="alert(1)">','Code':'<bad-code>'});send(s,'lines')
   check(page.locator('#drawer .line-feedback img').count()==0 and '<img src=' in page.locator('#drawer .line-feedback').inner_text(),theme+': all feedback content is escaped')
   for width in [1280,960,768]:
    page.set_viewport_size({'width':width,'height':900})
    check(page.evaluate('document.documentElement.scrollWidth <= document.documentElement.clientWidth'),theme+f': {width}px feedback has no page overflow')
    check(page.locator('#drawer [data-action=reviewLineAction]').is_visible(),theme+f': {width}px preserves the next action')
   s['ReadOnly']=True;send(s,'lines')
   check(page.locator('#drawer [data-action=reviewLineAction]').is_disabled(),theme+': read-only mode blocks action submission')
   s['ReadOnly']=False;s['Lines'][1]['Feedback']=[];send(s,'lines')
   page.keyboard.press('Escape')
   check(page.locator('#drawer').is_hidden(),theme+': Escape closes the drawer after feedback updates')
   context.close()
  browser.close()
 check(not errors,'no browser runtime errors')
 check(not external,'no external network requests')
 passed=True
except Exception as e:
 failure=str(e);raise
finally:
 result={'Passed':passed,'Checks':len(checks),'Assertions':checks,'Failure':failure,'BrowserErrors':errors,'ExternalRequests':external,'ProductionWrites':0}
 (args.report/'result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
 print(json.dumps({'Passed':passed,'Checks':len(checks),'Failure':failure},ensure_ascii=False))
