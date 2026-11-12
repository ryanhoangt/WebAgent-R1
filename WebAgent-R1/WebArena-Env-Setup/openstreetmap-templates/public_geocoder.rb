# Local public-Nominatim adapter: same API data, shared rate limit and disk cache.
require 'digest'
require 'fileutils'
require 'json'
require 'uri'

module WebArenaPublicGeocoder
  PREFIX = '/public-geocoder/'.freeze
  CACHE = '/webarena-geocoder-cache'.freeze
  TTL = 86_400
  INTERVAL = 1.1

  def self.fetch(path, query)
    return [404, {}, ['Unknown geocoder endpoint']] unless %w[search reverse].include?(path)
    FileUtils.mkdir_p(CACHE)
    upstream = ENV.fetch('MAP_PUBLIC_GEOCODER_UPSTREAM').sub(%r{/*$}, '/')
    key = Digest::SHA256.hexdigest(upstream + path + '?' + query)
    filename = File.join(CACHE, key + '.json')
    File.open(File.join(CACHE, 'request.lock'), 'a+') do |lock|
      lock.flock(File::LOCK_EX)
      if File.exist?(filename)
        cached = JSON.parse(File.read(filename))
        if Time.now.to_f - cached['time'] < TTL
          return [200, {'Content-Type' => cached['type'], 'X-WebArena-Cache' => 'HIT'}, [cached['body']]]
        end
      end
      timestamp = File.join(CACHE, 'last_request')
      previous = File.exist?(timestamp) ? File.read(timestamp).to_f : 0
      delay = INTERVAL - (Time.now.to_f - previous)
      sleep([delay, INTERVAL].min) if delay.positive?
      File.write(timestamp, Time.now.to_f.to_s)
      response = OSM.http_client.get(URI.parse(upstream + path + '?' + query))
      type = response.headers['content-type'] || 'application/json'
      body = response.body.to_s
      if response.status == 200
        File.write(filename, JSON.generate({'time' => Time.now.to_f, 'type' => type, 'body' => body}))
      end
      [response.status, {'Content-Type' => type, 'X-WebArena-Cache' => 'MISS'}, [body]]
    end
  end

  class Middleware
    def initialize(app)
      @app = app
    end

    def call(env)
      path = env['PATH_INFO']
      return @app.call(env) unless path.start_with?(PREFIX)
      return [405, {}, ['GET required']] unless env['REQUEST_METHOD'] == 'GET'
      begin
        WebArenaPublicGeocoder.fetch(path.delete_prefix(PREFIX), env['QUERY_STRING'].to_s)
      rescue StandardError => error
        Rails.logger.warn("Public geocoder failed: #{error.class}")
        [502, {'Content-Type' => 'application/json'}, [JSON.generate({'error' => error.class.name})]]
      end
    end
  end

  module ServerFetch
    def fetch_text(url)
      return super unless url.start_with?(WebArenaPublicGeocoder::PREFIX)
      uri = URI.parse(url)
      status, _, body = WebArenaPublicGeocoder.fetch(
        uri.path.delete_prefix(WebArenaPublicGeocoder::PREFIX), uri.query.to_s)
      raise "Public geocoder HTTP #{status}" unless status == 200
      body.join
    end
  end
end

Rails.application.config.middleware.insert_before 0, WebArenaPublicGeocoder::Middleware
Rails.application.config.to_prepare do
  OSM.http_client.headers['User-Agent'] = 'WebArenaLocalMapEval/1.0 (local research evaluation)'
  GeocoderController.prepend(WebArenaPublicGeocoder::ServerFetch)
end
