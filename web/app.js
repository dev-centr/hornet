/** Hornet desk — v1 grid + v2 temporal layout */

let selectedId = null;
let graphData = { nodes: [] };
let temporalAt = null;

const $ = (id) => document.getElementById(id);

async function api(path, opts = {}) {
  const res = await fetch(path, {
    headers: { 'Content-Type': 'application/json' },
    ...opts,
  });
  return res.json();
}

function statusLabel(s) {
  return (s || 'idle').charAt(0).toUpperCase() + (s || 'idle').slice(1);
}

function renderGrid(nodes, opacities = {}) {
  const grid = $('inbox-grid');
  const tasks = nodes.filter((n) => n.type === 'task' && !n.hidden);
  grid.innerHTML = tasks
    .map((t) => {
      const op = opacities[t.id] ?? 1;
      return `<button type="button" class="task-card status-${t.status}${selectedId === t.id ? ' is-selected' : ''}"
        data-id="${t.id}" style="opacity:${op}" role="listitem">
        <span class="task-title">${esc(t.title || t.id)}</span>
        <span class="task-summary">${esc(t.summary || '')}</span>
        <span class="task-foot">
          <span class="status-dot status-${t.status}" aria-hidden="true"></span>
          <span>${statusLabel(t.status)}</span>
          ${t.mixrModel ? `<span title="${esc(t.mixrReason || '')}">· ${esc(t.mixrModel.split('/').pop())}</span>` : ''}
        </span>
      </button>`;
    })
    .join('');

  grid.querySelectorAll('.task-card').forEach((btn) => {
    btn.addEventListener('click', () => openFork(btn.dataset.id));
  });

  const running = tasks.filter((t) => t.status === 'running').length;
  $('run-chip').textContent = `${running} of ${tasks.length} running`;
}

function renderCoordinator(nodes) {
  const coord = nodes.find((n) => n.type === 'coordinator');
  const lines = $('main-lines');
  if (!coord) {
    lines.innerHTML = '';
    return;
  }
  lines.innerHTML = `<li class="is-coordinator">${esc(coord.summary || 'Coordinator ready')}</li>`;
}

function esc(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

async function openFork(nodeId) {
  selectedId = nodeId;
  const node = graphData.nodes.find((n) => n.id === nodeId);
  if (!node) return;
  $('fork-panel').classList.remove('is-hidden');
  $('fork-title').textContent = node.title || node.id;
  $('fork-status').textContent = `${statusLabel(node.status)} · ${node.mixrModel || 'unrouted'}`;
  const { lines } = await api(`/api/nodes/${nodeId}/chat`);
  $('fork-lines').innerHTML = lines
    .map((l) => `<li class="is-${l.role}">${esc(l.text)}</li>`)
    .join('');
  await loadGraph();
}

async function loadGraph() {
  graphData = await api('/api/graph');
  const op = {};
  graphData.nodes.forEach((n) => {
    if (n.opacity != null) op[n.id] = n.opacity;
  });
  renderGrid(graphData.nodes, op);
  renderCoordinator(graphData.nodes);

  const scope = $('timeline-scope');
  scope.innerHTML = '<option value="global">Global</option>';
  graphData.nodes.forEach((n) => {
    const opt = document.createElement('option');
    opt.value = `node:${n.id}`;
    opt.textContent = `Subtree: ${n.title || n.id}`;
    scope.appendChild(opt);
  });
}

async function loadTemporal() {
  const scope = $('timeline-scope').value;
  const zoom = $('timeline-zoom').value;
  const scrub = $('timeline-scrub').value;
  const q = new URLSearchParams({ scope, zoom });
  if (temporalAt) q.set('at', temporalAt);
  const data = await api(`/api/temporal?${q}`);
  drawHeatmap(data.heatmap || []);
  const op = {};
  (data.nodes || []).forEach((n) => {
    op[n.id] = n.opacity;
  });
  renderGrid(graphData.nodes, op);

  const bm = $('timeline-bookmarks');
  bm.innerHTML = (data.bookmarks || [])
    .flatMap((b) => (b.keywords || []).map((k) => `<li>${esc(k)}</li>`))
    .join('');
}

function drawHeatmap(buckets) {
  const canvas = $('timeline-heatmap');
  const ctx = canvas.getContext('2d');
  const w = canvas.clientWidth || 600;
  canvas.width = w;
  const h = canvas.height;
  const bw = w / buckets.length;
  ctx.clearRect(0, 0, w, h);
  buckets.forEach((v, i) => {
    ctx.fillStyle = `rgba(110, 181, 255, ${0.08 + v * 0.45})`;
    ctx.fillRect(i * bw, h - v * h, bw - 1, v * h);
  });
}

$('fork-close').addEventListener('click', () => {
  selectedId = null;
  $('fork-panel').classList.add('is-hidden');
  loadGraph();
});

$('fork-compose').addEventListener('submit', async (e) => {
  e.preventDefault();
  const text = $('fork-input').value.trim();
  if (!text || !selectedId) return;
  await api('/api/message', {
    method: 'POST',
    body: JSON.stringify({ nodeId: selectedId, text }),
  });
  $('fork-input').value = '';
  openFork(selectedId);
});

$('serialized-mode').addEventListener('change', (e) => {
  document.body.classList.toggle('is-serialized', e.target.checked);
  $('inbox-region').classList.toggle('is-hidden', e.target.checked);
  $('bus-strip').textContent = e.target.checked
    ? 'Serialized mode — the old wall returns.'
    : 'Grid mode — cards update in place.';
});

$('btn-spawn-task').addEventListener('click', async () => {
  const title = prompt('Task title', 'new-task');
  if (!title) return;
  await api('/api/spawn', {
    method: 'POST',
    body: JSON.stringify({
      parentId: 'coordinator',
      type: 'task',
      title,
      reason: 'User spawned task',
    }),
  });
  await loadGraph();
});

$('timeline-scope').addEventListener('change', loadTemporal);
$('timeline-zoom').addEventListener('input', loadTemporal);
$('timeline-scrub').addEventListener('input', () => {
  const pct = Number($('timeline-scrub').value) / 100;
  const now = Date.now();
  temporalAt = new Date(now - (1 - pct) * 7 * 24 * 3600 * 1000).toISOString();
  loadTemporal();
});

loadGraph();
loadTemporal();
setInterval(loadGraph, 8000);
