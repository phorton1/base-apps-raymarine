// navMate map.js
// Leaflet client. Polls /poll?v=N at 1Hz; on version change fetches /geojson
// and re-renders all features. Additive accumulation is server-side.

// ---- Esri tile layers (free, no API key) ----

const imageryLayer = L.tileLayer(
    'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
    { attribution: 'Tiles &copy; Esri' }
);
const labelsLayer = L.tileLayer(
    'https://server.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}',
    { attribution: 'Labels &copy; Esri' }
);

// ---- Map init ----

const map = L.map('map', { layers: [imageryLayer, labelsLayer] });
map.setView([9.35, -82.25], 8);

// ---- Render layer ----

const renderLayer = L.layerGroup().addTo(map);

// ---- Auto-zoom control (top-left, below zoom buttons) ----

const AutoZoomControl = L.Control.extend({
    options: { position: 'topleft' },
    onAdd: function() {
        const div = L.DomUtil.create('div', 'leaflet-bar leaflet-control nm-ctl');
        const lbl = L.DomUtil.create('label', '', div);
        const cb  = document.createElement('input');
        cb.type    = 'checkbox';
        cb.id      = 'autozoom';
        cb.checked = true;
        lbl.appendChild(cb);
        lbl.appendChild(document.createTextNode(' Auto-zoom'));
        L.DomEvent.disableClickPropagation(div);
        L.DomEvent.disableScrollPropagation(div);
        return div;
    }
});
new AutoZoomControl().addTo(map);

// ---- Clear control (top-left, below auto-zoom) ----

const ClearControl = L.Control.extend({
    options: { position: 'topleft' },
    onAdd: function() {
        const div = L.DomUtil.create('div', 'leaflet-bar leaflet-control nm-ctl');
        const btn = L.DomUtil.create('button', 'nm-clear-btn', div);
        btn.textContent = 'Clear';
        L.DomEvent.on(btn, 'click', function(e) {
            L.DomEvent.stopPropagation(e);
            fetch('/clear', { method: 'POST' }).catch(() => {});
        });
        L.DomEvent.disableClickPropagation(div);
        L.DomEvent.disableScrollPropagation(div);
        return div;
    }
});
new ClearControl().addTo(map);

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

function renderAll(geojson) {
    renderLayer.clearLayers();
    const allLatLngs = [];

    (geojson.features || []).forEach(f => {
        const geom  = f.geometry;
        const props = f.properties || {};
        if (!geom) return;

        if (geom.type === 'Point') {
            const [lon, lat] = geom.coordinates;
            const m = L.marker([lat, lon], { icon: wpIcon });
            if (props.name) m.bindTooltip(props.name, { permanent: false });
            m.addTo(renderLayer);
            allLatLngs.push([lat, lon]);
        }
        else if (geom.type === 'LineString') {
            if (!geom.coordinates.length) return;
            const coords = geom.coordinates.map(([lon, lat]) => [lat, lon]);
            const color  = e80Color(props.color);
            const line   = L.polyline(coords, { color: color, weight: 2 });
            if (props.name) line.bindTooltip(props.name, { permanent: false, sticky: true });
            line.addTo(renderLayer);
            allLatLngs.push(...coords);
            if (props.obj_type === 'route') {
                coords.forEach(([lat, lon]) => {
                    L.circleMarker([lat, lon], {
                        radius:      4,
                        color:       color,
                        fillColor:   color,
                        fillOpacity: 0.5,
                        weight:      1
                    }).addTo(renderLayer);
                });
            }
        }
    });

    if (isAutoZoom() && allLatLngs.length) {
        map.fitBounds(L.latLngBounds(allLatLngs), { padding: [30, 30] });
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
