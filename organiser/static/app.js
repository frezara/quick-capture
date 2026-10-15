'use strict';
const $ = id => document.getElementById(id);
let token = '', rows = [], selected = null, filter = 'all', currentConflict = null, pending = null;
let initialForm = '';
let calendarMonth = new Date();
function formState() { return JSON.stringify(['body','kind','section','url','starts','ends','reminder'].map(id => $(id).value).concat($('completed').checked)); }
function canLeave() { return $('edit').hidden || initialForm === formState() || confirm('Discard the unsaved changes in this form?'); }
function status(text) { $('status').textContent = text; }
async function api(path, options = {}) {
  const response = await fetch(path, {...options, headers: {Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', ...options.headers}});
  const value = await response.json();
  if (!response.ok) { const error = new Error(response.status === 401 ? 'Access key was not accepted.' : `Request failed (${response.status}).`); error.detail = value.detail; throw error; }
  return value;
}
function timeLocal(value) { if (!value) return ''; const date = new Date(value); return new Date(date - date.getTimezoneOffset()*60000).toISOString().slice(0,16); }
function timeISO(id) { return $(id).value ? new Date($(id).value).toISOString() : null; }
function renderCalendar(rows) {
  $('calendar').hidden = filter !== 'event';
  if (filter !== 'event') return;
  $('calendar-month').textContent = calendarMonth.toLocaleDateString(undefined,{month:'long',year:'numeric'});
  $('calendar-zone').textContent = `Times shown in ${Intl.DateTimeFormat().resolvedOptions().timeZone}. Select a date to add an event.`;
  const grid = $('calendar-grid'); grid.replaceChildren();
  for (const day of organiserCalendar.month(calendarMonth, rows)) {
    const cell = document.createElement('div'); cell.className='calendar-day'+(day.current?'':' outside');
    if (+day.date===+organiserCalendar.startOfDay(new Date())) cell.classList.add('today');
    const label = document.createElement('button');label.className='day-number';label.textContent=day.date.getDate();
    label.setAttribute('aria-label','New event on '+day.date.toLocaleDateString(undefined,{dateStyle:'full'}));
    label.onclick=()=>openItem(null,day.date);cell.append(label);
    for (const row of day.rows) {
      const event=document.createElement('button');event.className='calendar-event';
      event.textContent=new Date(row.document.starts_at).toLocaleTimeString(undefined,{hour:'2-digit',minute:'2-digit'})+' '+row.document.body_markdown.replace(/^[-*+] \[[ xX]\] /,'').split('\n')[0];
      event.title=event.textContent;event.onclick=()=>openItem(row);cell.append(event);
    }
    grid.append(cell);
  }
}
function render() {
  const query = $('search').value.toLowerCase();
  const visible = rows.filter(row => (filter === 'all' || (filter === 'reminder' ? !!row.document.reminder_at : row.document.kind === filter)) && row.document.body_markdown.toLowerCase().includes(query));
  renderCalendar(visible);
  if (filter === 'reminder') visible.sort((a,b)=>new Date(a.document.reminder_at)-new Date(b.document.reminder_at));
  if (filter === 'event') visible.sort((a,b) => (a.document.starts_at || '').localeCompare(b.document.starts_at || ''));
  $('items').replaceChildren(); $('count').textContent = `${visible.length} ${visible.length === 1 ? 'item' : 'items'}`;
  if (!visible.length) { const empty = document.createElement('p'); empty.textContent = 'Nothing here yet. Capture a thought or create an item.'; $('items').append(empty); }
  for (const row of visible) {
    const button = document.createElement('button'); button.className = `card${row.document.completed ? ' done' : ''}`;
    const meta = document.createElement('small'); meta.textContent = `${row.document.kind} · ${row.document.section}${row.document.starts_at ? ' · '+new Date(row.document.starts_at).toLocaleString() : ''}${row.document.reminder_at ? ' · remind '+new Date(row.document.reminder_at).toLocaleString() : ''}${row.document.completed ? ' · completed' : ''}`;
    const text = document.createElement('span'); text.textContent = row.document.body_markdown.replace(/<!--qc-source:[^>]+-->/g, '').slice(0,500);
    button.append(meta,text); button.onclick = () => openItem(row); $('items').append(button);
  }
}
async function refresh() {
  let all = [], page;
  do { page = await api(`/api/items?offset=${all.length}&limit=1000`); all.push(...page); } while (page.length === 1000);
  rows = all; render();
}
async function openItem(row, eventDate) {
  if (!canLeave()) return;
  selected = row; pending = null; currentConflict = null;
  const d = row?.document || {body_markdown:'',kind:filter === 'all' ? 'capture' : filter,section:'Quick capture'};
  $('body').value=d.body_markdown; $('kind').value=d.kind; $('section').value=d.section; $('url').value=d.source_url || '';
  $('completed').checked=!!d.completed; $('starts').value=timeLocal(d.starts_at); $('ends').value=timeLocal(d.ends_at); $('reminder').value=timeLocal(d.reminder_at);
  if (!row && eventDate) {
    const start=new Date(eventDate);start.setHours(9,0,0,0);
    $('kind').value='event';$('starts').value=timeLocal(start.toISOString());$('ends').value=timeLocal(new Date(+start+30*60000).toISOString());
  }
  updateRequiredDates();
  initialForm = formState();
  $('edit-title').textContent=row ? 'Edit item' : 'New item'; $('delete').hidden=!row; $('conflict').hidden=true; $('edit').hidden=false; $('attachments').replaceChildren();
  if (row) { try { const detail = await api(`/api/items/${row.id}`); if (selected?.id !== row.id) return;
    for (const file of detail.attachments) { const button=document.createElement('button'); button.type='button'; button.textContent=file.path.split('/').pop(); button.onclick=async()=>{
      try { const response=await fetch(`/api/items/${row.id}/attachment?path=${encodeURIComponent(file.path)}`,{headers:{Authorization:`Bearer ${token}`}}); if(!response.ok) throw new Error('Attachment could not be downloaded.'); const url=URL.createObjectURL(await response.blob()); const link=document.createElement('a');link.href=url;link.download=file.path.split('/').pop();link.click();setTimeout(()=>URL.revokeObjectURL(url),1000); } catch(e){status(e.message);} }; $('attachments').append(button); }
  } catch(e) {status(e.message);} }
}
async function save(deleted=false) {
  const document={body_markdown:$('body').value,kind:$('kind').value,section:$('section').value,source_url:$('url').value || null,completed:$('completed').checked,deleted,starts_at:timeISO('starts'),ends_at:timeISO('ends'),reminder_at:timeISO('reminder')};
  const draft={item_id:selected?.id || pending?.item_id || crypto.randomUUID(),expected_revision:selected?.revision || 0,item:document,...(document.kind==='project'?{attachments:[]}: {})};
  // Keep the operation identity for retry after an uncertain network response.
  if (!pending || JSON.stringify(draft)!==JSON.stringify(pending.draft)) pending={draft,item_id:draft.item_id,operation_id:crypto.randomUUID()};
  $('save').disabled=true; $('delete').disabled=true;
  try { const receipt=await api('/api/operations',{method:'POST',body:JSON.stringify({...draft,operation_id:pending.operation_id})}); selected={id:receipt.item_id,revision:receipt.revision,document}; pending=null; $('edit').hidden=true; await refresh(); status(deleted?'Item deleted.':'Saved to organiser.'); }
  catch(e){ if(e.detail?.code==='revision_conflict'){currentConflict=e.detail.current;$('remote').textContent=currentConflict?.document.body_markdown || 'Item no longer exists.';$('conflict').hidden=false;status('Your draft has not been overwritten. Resolve the conflict before saving.');}else{status(typeof e.detail==='string'?e.detail:e.message+' Your draft is still here.');} }
  finally{$('save').disabled=false;$('delete').disabled=false;}
}
$('login').onsubmit=async event=>{event.preventDefault();token=$('token').value;try{await refresh();$('token').value='';$('login').hidden=true;$('workspace').hidden=false;$('signout').hidden=false;status('Connected to your organiser.');}catch(e){token='';status(e.message);}};
$('signout').onclick=()=>{if(canLeave())location.reload();};
$('edit').onsubmit=event=>{event.preventDefault();save();};
$('delete').onclick=()=>{if(confirm('Delete this item from the organiser?'))save(true);};
$('new').onclick=()=>openItem(null);$('cancel').onclick=()=>{if(canLeave())$('edit').hidden=true;};
$('load-current').onclick=()=>{if(currentConflict)openItem(currentConflict);};
window.addEventListener('beforeunload',event=>{if(!$('edit').hidden && initialForm!==formState()){event.preventDefault();event.returnValue='';}});
$('refresh').onclick=()=>refresh().catch(e=>status(e.message));$('search').oninput=render;
for(const button of document.querySelectorAll('[data-kind]'))button.onclick=()=>{filter=button.dataset.kind;for(const b of document.querySelectorAll('[data-kind]'))b.setAttribute('aria-pressed',String(b===button));$('list-title').textContent=button.textContent;render();};

$('previous-month').onclick=()=>{calendarMonth=new Date(calendarMonth.getFullYear(),calendarMonth.getMonth()-1,1);render();};
$('next-month').onclick=()=>{calendarMonth=new Date(calendarMonth.getFullYear(),calendarMonth.getMonth()+1,1);render();};
$('calendar-today').onclick=()=>{calendarMonth=new Date();render();};

let refreshing = false;
setInterval(async()=>{
  if (!token || refreshing || document.hidden) return;
  refreshing=true;
  try { await refresh(); } catch(e) { status(e.message+' Your open draft is retained.'); }
  finally { refreshing=false; }
},10000);

function updateRequiredDates() { $('starts').required=$('kind').value==='event';$('reminder').required=$('kind').value==='reminder'; }
$('kind').onchange=updateRequiredDates;
