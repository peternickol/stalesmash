# frozen_string_literal: true

require_relative "lib/stalesmash/version"

Gem::Specification.new do |spec|
  spec.name = "stalesmash"
  spec.version = StaleSmash::VERSION
  spec.authors = ["StaleSmash"]
  spec.email = ["dev@localhost"]
  spec.summary = "Cache busting for Jekyll from git"
  spec.description = <<~TEXT
    A Jekyll plugin that crawls the built site and appends each asset's git
    version to its URL. Any local file except an HTML page is an asset.
    Browsers refetch a file when that file changes and keep the rest.
    Dish and the GitHub Action call the same stalesmash command.
  TEXT
  spec.license = "MIT"
  spec.files = Dir.glob("{lib,exe}/**/*") + %w[README.md LICENSE]
  spec.bindir = "exe"
  spec.executables = ["stalesmash"]
  spec.require_paths = ["lib"]
  spec.required_ruby_version = ">= 2.7.0"

  spec.add_dependency "jekyll", ">= 3.9", "< 5"
  spec.add_development_dependency "minitest", "~> 5.0"

  spec.metadata = {
    "plugin_type" => "generator"
  }
end
