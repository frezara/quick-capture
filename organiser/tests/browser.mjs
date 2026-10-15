import { chromium } from 'playwright';
import { readFile } from 'node:fs/promises';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';

const base = process.env.ORGANISER_URL || 'http://127.0.0.1:8787';
const token = (await readFile(process.env.ORGANISER_TOKEN_FILE || new URL('../secrets/organiser_token', import.meta.url), 'utf8')).trim();
const browser = await chromium.launch({executablePath:process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true});
const page = await browser.newPage({viewport:{width:1280,height:900}});
const errors=[];page.on('pageerror',e=>errors.push(e.message));
const marker=`Browser verification ${randomUUID()}`;
async function api(path,options={}) {const r=await fetch(base+path,{...options,headers:{Authorization:`Bearer ${token}`,'Content-Type':'application/json'}});assert.ok(r.ok,`HTTP ${r.status}`);return r.json();}
let row;
try {
 await page.goto(base); await page.locator('#token').fill(token); await page.getByRole('button',{name:'Unlock organiser'}).click();
 await page.locator('#workspace').waitFor({state:'visible'});
 await page.getByRole('button',{name:'New item',exact:true}).click();
 await page.locator('#body').fill(marker+' <script>window.injected=true</script>');
 await page.locator('#kind').selectOption('note'); await page.getByRole('button',{name:'Save item'}).click();
 await page.locator('#edit').waitFor({state:'hidden'}); await page.locator('#search').fill(marker);
 await page.locator('.card').click(); await page.locator('#body').fill(marker+' local draft');
 row=(await api('/api/items?limit=1000')).find(r=>r.document.body_markdown.startsWith(marker));assert.ok(row);
 await api('/api/operations',{method:'POST',body:JSON.stringify({operation_id:randomUUID(),item_id:row.id,expected_revision:row.revision,item:{...row.document,body_markdown:marker+' server edit'}})});
 await page.getByRole('button',{name:'Save item'}).click(); await page.locator('#conflict').waitFor({state:'visible'});
 assert.equal(await page.locator('#body').inputValue(),marker+' local draft');
 assert.ok((await page.locator('#remote').textContent()).endsWith('server edit'));
 assert.equal(await page.evaluate(()=>window.injected),undefined);
 page.once('dialog',d=>d.accept());await page.getByRole('button',{name:'Load current version'}).click();
 assert.equal(await page.locator('#body').inputValue(),marker+' server edit');
 await page.locator('#completed').check();await page.getByRole('button',{name:'Save item'}).click();await page.locator('#edit').waitFor({state:'hidden'});
 row=await api(`/api/items/${row.id}`);assert.equal(row.document.completed,true);
 await page.screenshot({path:'/tmp/organiser-desktop.png',fullPage:true});
 await page.setViewportSize({width:390,height:844});await page.waitForTimeout(300);await page.screenshot({path:'/tmp/organiser-mobile.png',fullPage:true});
 assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth));
 assert.deepEqual(errors,[]);console.log('Browser checks passed: login, create, edit, conflict preservation, completion, safe text, mobile width.');
} finally {
 if(row){const current=await api(`/api/items/${row.id}`);if(!current.document.deleted)await api('/api/operations',{method:'POST',body:JSON.stringify({operation_id:randomUUID(),item_id:row.id,expected_revision:current.revision,item:{...current.document,deleted:true}})});}
 await browser.close();
}
