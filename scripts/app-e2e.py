#!/usr/bin/env python3
"""Drive the actual app through macOS accessibility; never reads a credential value."""
import json, pathlib, plistlib, subprocess, sys, time
ROOT=pathlib.Path(__file__).resolve().parents[1]
APP=ROOT/'dist/WYSIWAG.app'
EVIDENCE=ROOT/'docs/verification/evidence'
SCREENSHOTS=ROOT/'docs/screenshots'
for folder in [EVIDENCE, SCREENSHOTS]: folder.mkdir(parents=True,exist_ok=True)

def run(args, **kwargs): return subprocess.run(args,check=True,capture_output=True,text=True,**kwargs).stdout.strip()
def stop():
    result=subprocess.run(['pgrep','-f',str(APP/'Contents/MacOS/WYSIWAG')],capture_output=True,text=True)
    for pid in result.stdout.split(): subprocess.run(['kill',pid],check=False)
    time.sleep(.4)
def launch(*args):
    run(['open',str(APP),'--args','--evidence',*args]); time.sleep(1)
    pid=int(run(['pgrep','-f',str(APP/'Contents/MacOS/WYSIWAG')]).split()[0])
    # Foregrounding also makes accessory-app AX windows available on some macOS versions.
    run(['osascript','-e','tell application "System Events" to tell process "WYSIWAG" to set frontmost to true'])
    return pid

SCRIPT=r'''
on run argv
 set ident to item 1 of argv
 set actionName to item 2 of argv
 set inputValue to item 3 of argv
 tell application "System Events"
  tell process "WYSIWAG"
   set allItems to entire contents of window 1
   repeat with itemRef in allItems
    set foundIt to false
    try
     set foundIt to (value of attribute "AXIdentifier" of itemRef is ident)
    end try
    if foundIt then
     if actionName is "click" then
      perform action "AXPress" of itemRef
      return "pressed"
     else if actionName is "set" then
      set value of attribute "AXFocused" of itemRef to true
      keystroke "a" using command down
      keystroke inputValue
      key code 48
      return "typed"
     else if actionName is "pick" then
      click itemRef
      click menu item inputValue of menu 1 of itemRef
      return "picked"
     else if actionName is "enabled" then
      return value of attribute "AXEnabled" of itemRef as text
     else
      return value of attribute "AXValue" of itemRef as text
     end if
    end if
   end repeat
  end tell
 end tell
 error "Missing UI identifier: " & ident
end run
'''
def ui(ident,action='value',value=''):
    result=run(['osascript','-',ident,action,value],input=SCRIPT)
    time.sleep(.25)
    return result

def key_present():
    return subprocess.run(['security','find-generic-password','-s','com.wysiwag.evidence','-a','jevKey'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0

def preferences():
    raw=subprocess.run(['defaults','export','com.wysiwag.evidence','-'],check=True,capture_output=True).stdout
    return json.loads(plistlib.loads(raw)['settings'])

def screenshot(pid,path):
    # Read only this app's window list; do not capture the desktop or other apps.
    listing=json.loads(run(['orca','computer','list-windows','--app',f'pid:{pid}','--json']))
    windows=listing['result']['windows']
    window=next(w for w in windows if w['title']=='WYSIWAG')
    run(['screencapture','-x','-o','-l',str(window['id']),str(path)])

try:
    stop()
    subprocess.run(['security','delete-generic-password','-s','com.wysiwag.evidence','-a','jevKey'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    pid=launch('--reset-evidence','--language','en')
    assert ui('interval')=='5', 'first-run interval'
    assert ui('mode-AUTO')=='Selected', 'AUTO default'
    assert ui('mode-SMART','enabled')=='false', 'SMART must require key'
    screenshot(pid,SCREENSHOTS/'settings-en.png')
    ui('mode-ALL','click'); ui('interval','set','7'); ui('save-settings','click')
    assert preferences()['mode']=='ALL' and preferences()['interval']==7, 'save UI settings'
    ui('toggle-capture','click')
    all_status=ui('capture-status')
    all_permission='denied' if 'permission' in all_status else 'granted'
    if all_permission=='granted': ui('toggle-capture','click')
    stop(); pid=launch()
    assert ui('mode-ALL')=='Selected' and ui('interval')=='7', 'relaunch persistence'
    ui('replace-jevKey','click')
    ui('credential-input','set','e2e-placeholder')
    ui('save-credential','click'); time.sleep(.3)
    assert key_present(), 'UI writes isolated Keychain item'
    assert ui('mode-SMART','enabled')=='true', 'key enables SMART'
    ui('mode-SMART','click'); ui('save-settings','click')
    assert preferences()['mode']=='SMART', 'SMART selected through UI'
    ui('delete-jevKey','click'); time.sleep(.3)
    assert not key_present(), 'UI deletes Keychain item'
    assert ui('mode-SMART','enabled')=='false', 'clear key disables SMART'
    ui('mode-AUTO','click'); ui('save-settings','click')
    ui('toggle-capture','click')
    status=ui('capture-status')
    # Permission is a real environment result, never synthesized as success.
    permission='denied' if 'permission' in status else 'granted'
    if permission=='granted': ui('toggle-capture','click')
    screenshot(pid,EVIDENCE/'permission-state.png')
    ui('section-Destinations','click')
    assert ui('notion-enabled','enabled')=='false' and ui('google-enabled','enabled')=='false', 'unconfigured cloud destinations cannot be enabled'
    screenshot(pid,EVIDENCE/'destinations-en.png')
    ui('section-Privacy','click'); screenshot(pid,EVIDENCE/'privacy-en.png')
    ui('section-General','click'); ui('language','pick','Japanese'); ui('save-settings','click')
    assert preferences()['language']=='ja', 'language persisted'
    ui('section-Capture','click')
    assert 'TypeSafe' in ui('capture-status') or ui('mode-AUTO')=='選択中'
    screenshot(pid,SCREENSHOTS/'settings-ja.png')
    stop(); pid=launch()
    assert ui('mode-AUTO')=='選択中', 'Japanese persists after relaunch'
    report={'firstLaunch':'passed','modes':'passed','intervalPersistence':'passed','fakeKeySetAndDeleted':'passed',
            'languagePersistence':'passed','screenRecordingPermission':permission,'liveModeAttempts':{'ALL':all_permission,'AUTO':permission},'keychainService':'com.wysiwag.evidence'}
    (EVIDENCE/'app-e2e.json').write_text(json.dumps(report,indent=2)+'\n')
    print('PASS: real app launch, modes, interval, Keychain set/delete, settings relaunch, Japanese UI')
    print('Screen Recording permission:',permission)
except Exception as error:
    print('App E2E failed:', type(error).__name__, str(error),file=sys.stderr)
    sys.exit(1)
finally:
    # Fake test item only; no production Keychain operation.
    subprocess.run(['security','delete-generic-password','-s','com.wysiwag.evidence','-a','jevKey'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
