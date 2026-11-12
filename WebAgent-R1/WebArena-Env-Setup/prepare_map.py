"""Generate isolated Map runtime config without starting/building containers."""
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
from urllib.parse import urlsplit


def prepare():
    setup = Path(__file__).resolve().parent
    app = setup / 'openstreetmap-website'
    runtime = Path(os.environ['MAP_RUNTIME_DIR']).resolve()
    mode = os.environ.get('MAP_BACKEND_MODE', '')
    if mode not in {'public', 'benchmark'}:
        raise SystemExit('Choose MAP_BACKEND_MODE=public or benchmark in map.env first. '
                         'Public services are not a frozen benchmark backend.')
    defaults = dict(MAP_GEOCODING_URL='https://nominatim.openstreetmap.org/',
                    MAP_TILE_URL='https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    MAP_ROUTING_URL='https://routing.openstreetmap.de',
                    MAP_CAR_SUFFIX='/routed-car', MAP_BIKE_SUFFIX='/routed-bike',
                    MAP_FOOT_SUFFIX='/routed-foot')
    backend = {'mode': mode}
    for key, default in defaults.items():
        value = os.environ.get(key) or (default if mode == 'public' else '')
        if not value:
            raise SystemExit(f'{key} is required in benchmark mode (no public fallback).')
        if key.endswith('_URL'):
            parsed = urlsplit(value)
            if parsed.scheme not in {'http', 'https'} or not parsed.netloc or parsed.username or parsed.password:
                raise SystemExit(f'{key} must be an HTTP(S) URL without embedded credentials.')
        elif not value.startswith(('/', ':')):
            raise SystemExit(f'{key} must start with / (path) or : (port).')
        backend[key] = value
    port = int(os.environ.get('MAP_PORT', '9003'))
    if not 1 <= port <= 65535:
        raise SystemExit('Invalid MAP_PORT')
    host = os.environ.get('PUBLIC_HOSTNAME', 'localhost')
    dns_overrides = json.loads(os.environ.get('MAP_DNS_OVERRIDES', '{}'))
    if not isinstance(dns_overrides, dict) or any(
            key not in {'nominatim.openstreetmap.org', 'tile.openstreetmap.org'}
            for key in dns_overrides):
        raise SystemExit('MAP_DNS_OVERRIDES must map the public Nominatim/tile hostnames to IPs.')
    for value in dns_overrides.values():
        ipaddress.ip_address(value)
    manifest = dict(backend=backend, base_url=f'http://{host}:{port}', dns_overrides=dns_overrides,
                    public_geocoder_adapter='cache24h-rate1.1s-v1' if mode == 'public' else None)
    # Different configurations use different files; --prepare does not overwrite
    # bind-mounted configuration from another running Map profile.
    profile = hashlib.sha256(json.dumps(manifest, sort_keys=True).encode()).hexdigest()[:16]
    generated = runtime / profile
    generated.mkdir(parents=True, exist_ok=True)
    settings = (app / 'config/settings.yml').read_text()
    for key, value in dict(server_protocol='http', server_url=f'{host}:{port}',
                           nominatim_url='/public-geocoder/' if mode == 'public' else backend['MAP_GEOCODING_URL'],
                           fossgis_osrm_url=backend['MAP_ROUTING_URL']).items():
        settings, count = re.subn(r'^' + key + r':.*$',
                                  lambda _: key + ': ' + json.dumps(value), settings, flags=re.M)
        if count != 1:
            raise SystemExit(f'Expected exactly one settings key: {key}')
    (generated / 'settings.yml').write_text(settings)
    routing = (setup / 'openstreetmap-templates/fossgis_osrm.js').read_text()
    for vehicle in ('Car', 'Bike', 'Foot'):
        # JSON string quoting also protects JavaScript syntax in supplied suffixes.
        routing = routing.replace('"__OSM' + vehicle + 'Suffix__"',
                                  json.dumps(backend[f'MAP_{vehicle.upper()}_SUFFIX']))
    (generated / 'fossgis_osrm.js').write_text(routing)
    tiles = (setup / 'openstreetmap-templates/leaflet.osm.js').read_text()
    tiles = tiles.replace("url: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png'",
                          'url: ' + json.dumps(backend['MAP_TILE_URL']))
    (generated / 'leaflet.osm.js').write_text(tiles)
    public_overrides = []
    if mode == 'public':
        initializer = generated / 'public_backend.rb'
        initializer.write_text((setup / 'openstreetmap-templates/public_geocoder.rb').read_text())
        public_overrides = [dict(type='bind', source=str(initializer),
                                 target='/app/config/initializers/webarena_public_backend.rb',
                                 read_only=True)]
        # Cache survives website/database resets; it contains only public lookup
        # responses, not website or benchmark-user state.
        cache_dir = runtime / 'public-geocoder-cache'
        cache_dir.mkdir(exist_ok=True)
        public_overrides.append(dict(type='bind', source=str(cache_dir),
                                     target='/webarena-geocoder-cache'))

    def bind(source, target, readonly=False):
        return dict(type='bind', source=str(source), target=target, read_only=readonly)

    compose = dict(services=dict(
        web=dict(image='openstreetmap-website-web:latest', container_name='map',
                 extra_hosts=dns_overrides,
                 working_dir='/app', environment=dict(RAILS_ENV='development', PIDFILE='/tmp/pids/server.pid',
                    MAP_PUBLIC_GEOCODER_UPSTREAM=backend['MAP_GEOCODING_URL']),
                 labels={'webarena.map.backend': json.dumps(manifest, sort_keys=True)},
                 ports=[f'{port}:3000'], tmpfs=['/tmp/pids'],
                 command=['bundle', 'exec', 'rails', 's', '-p', '3000', '-b', '0.0.0.0'],
                 depends_on={'db': {'condition': 'service_healthy'}},
                 volumes=[bind(app, '/app'), '/app/node_modules', 'web-tmp:/app/tmp',
                          'web-storage:/app/storage',
                          bind(generated / 'settings.yml', '/app/config/settings.yml', True),
                          bind(generated / 'fossgis_osrm.js', '/app/app/assets/javascripts/index/directions/fossgis_osrm.js', True),
                          bind(generated / 'leaflet.osm.js', '/app/vendor/assets/leaflet/leaflet.osm.js', True)] + public_overrides),
        db=dict(image='openstreetmap-website-db:latest', container_name='map_db',
                environment=dict(POSTGRES_HOST_AUTH_METHOD='trust', POSTGRES_DB='openstreetmap'),
                volumes=['db-data:/var/lib/postgresql/data'],
                healthcheck=dict(test=['CMD-SHELL', 'pg_isready -U postgres -d openstreetmap'],
                                 interval='2s', timeout='5s', retries=90))),
        volumes={'db-data': {}, 'web-tmp': {}, 'web-storage': {}})
    (runtime / 'compose.json').write_text(json.dumps(compose, indent=2) + '\n')
    (generated / 'backend.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'Map profile: {mode}; config: {generated}')


if __name__ == '__main__':
    prepare()
