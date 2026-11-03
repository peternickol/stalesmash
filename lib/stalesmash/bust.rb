# frozen_string_literal: true

require_relative "history"
require_relative "crawl"

module StaleSmash
  # Stamp ?v=<commit> on the built site. The Jekyll hook, the stalesmash
  # command, and the GitHub Action all call this.
  def self.bust(source:, dest:, baseurl: "", url: "")
    root = File.expand_path(source)
    built = File.expand_path(dest)
    raise "site root does not exist: #{root}" unless File.directory?(root)
    raise "build directory does not exist: #{built}" unless File.directory?(built)

    prefix = baseurl.to_s
    origin = url.to_s
    history = History.build(root, baseurl: prefix, url: origin)
    history.cover(built)
    Crawl.rewrite(built, history.tokens, baseurl: prefix, url: origin)
    history.tokens.length
  end
end
