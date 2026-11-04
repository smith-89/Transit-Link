/* Icons, the brand star and a small hatched bar chart. Plain script, no dependencies. */
var ICONS = {
  home: '<path d="M4 11.5 12 4l8 7.5"/><path d="M6.5 10v9h11v-9"/>',
  qr: '<rect x="4" y="4" width="6" height="6" rx="1.2"/><rect x="14" y="4" width="6" height="6" rx="1.2"/><rect x="4" y="14" width="6" height="6" rx="1.2"/><path d="M14 14h2.5v2.5H14zM19 14h1M14 19.5h1M17.5 18h2.5v2"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  receipt: '<path d="M6 3.5h12V21l-3-2-3 2-3-2-3 2z"/><path d="M9 8.5h6M9 12.5h6"/>',
  dots: '<circle cx="8" cy="8" r="1.5" fill="currentColor" stroke="none"/><circle cx="16" cy="8" r="1.5" fill="currentColor" stroke="none"/><circle cx="8" cy="16" r="1.5" fill="currentColor" stroke="none"/><circle cx="16" cy="16" r="1.5" fill="currentColor" stroke="none"/>',
  logout: '<path d="M10 4H6.5A2.5 2.5 0 0 0 4 6.5v11A2.5 2.5 0 0 0 6.5 20H10"/><path d="m15 8 4 4-4 4M19 12H9"/>',
  refresh: '<path d="M20 11a8 8 0 1 0-2.3 5.7"/><path d="M20 5v6h-6"/>',
  up: '<path d="M7 17 17 7M8.5 7H17v8.5"/>',
  share: '<path d="M12 15V4M8 8l4-4 4 4"/><path d="M5 13v6h14v-6"/>',
  shield: '<path d="M12 3 5 6v5.5c0 4.3 3 7.8 7 9.5 4-1.7 7-5.2 7-9.5V6z"/><path d="m9.5 12 2 2 3.5-4"/>',
  cash: '<rect x="3" y="6.5" width="18" height="11" rx="2.5"/><circle cx="12" cy="12" r="2.6"/><path d="M6.5 9.5v.01M17.5 14.5v.01"/>',
  chart: '<path d="M5 20v-8M12 20V4M19 20v-5"/>',
  grid: '<rect x="4" y="4" width="6.5" height="6.5" rx="1.5"/><rect x="13.5" y="4" width="6.5" height="6.5" rx="1.5"/><rect x="4" y="13.5" width="6.5" height="6.5" rx="1.5"/><rect x="13.5" y="13.5" width="6.5" height="6.5" rx="1.5"/>',
  alert: '<path d="M12 4 3.5 19.5h17z"/><path d="M12 10v4.5M12 17v.01"/>',
  user: '<circle cx="12" cy="8" r="3.6"/><path d="M5 20c1-4 4-6 7-6s6 2 7 6"/>',
  clock: '<circle cx="12" cy="12" r="8.5"/><path d="M12 7.5V12l3 2"/>',
  eye: '<path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z"/><circle cx="12" cy="12" r="3"/>',
  scan: '<path d="M4 8V6.5A2.5 2.5 0 0 1 6.5 4H8M16 4h1.5A2.5 2.5 0 0 1 20 6.5V8M20 16v1.5a2.5 2.5 0 0 1-2.5 2.5H16M8 20H6.5A2.5 2.5 0 0 1 4 17.5V16"/><path d="M4 12h16"/>',
  train: '<rect x="5" y="3.5" width="14" height="13" rx="3.5"/><path d="M5 11h14M8.5 20.5l2-4M15.5 20.5l-2-4"/><path d="M9 14v.01M15 14v.01"/>',
  wifi: '<path d="M3 9.5a14 14 0 0 1 18 0M6 13a9.5 9.5 0 0 1 12 0M9.2 16.4a5 5 0 0 1 5.6 0"/><path d="M12 19.5v.01"/>',
  arrow: '<path d="M5 12h14M13 6l6 6-6 6"/>',
  check: '<path d="m5 12.5 4.5 4.5L19 7.5"/>',
};

function icon(name, size) {
  size = size || 22;
  return '<svg viewBox="0 0 24 24" width="' + size + '" height="' + size + '" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + (ICONS[name] || '') + '</svg>';
}

/* The seven-point star from the brand reference. */
function star(size, color) {
  return '<svg viewBox="0 0 100 100" width="' + size + '" height="' + size + '" aria-hidden="true"><polygon fill="' + (color || 'currentColor') + '" points="50,3 60.8,27.5 86.7,20.7 74.4,44.4 95.8,60.5 69.5,65.6 70.4,92.3 50,75 29.6,92.3 30.5,65.6 4.2,60.5 25.6,44.4 13.3,20.7 39.2,27.5"/></svg>';
}

/* Fill every <span data-icon="name"> or <span data-star> on the page. */
function mountIcons(root) {
  (root || document).querySelectorAll('[data-icon]').forEach(function (el) {
    el.innerHTML = icon(el.getAttribute('data-icon'), parseInt(el.getAttribute('data-size') || '22', 10));
  });
  (root || document).querySelectorAll('[data-star]').forEach(function (el) {
    el.innerHTML = star(parseInt(el.getAttribute('data-star') || '28', 10));
  });
}

/* Hatched bar chart. o = { labels, values, selected, highlight, fmt, onSelect, compact, labelEvery }
   One bar can be selected (solid, with a white tooltip); `highlight` solidifies several bars. */
function barChart(el, o) {
  var max = Math.max.apply(null, [1].concat(o.values));
  var fmt = o.fmt || function (v) { return String(v); };
  var every = o.labelEvery || 1;
  el.className = 'bars' + (o.compact ? ' compact' : '');
  el.innerHTML = '';
  o.values.forEach(function (v, i) {
    var on = i === o.selected || (o.highlight && o.highlight.indexOf(i) !== -1);
    var pct = Math.round((v / max) * 100);
    var b = document.createElement('button');
    b.type = 'button';
    b.className = 'bar' + (on ? ' on' : '');
    b.setAttribute('aria-label', o.labels[i] + ': ' + fmt(v));
    var track = document.createElement('div');
    track.className = 'bar-track';
    var fill = document.createElement('div');
    fill.className = 'bar-fill';
    fill.style.height = pct + '%';
    track.appendChild(fill);
    if (i === o.selected) {
      var tip = document.createElement('span');
      tip.className = 'tip' + (i === 0 ? ' first' : (i === o.values.length - 1 ? ' last' : ''));
      tip.style.bottom = 'calc(' + pct + '% + 8px)';
      tip.textContent = fmt(v);
      track.appendChild(tip);
    }
    var label = document.createElement('div');
    label.className = 'bar-label';
    label.textContent = i % every === 0 ? o.labels[i] : '';
    b.append(track, label);
    if (o.onSelect) b.onclick = function () { o.onSelect(i); };
    el.appendChild(b);
  });
}
