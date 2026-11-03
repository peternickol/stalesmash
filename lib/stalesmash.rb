# frozen_string_literal: true

require "jekyll"
require_relative "stalesmash/version"
require_relative "stalesmash/bust"

module StaleSmash
  def self.enabled?(site)
    return false if ENV.fetch("STALESMASH_DISABLE", "") == "1"

    config = site.config["stalesmash"]
    return false if config.is_a?(Hash) && config["enabled"] == false

    true
  end
end

Jekyll::Hooks.register(:site, :post_write) do |site|
  next unless StaleSmash.enabled?(site)

  count = StaleSmash.bust(
    source: site.source,
    dest: site.dest,
    baseurl: site.baseurl,
    url: site.config["url"]
  )
  Jekyll.logger.info "StaleSmash:", "versioned #{count} files from git"
end
