// nmEdit.js - navMate track/route editing
// Vertex drag/insert/delete, trim, split, join, append, and round-trip update.
// Depends on globals from map.js: map, editSubject, deselectFeature(), hideInfo(), abgrToCSS()

// ---- Edit state ----

let editMode   = false;
let splitMode  = false;
let appendMode = false;   // false | 'start' | 'end'

let rubberBandLine   = null;
let rubberBandAnchor = null;

let vtxHandles = [];   // L.Marker, one per vertex
let midHandles = [];   // L.Marker, one per segment midpoint
let midDragIdx = -1;   // index in layer LatLngs of the vertex being drag-inserted

// ---- Join state ----

let joinMode  = false;
let joinPhase = '';       // 'pickEndA' | 'pickTrackB' | 'pickStartB' | 'preview'
let joinTrackA = null;
let joinIdxA   = -1;
let joinTrackB = null;
let joinIdxB   = -1;
let joinPreviewLayers = [];

// ---- Icons ----

const vtxIcon      = L.divIcon({ className: 'nm-vtx',              iconSize: [12, 12], iconAnchor: [6, 6] });
const vtxStartIcon = L.divIcon({ className: 'nm-vtx nm-vtx-start', iconSize: [12, 12], iconAnchor: [6, 6] });
const vtxEndIcon   = L.divIcon({ className: 'nm-vtx nm-vtx-end',   iconSize: [12, 12], iconAnchor: [6, 6] });
const midIcon      = L.divIcon({ className: 'nm-mid',              iconSize: [8,   8], iconAnchor: [4, 4] });

// ---- Context menu ----

const ctxMenuDiv = document.createElement('div');
ctxMenuDiv.id = 'nm-ctx-menu';
ctxMenuDiv.style.display = 'none';
(function() {
    function makeBtn(id, text, fn) {
        const b = document.createElement('button');
        b.id          = id;
        b.textContent = text;
        b.onclick     = fn;
        ctxMenuDiv.appendChild(b);
    }
    makeBtn('nm-ctx-edit',   'Edit Track',   function() { enterEditMode();     });
    makeBtn('nm-ctx-join',   'Join Track',   function() { enterJoinMode();     });
    makeBtn('nm-ctx-create', 'Create Route', function() { startCreateRoute();  });
}());
document.body.appendChild(ctxMenuDiv);

function hideCtxMenu() {
    ctxMenuDiv.style.display = 'none';
}

function showCtxMenu(x, y, mode) {
    const editBtn   = document.getElementById('nm-ctx-edit');
    const joinBtn   = document.getElementById('nm-ctx-join');
    const createBtn = document.getElementById('nm-ctx-create');
    if (mode === 'map') {
        if (editBtn)   editBtn.style.display   = 'none';
        if (joinBtn)   joinBtn.style.display   = 'none';
        if (createBtn) createBtn.style.display = 'block';
    } else {
        const isRoute   = editSubject && editSubject.props.obj_type === 'route';
        const isDbTrack = editSubject && editSubject.props.data_source === 'db'
                                      && editSubject.props.obj_type === 'track';
        if (editBtn) {
            editBtn.textContent   = isRoute ? 'Edit Route' : 'Edit Track';
            editBtn.style.display = 'block';
        }
        if (joinBtn)   joinBtn.style.display   = isDbTrack ? 'block' : 'none';
        if (createBtn) createBtn.style.display = 'none';
    }
    ctxMenuDiv.style.display = 'block';
    const cw = ctxMenuDiv.offsetWidth;
    const ch = ctxMenuDiv.offsetHeight;
    ctxMenuDiv.style.left = (x + cw > window.innerWidth  ? x - cw : x) + 'px';
    ctxMenuDiv.style.top  = (y + ch > window.innerHeight ? y - ch : y) + 'px';
}

// ---- Edit bar ----

let editSplitHint;
let appendStartBtn, appendEndBtn, createDoneBtn;
const editBarDiv = document.createElement('div');
editBarDiv.id = 'nm-edit-bar';
editBarDiv.style.display = 'none';
(function() {
    function makeBtn(text, cls, fn) {
        const b = document.createElement('button');
        b.textContent = text;
        if (cls) b.className = cls;
        b.onclick = fn;
        editBarDiv.appendChild(b);
        return b;
    }
    makeBtn('< Trim start', '', function() { doTrim('start');           });
    makeBtn('Trim end >',   '', function() { doTrim('end');             });
    appendStartBtn = makeBtn('+Start', '', function() { toggleAppendMode('start'); });
    appendEndBtn   = makeBtn('+End',   '', function() { toggleAppendMode('end');   });
    makeBtn('Split...', '', function() { enterSplitMode(); });
    createDoneBtn = makeBtn('Done',    'nm-btn-confirm', function() { exitEditMode(true); });
    makeBtn('Confirm',                 'nm-btn-confirm', function() { exitEditMode(true); });
    makeBtn('Cancel',                  'nm-btn-cancel',  function() { exitEditMode(false); });
    const hint = document.createElement('span');
    hint.className   = 'nm-split-hint';
    hint.textContent = 'Click on track to select split vertex';
    editBarDiv.appendChild(hint);
    editSplitHint         = hint;
    createDoneBtn.style.display = 'none';
}());
document.body.appendChild(editBarDiv);

// ---- Join bar ----

let joinHint;
let joinConfirmBtn;
const joinBarDiv = document.createElement('div');
joinBarDiv.id = 'nm-join-bar';
joinBarDiv.style.display = 'none';
(function() {
    const hint = document.createElement('span');
    hint.className = 'nm-join-hint';
    joinBarDiv.appendChild(hint);
    joinHint = hint;
    function makeBtn(text, cls, fn) {
        const b = document.createElement('button');
        b.textContent = text;
        if (cls) b.className = cls;
        b.onclick = fn;
        joinBarDiv.appendChild(b);
        return b;
    }
    joinConfirmBtn = makeBtn('Confirm Join', 'nm-btn-confirm', function() { confirmJoin();    });
    makeBtn('Cancel',                        'nm-btn-cancel',  function() { exitJoinMode();   });
}());
document.body.appendChild(joinBarDiv);

function showJoinBar(hintText, showConfirm) {
    joinHint.textContent = hintText;
    joinConfirmBtn.style.display = showConfirm ? '' : 'none';
    joinBarDiv.style.display = 'flex';
}

// ---- Map event handlers ----

map.on('click', function(e) {
    if (appendMode && editSubject) {
        const lls = editSubject.layer.getLatLngs();
        if (appendMode === 'end') {
            lls.push(e.latlng);
            if (editSubject.editUuids) editSubject.editUuids.push(null);
        } else {
            lls.unshift(e.latlng);
            if (editSubject.editUuids) editSubject.editUuids.unshift(null);
        }
        editSubject.layer.setLatLngs(lls);
        rubberBandAnchor = appendMode === 'end' ? lls[lls.length - 1] : lls[0];
        if (!rubberBandLine) {
            rubberBandLine = L.polyline([rubberBandAnchor, rubberBandAnchor], {
                color: '#ffff00', weight: 2, dashArray: '5 5', interactive: false
            }).addTo(map);
        } else {
            rubberBandLine.setLatLngs([rubberBandAnchor, rubberBandAnchor]);
        }
        buildHandles();
        return;
    }
    if (!editMode && !joinMode) deselectFeature();
});

map.on('mousemove', function(e) {
    if (!appendMode || !rubberBandLine || !rubberBandAnchor) return;
    rubberBandLine.setLatLngs([rubberBandAnchor, e.latlng]);
});

map.on('contextmenu', function(e) {
    if (editMode || joinMode || appendMode) return;
    showCtxMenu(e.originalEvent.clientX, e.originalEvent.clientY, 'map');
});

document.addEventListener('keydown', function(e) {
    if (e.key !== 'Escape') return;
    hideCtxMenu();
    if (appendMode) {
        exitAppendMode();
    } else if (joinMode) {
        exitJoinMode();
    } else if (splitMode) {
        splitMode = false;
        editSplitHint.style.display = 'none';
        if (editSubject) buildHandles();
        editBarDiv.style.display = 'flex';
    } else if (editMode) {
        exitEditMode(false);
    } else {
        deselectFeature();
    }
});

// ---- Append mode ----

function enterAppendMode(which) {
    if (!editMode || !editSubject || splitMode) return;
    exitAppendMode();
    appendMode = which;
    const lls = editSubject.layer.getLatLngs();
    if (lls.length > 0) {
        rubberBandAnchor = which === 'start' ? lls[0] : lls[lls.length - 1];
        rubberBandLine   = L.polyline([rubberBandAnchor, rubberBandAnchor], {
            color: '#ffff00', weight: 2, dashArray: '5 5', interactive: false
        }).addTo(map);
    }
    _updateAppendButtons();
}

function exitAppendMode() {
    if (!appendMode) return;
    appendMode = false;
    if (rubberBandLine) { map.removeLayer(rubberBandLine); rubberBandLine = null; }
    rubberBandAnchor = null;
    _updateAppendButtons();
}

function toggleAppendMode(which) {
    if (appendMode === which) { exitAppendMode(); return; }
    enterAppendMode(which);
}

function _updateAppendButtons() {
    if (appendStartBtn) appendStartBtn.className = appendMode === 'start' ? 'nm-btn-active' : '';
    if (appendEndBtn)   appendEndBtn.className   = appendMode === 'end'   ? 'nm-btn-active' : '';
}

// ---- Vertex handle management ----

function clearHandles() {
    vtxHandles.forEach(function(h) { map.removeLayer(h); });
    midHandles.forEach(function(h) { map.removeLayer(h); });
    vtxHandles = [];
    midHandles = [];
}

function buildHandles() {
    clearHandles();
    if (!editSubject) return;
    const lls  = editSubject.layer.getLatLngs();
    const last = lls.length - 1;
    lls.forEach(function(ll, i) {
        const icon = i === 0 ? vtxStartIcon : i === last ? vtxEndIcon : vtxIcon;
        const h = L.marker(ll, { icon: icon, draggable: !joinMode, zIndexOffset: 1000 }).addTo(map);
        h.on('drag',    function() { if (!splitMode) syncPolyline(); });
        h.on('dragend', function() { if (!splitMode) buildMidHandles(); });
        h.on('click', function(e) {
            L.DomEvent.stopPropagation(e);
            const idx  = vtxHandles.indexOf(this);
            const hlast = vtxHandles.length - 1;
            if (splitMode) {
                doSplitAtIdx(idx);
            } else if (joinMode && joinPhase === 'pickEndA') {
                setJoinEndA(idx);
            } else if (joinMode && joinPhase === 'pickStartB') {
                setJoinStartB(idx);
            } else if (editMode) {
                if (idx === 0) {
                    const was = appendMode === 'start';
                    exitAppendMode();
                    if (!was) enterAppendMode('start');
                } else if (idx === hlast) {
                    const was = appendMode === 'end';
                    exitAppendMode();
                    if (!was) enterAppendMode('end');
                }
            }
        });
        h.on('contextmenu', function(e) {
            if (splitMode || joinMode) return;
            L.DomEvent.stopPropagation(e);
            const idx = vtxHandles.indexOf(this);
            if (idx !== -1) deleteVertex(idx);
        });
        vtxHandles.push(h);
    });
    if (!joinMode) buildMidHandles();
}

function buildMidHandles() {
    midHandles.forEach(function(h) { map.removeLayer(h); });
    midHandles = [];
    if (!editSubject) return;
    const lls = editSubject.layer.getLatLngs();
    for (let i = 0; i < lls.length - 1; i++) {
        const mid = L.latLng((lls[i].lat + lls[i + 1].lat) / 2,
                             (lls[i].lng + lls[i + 1].lng) / 2);
        const h = L.marker(mid, { icon: midIcon, draggable: true, zIndexOffset: 900 }).addTo(map);
        h.on('dragstart', function() {
            const idx  = midHandles.indexOf(this);
            if (idx === -1) return;
            const lls  = editSubject.layer.getLatLngs();
            const midLl = this.getLatLng();
            lls.splice(idx + 1, 0, midLl);
            editSubject.layer.setLatLngs(lls);
            if (editSubject.editUuids) editSubject.editUuids.splice(idx + 1, 0, null);
            midDragIdx = idx + 1;
        });
        h.on('drag', function() {
            if (midDragIdx === -1) return;
            const lls = editSubject.layer.getLatLngs();
            lls[midDragIdx] = this.getLatLng();
            editSubject.layer.setLatLngs(lls);
        });
        h.on('dragend', function() {
            midDragIdx = -1;
            buildHandles();
        });
        h.on('click', function(e) {
            L.DomEvent.stopPropagation(e);
            const idx = midHandles.indexOf(this);
            if (idx !== -1) insertVertex(idx);
        });
        midHandles.push(h);
    }
}

function syncPolyline() {
    if (!editSubject) return;
    editSubject.layer.setLatLngs(vtxHandles.map(function(h) { return h.getLatLng(); }));
}

function deleteVertex(idx) {
    const lls = editSubject.layer.getLatLngs();
    if (lls.length <= 2) return;
    lls.splice(idx, 1);
    editSubject.layer.setLatLngs(lls);
    if (editSubject.editUuids) editSubject.editUuids.splice(idx, 1);
    buildHandles();
}

function insertVertex(afterIdx) {
    const lls = editSubject.layer.getLatLngs();
    const a = lls[afterIdx], b = lls[afterIdx + 1];
    lls.splice(afterIdx + 1, 0, L.latLng((a.lat + b.lat) / 2, (a.lng + b.lng) / 2));
    editSubject.layer.setLatLngs(lls);
    if (editSubject.editUuids) editSubject.editUuids.splice(afterIdx + 1, 0, null);
    buildHandles();
}

// ---- Enter / exit edit mode ----

function enterEditMode() {
    if (!editSubject || editMode) return;
    editMode = true;
    if (editSubject.type === 'route') {
        editSubject.editUuids = editSubject.origCoords.map(function(c) { return c.uuid; });
    }
    hideCtxMenu();
    hideInfo();
    buildHandles();
    editBarDiv.style.display = 'flex';
}

function exitEditMode(doConfirm) {
    if (!editMode || !editSubject) return;
    exitAppendMode();
    splitMode = false;
    editSplitHint.style.display = 'none';
    if (createDoneBtn) createDoneBtn.style.display = 'none';
    clearHandles();
    editMode = false;
    editBarDiv.style.display = 'none';
    const creating = editSubject.creating;
    if (doConfirm) {
        if (editSubject.type === 'route' && creating) {
            submitCreateRoute();
        } else if (editSubject.type === 'route') {
            submitRouteUpdate();
        } else {
            submitTrackUpdate();
        }
    } else {
        if (creating) {
            map.removeLayer(editSubject.layer);
            editSubject = null;
        } else if (editSubject.type === 'route') {
            editSubject.layer.setLatLngs(
                editSubject.origCoords.map(function(c) { return L.latLng(c.lat, c.lon); })
            );
            deselectFeature();
        } else {
            editSubject.layer.setLatLngs(
                editSubject.origCoords.map(function(c) { return L.latLng(c[0], c[1]); })
            );
            deselectFeature();
        }
    }
}

// ---- Trim ----

function doTrim(end) {
    if (!editMode || !editSubject) return;
    const lls = editSubject.layer.getLatLngs();
    if (lls.length <= 2) return;
    if (end === 'start') {
        lls.shift();
        if (editSubject.editUuids) editSubject.editUuids.shift();
    } else {
        lls.pop();
        if (editSubject.editUuids) editSubject.editUuids.pop();
    }
    editSubject.layer.setLatLngs(lls);
    buildHandles();
}

// ---- Split ----

function enterSplitMode() {
    if (!editMode || !editSubject) return;
    splitMode = true;
    editSplitHint.style.display = 'inline';
}

function doSplitAtIdx(vertexIdx) {
    if (editSubject && editSubject.type === 'route') {
        doSplitRouteAtIdx(vertexIdx);
        return;
    }
    doSplitTrackAtIdx(vertexIdx);
}

function doSplitTrackAtIdx(vertexIdx) {
    splitMode = false;
    editSplitHint.style.display = 'none';
    const lls = editSubject.layer.getLatLngs();
    if (vertexIdx <= 0 || vertexIdx >= lls.length - 1) {
        editMode = true;
        editBarDiv.style.display = 'flex';
        buildHandles();
        return;
    }
    editMode = false;
    editBarDiv.style.display = 'none';
    clearHandles();
    const defaultName = editSubject.props.name + '-2';
    const newName = window.prompt('Name for the second track segment:', defaultName);
    if (newName === null) {
        editMode = true;
        editBarDiv.style.display = 'flex';
        buildHandles();
        return;
    }
    const payload = {
        op:        'split',
        uuid:      editSubject.props.uuid,
        source:    editSubject.props.data_source,
        split_idx: vertexIdx,
        new_name:  newName.trim() || defaultName,
    };
    deselectFeature();
    fetch('/track/edit', {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        body:    JSON.stringify(payload),
    }).catch(function() {});
}

function doSplitRouteAtIdx(vertexIdx) {
    splitMode = false;
    editSplitHint.style.display = 'none';
    const lls = editSubject.layer.getLatLngs();
    if (vertexIdx <= 0 || vertexIdx >= lls.length - 1) {
        editMode = true;
        editBarDiv.style.display = 'flex';
        buildHandles();
        return;
    }
    editMode = false;
    editBarDiv.style.display = 'none';
    clearHandles();
    const defaultName = editSubject.props.name + '-2';
    const newName = window.prompt('Name for the second route segment:', defaultName);
    if (newName === null) {
        editMode = true;
        editBarDiv.style.display = 'flex';
        buildHandles();
        return;
    }
    const payload = {
        op:        'split',
        source:    'db',
        uuid:      editSubject.props.uuid,
        split_idx: vertexIdx,
        new_name:  newName.trim() || defaultName,
    };
    deselectFeature();
    fetch('/route/edit', {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        body:    JSON.stringify(payload),
    }).catch(function() {});
}

// ---- Submit updates ----

function submitTrackUpdate() {
    const lls    = editSubject.layer.getLatLngs();
    const coords = lls.map(function(ll) { return [ll.lat, ll.lng]; });
    const payload = {
        op:     'update',
        uuid:   editSubject.props.uuid,
        source: editSubject.props.data_source,
        coords: coords,
    };
    deselectFeature();
    fetch('/track/edit', {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        body:    JSON.stringify(payload),
    }).catch(function() {});
}

function submitRouteUpdate() {
    const lls      = editSubject.layer.getLatLngs();
    const uuids    = editSubject.editUuids || [];
    const waypoints = lls.map(function(ll, i) {
        return { uuid: uuids[i] || null, lat: ll.lat, lon: ll.lng };
    });
    const payload = {
        op:        'full_update',
        source:    'db',
        uuid:      editSubject.props.uuid,
        waypoints: waypoints,
    };
    deselectFeature();
    fetch('/route/edit', {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        body:    JSON.stringify(payload),
    }).catch(function() {});
}

function submitCreateRoute() {
    const lls      = editSubject.layer.getLatLngs();
    const name     = editSubject.props.name;
    const collUuid = editSubject.createCollUuid;
    map.removeLayer(editSubject.layer);
    editSubject = null;
    if (lls.length < 2) return;
    const waypoints = lls.map(function(ll) {
        return { uuid: null, lat: ll.lat, lon: ll.lng };
    });
    const payload = {
        op:              'create',
        source:          'db',
        name:            name,
        collection_uuid: collUuid,
        waypoints:       waypoints,
    };
    fetch('/route/edit', {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        body:    JSON.stringify(payload),
    }).catch(function() {});
}

// ---- Create Route ----

function startCreateRoute() {
    hideCtxMenu();
    const name = window.prompt('Route name:');
    if (!name) return;
    const collUuid = window.prompt('Collection UUID:');
    if (!collUuid) return;

    const line = L.polyline([], { color: '#ffff00', weight: 2 }).addTo(map);
    editSubject = {
        layer:          line,
        props:          { uuid: null, name: name, obj_type: 'route', data_source: 'db', color: 'ff00ffffff' },
        origCoords:     [],
        type:           'route',
        createCollUuid: collUuid,
        creating:       true,
        editUuids:      [],
    };

    editMode = true;
    hideInfo();
    buildHandles();
    editBarDiv.style.display = 'flex';
    if (createDoneBtn) createDoneBtn.style.display = '';
    enterAppendMode('end');
}

// ---- Join ----

function enterJoinMode() {
    if (!editSubject || editMode || joinMode) return;
    if (editSubject.props.data_source !== 'db') return;
    joinMode   = true;
    joinPhase  = 'pickEndA';
    joinTrackA = editSubject;
    joinIdxA   = -1;
    joinTrackB = null;
    joinIdxB   = -1;
    hideCtxMenu();
    hideInfo();
    buildHandles();
    showJoinBar('Click the vertex where ' + (joinTrackA.props.name || 'track') + ' should END', false);
}

function setJoinEndA(idx) {
    joinIdxA      = idx;
    joinPhase     = 'pickTrackB';
    clearHandles();
    editSubject   = null;
    showJoinBar('Click the second track to join', false);
}

function handleJoinTrackBPick(track) {
    if (!track || !joinTrackA) return;
    if (track.layer === joinTrackA.layer) return;
    if (track.props.data_source !== 'db') return;
    joinTrackB    = track;
    editSubject   = track;
    track.layer.setStyle({ color: '#ffff00', weight: 4 });
    joinPhase = 'pickStartB';
    buildHandles();
    showJoinBar('Click the vertex where ' + (track.props.name || 'track') + ' should START', false);
}

function setJoinStartB(idx) {
    joinIdxB      = idx;
    joinPhase     = 'preview';
    clearHandles();
    editSubject   = null;
    buildJoinPreview();
    showJoinBar(
        'Confirm join: ' + (joinTrackA.props.name || 'track A') + ' + ' + (joinTrackB.props.name || 'track B'),
        true
    );
}

function buildJoinPreview() {
    clearJoinPreview();
    const llsA   = joinTrackA.layer.getLatLngs();
    const llsB   = joinTrackB.layer.getLatLngs();
    const sliceA = llsA.slice(0, joinIdxA + 1);
    const sliceB = llsB.slice(joinIdxB);
    const gap    = [llsA[joinIdxA], llsB[joinIdxB]];
    joinPreviewLayers = [
        L.polyline(sliceA, { color: '#ffffff', weight: 3 }).addTo(map),
        L.polyline(sliceB, { color: '#ffffff', weight: 3 }).addTo(map),
        L.polyline(gap,    { color: '#ffff00', weight: 2, dashArray: '6 6' }).addTo(map),
    ];
}

function clearJoinPreview() {
    joinPreviewLayers.forEach(function(l) { map.removeLayer(l); });
    joinPreviewLayers = [];
}

function confirmJoin() {
    if (!joinMode || !joinTrackA || !joinTrackB || joinIdxA < 0 || joinIdxB < 0) return;
    const payload = {
        op:     'join',
        source: 'db',
        uuid:   joinTrackA.props.uuid,
        uuid_b: joinTrackB.props.uuid,
        idx_a:  joinIdxA,
        idx_b:  joinIdxB,
    };
    exitJoinMode();
    fetch('/track/edit', {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        body:    JSON.stringify(payload),
    }).catch(function() {});
}

function exitJoinMode() {
    if (!joinMode) return;
    joinMode  = false;
    joinPhase = '';
    clearHandles();
    clearJoinPreview();
    if (joinTrackA) joinTrackA.layer.setStyle({ color: abgrToCSS(joinTrackA.props.color), weight: 2 });
    if (joinTrackB) joinTrackB.layer.setStyle({ color: abgrToCSS(joinTrackB.props.color), weight: 2 });
    joinTrackA    = null;
    joinTrackB    = null;
    joinIdxA      = -1;
    joinIdxB      = -1;
    editSubject   = null;
    joinBarDiv.style.display = 'none';
}
