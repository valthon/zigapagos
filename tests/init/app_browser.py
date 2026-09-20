"""Journeys for the fresh project emitted by app.sh, served as static files."""
import functools
import http.server
import sys
import threading
from playwright.sync_api import sync_playwright, expect

class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Quiet, directory=sys.argv[1]))
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f'http://127.0.0.1:{server.server_port}'
try:
    with sync_playwright() as p:
        browser=p.chromium.launch(channel='chrome')
        # Loading is real prerendered content, not an artificial timed demo delay.
        nojs=browser.new_page(java_script_enabled=False)
        nojs.goto(base+'/app/')
        expect(nojs.get_by_role('status')).to_have_text('Loading tasks…')
        nojs.close()
        page=browser.new_page(viewport={'width':390,'height':850})
        errors=[]
        page.on('pageerror',lambda e: errors.append(str(e)))
        page.add_init_script('''
            // Match the missing secure-context API on an HTTP LAN preview.
            Object.defineProperty(crypto, 'randomUUID', { value: undefined, configurable: true });
            window.failRead = true;
            window.failWrite = true;
            const read = Storage.prototype.getItem, write = Storage.prototype.setItem;
            Storage.prototype.getItem = function(key) {
              if (key === 'zigapagos.tasks.v1' && window.failRead) throw new Error('blocked storage');
              return read.call(this,key);
            };
            Storage.prototype.setItem = function(key,value) {
              if (key === 'zigapagos.tasks.v1' && window.failWrite) throw new Error('quota exceeded');
              return write.call(this,key,value);
            };
        ''')
        page.goto(base+'/app/',wait_until='networkidle')
        assert page.evaluate('typeof crypto.randomUUID') == 'undefined'
        expect(page.get_by_role('alert')).to_contain_text('Could not read saved tasks')
        page.evaluate('window.failRead=false')
        page.get_by_role('button',name='Retry loading').click()
        expect(page.get_by_text('No tasks yet.',exact=False)).to_be_visible()
        page.evaluate('window.navigationMarker=123')
        page.get_by_role('link',name='New task',exact=True).click()
        expect(page).to_have_url(base+'/app/new')
        assert page.evaluate('window.navigationMarker')==123, 'navigation reloaded document'
        title=page.get_by_label('Task title',exact=True)
        title.fill('   ')
        page.get_by_role('button',name='Create task').click()
        expect(title).to_be_focused()
        expect(title).to_have_attribute('aria-invalid','true')
        title.fill('Ship <strong>something</strong>')
        page.get_by_role('button',name='Create task').click()
        expect(page.get_by_role('alert')).to_contain_text('Could not save your task')
        expect(title).to_have_value('Ship <strong>something</strong>')
        page.evaluate('window.failWrite=false')
        title.press('Enter')
        task=page.get_by_role('checkbox',name='Ship <strong>something</strong>')
        expect(task).to_be_visible()
        assert page.locator('strong').count()==0, 'task title became HTML'
        page.evaluate('window.failWrite=true')
        task.click()
        expect(page.get_by_role('alert')).to_contain_text('Could not save the change')
        expect(task).not_to_be_checked()
        page.evaluate('window.failWrite=false')
        task.focus();page.keyboard.press('Space')
        expect(task).to_be_checked()
        # Reload creates the same browser-local task, then recover read failure again.
        page.reload(wait_until='networkidle')
        page.evaluate('window.failRead=false')
        page.get_by_role('button',name='Retry loading').click()
        expect(page.get_by_role('checkbox',name='Ship <strong>something</strong>')).to_be_checked()
        page.goto(base+'/app/new/',wait_until='networkidle')
        expect(page.get_by_role('heading',name='New task')).to_be_visible()
        expect(page.get_by_role('button',name='Create task')).to_be_disabled()
        assert page.evaluate('document.documentElement.scrollWidth <= innerWidth')
        page.goto(base+'/app/about/')
        expect(page.get_by_text('This starter has no sign-in',exact=False)).to_be_visible()
        # Corrupt stored data cannot be silently replaced with an empty list.
        page.evaluate("window.failWrite=false;localStorage.setItem('zigapagos.tasks.v1','bad-json')")
        page.goto(base+'/app/')
        page.evaluate('window.failRead=false')
        page.get_by_role('button',name='Retry loading').click()
        expect(page.get_by_role('alert')).to_contain_text('Existing data was not overwritten')
        assert page.evaluate("localStorage.getItem('zigapagos.tasks.v1')")=='bad-json'
        page.goto(base+'/')
        assert page.locator('script').count()==0
        assert not errors, errors
        browser.close()
        print('PASS: loading/empty/error recovery, form validation, failed writes, navigation, persistence and static landing')
finally:
    server.shutdown();server.server_close()
