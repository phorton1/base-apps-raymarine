// navMate map.js
// Leaflet client.
//
// SERVER PROTOCOL
// ---------------
// The server (navServer.pm) holds the truth in %features_by_key, keyed by
// composite "$source:$uuid".  Three endpoints:
//   GET /poll      -> { version }     cheap version probe
//   GET /geojson   -> FeatureCollection of everything currently visible
//   POST /clear    -> wipe-all (user-driven coarse clear)
//
// CLIENT STATE MACHINE
// --------------------
// Three version variables drive the protocol:
//   _polled_version        -- last value received from /poll
//   _rendering_version     -- version of the in-flight render (null when idle)
//   _last_rendered_version -- version of the most recently completed render
//
// Two timers (split deliberately):
//   _pollVersion   at _POLL_INTERVAL_MS    -- updates _polled_version
//   _renderTrigger at _RENDER_INTERVAL_MS  -- fires _fetchAndRender if needed
//
// This split keeps the keep-alive cadence independent of render workload --
// but JavaScript is single-threaded, so the split alone is not enough.
// renderAll is async and yields via requestAnimationFrame between chunks;
// THAT is what actually lets _pollVersion fire on schedule during a heavy
// render.  Do not remove that yield.
//
// CLIENT-OWNED RECONNECT
// ----------------------
// All fetches use AbortController with short timeouts.  On timeout or any
// fetch error, _connection_state flips to 'disconnected' and
// _resetForReconnect() runs:  clears the layer, resets prevRenderedUuids,
// sets _last_rendered_version = -1.  The next successful /poll will see a
// version mismatch and fire a full /geojson resync.  The server has no
// notion of "browser connect" -- it just answers questions.
//
// FEATURE IDENTITY
// ----------------
// Render identity is composite (data_source, uuid), not bare uuid.  A
// single UUID may exist as denormalized renderable items under db / e80 /
// fsh with different colors and geometries -- they coexist on the map as
// distinct features.  prevRenderedUuids stores "source:uuid" strings.

// ---- Google Maps base layers + Esri labels overlay ----

function googleLayer(lyrs) {
    return L.tileLayer(
        'https://mt{s}.google.com/vt/lyrs=' + lyrs + '&x={x}&y={y}&z={z}&key=AIzaSyCApJ-27s7aNpIplcjaIbMsRcvWz42ZjR4',
        {
            subdomains: ['0','1','2','3'],
            attribution: '&copy; Google',
            maxNativeZoom: 20,
            maxZoom: 22,
        }
    );
}
const imageryLayer = googleLayer('s');    // satellite
const hybridLayer  = googleLayer('y');    // mixed: satellite + roads/labels
const terrainLayer = googleLayer('p');    // terrain with roads

const labelsLayer = L.tileLayer(
    'https://server.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}',
    { attribution: 'Labels &copy; Esri', maxNativeZoom: 19, maxZoom: 22 }
);

const gebcoLayer = L.tileLayer.wms('https://wms.gebco.net/mapserv?', {
    layers:      'GEBCO_LATEST',
    format:      'image/png',
    attribution: 'Bathymetry &copy; GEBCO',
});

// ---- Map init ----

const map = L.map('map', {
    layers:             [imageryLayer, labelsLayer],
    maxZoom:            22,
    zoomSnap:           0,
    zoomDelta:          0.5,
    wheelPxPerZoomLevel: 240,
});
map.setView([9.35, -82.25], 8);

// Sentinel layer for the "Live depth" overlay-checkbox.  Carries no tiles;
// presence on the map is what enables GEBCO-depth-at-cursor queries.
const depthLiveSentinel = L.layerGroup();
let depthLiveEnabled = false;
map.on('overlayadd',    e => { if (e.layer === depthLiveSentinel) depthLiveEnabled = true; });
map.on('overlayremove', e => { if (e.layer === depthLiveSentinel) { depthLiveEnabled = false; depthDiv.textContent = ''; } });

const layerControl = L.control.layers({
    'Satellite':         imageryLayer,
    'Mixed (hybrid)':    hybridLayer,
    'Terrain':           terrainLayer,
    'GEBCO bathymetry':  gebcoLayer,
}, {
    'Live depth (GEBCO)': depthLiveSentinel,
}, { collapsed: true }).addTo(map);

// Hide the info box while the user is interacting with the layer control --
// they share the top-right corner and the info box otherwise covers the
// expanded layer-control panel.
{
    const lcEl = layerControl.getContainer();
    if (lcEl) {
        const infoEl = document.getElementById('nm-info');
        lcEl.addEventListener('mouseenter', () => { if (infoEl) infoEl.style.visibility = 'hidden'; });
        lcEl.addEventListener('mouseleave', () => { if (infoEl) infoEl.style.visibility = ''; });
    }
}

// ---- Cursor coordinates ----

function toDDM(dd, isLat) {
    const dir = isLat ? (dd >= 0 ? 'N' : 'S') : (dd >= 0 ? 'E' : 'W');
    const abs = Math.abs(dd);
    const deg = Math.floor(abs);
    const min = (abs - deg) * 60;
    return deg + '\u00B0' + min.toFixed(3) + "' " + dir;
}

const coordsDiv = document.getElementById('nm-coords');
const depthDiv  = document.getElementById('nm-depth');

// ---- GEBCO depth-at-cursor (live only when checkbox + GEBCO base both active) ----
//
// GEBCO's WMS GetFeatureInfo returns the elevation in meters (negative for
// below sea level).  Cells are ~450 m; snapping cursor lat/lon to that grid
// + caching means each unique cell is fetched at most once per session.
// Debounce avoids firing while the cursor is in motion.

const GEBCO_SNAP_DEG     = 0.004;   // ~450 m at equator -- matches GEBCO grid
const DEPTH_DEBOUNCE_MS  = 250;
const depthCache = new Map();
let depthFetchTimer = null;
let depthFetchSeq   = 0;            // race-guard: ignore stale responses

function snapGebcoLatLon(lat, lon) {
    return [Math.round(lat / GEBCO_SNAP_DEG) * GEBCO_SNAP_DEG,
            Math.round(lon / GEBCO_SNAP_DEG) * GEBCO_SNAP_DEG];
}

async function fetchGebcoDepth(snapLat, snapLon) {
    const key = snapLat.toFixed(4) + ',' + snapLon.toFixed(4);
    if (depthCache.has(key)) return depthCache.get(key);
    const half = GEBCO_SNAP_DEG / 2;
    const params = new URLSearchParams({
        SERVICE:      'WMS',
        VERSION:      '1.3.0',
        REQUEST:      'GetFeatureInfo',
        LAYERS:       'GEBCO_LATEST_2',     // queryable flat-image layer
        QUERY_LAYERS: 'GEBCO_LATEST_2',
        CRS:          'EPSG:4326',
        BBOX:         (snapLat - half) + ',' + (snapLon - half) + ',' +
                      (snapLat + half) + ',' + (snapLon + half),
        WIDTH:        '2',
        HEIGHT:       '2',
        I:            '1',
        J:            '1',
        INFO_FORMAT:  'text/plain',         // GEBCO doesn't offer JSON
    });
    let elev = null;
    try {
        const res  = await fetch('https://wms.gebco.net/mapserv?' + params.toString());
        const text = await res.text();
        const m = text.match(/value_list\s*=\s*'(-?\d+(?:\.\d+)?)'/);
        if (m) elev = parseFloat(m[1]);
    } catch (err) { /* leave elev as null */ }
    depthCache.set(key, elev);
    return elev;
}

function maybeQueueDepthQuery(lat, lng) {
    if (!depthLiveEnabled || !map.hasLayer(gebcoLayer)) return;
    clearTimeout(depthFetchTimer);
    const mySeq = ++depthFetchSeq;
    depthFetchTimer = setTimeout(async () => {
        const [sLat, sLon] = snapGebcoLatLon(lat, lng);
        const elev = await fetchGebcoDepth(sLat, sLon);
        if (mySeq !== depthFetchSeq) return;     // newer query superseded us
        if (elev == null) {
            depthDiv.textContent = '(no GEBCO data)';
        } else if (elev >= 0) {
            depthDiv.textContent = elev.toFixed(0) + ' m above sea level';
        } else {
            const m  = (-elev).toFixed(0);
            const ft = (-elev * 3.28084).toFixed(0);
            depthDiv.textContent = m + ' m   (' + ft + ' ft)';
        }
    }, DEPTH_DEBOUNCE_MS);
}

map.on('mousemove', e => {
    const lat = e.latlng.lat, lng = e.latlng.lng;
    coordsDiv.textContent =
        toDDM(lat, true) + '  ' + toDDM(lng, false) + '\n' +
        lat.toFixed(5)   + '  ' + lng.toFixed(5);
    maybeQueueDepthQuery(lat, lng);
});
map.on('mouseout', () => {
    coordsDiv.textContent = '';
    depthDiv.textContent  = '';
    clearTimeout(depthFetchTimer);
});

// ---- Render layer ----

const renderLayer = L.layerGroup().addTo(map);

// ---- Feature selection state ----

let editSubject = null;  // { layer, props, origCoords, type }  type='track'|'route'

// ---- Overlay control (top-left, below zoom buttons) ----

const OverlayControl = L.Control.extend({
    options: { position: 'topleft' },
    onAdd: function() {
        const div = L.DomUtil.create('div', 'leaflet-bar leaflet-control nm-ctl');

        function makeRow(id, text, checked) {
            const lbl = document.createElement('label');
            const cb  = document.createElement('input');
            cb.type    = 'checkbox';
            cb.id      = id;
            cb.checked = checked;
            cb.addEventListener('change', rerender);
            lbl.appendChild(cb);
            lbl.appendChild(document.createTextNode(' ' + text));
            return lbl;
        }

        div.appendChild(makeRow('autozoom', 'Auto-zoom', true));

        const btn = L.DomUtil.create('button', 'nm-clear-btn', div);
        btn.textContent = 'Clear';
        L.DomEvent.on(btn, 'click', function(e) {
            L.DomEvent.stopPropagation(e);
            fetch('/clear', { method: 'POST' }).catch(() => {});
        });

        div.appendChild(makeRow('labels',    'Labels',    true));
        div.appendChild(makeRow('wps',      'WPs',       true));
        div.appendChild(makeRow('wpnames',  'WP names',  false));
        div.appendChild(makeRow('rpnames',  'RP names',  false));
        div.appendChild(makeRow('soundings','Soundings', true));

        const hr = document.createElement('hr');
        hr.style.margin = '4px 0';
        div.appendChild(hr);
        div.appendChild(makeRow('src_db',  'DATABASE', true));
        div.appendChild(makeRow('src_e80', 'E80',      true));
        div.appendChild(makeRow('src_fsh', 'FSH',      true));

        L.DomEvent.disableClickPropagation(div);
        L.DomEvent.disableScrollPropagation(div);
        return div;
    }
});
new OverlayControl().addTo(map);


const TS_FIELDS = new Set(['created_ts', 'ts_start', 'ts_end']);
const SKIP_FIELDS = new Set(['obj_type', 'name', 'rp_names', 'data_source', 'depth_cm', 'rp_uuids']);
const TYPE_ABBREV = { waypoint: 'WP', route: 'Route', track: 'TRK' };

function escHtml(s) {
    return String(s ?? '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}

function fmtVal(k, v) {
    if (TS_FIELDS.has(k) && v > 0)
        return new Date(v * 1000).toISOString().replace('T',' ').replace('.000Z',' UTC');
    return String(v);
}

function showInfo(props, context) {
    const div = document.getElementById('nm-info');
    if (!div) return;
    const srcLabels = { db: '--- DATABASE ---', e80: '--- E80 ---', fsh: '--- FSH ---' };
    const src = srcLabels[props.data_source] || '--- DATABASE ---';
    const abbrev = TYPE_ABBREV[props.obj_type] || props.obj_type || '';
    let html = '<div class="nm-info-source">' + src + '</div>'
             + '<div class="nm-info-header">'
             + '<span class="nm-info-type">' + escHtml(abbrev) + ':</span> '
             + '<span class="nm-info-name">' + escHtml(props.name || '(unnamed)') + '</span>'
             + '</div>';
    if (context) html += '<div class="nm-info-ctx">' + escHtml(context) + '</div>';
    html += '<table class="nm-info-table">';
    for (const [k, v] of Object.entries(props)) {
        if (SKIP_FIELDS.has(k)) continue;
        if (v === null || v === undefined || v === '' || v === 0 && TS_FIELDS.has(k)) continue;
        html += '<tr><td class="nm-info-key">' + escHtml(k) + '</td>'
              + '<td class="nm-info-val">' + escHtml(fmtVal(k, v)) + '</td></tr>';
    }
    html += '</table>';
    div.innerHTML = html;
    div.style.display = 'block';
}

function hideInfo() {
    const div = document.getElementById('nm-info');
    if (div) div.style.display = 'none';
}

function nearestPointIdx(coords, latlng) {
    let best = 0, bestDist = Infinity;
    for (let i = 0; i < coords.length; i++) {
        const dlat = coords[i][0] - latlng.lat;
        const dlon = coords[i][1] - latlng.lng;
        const d = dlat * dlat + dlon * dlon;
        if (d < bestDist) { bestDist = d; best = i; }
    }
    return best;
}

// ---- Helpers ----

function isAutoZoom() {
    const cb = document.getElementById('autozoom');
    return cb ? cb.checked : true;
}

function makeColoredWpIcon(color) {
    const css = abgrToCSS(color);
    return L.divIcon({
        className:   '',
        html:        '<svg width="12" height="12"><circle cx="6" cy="6" r="5" fill="' + css + '"/></svg>',
        iconSize:    [12, 12],
        iconAnchor:  [6, 6],
        popupAnchor: [0, -8]
    });
}

function abgrToCSS(abgr) {
    if (!abgr || typeof abgr !== 'string' || abgr.length < 8) return '#ffffff';
    return '#' + abgr.slice(6,8) + abgr.slice(4,6) + abgr.slice(2,4);
}

// ---- Render all features from a GeoJSON FeatureCollection ----

// Composite "source:uuid" keys from the previous render.  Autozoom fires
// only for keys absent from the previous call, so toggle-off then toggle-on
// re-triggers zoom correctly.  Same UUID under different data_source
// counts as separate keys (the whole point of the source-keyed identity).
let prevRenderedUuids = new Set();

let lastGeojson = null;

// Render-generation counter.  Every renderAll invocation captures its own
// generation at entry; if a newer renderAll starts while this one is still
// yielding between chunks, the older one bails out at its next yield.
// Without this, a filter-checkbox click during a heavy poll-driven render
// would leave two async renderAlls interleaving on renderLayer.
let _render_generation = 0;

function rerender() {
    // Fire-and-forget.  renderAll is async now; _render_generation handles
    // the case where this is called while another renderAll is mid-chunk.
    if (lastGeojson) renderAll(lastGeojson);
}

function isLabels()    { const cb = document.getElementById('labels');    return cb ? cb.checked : true;  }
function isWPs()       { const cb = document.getElementById('wps');       return cb ? cb.checked : true;  }
function isWpNames()   { const cb = document.getElementById('wpnames');   return cb ? cb.checked : false; }
function isRpNames()   { const cb = document.getElementById('rpnames');   return cb ? cb.checked : false; }
function isSoundings() { const cb = document.getElementById('soundings'); return cb ? cb.checked : true;  }
function isDbVisible()  { const cb = document.getElementById('src_db');  return cb ? cb.checked : true; }
function isE80Visible() { const cb = document.getElementById('src_e80'); return cb ? cb.checked : true; }
function isFshVisible() { const cb = document.getElementById('src_fsh'); return cb ? cb.checked : true; }

async function renderAll(geojson)
    // Re-renders the full visible feature set from a /geojson snapshot.
    //
    // CHUNKED + YIELDED.  After every _RENDER_CHUNK_SIZE features we yield
    // via `await requestAnimationFrame`.  This is the single most important
    // line of the whole client protocol: it is what lets _pollVersion fire
    // during a heavy render.  JavaScript is single-threaded; without this
    // yield both interval timers stall until the loop completes, which is
    // exactly the "tracks disappear after 10-30s" class of bug that this
    // whole rework is fixing.  Do not remove the yield.
    //
    // GENERATION GUARD.  Captures _render_generation at entry; if a newer
    // renderAll starts during a yield, the older one returns at the next
    // generation check.  Prevents two async renders from interleaving on
    // renderLayer (e.g. a filter-checkbox rerender during a poll-driven
    // render).
    //
    // FEATURE IDENTITY IS COMPOSITE.  prevRenderedUuids is keyed
    // "source:uuid".  See top-of-file comment.
{
    if (editMode || joinMode) return;
    const my_gen = ++_render_generation;
    clearHandles();
    if (editSubject) { editSubject = null; hideCtxMenu(); }
    renderLayer.clearLayers();
    lastGeojson = geojson;
    const features = geojson.features || [];

    // Server cleared  -  reset our key tracking.
    if (features.length === 0) {
        prevRenderedUuids = new Set();
        return;
    }

    const newLatLngs  = [];
    const currentKeys = new Set();

    for (let i = 0; i < features.length; i++) {
        const f = features[i];
        const geom  = f.geometry;
        const props = f.properties || {};
        if (!geom) continue;

        const dsrc = props.data_source;
        const key  = (dsrc || '') + ':' + (props.uuid || '');
        const isNew = !prevRenderedUuids.has(key);
        if (props.uuid) currentKeys.add(key);

        if (dsrc === 'db'  && !isDbVisible())  continue;
        if (dsrc === 'e80' && !isE80Visible()) continue;
        if (dsrc === 'fsh' && !isFshVisible()) continue;

        if (geom.type === 'Point') {
            const [lon, lat] = geom.coordinates;
            const wpType  = props.wp_type || 'nav';
            const isNavWp = (wpType !== 'label' && wpType !== 'sounding');

            if (wpType === 'label'    && !isLabels())              continue;
            if (wpType === 'sounding' && !isSoundings())           continue;
            if (isNavWp               && !isWPs() && !isWpNames()) continue;

            let m;
            if (wpType === 'label') {
                const displayName = (props.name || '').replace(/~.*$/, '');
                m = L.marker([lat, lon], {
                    icon: L.divIcon({
                        className:  'nm-label',
                        html: '<span style="color:' + abgrToCSS(props.color) + '">' + escHtml(displayName) + '</span>',
                        iconSize:   [0, 0],
                        iconAnchor: [0, 8],
                    })
                });
            } else if (wpType === 'sounding') {
                const shallow = props.depth_cm > 0 && props.depth_cm < 183;
                m = L.marker([lat, lon], {
                    icon: L.divIcon({
                        className:  'nm-sounding' + (shallow ? ' nm-sounding-shallow' : ''),
                        html:       props.name || '',
                        iconSize:   [0, 0],
                        iconAnchor: [0, 8],
                    })
                });
            } else if (isWPs()) {
                m = L.marker([lat, lon], { icon: makeColoredWpIcon(props.color) });
            }

            if (m) {
                m.on('mouseover', () => {
                    if (isNavWp) m.getElement()?.classList.add('nm-wp-hover');
                    showInfo(props);
                });
                m.on('mouseout', () => {
                    if (isNavWp) m.getElement()?.classList.remove('nm-wp-hover');
                    hideInfo();
                });
                m.addTo(renderLayer);
            }
            if (isNew) newLatLngs.push([lat, lon]);
            if (isNavWp && isWpNames() && props.name) {
                L.marker([lat, lon], {
                    icon: L.divIcon({
                        className:  'nm-wp-name',
                        html:       '<span style="color:' + abgrToCSS(props.color) + '">' + escHtml(props.name) + '</span>',
                        iconSize:   [0, 0],
                        iconAnchor: [-8, 5],
                    })
                }).addTo(renderLayer);
            }
        }
        else if (geom.type === 'LineString') {
            if (!geom.coordinates.length) continue;
            const isSentinel = ([lat, lon]) => Math.abs(lat) < 0.01 && Math.abs(lon) < 0.01;
            const rawPts = geom.coordinates.map(([lon, lat]) => [lat, lon]);
            const rawDepths = Array.isArray(props.depth_cm) ? props.depth_cm : [];
            const coords = [];
            const depths = [];
            for (let i = 0; i < rawPts.length; i++) {
                if (isSentinel(rawPts[i])) continue;
                coords.push(rawPts[i]);
                depths.push(i < rawDepths.length ? rawDepths[i] : null);
            }
            let lineCoords = coords;
            if (rawPts.length !== coords.length) {
                lineCoords = [];
                let seg = [];
                for (const pt of rawPts) {
                    if (isSentinel(pt)) {
                        if (seg.length) { lineCoords.push(seg); seg = []; }
                    } else {
                        seg.push(pt);
                    }
                }
                if (seg.length) lineCoords.push(seg);
            }
            const color  = abgrToCSS(props.color);
            const isEditable = props.obj_type === 'track' && (dsrc === 'db' || dsrc === 'fsh');
            const line   = L.polyline(lineCoords, { color: color, weight: 2 });
            if (props.obj_type === 'track') {
                const total = coords.length;
                line.on('mouseover', () => {
                    if (editSubject && editSubject.layer === line) return;
                    line.setStyle({ color: '#ffffff' });
                });
                line.on('mousemove', e => {
                    if (editMode) return;
                    const idx = nearestPointIdx(coords, e.latlng);
                    const d = depths[idx];
                    const dStr = (d == null) ? '--' : (d / 30.48).toFixed(1) + ' ft';
                    showInfo(props, 'point ' + (idx + 1) + ' / ' + total + ' — ' + dStr);
                });
                line.on('mouseout', () => {
                    if (editSubject && editSubject.layer === line) return;
                    line.setStyle({ color: color });
                });
                if (isEditable) {
                    line.on('click', function(e) {
                        L.DomEvent.stopPropagation(e);
                        hideCtxMenu();
                        if (splitMode && editSubject && editSubject.layer === line) {
                            doSplitAtIdx(nearestPointIdx(coords, e.latlng));
                            return;
                        }
                        if (!editSubject || editSubject.layer !== line) selectFeature(line, props, coords, 'track');
                    });
                    line.on('contextmenu', function(e) {
                        L.DomEvent.stopPropagation(e);
                        if (!editSubject || editSubject.layer !== line) selectFeature(line, props, coords, 'track');
                        if (!editMode && !joinMode) showCtxMenu(e.originalEvent.clientX, e.originalEvent.clientY, 'feature');
                    });
                }
            } else {
                line.on('mouseover', () => { line.setStyle({ color: '#ffffff' }); showInfo(props, coords.length + ' route points'); });
                line.on('mouseout',  () => { line.setStyle({ color: color }); hideInfo(); });
                if (props.obj_type === 'route' && dsrc === 'db') {
                    line.on('contextmenu', function(e) {
                        L.DomEvent.stopPropagation(e);
                        if (editMode || joinMode) return;
                        const origCoords = coords.map(function(c, i) {
                            return { uuid: (props.rp_uuids && props.rp_uuids[i]) || null, lat: c[0], lon: c[1] };
                        });
                        if (!editSubject || editSubject.layer !== line) selectFeature(line, props, origCoords, 'route');
                        showCtxMenu(e.originalEvent.clientX, e.originalEvent.clientY, 'feature');
                    });
                }
            }
            line.addTo(renderLayer);
            if (isNew) newLatLngs.push(...coords);
            if (props.obj_type === 'route') {
                const total = coords.length;
                coords.forEach(([lat, lon], idx) => {
                    L.circleMarker([lat, lon], {
                        radius:      4,
                        color:       color,
                        fillColor:   color,
                        fillOpacity: 0.5,
                        weight:      1
                    })
                    .on('mouseover', function() {
                        this.setStyle({ color: '#ffffff', fillColor: '#ffffff' });
                        showInfo(props, 'RP: ' + (idx + 1) + ' / ' + total);
                    })
                    .on('mouseout', function() {
                        this.setStyle({ color: color, fillColor: color });
                        hideInfo();
                    })
                    .addTo(renderLayer);
                    if (isRpNames()) {
                        const rpName = (props.rp_names && props.rp_names[idx]) || String(idx + 1);
                        L.marker([lat, lon], {
                            icon: L.divIcon({
                                className:  'nm-rp-name',
                                html:       '<span style="color:' + abgrToCSS(props.color) + '">' + escHtml(rpName) + '</span>',
                                iconSize:   [0, 0],
                                iconAnchor: [-6, 5],
                            })
                        }).addTo(renderLayer);
                    }
                });
            }
        }

        // Yield to event loop between chunks so timers (especially
        // _pollVersion) can fire during a heavy render.  See the function
        // header block for why this line is load-bearing.
        if ((i + 1) % _RENDER_CHUNK_SIZE === 0 && i < features.length - 1) {
            await new Promise(function(r) { requestAnimationFrame(r); });
            if (my_gen !== _render_generation) return;
        }
    }

    if (my_gen !== _render_generation) return;
    prevRenderedUuids = currentKeys;

    if (isAutoZoom() && newLatLngs.length) {
        if (newLatLngs.length === 1) {
            map.setView(newLatLngs[0], 15);
        } else {
            map.fitBounds(L.latLngBounds(newLatLngs), { padding: [30, 30], maxZoom: 17 });
        }
    }
}

// ---- Feature selection ----

function selectFeature(layer, props, origCoords, type) {
    if (joinMode && joinPhase === 'pickTrackB' && type === 'track') {
        handleJoinTrackBPick({ layer: layer, props: props, origCoords: origCoords.slice() });
        return;
    }
    deselectFeature();
    editSubject = { layer: layer, props: props, origCoords: origCoords.slice(), type: type };
    layer.setStyle({ color: '#ffff00', weight: 4 });
}

function deselectFeature() {
    if (!editSubject) return;
    editSubject.layer.setStyle({ color: abgrToCSS(editSubject.props.color), weight: 2 });
    editSubject = null;
    hideCtxMenu();
}

// ============================================================================
// Server protocol -- poll/render state machine and fetch lifecycle
// ============================================================================
// Tuning constants and state variables for the protocol described at the top
// of this file.  Read that header block first.

const _POLL_INTERVAL_MS   = 1000;    // server version-probe cadence
const _RENDER_INTERVAL_MS = 250;     // render-decision cadence; cheap when guarded
const _POLL_TIMEOUT_MS    = 2000;    // /poll fetch timeout -- short, detect disconnect quickly
const _GEOJSON_TIMEOUT_MS = 10000;   // /geojson fetch timeout -- longer; payload can be large
const _RENDER_CHUNK_SIZE  = 50;      // features per chunk between renderAll yields

let _polled_version        = -1;
let _rendering_version     = null;          // non-null while a /geojson fetch+render is in flight
let _last_rendered_version = -1;
let _connection_state      = 'connected';   // 'connected' | 'disconnected'


function _fetchWithTimeout(url, ms)
    // AbortController-based fetch timeout.  fetch() has no native timeout; a
    // stalled response would otherwise block the protocol indefinitely.
    // Returns parsed JSON, or throws on timeout / network error.
{
    const ctrl  = new AbortController();
    const timer = setTimeout(function() { ctrl.abort(); }, ms);
    return fetch(url, { signal: ctrl.signal })
        .then(function(r) { return r.json(); })
        .finally(function() { clearTimeout(timer); });
}


function _resetForReconnect()
    // Local state reset triggered by detected disconnect (fetch timeout, or
    // tab becoming visible after being hidden).  Setting
    // _last_rendered_version to -1 guarantees the next /poll comparison
    // fires a fresh /geojson resync, picking up whatever server truth is
    // now.  Does NOT touch the server -- the server holds the union of all
    // pane contributions and the right thing for us to do on reconnect is
    // to re-pull, not to push.
{
    _last_rendered_version = -1;
    prevRenderedUuids = new Set();
    renderLayer.clearLayers();
    if (editSubject) { editSubject = null; hideCtxMenu(); }
}


function _pollVersion()
    // Timer A.  Asks the server for its current version and updates
    // _polled_version.  Does not render -- _renderTrigger makes that
    // decision on its own cadence so a slow render cannot delay subsequent
    // polls.  Fetch timeout flips to 'disconnected' and resets local
    // render state so the next successful poll triggers a full resync.
{
    _fetchWithTimeout('/poll?v=' + _polled_version, _POLL_TIMEOUT_MS)
        .then(function(data) {
            if (_connection_state === 'disconnected') {
                _connection_state = 'connected';
            }
            _polled_version = data.version;
        })
        .catch(function() {
            if (_connection_state === 'connected') {
                _connection_state = 'disconnected';
                _resetForReconnect();
            }
        });
}


function _renderTrigger()
    // Timer B.  Fires every _RENDER_INTERVAL_MS but only kicks off a render
    // when (a) there is something new to render and (b) no render is
    // already in flight.  The _rendering_version guard is what prevents
    // overlapping poll-driven renders when /geojson is slow.  Re-entry
    // from rerender() (filter checkboxes) is handled differently -- see
    // _render_generation in renderAll.
{
    if (_rendering_version !== null) return;
    if (_polled_version < 0) return;
    if (_polled_version === _last_rendered_version) return;
    _fetchAndRender(_polled_version);
}


function _fetchAndRender(version)
    // Claims the in-flight slot, fetches /geojson, awaits the async
    // renderAll, then commits _last_rendered_version.  On error or timeout
    // releases the slot and flips to 'disconnected' so the next successful
    // poll triggers a fresh resync.
{
    _rendering_version = version;
    _fetchWithTimeout('/geojson', _GEOJSON_TIMEOUT_MS)
        .then(function(geojson) { return renderAll(geojson); })
        .then(function() {
            _last_rendered_version = version;
            _rendering_version = null;
        })
        .catch(function() {
            _rendering_version = null;
            if (_connection_state === 'connected') {
                _connection_state = 'disconnected';
                _resetForReconnect();
            }
        });
}


setInterval(_pollVersion,   _POLL_INTERVAL_MS);
setInterval(_renderTrigger, _RENDER_INTERVAL_MS);


document.addEventListener('visibilitychange', function() {
    // When the tab becomes visible again after being hidden (laptop closed,
    // tab switched, system sleep), local state may be stale by an arbitrary
    // amount.  Force a full resync via the reconnect path.
    if (document.visibilityState === 'visible') {
        _resetForReconnect();
    }
});
