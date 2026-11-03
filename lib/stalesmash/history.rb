# frozen_string_literal: true

require "digest"
require "find"
require "open3"
require_relative "url"

module StaleSmash
  # The version is a commit. Unchanged files keep the commit that last touched
  # them, so the browser and a CDN keep those objects. A stylesheet, script,
  # manifest, or SVG uses the newest commit among the files it pulls in,
  # because that is the one URL the browser caches.
  class History
    # HTML is a page, not an asset. Everything else that exists can be versioned.
    PAGE_EXTENSIONS = %w[.html .htm].freeze
    TEXT_EXTENSIONS = %w[.css .scss .sass .js .mjs .json .webmanifest .svg .xml .rss .atom].freeze
    STYLE_EXTENSIONS = %w[.css .scss .sass].freeze
    QUOTED_EXTENSIONS = %w[.js .mjs .json .webmanifest .svg .xml .rss .atom].freeze
    # A feed or sitemap is written into the build and has no source commit.
    GENERATED_EXTENSIONS = %w[.xml .rss .atom].freeze
    CONTENT_DIRECTORIES = %w[_posts _layouts _includes _data].freeze
    PAGE_SOURCE_EXTENSIONS = %w[.md .markdown .mdown .html .htm .textile .adoc .asciidoc].freeze
    SKIP_DIRECTORIES = %w[
      .git .jekyll-cache .sass-cache .bundle node_modules .work _site
    ].freeze

    IMPORT_STATEMENT = /@(?:import|use|forward)\s+([^;]+);/m
    QUOTED = /['"]([^'"]+)['"]/
    # Whole quoted value, or a backtick string with no interpolation.
    QUOTED_STRING = /(['"])([^'"\n]*)\1|`([^`\n]*)`/
    CSS_URL = /url\(\s*(?:(['"])([^'"]*)\1|([^)\s]+))\s*\)/i
    CSS_IMPORT = /@import\s+(['"])([^'"]+)\1/
    ATTR_REF = /\b(?:data-src|href|src|poster|content|data|url)\s*=\s*(?:(["'])([^"']*)\1|([^\s"'<>`]+?)(?=\s|\/?>|$))/i
    SRCSET_REF = /\b[\w:-]*srcset\s*=\s*(?:(["'])([^"']*)\1|([^\s"'<>`]+?)(?=\s|\/?>|$))/i

    attr_reader :tokens

    def self.build(dir, baseurl: "", url: "")
      history = new(dir, baseurl, url)
      history.build
      history
    end

    def initialize(dir, baseurl = "", url = "")
      @source = File.expand_path(dir)
      @baseurl = baseurl.to_s
      @site_url = url.to_s
      @commit_sha = {}
      @commit_order = {}
      @dirty = {}
      @snap = {}
      @tokens = {}
      @references = {}
      @content_records = nil
    end

    def build
      deepen
      parse_commits
      parse_dirty
      each_file { |rel| snapshot(rel, []) }
      @tokens = {}
      @snap.each do |path, record|
        next if record.nil? || record[:id].nil? || record[:id].empty?

        @tokens[path] = record[:id]
      end
      alias_stylesheets
      self
    end

    # Files that exist only in the built site, such as a generated feed.
    # The version is the newest commit among the content that can change
    # the document and the assets that document actually references.
    def cover(dest)
      root = File.expand_path(dest.to_s)
      return unless File.directory?(root)

      Find.find(root) do |path|
        next if File.directory?(path) || File.symlink?(path)

        rel = path.delete_prefix("#{root}/")
        next if rel.start_with?("../") || rel.include?("/../")
        next unless generated?(rel)
        next if @tokens[rel] && !@tokens[rel].to_s.empty?

        record = generated_record(path, rel)
        next if record.nil? || record[:id].nil? || record[:id].empty?

        @tokens[rel] = record[:id]
      end
    end

    private

    def deepen
      return unless repo? && shallow?

      _fetched, fetch_status = Open3.capture2e(
        { "GIT_TERMINAL_PROMPT" => "0" },
        "git", "-C", @source, "-c", "protocol.file.allow=always", "fetch", "--unshallow"
      )
      # fetch exits 0 when there is no remote and leaves the clone shallow.
      return if fetch_status.success? && !shallow?

      warn "stalesmash: this checkout is shallow and the rest of the history could not be fetched. Files that were not changed in the fetched commits use a content hash."
    end

    def shallow?
      output, status = Open3.capture2("git", "-C", @source, "rev-parse", "--is-shallow-repository")
      status.success? && output.strip == "true"
    end

    def shallow_boundaries
      return @shallow_boundaries if @shallow_boundaries

      @shallow_boundaries = {}
      return @shallow_boundaries unless shallow?

      output, status = Open3.capture2("git", "-C", @source, "rev-parse", "--absolute-git-dir")
      return @shallow_boundaries unless status.success?

      file = File.join(output.strip, "shallow")
      return @shallow_boundaries unless File.file?(file)

      File.foreach(file) do |line|
        sha = line.strip.downcase
        @shallow_boundaries[sha] = true if sha.match?(/\A[0-9a-f]{40,64}\z/)
      end
      @shallow_boundaries
    end

    def parse_commits
      return unless repo?

      output, status = Open3.capture2(
        "git", "-C", @source, "-c", "core.quotepath=false",
        "log", "--abbrev=12", "--pretty=format:%H %h", "--name-only"
      )
      return unless status.success?

      boundaries = shallow_boundaries
      sha = nil
      order = nil
      skip_commit = false
      next_order = 0
      output.each_line do |line|
        line = line.strip
        if line.empty?
          sha = nil
          skip_commit = false
          next
        end
        if sha.nil? && (match = line.match(/\A([0-9a-f]{40,64}) ([0-9a-f]{7,64})\z/i))
          # A shallow boundary has no parent, so its name list is the whole
          # tree. That is not the commit that changed each file.
          skip_commit = boundaries.key?(match[1].downcase)
          sha = match[2]
          order = next_order
          next_order += 1
          next
        end
        next unless sha && !skip_commit

        rel = site_path(line)
        next if rel.nil? || @commit_sha.key?(rel)

        @commit_sha[rel] = sha
        @commit_order[rel] = order
      end
    end

    def parse_dirty
      return unless repo?

      output, status = Open3.capture2(
        "git", "-C", @source, "status", "--porcelain", "-z", "-uall"
      )
      return unless status.success?

      entries = output.split("\0")
      index = 0
      while index < entries.length
        entry = entries[index].to_s
        index += 1
        next if entry.length < 4

        mark_dirty(entry[3..])
        # R and C records are "XY new-path\\0old-path\\0". The old path has no status prefix.
        next unless entry[0] == "R" || entry[0] == "C" || entry[1] == "R" || entry[1] == "C"

        mark_dirty(entries[index])
        index += 1
      end
    end

    def snapshot(path, stack)
      return @snap[path] if @snap.key?(path)
      return nil unless readable?(path)
      if stack.include?(path)
        return record_for(path)
      end

      stack.push(path)
      entries = [[path, record_for(path)]]
      references(path).each do |kid|
        record = text?(kid) ? snapshot(kid, stack) : record_for(kid)
        entries << [kid, record] if record && record[:id]
      end
      stack.pop

      result = if entries.length == 1
                 entries[0][1]
               elsif entries.all? { |_, record| record[:commit] }
                 entries.map(&:last).min_by { |record| record[:order] }
               else
                 { id: mix(entries.map { |name, record| [name, record[:id]] }), order: -1, commit: false }
               end
      @snap[path] = result
      result
    end

    def alias_stylesheets
      @tokens.keys.grep(/\.sass\z/).each { |key| copy_style(key) }
      @tokens.keys.grep(/\.scss\z/).each { |key| copy_style(key) }
    end

    def copy_style(key)
      return if File.basename(key).start_with?("_")
      return if @tokens[key].nil? || @tokens[key].empty?

      @tokens[key.sub(/\.(?:scss|sass)\z/, ".css")] = @tokens[key]
    end

    def references(path)
      return [] unless text?(path)

      @references[path] ||= begin
        body = read_text(path)
        found = []
        found.concat(import_keys(path, body)) if style?(path)
        found.concat(url_keys(path, body)) if style?(path) || markup?(path)
        found.concat(style_path_keys(path, body)) if style?(path)
        found.concat(image_set_keys(path, body)) if style?(path)
        found.concat(quoted_keys(path, body)) if quoted_source?(path)
        found.concat(attr_keys(path, body)) if markup?(path)
        found.uniq.reject { |dep| dep == path || !asset_file?(dep) }
      end
    end

    def import_keys(path, body)
      found = []
      body.scan(IMPORT_STATEMENT) do |statement,|
        statement.to_s.scan(QUOTED) do |name,|
          resolved = resolve_import(path, name) || resolve_reference(path, name)
          found << resolved if resolved
        end
      end
      found
    end

    def url_keys(path, body)
      found = []
      body.scan(CSS_URL) do |_quote, quoted, bare|
        found << resolve_reference(path, (quoted || bare).to_s)
      end
      found.compact
    end

    def quoted_keys(path, body)
      found = []
      body.scan(QUOTED_STRING) do |_quote, plain, backtick|
        value = plain || backtick
        next if value.nil?
        if value.include?("${")
          URL.template_asset_paths(value).each do |part|
            found << resolve_reference(path, part)
          end
          next
        end
        next unless URL.pathlike?(value)

        found << resolve_reference(path, value)
      end
      found.compact
    end

    # image-set("logo.png") is a URL. content: "logo.png" is not, so a bare
    # name is a dependency only inside image-set().
    def image_set_keys(path, body)
      found = []
      body.scan(/image-set\(([^)]*)\)/i) do |inner,|
        inner.to_s.scan(QUOTED_STRING) do |_quote, plain, backtick|
          value = plain || backtick
          next if value.nil? || value.include?("${") || !URL.pathlike?(value)

          found << resolve_reference(path, value)
        end
      end
      found.compact
    end

    def style_path_keys(path, body)
      found = []
      body.scan(QUOTED_STRING) do |_quote, plain, backtick|
        value = plain || backtick
        next if value.nil? || !URL.stylesheet_reference?(value)

        found << resolve_reference(path, value)
      end
      found.compact
    end

    def attr_keys(path, body)
      found = []
      body.scan(ATTR_REF) do |quote, quoted, bare|
        found << resolve_reference(path, quote ? quoted : bare)
      end
      body.scan(SRCSET_REF) do |quote, quoted, bare|
        raw = quote ? quoted : bare
        next if raw.nil?

        raw.scan(/(?:\A|,)\s*(?!data:)([^\s,]+)/i) do |target,|
          found << resolve_reference(path, target)
        end
      end
      found.compact
    end

    # Root-absolute and same-host URLs may already include baseurl.
    def resolve_reference(from, raw)
      local = URL.local_path(raw, @site_url)
      return nil unless local

      local = URL.strip_base(@baseurl, local) if local.start_with?("/")
      key = URL.resolve_key(from, URL.decode_percent(URL.decode_amp(local)))
      key if asset_file?(key)
    end

    # An explicit .css import is that CSS file. A stylesheet with no
    # extension is a Sass partial, and the .css file must not steal it.
    def resolve_import(from, name)
      text = name.to_s.strip
      return nil if text.empty? || text.include?("*") || text.include?("://")
      return nil if text.start_with?("sass:", "//", "/")

      explicit = text[/\.(css|scss|sass)\z/i, 1]&.downcase
      stem = text.sub(/\.(?:css|scss|sass)\z/i, "")
      base = File.basename(stem)
      nested = File.dirname(stem)
      nested = nil if nested == "."
      from_dir = File.dirname(from)
      from_dir = nil if from_dir == "."

      if explicit == "css" || File.extname(from).downcase == ".css"
        candidate = URL.clean_path(File.join(*[from_dir, nested, "#{base}.#{explicit || "css"}"].compact))
        return candidate if candidate && readable?(candidate)

        return nil
      end

      leaves = base.start_with?("_") ? [base] : ["_#{base}", base]
      exts = explicit ? [".#{explicit}"] : %w[.scss .sass .css]
      [from_dir, "_sass"].uniq.each do |dir|
        leaves.each do |leaf|
          exts.each do |ext|
            candidate = URL.clean_path(File.join(*[dir, nested, "#{leaf}#{ext}"].compact))
            return candidate if candidate && readable?(candidate)
          end
        end
      end
      nil
    end

    def each_file
      walk(@source, [], content: false) { |rel| yield rel }
    end

    # Follow a symlink only while its real path stays inside the site.
    # A directory link is indexed under both URL prefixes. The ancestor
    # set is this chain, so a second prefix is not dropped as a repeat.
    def walk(dir, ancestors, content:, &block)
      real = safe_realpath(dir)
      return unless real && inside_root?(real)
      return if ancestors.include?(real)

      chain = ancestors + [real]
      begin
        children = Dir.children(dir)
      rescue SystemCallError
        return
      end
      children.each do |name|
        path = File.join(dir, name)
        if walkable_directory?(path, name, content)
          walk(path, chain, content: content, &block)
        elsif indexable_file?(path)
          rel = site_relative(path)
          next if rel.nil?
          next if !content && page?(rel)

          block.call(rel)
        end
      end
    end

    def walkable_directory?(path, name, content)
      return false unless File.directory?(path)
      return false if content ? skip_content_directory?(name) : skip_directory?(name)

      contained?(path)
    end

    def indexable_file?(path)
      File.file?(path) && contained?(path)
    end

    def skip_content_directory?(name)
      return false if CONTENT_DIRECTORIES.include?(name)

      skip_directory?(name)
    end

    def contained?(path)
      return true unless File.symlink?(path)

      real = safe_realpath(path)
      real && inside_root?(real) && !skipped_location?(real)
    end

    def skipped_location?(real)
      return false if real == source_root

      rel = real.delete_prefix("#{source_root}/")
      return false if rel.empty? || rel == real

      rel.split("/").any? { |part| skip_directory?(part) }
    end

    def site_relative(path)
      full = File.expand_path(path)
      prefix = "#{@source}/"
      return nil unless full.start_with?(prefix)

      rel = full.delete_prefix(prefix)
      return nil if rel.empty? || rel.start_with?("../") || rel.include?("/../")

      rel
    end

    def source_root
      @source_root ||= safe_realpath(@source) || @source
    end

    def inside_root?(real)
      real == source_root || real.start_with?(source_root + File::SEPARATOR)
    end

    def safe_realpath(path)
      File.realpath(path)
    rescue SystemCallError
      nil
    end

    def skip_directory?(name)
      SKIP_DIRECTORIES.include?(name) || name.start_with?(".", "_")
    end

    # A clean file is the commit that last changed it. A dirty worktree has no
    # commit yet, so local edits use the bytes until the next commit replaces
    # that with the new commit.
    # A normal file is its own commit. A symlink also carries the target's
    # commit, and a path under a directory symlink carries that link, so
    # either side moving changes the URL. One dirty side has no single commit.
    def record_for(path)
      named = version_paths(path).filter_map do |item|
        record = single_record(item)
        [item, record] if record && record[:id] && !record[:id].empty?
      end
      if named.empty?
        id = worktree_id(path)
        return nil if id.nil? || id.empty?

        return { id: id, order: -1, commit: false }
      end
      return named.map(&:last).min_by { |record| record[:order] } if named.all? { |_, record| record[:commit] }
      return named[0][1] if named.length == 1

      { id: mix(named.map { |item, record| [item, record[:id]] }), order: -1, commit: false }
    end

    def single_record(path)
      if @commit_sha[path] && !@dirty[path]
        { id: @commit_sha[path], order: @commit_order[path], commit: true }
      else
        id = worktree_id(path)
        return nil if id.nil? || id.empty?

        { id: id, order: -1, commit: false }
      end
    end

    def version_paths(path)
      found = []
      parts = []
      path.to_s.split("/").each do |part|
        next if part.empty?

        parts << part
        rel = parts.join("/")
        file = absolute(rel)
        found << rel if file && File.symlink?(file) && contained?(file)
      end
      canon = canonical_rel(path)
      found << canon if canon
      found << path if found.empty?
      found.uniq
    end

    def canonical_rel(path)
      file = absolute(path)
      return nil unless file

      real = safe_realpath(file)
      return nil unless real && inside_root?(real) && !skipped_location?(real)
      return nil if real == source_root

      rel = real.delete_prefix("#{source_root}/")
      return nil if rel.empty? || rel.end_with?("/")

      rel
    end

    def worktree_id(path)
      file = absolute(path)
      if repo? && file && File.exist?(file)
        output, status = Open3.capture2("git", "-C", @source, "hash-object", "--", path)
        hashed = output.to_s.strip
        return hashed[0, 12] if status.success? && hashed.match?(/\A[0-9a-f]{40,64}\z/i)
      end
      return nil unless file && File.file?(file)

      Digest::SHA256.file(file).hexdigest[0, 12]
    rescue SystemCallError
      nil
    end

    def generated?(path)
      GENERATED_EXTENSIONS.include?(File.extname(path.to_s).downcase)
    end

    def generated_record(path, rel)
      body = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace)
      entries = content_records.dup
      reference_keys(rel, body).each do |key|
        record = rolled_record(key)
        entries << [key, record] if record && record[:id] && !record[:id].empty?
      end
      combine(entries)
    rescue SystemCallError
      nil
    end

    def reference_keys(from, body)
      found = []
      found.concat(url_keys(from, body))
      found.concat(quoted_keys(from, body))
      found.concat(attr_keys(from, body))
      URL.escaped_tag_bodies(body).each do |inner|
        found.concat(attr_keys(from, inner))
      end
      found.uniq.compact
    end

    def rolled_record(key)
      return @snap[key] if @snap.key?(key) && @snap[key]

      single_record(key)
    end

    def content_records
      return @content_records if @content_records

      pairs = {}
      each_content_file do |rel|
        record = single_record(rel)
        pairs[rel] = record if record && record[:id] && !record[:id].empty?
      end
      @commit_sha.each do |rel, sha|
        next if pairs.key?(rel) || @dirty[rel] || !content_path?(rel)

        pairs[rel] = { id: sha, order: @commit_order[rel], commit: true }
      end
      @content_records = pairs.to_a
    end

    def each_content_file
      walk(@source, [], content: true) do |rel|
        yield rel if content_path?(rel)
      end
    end

    def content_path?(rel)
      text = rel.to_s
      return false if text.empty?
      return true if text == "_config.yml" || text == "_config.yaml"

      parts = text.split("/")
      if CONTENT_DIRECTORIES.include?(parts[0])
        return parts.none? { |part| part.start_with?(".") }
      end
      return false if parts.any? { |part| part.start_with?(".", "_") }

      PAGE_SOURCE_EXTENSIONS.include?(File.extname(text).downcase)
    end

    def combine(entries)
      usable = entries.reject { |_, record| record.nil? || record[:id].nil? || record[:id].empty? }
      return nil if usable.empty?
      return usable.map(&:last).min_by { |record| record[:order] } if usable.all? { |_, record| record[:commit] }

      { id: mix(usable.map { |name, record| [name, record[:id]] }), order: -1, commit: false }
    end

    def mix(pairs)
      body = pairs.map { |path, id| "#{path}=#{id}" }.sort.join("\n")
      Digest::SHA256.hexdigest("stalesmash-2\n#{body}")[0, 12]
    end

    def text?(path)
      TEXT_EXTENSIONS.include?(File.extname(path.to_s).downcase)
    end

    def style?(path)
      STYLE_EXTENSIONS.include?(File.extname(path.to_s).downcase)
    end

    def quoted_source?(path)
      QUOTED_EXTENSIONS.include?(File.extname(path.to_s).downcase)
    end

    def page?(path)
      PAGE_EXTENSIONS.include?(File.extname(path.to_s).downcase)
    end

    def asset_file?(key)
      return false if key.nil? || key.empty? || page?(key)

      readable?(key)
    end

    def readable?(path)
      cleaned = URL.clean_path(path)
      return false unless cleaned

      file = absolute(cleaned)
      return false unless file && File.file?(file)
      return true unless File.symlink?(file)

      contained?(file)
    end

    def markup?(path)
      ext = File.extname(path.to_s).downcase
      %w[.svg .xml .rss .atom].include?(ext)
    end

    def read_text(path)
      File.read(absolute(path), encoding: "UTF-8", invalid: :replace, undef: :replace)
    end

    def absolute(path)
      cleaned = URL.clean_path(path)
      return nil unless cleaned

      file = File.expand_path(cleaned, @source)
      return nil unless file == @source || file.start_with?(@source + File::SEPARATOR)

      file
    end

    def mark_dirty(path)
      rel = site_path(path)
      @dirty[rel] = true if rel
    end

    # git log and git status paths are relative to the repository root.
    # A Jekyll site in a subdirectory still versions files by their site path.
    def site_path(path)
      text = path.to_s.tr("\\", "/")
      return nil if text.empty?

      prefix = repo_prefix
      if !prefix.empty?
        return nil unless text.start_with?(prefix)

        text = text.delete_prefix(prefix)
      end
      return nil if text.empty? || text.end_with?("/")

      text
    end

    def repo_prefix
      return @repo_prefix unless @repo_prefix.nil?
      return @repo_prefix = "" unless repo?

      output, status = Open3.capture2("git", "-C", @source, "rev-parse", "--show-prefix")
      prefix = status.success? ? output.strip : ""
      prefix = "" if prefix == "."
      prefix = prefix.delete_suffix("/")
      @repo_prefix = prefix.empty? ? "" : "#{prefix}/"
    end

    def repo?
      return @repo unless @repo.nil?

      _output, status = Open3.capture2("git", "-C", @source, "rev-parse", "--is-inside-work-tree")
      @repo = status.success?
    end
  end
end
