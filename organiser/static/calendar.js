'use strict';
(function(root) {
  const startOfDay = date => new Date(date.getFullYear(), date.getMonth(), date.getDate());
  function overlaps(item, start, end) {
    if (!item.starts_at || item.deleted) return false;
    const a = new Date(item.starts_at), b = item.ends_at ? new Date(item.ends_at) : new Date(+a + 1);
    return a < end && (b > start || (+a === +b && a >= start));
  }
  function month(date, rows) {
    const first = new Date(date.getFullYear(), date.getMonth(), 1);
    const start = new Date(first); start.setDate(1 - ((first.getDay() + 6) % 7));
    return Array.from({length:42}, (_, i) => {
      const day = new Date(start); day.setDate(start.getDate() + i);
      const end = new Date(day); end.setDate(day.getDate() + 1);
      return {date:day, current:day.getMonth()===date.getMonth(), rows:rows.filter(r=>overlaps(r.document,day,end)).sort((a,b)=>new Date(a.document.starts_at)-new Date(b.document.starts_at))};
    });
  }
  const calendar = {month, overlaps, startOfDay};
  if (typeof module !== 'undefined') module.exports = calendar;
  else root.organiserCalendar = calendar;
})(globalThis);
