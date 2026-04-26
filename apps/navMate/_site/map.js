// navMate map.js
// Leaflet client. Polls /poll?v=N at 1Hz; on version change fetches /geojson
// and re-renders all features. Additive accumulation is server-side.

// ---- Esri tile layers (free, no API key) ----

const imageryLayer = L.tileLayer(
    'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
    { attribution: 'Tiles &copy; Esri', maxNativeZoom: 19, maxZoom: 22 }
);
const labelsLayer = L.tileLayer(
    'https://server.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}',
    { attribution: 'Labels &copy; Esri', maxNativeZoom: 19, maxZoom: 22 }
);

// ---- Map init ----

const map = L.map('map', {
    layers:             [imageryLayer, labelsLayer],
    maxZoom:            22,
    zoomSnap:           0,
    zoomDelta:          0.5,
    wheelPxPerZoomLevel: 240,
});
map.setView([9.35, -82.25], 8);

// ---- Cursor coordinates ----

function toDDM(dd, isLat) {
    const dir = isLat ? (dd >= 0 ? 'N' : 'S') : (dd >= 0 ? 'E' : 'W');
    const abs = Math.abs(dd);
    const deg = Math.floor(abs);
    const min = (abs - deg) * 60;
    return deg + '°' + min.toFixed(3) + "' " + dir;
}

const coordsDiv = document.getElementById('nm-coords');
map.on('mousemove', e => {
    const lat = e.latlng.lat, lng = e.latlng.lng;
    coordsDiv.textContent =
        toDDM(lat, true) + '  ' + toDDM(lng, false) + '\n' +
        lat.toFixed(5)   + '  ' + lng.toFixed(5);
});
map.on('mouseout', () => { coordsDiv.textContent = ''; });

// ---- Render layer ----

const renderLayer = L.layerGroup().addTo(map);

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

        div.appendChild(makeRow('labels',  'Labels',   true));
        div.appendChild(makeRow('wpnames', 'WP names', false));
        div.appendChild(makeRow('rpnames', 'RP names', false));
        L.DomEvent.disableClickPropagation(div);
        L.DomEvent.disableScrollPropagation(div);
        return div;
    }
});
new OverlayControl().addTo(map);

const TS_FIELDS = new Set(['created_ts', 'ts_start', 'ts_end']);
const SKIP_FIELDS = new Set(['obj_type', 'name', 'rp_names']);
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
    const abbrev = TYPE_ABBREV[props.obj_type] || props.obj_type || '';
    let html = '<div class="nm-info-header">'
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

function makeWpIcon() {
    return L.divIcon({
        className:   'nm-wp-marker',
        iconSize:    [12, 12],
        iconAnchor:  [6, 6],
        popupAnchor: [0, -8]
    });
}

const wpIcon = makeWpIcon();

const E80_COLORS = ['#ff0000', '#ffff00', '#00ff00', '#0000ff', '#ff00ff', '#ffffff'];

function e80Color(idx) {
    return E80_COLORS[(idx >= 0 && idx < E80_COLORS.length) ? idx : 0];
}

// ---- Render all features from a GeoJSON FeatureCollection ----

// Track UUIDs already rendered so autozoom only moves to newly added items.
let renderedUuids = new Set();

let lastGeojson = null;

function rerender() {
    if (lastGeojson) renderAll(lastGeojson);
}

function isLabels()  { const cb = document.getElementById('labels');  return cb ? cb.checked : true;  }
function isWpNames() { const cb = document.getElementById('wpnames'); return cb ? cb.checked : false; }
function isRpNames() { const cb = document.getElementById('rpnames'); return cb ? cb.checked : false; }

function renderAll(geojson) {
    renderLayer.clearLayers();
    lastGeojson = geojson;
    const features = geojson.features || [];

    // Server cleared — reset our UUID tracking.
    if (features.length === 0) {
        renderedUuids = new Set();
        return;
    }

    const newLatLngs = [];

    features.forEach(f => {
        const geom  = f.geometry;
        const props = f.properties || {};
        if (!geom) return;

        const isNew = !renderedUuids.has(props.uuid);
        if (props.uuid) renderedUuids.add(props.uuid);

        if (geom.type === 'Point') {
            if (!isLabels()) return;
            const [lon, lat] = geom.coordinates;
            const wpType = props.wp_type || 'nav';
            let m;
            if (wpType === 'label') {
                const displayName = (props.name || '').replace(/~.*$/, '');
                m = L.marker([lat, lon], {
                    icon: L.divIcon({
                        className:  'nm-label',
                        html: escHtml(displayName),
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
            } else {
                m = L.marker([lat, lon], { icon: wpIcon });
            }
            const isNavWp = (wpType !== 'label' && wpType !== 'sounding');
            m.on('mouseover', () => {
                if (isNavWp) m.getElement()?.classList.add('nm-wp-hover');
                showInfo(props);
            });
            m.on('mouseout', () => {
                if (isNavWp) m.getElement()?.classList.remove('nm-wp-hover');
                hideInfo();
            });
            m.addTo(renderLayer);
            if (isNew) newLatLngs.push([lat, lon]);
            if (isWpNames() && props.name) {
                L.marker([lat, lon], {
                    icon: L.divIcon({
                        className:  'nm-wp-name',
                        html:       escHtml(props.name),
                        iconSize:   [0, 0],
                        iconAnchor: [-8, 5],
                    })
                }).addTo(renderLayer);
            }
        }
        else if (geom.type === 'LineString') {
            if (!geom.coordinates.length) return;
            const coords = geom.coordinates.map(([lon, lat]) => [lat, lon]);
            const color  = e80Color(props.color);
            const line   = L.polyline(coords, { color: color, weight: 2 });
            if (props.obj_type === 'track') {
                const total = coords.length;
                line.on('mouseover', () => line.setStyle({ color: '#ffffff' }));
                line.on('mousemove', e => {
                    const idx = nearestPointIdx(coords, e.latlng);
                    showInfo(props, 'point ' + (idx + 1) + ' / ' + total);
                });
                line.on('mouseout', () => { line.setStyle({ color: color }); hideInfo(); });
            } else {
                line.on('mouseover', () => { line.setStyle({ color: '#ffffff' }); showInfo(props, coords.length + ' route points'); });
                line.on('mouseout',  () => { line.setStyle({ color: color }); hideInfo(); });
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
                                html:       escHtml(rpName),
                                iconSize:   [0, 0],
                                iconAnchor: [-6, 5],
                            })
                        }).addTo(renderLayer);
                    }
                });
            }
        }
    });

    if (isAutoZoom() && newLatLngs.length) {
        if (newLatLngs.length === 1) {
            map.setView(newLatLngs[0], 15);
        } else {
            map.fitBounds(L.latLngBounds(newLatLngs), { padding: [30, 30], maxZoom: 17 });
        }
    }
}

// ---- Polling ----

let currentVersion = -1;

function poll() {
    fetch('/poll?v=' + currentVersion)
        .then(r => r.json())
        .then(data => {
            if (data.version === currentVersion) return;
            currentVersion = data.version;
            fetch('/geojson')
                .then(r => r.json())
                .then(renderAll)
                .catch(() => {});
        })
        .catch(() => {});
}

setInterval(poll, 1000);
