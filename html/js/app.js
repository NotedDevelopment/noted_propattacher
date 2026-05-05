'use strict';

function lua(event, data = {}) {
    return fetch(`https://noted_propattacher/${event}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(data),
    }).then(r => r.json()).catch(() => ({ ok: false, error: 'fetch failed' }));
}

// ── State ─────────────────────────────────────────────────────────────────────
const State = { bones: [], presets: [], attached: [], placing: false, freeCam: false };
let offsetStep   = 0.01;
let rotationStep = 5;

// ── DOM ───────────────────────────────────────────────────────────────────────
const app           = document.getElementById('app');
const modelInput    = document.getElementById('modelInput');
const boneSearch    = document.getElementById('boneSearch');
const boneListEl    = document.getElementById('boneList');
const presetListEl  = document.getElementById('presetList');
const spawnStatus   = document.getElementById('spawnStatus');
const placementHint = document.getElementById('placementHint');
const liveBadge     = document.getElementById('liveBadge');
const axisLabel     = document.getElementById('axisLabel');
const rotLabel      = document.getElementById('rotLabel');
const attachedList  = document.getElementById('attachedList');
const exportOutput  = document.getElementById('exportOutput');

const V = {
    ox: document.getElementById('ox'), oy: document.getElementById('oy'), oz: document.getElementById('oz'),
    rx: document.getElementById('rx'), ry: document.getElementById('ry'), rz: document.getElementById('rz'),
};

// ── Freecam: RMB outside panel ────────────────────────────────────────────────
// Track whether pointer is inside the panel
let pointerInsidePanel = false;
app.addEventListener('mouseenter', () => { pointerInsidePanel = true; });
app.addEventListener('mouseleave', () => { pointerInsidePanel = false; });

// RMB down on document (not panel) → trigger freecam
document.addEventListener('mousedown', e => {
    if (e.button === 2 && !pointerInsidePanel && State.placing && !State.freeCam) {
        e.preventDefault();
        lua('rmbOutside');
    }
    // LMB outside panel → send to Lua for gizmo
    if (e.button === 0 && !pointerInsidePanel && State.placing && !State.freeCam) {
        const sx = e.clientX / window.innerWidth;
        const sy = e.clientY / window.innerHeight;
        lua('lmbDown', { x: sx, y: sy });
    }
});
document.addEventListener('mouseup', e => {
    if (e.button === 0 && State.placing && !State.freeCam) {
        lua('lmbUp', {});
    }
});
// Prevent context menu from appearing
document.addEventListener('contextmenu', e => e.preventDefault());

// ── Cursor tracking → Lua for gizmo hit testing ───────────────────────────────
let cursorThrottle = 0;
document.addEventListener('mousemove', e => {
    if (!State.placing || State.freeCam) return;
    const now = Date.now();
    if (now - cursorThrottle < 16) return; // ~60fps max
    cursorThrottle = now;
    const sx = e.clientX / window.innerWidth;
    const sy = e.clientY / window.innerHeight;
    lua('cursorMove', { x: sx, y: sy });
});

// ── Tabs ──────────────────────────────────────────────────────────────────────
document.querySelectorAll('.tab').forEach(tab => {
    tab.addEventListener('click', () => {
        document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
        document.querySelectorAll('.tab-content').forEach(c => c.classList.remove('active'));
        tab.classList.add('active');
        document.getElementById('tab-' + tab.dataset.tab)?.classList.add('active');
    });
});
function switchTab(name) {
    document.querySelectorAll('.tab').forEach(t => t.classList.toggle('active', t.dataset.tab === name));
    document.querySelectorAll('.tab-content').forEach(c => c.classList.toggle('active', c.id === 'tab-' + name));
}

// ── Bones ─────────────────────────────────────────────────────────────────────
let selectedBone = null;
function renderBones(filter = '') {
    boneListEl.innerHTML = '';
    const fl = filter.toLowerCase();
    State.bones.forEach(b => {
        if (fl && !b.label.toLowerCase().includes(fl) && !String(b.index).includes(fl)) return;
        const el = document.createElement('div');
        el.className = 'bone-item' + (selectedBone === b.index ? ' selected' : '');
        el.innerHTML = `<span>${b.label}</span><span class="bone-index">${b.index}</span>`;
        el.addEventListener('click', () => {
            selectedBone = b.index;
            renderBones(boneSearch.value);
            lua('setBone', { bone: b.index });
        });
        boneListEl.appendChild(el);
    });
}
boneSearch.addEventListener('input', () => renderBones(boneSearch.value));

// Direct bone index entry
document.getElementById('btnSetBoneNum').addEventListener('click', () => {
    const num = parseInt(document.getElementById('boneNumInput').value);
    if (isNaN(num)) return;
    selectedBone = num;
    renderBones(boneSearch.value);  // refresh highlight
    lua('setBone', { bone: num });
});
document.getElementById('boneNumInput').addEventListener('keydown', e => {
    if (e.key === 'Enter') document.getElementById('btnSetBoneNum').click();
});

// ── Presets ───────────────────────────────────────────────────────────────────
function renderPresets() {
    presetListEl.innerHTML = '';
    State.presets.forEach((p, i) => {
        const btn = document.createElement('button');
        btn.className = 'preset-btn';
        btn.textContent = p.label;
        btn.addEventListener('click', async () => {
            const res = await lua('applyPreset', { index: i + 1 });
            if (res.ok) { updateVec(res.offset, res.rotation); setStatus('✓ Preset: ' + p.label, 'ok'); switchTab('adjust'); }
        });
        presetListEl.appendChild(btn);
    });
}

// ── Attached ──────────────────────────────────────────────────────────────────
function renderAttached(list) {
    if (list) State.attached = list;
    attachedList.innerHTML = '';
    if (!State.attached.length) {
        attachedList.innerHTML = '<div class="empty-state">No props attached yet.</div>'; return;
    }
    State.attached.forEach((a, i) => {
        const el = document.createElement('div');
        el.className = 'attached-item';
        el.innerHTML = `<div class="item-info"><div class="item-model">${a.model}</div><div class="item-bone">Bone: ${a.bone}</div></div><button class="item-delete" data-idx="${i+1}">✕</button>`;
        el.querySelector('.item-delete').addEventListener('click', async () => {
            const res = await lua('deleteSelected', { index: i+1 });
            if (res.ok) { State.attached.splice(i, 1); renderAttached(); }
        });
        attachedList.appendChild(el);
    });
}

// ── Vec helpers ───────────────────────────────────────────────────────────────
function fmt(n) { return parseFloat(n || 0).toFixed(4); }
function updateVec(offset, rotation) {
    const focused = document.activeElement;
    if (offset) {
        if (focused !== V.ox) V.ox.value = fmt(offset.x);
        if (focused !== V.oy) V.oy.value = fmt(offset.y);
        if (focused !== V.oz) V.oz.value = fmt(offset.z);
    }
    if (rotation) {
        if (focused !== V.rx) V.rx.value = fmt(rotation.x);
        if (focused !== V.ry) V.ry.value = fmt(rotation.y);
        if (focused !== V.rz) V.rz.value = fmt(rotation.z);
    }
}
function setStatus(msg, type='') { spawnStatus.textContent=msg; spawnStatus.className='status-bar '+type; }

// ── Step size buttons ─────────────────────────────────────────────────────────
document.querySelectorAll('.step-btn').forEach(btn => {
    btn.addEventListener('click', () => {
        const target = btn.dataset.stepTarget, val = parseFloat(btn.dataset.val);
        document.querySelectorAll(`.step-btn[data-step-target="${target}"]`).forEach(b => b.classList.remove('active'));
        btn.classList.add('active');
        if (target === 'offset')   offsetStep   = val;
        if (target === 'rotation') rotationStep = val;
        document.querySelectorAll(`.nudge-btn[data-type="${target}"]`).forEach(nb => {
            nb.dataset.step = parseFloat(nb.dataset.step) < 0 ? -val : val;
        });
    });
});

// ── Nudge buttons ─────────────────────────────────────────────────────────────
document.querySelectorAll('.nudge-btn').forEach(btn => {
    btn.addEventListener('click', async () => {
        const res = await lua(
            btn.dataset.type === 'offset' ? 'nudgeOffset' : 'nudgeRotation',
            { axis: btn.dataset.axis, step: parseFloat(btn.dataset.step) }
        );
        if (res.ok) updateVec(res.offset, res.rotation);
    });
});

// ── Direct input ──────────────────────────────────────────────────────────────
// Direct input — fire on both 'change' (blur) and 'input' (live typing)
// Don't send on every keystroke, debounce to avoid spamming Lua
let inputDebounce = null;
function sendOffset() {
    clearTimeout(inputDebounce);
    inputDebounce = setTimeout(() => lua('setOffset', {x:V.ox.value,y:V.oy.value,z:V.oz.value}), 200);
}
function sendRotation() {
    clearTimeout(inputDebounce);
    inputDebounce = setTimeout(() => lua('setRotation', {x:V.rx.value,y:V.ry.value,z:V.rz.value}), 200);
}
['ox','oy','oz'].forEach(id => {
    V[id].addEventListener('change', sendOffset);
    V[id].addEventListener('input',  sendOffset);
});
['rx','ry','rz'].forEach(id => {
    V[id].addEventListener('change', sendRotation);
    V[id].addEventListener('input',  sendRotation);
});

// ── Spawn ─────────────────────────────────────────────────────────────────────
document.getElementById('btnSpawn').addEventListener('click', async () => {
    const model = modelInput.value.trim();
    if (!model) { setStatus('⚠ Enter a model name', 'err'); return; }
    setStatus('Loading...', '');
    const res = await lua('spawnProp', { model });
    if (res.ok) { setStatus('✓ Spawned — RMB outside to look around', 'ok'); switchTab('adjust'); }
    else setStatus('✗ ' + (res.error || 'Error'), 'err');
});
modelInput.addEventListener('keydown', e => { if (e.key === 'Enter') document.getElementById('btnSpawn').click(); });

// ── Recalibrate ───────────────────────────────────────────────────────────────
let recalData = null;

document.getElementById('btnRecalibrate').addEventListener('click', async () => {
    const popup = document.getElementById('recalPopup');
    const body  = document.getElementById('recalBody');
    body.innerHTML = '<span style="color:var(--muted)">Calculating...</span>';
    popup.classList.remove('hidden');
    document.getElementById('recalActions').classList.add('hidden');
    document.getElementById('recalSame').classList.add('hidden');

    const res = await lua('recalibrate');
    if (!res.ok) {
        body.innerHTML = `<span style="color:var(--danger)">${res.error || 'Error'}</span>`;
        return;
    }

    recalData = res;

    if (res.isSame) {
        body.innerHTML = `
            <div class="recal-row"><span class="recal-lbl">Closest bone</span><span class="recal-val">${res.newBone}</span></div>
            <div class="recal-row"><span class="recal-lbl">Result</span><span class="recal-val">Already optimal — same bone as current.</span></div>`;
        document.getElementById('recalSame').classList.remove('hidden');
    } else {
        const f = n => parseFloat(n).toFixed(4);
        const offsetChanged = ['x','y','z'].some(k => Math.abs(res.newOffset[k] - res.curOffset[k]) > 0.0001);
        body.innerHTML = `
            <div class="recal-row"><span class="recal-lbl">Current bone</span><span class="recal-val">${res.curBone}</span></div>
            <div class="recal-row"><span class="recal-lbl">Suggested bone</span><span class="recal-val changed">${res.newBone}</span></div>
            <div class="recal-row"><span class="recal-lbl">Current offset</span><span class="recal-val">${f(res.curOffset.x)}, ${f(res.curOffset.y)}, ${f(res.curOffset.z)}</span></div>
            <div class="recal-row"><span class="recal-lbl">New offset</span><span class="recal-val ${offsetChanged ? 'changed' : ''}">${f(res.newOffset.x)}, ${f(res.newOffset.y)}, ${f(res.newOffset.z)}</span></div>
            <div class="recal-row"><span class="recal-lbl">Rotation</span><span class="recal-val">${f(res.curRot.x)}, ${f(res.curRot.y)}, ${f(res.curRot.z)} (unchanged)</span></div>`;
        document.getElementById('recalActions').classList.remove('hidden');
    }
});

document.getElementById('btnRecalApply').addEventListener('click', async () => {
    if (!recalData) return;
    const res = await lua('applyRecalibrate', {
        bone: recalData.newBoneIdx,
        ox: recalData.newOffset.x, oy: recalData.newOffset.y, oz: recalData.newOffset.z,
        rx: recalData.newRot.x,    ry: recalData.newRot.y,    rz: recalData.newRot.z,
    });
    if (res.ok) {
        updateVec(res.offset, res.rotation);
        // Update selected bone highlight
        selectedBone = recalData.newBoneIdx;
        renderBones(boneSearch.value);
    }
    document.getElementById('recalPopup').classList.add('hidden');
    recalData = null;
});

document.getElementById('btnRecalDismiss').addEventListener('click', () => {
    document.getElementById('recalPopup').classList.add('hidden');
    recalData = null;
});
document.getElementById('btnRecalOk').addEventListener('click', () => {
    document.getElementById('recalPopup').classList.add('hidden');
    recalData = null;
});
document.getElementById('btnReset').addEventListener('click', async () => {
    const res = await lua('resetTransform');
    if (res.ok) updateVec(res.offset, res.rotation);
});
document.getElementById('btnCancel').addEventListener('click', async () => {
    await lua('cancelPlacement');
    State.placing = false;
    liveBadge.classList.add('hidden');
    placementHint.textContent = 'Placement cancelled.';
});
document.getElementById('btnConfirm').addEventListener('click', async () => {
    const res = await lua('confirmAttach');
    // Always reset UI state regardless of result - nothing should linger
    State.placing = false;
    liveBadge.classList.add('hidden');
    updateVec({ x:0, y:0, z:0 }, { x:0, y:0, z:0 });
    placementHint.textContent = res.ok
        ? 'Prop attached! Spawn another or check Attached tab.'
        : 'Ready — spawn a prop to begin.';
    if (res.ok && res.attached) renderAttached(res.attached);
});

// ── Attached / Export ─────────────────────────────────────────────────────────
document.getElementById('btnDetachAll').addEventListener('click', () => {
    document.getElementById('detachConfirmRow').classList.remove('hidden');
});
document.getElementById('btnDetachConfirm').addEventListener('click', async () => {
    document.getElementById('detachConfirmRow').classList.add('hidden');
    await lua('detachAll');
    State.attached = []; renderAttached();
});
document.getElementById('btnDetachCancel').addEventListener('click', () => {
    document.getElementById('detachConfirmRow').classList.add('hidden');
});

async function getExportData() {
    const res = await lua('exportConfig');
    if (!res.ok || !res.data?.length) { exportOutput.value = '-- No attached props.'; return null; }
    return res.data;
}

document.getElementById('btnExportAttach').addEventListener('click', async () => {
    const data = await getExportData(); if (!data) return;
    const lines = ['-- prop_attacher — AttachEntityToEntity format', ''];
    data.forEach((e, i) => {
        lines.push(`-- [${i+1}] bone ${e.bone}`);
        lines.push(`local hash${i+1} = GetHashKey("${e.model}")`);
        lines.push(`RequestModel(hash${i+1}); while not HasModelLoaded(hash${i+1}) do Wait(0) end`);
        lines.push(`local prop${i+1} = CreateObject(hash${i+1}, 0,0,0, true,true,false)`);
        lines.push(`SetEntityCollision(prop${i+1}, false, false)`);
        lines.push(`AttachEntityToEntity(`);
        lines.push(`    prop${i+1}, ped, GetPedBoneIndex(ped, ${e.bone}),`);
        lines.push(`    ${(+e.offset.x).toFixed(4)}, ${(+e.offset.y).toFixed(4)}, ${(+e.offset.z).toFixed(4)},`);
        lines.push(`    ${(+e.rotation.x).toFixed(4)}, ${(+e.rotation.y).toFixed(4)}, ${(+e.rotation.z).toFixed(4)},`);
        lines.push(`    true, true, false, true, 1, true`);
        lines.push(`)\n`);
    });
    exportOutput.value = lines.join('\n');
});

document.getElementById('btnExportCompact').addEventListener('click', async () => {
    const data = await getExportData(); if (!data) return;
    const lines = ['-- prop_attacher — compact format', ''];
    data.forEach((e, i) => {
        const ox = (+e.offset.x).toFixed(4), oy = (+e.offset.y).toFixed(4), oz = (+e.offset.z).toFixed(4);
        const rx = (+e.rotation.x).toFixed(4), ry = (+e.rotation.y).toFixed(4), rz = (+e.rotation.z).toFixed(4);
        lines.push(`{bone = ${e.bone}, pos = vec3(${ox}, ${oy}, ${oz}), rot = vec3(${rx}, ${ry}, ${rz})},`);
    });
    exportOutput.value = lines.join('\n');
});
document.getElementById('btnCopy').addEventListener('click', () => {
    exportOutput.select(); document.execCommand('copy');
    const btn = document.getElementById('btnCopy');
    btn.textContent = 'COPIED ✓';
    setTimeout(() => { btn.textContent = 'COPY TO CLIPBOARD'; }, 2000);
});

// ── Header buttons ────────────────────────────────────────────────────────────
document.getElementById('btnMinimize').addEventListener('click', () => lua('minimize'));
document.getElementById('btnClose').addEventListener('click', () => lua('closeUI'));
document.addEventListener('keydown', e => { if (e.key === 'Escape') lua('closeUI'); });

// ── NUI messages from Lua ─────────────────────────────────────────────────────
window.addEventListener('message', e => {
    const d = e.data;
    switch (d.action) {
        case 'open':
            State.bones = d.bones || []; State.presets = d.presets || [];
            renderBones(); renderPresets(); renderAttached(d.attached || []);
            app.classList.remove('hidden');
            break;
        case 'close':
            app.classList.add('hidden');
            State.freeCam = false;
            break;
        case 'minimize':
            app.classList.add('hidden');
            break;
        case 'restore':
            app.classList.remove('hidden');
            break;
        case 'placementStart':
            State.placing = true;
            liveBadge.classList.remove('hidden');
            placementHint.textContent = 'RMB outside panel = freecam · Drag axis = move · Drag ring = rotate';
            break;
        case 'placementEnd':
            State.placing = false;
            liveBadge.classList.add('hidden');
            break;
        case 'placementCancelled':
            State.placing = false;
            liveBadge.classList.add('hidden');
            placementHint.textContent = 'Placement cancelled.';
            break;
        case 'placementConfirmRequest':
            document.getElementById('btnConfirm').click();
            break;
        case 'liveUpdate':
            updateVec(d.offset, d.rotation);
            if (axisLabel && d.axis) axisLabel.textContent = 'AXIS: ' + d.axis;
            break;
        case 'freeCamOn':
            State.freeCam = true;
            break;
        case 'freeCamOff':
            State.freeCam = false;
            break;
    }
});
