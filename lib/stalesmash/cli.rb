# frozen_string_literal: true

require "date"
require "optparse"
require "yaml"
require_relative "bust"

module StaleSmash
  module CLI
    module_function

    def run(argv)
      options = { source: Dir.pwd, dest: nil, baseurl: nil, url: nil }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: stalesmash [--source DIR] [--dest DIR] [--baseurl PATH] [--url ORIGIN]"
        opts.on("--source DIR", "Site root. Default: the current directory") { |dir| options[:source] = dir }
        opts.on("--dest DIR", "Built site. Default: destination in _config.yml, or _site") { |dir| options[:dest] = dir }
        opts.on("--baseurl PATH", "Prefix for root-absolute URLs. Default: baseurl in _config.yml") { |path| options[:baseurl] = path }
        opts.on("--url ORIGIN", "Site origin, such as https://example.com. Default: url in _config.yml") { |origin| options[:url] = origin }
      end
      args = parser.parse(argv)
      unless args.empty?
        warn "Unknown argument: #{args.first}"
        return 1
      end

      source = File.expand_path(options[:source])
      config = read_config(source)
      dest = options[:dest] || config["destination"] || "_site"
      dest = File.expand_path(dest, source)
      baseurl = options[:baseurl].nil? ? config["baseurl"].to_s : options[:baseurl]
      url = options[:url].nil? ? config["url"].to_s : options[:url]
      count = StaleSmash.bust(source: source, dest: dest, baseurl: baseurl, url: url)
      puts "Versioned #{count} files in #{dest}"
      0
    rescue StandardError => error
      warn "stalesmash: #{error.message}"
      1
    end

    def read_config(source)
      path = File.join(source, "_config.yml")
      return {} unless File.file?(path)

      loaded = YAML.safe_load(
        File.read(path),
        permitted_classes: [Date, Time, DateTime],
        aliases: true
      )
      loaded.is_a?(Hash) ? loaded : {}
    rescue StandardError
      {}
    end
  end
end
