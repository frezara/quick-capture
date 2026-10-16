const test = require('node:test');
const assert = require('node:assert/strict');
const {month, overlaps} = require('../static/calendar.js');
process.env.TZ = 'Europe/London';
test('month grid crosses years and starts on Monday', () => {
  const days=month(new Date(2027,0,1),[]);
  assert.equal(days.length,42);assert.equal(days[0].date.getDay(),1);
  assert.equal(days[0].date.getFullYear(),2026);assert.equal(days.filter(d=>d.current).length,31);
});
test('multi-day events exclude an end at midnight and include DST days', () => {
  const document={starts_at:'2026-03-28T23:00:00Z',ends_at:'2026-03-30T23:00:00Z'};
  const days=month(new Date(2026,2,1),[{id:'a',document}]);
  assert.deepEqual(days.filter(d=>d.rows.length).map(d=>d.date.getDate()),[28,29,30]);
  assert.equal(overlaps({...document,deleted:true},new Date(2026,2,28),new Date(2026,3,1)),false);
});
test('zero-duration events belong to their starting date', () => {
  const d={starts_at:'2026-10-15T12:00:00Z',ends_at:'2026-10-15T12:00:00Z'};
  assert.equal(overlaps(d,new Date(2026,9,15),new Date(2026,9,16)),true);
});
