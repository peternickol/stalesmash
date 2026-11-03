# frozen_string_literal: true

module StaleSmash
  # One URL shape everywhere: the original path, baseurl, any existing
  # query, then ?v=<commit>. A same-host absolute URL keeps its origin.
  module URL
    module_function

    def stamp(tokens, baseurl, from_rel, raw, site_url: "", base_dir: nil)
      text = raw.to_s.strip
      return nil if text.empty? || text.start_with?("data:", "#", "mailto:")

      peeled = peel(text, site_url)
      return nil if peeled == :foreign

      if peeled
        path, query, fragment = split(peeled[:rest])
        absolute = true
        origin = peeled[:origin]
      else
        path, query, fragment = split(text)
        absolute = path.start_with?("/")
        origin = nil
      end

      encoded = absolute ? strip_base(baseurl, path) : path
      key = resolve_key(from_rel, decode_percent(decode_amp(encoded)), base_dir: base_dir)
      return nil unless key

      token = tokens[key].to_s.strip
      return nil if token.empty?

      # Keep the author's encoding. %20 stays %20; the lookup used the decoded name.
      display_path = absolute ? prefix_base(baseurl, encoded) : path
      display = origin ? "#{origin}#{display_path}" : display_path
      build(display, query, fragment, token)
    end

    # Path to look up, without an origin, query, or fragment.
    # Foreign hosts return nil so a CDN URL is not a dependency.
    def local_path(raw, site_url)
      text = raw.to_s.strip
      return nil if text.empty? || text.start_with?("data:", "#", "mailto:")

      peeled = peel(text, site_url)
      return nil if peeled == :foreign

      body = peeled.nil? ? text : peeled[:rest]
      path, = split(body)
      return nil if path.nil? || path.empty?

      path
    end

    # A quoted value that might be a file reference. Sentences are not.
    def pathlike?(text)
      value = text.to_s.strip
      return false if value.empty? || value.match?(/\s/)
      return false if value.start_with?("data:", "#", "mailto:")
      return true if value.include?("://") || value.start_with?("//", "/", "./", "../")
      return true if value.match?(%r{\A[^/?#]+\.[A-Za-z][A-Za-z0-9]{0,15}(?:[?#].*)?\z})
      return true if value.include?("/") && value.match?(/\.[A-Za-z][A-Za-z0-9]{0,15}(?:[?#]|\z)/)

      false
    end

    # Quoted CSS paths such as image-set("/img/a.png" 1x). A bare word is
    # left alone so content: "logo.png" stays text. image-set("logo.png")
    # is handled by the image-set scan, which knows the string is a URL.
    def stylesheet_reference?(text)
      value = text.to_s.strip
      return false unless pathlike?(value)

      value.include?("/") || value.start_with?("//")
    end

    # A template literal may build the URL around ${...}. The static path
    # still names one file: `/img/a.png?w=${w}` and `${base}/img/a.png`.
    def version_template(tokens, baseurl, from_rel, value, site_url: "", base_dir: nil)
      text = value.to_s
      return nil unless text.include?("${")

      path, query, fragment = split(text)
      return nil if path.nil? || path.empty?
      if !path.include?("${")
        return stamp(tokens, baseurl, from_rel, text, site_url: site_url, base_dir: base_dir)
      end

      match = path.match(%r{(.*?)(/(?:[^${}\s?#]+/)*[^${}\s?#]+\.[A-Za-z0-9]{1,12})\z})
      return nil unless match

      key = resolve_key(from_rel, decode_percent(decode_amp(match[2])), base_dir: base_dir)
      return nil unless key

      token = tokens[key].to_s.strip
      return nil if token.empty?

      # The dynamic prefix supplies the location, so the path is not rewritten
      # with baseurl a second time.
      build("#{match[1]}#{match[2]}", query, fragment, token)
    end

    def template_asset_paths(value)
      path, = split(value.to_s)
      return [] if path.nil? || path.empty?

      paths = []
      paths << path unless path.include?("${")
      if (match = path.match(%r{((?:/(?:[^${}\s?#]+/)*[^${}\s?#]+\.[A-Za-z0-9]{1,12}))\z}))
        paths << match[1]
      end
      paths.uniq
    end

    # Directory used to resolve relative URLs in one HTML document.
    # nil keeps the file's own directory. :foreign means a <base href>
    # points at another host, so relative URLs are not local assets.
    # The first base element wins. Ones inside comments, scripts, and
    # styles are not elements.
    def base_directory(html, from_rel, baseurl, site_url)
      stripped = html.to_s.gsub(/<!--.*?-->/m, "")
      stripped = stripped.gsub(/<script\b[^>]*>.*?<\/script>/im, "")
      stripped = stripped.gsub(/<style\b[^>]*>.*?<\/style>/im, "")
      match = stripped.match(/<base\b[^>]*?\bhref\s*=\s*(?:(["'])(.*?)\1|([^\s"'<>`]+))/im)
      return nil unless match

      href = (match[2] || match[3]).to_s.strip
      return nil if href.empty? || href.start_with?("#", "mailto:", "data:")

      peeled = peel(href, site_url)
      return :foreign if peeled == :foreign

      raw_path = split(peeled ? peeled[:rest] : href).first.to_s
      return nil if raw_path.empty?

      host_path = if raw_path.start_with?("/")
                    raw_path
                  else
                    dir = File.dirname(from_rel.to_s)
                    dir = "" if dir == "."
                    joined = clean_path(File.join(dir, raw_path))
                    return nil if joined.nil? || joined.empty?

                    "/#{joined}"
                  end
      host_path = host_path.sub(%r{/[^/]*\z}, "/") unless raw_path.end_with?("/")
      host_path = "/" if host_path.empty?
      directory = strip_base(baseurl, host_path)
      directory = "/" if directory.empty?
      directory.sub(%r{\A/}, "").sub(%r{/\z}, "")
    end

    # Markup that a feed escaped with xml_escape. One pass, left to right,
    # so &amp; is decoded before a following lt and &amp;lt; stays &lt;.
    ESCAPED_ENTITY = /&(?:amp|lt|gt|quot|apos|#34|#x22|#39|#x27);/i

    def rewrite_escaped_tags(text)
      source = text.to_s
      return source unless source.match?(/&lt;/i)

      parts = []
      index = 0
      while (start = source.index(/&lt;/i, index))
        parts << source[index...start]
        finish = escaped_tag_finish(source, start)
        if finish.nil?
          parts << source[start..]
          return parts.join
        end

        chunk = source[start...finish]
        inner = unescape_xml_once(chunk)
        parts << yield(inner, chunk)
        index = finish
      end
      parts << source[index..] if index < source.length
      parts.join
    end

    def escaped_tag_bodies(text)
      bodies = []
      rewrite_escaped_tags(text) do |inner, chunk|
        bodies << inner
        chunk
      end
      bodies
    end

    def unescape_xml_once(text)
      text.to_s.gsub(ESCAPED_ENTITY) { |entity| xml_entity_char(entity) }
    end

    def xml_escape(text)
      text.to_s.gsub(/[&<>"]/) do |char|
        case char
        when "&" then "&amp;"
        when "<" then "&lt;"
        when ">" then "&gt;"
        when '"' then "&quot;"
        end
      end
    end

    def escaped_tag_finish(text, start)
      index = start
      quote = nil
      while index < text.length
        if (match = text.match(ESCAPED_ENTITY, index)) && match.begin(0) == index
          decoded = xml_entity_char(match[0])
          return index + match[0].length if quote.nil? && decoded == ">"

          quote = toggle_quote(quote, decoded)
          index += match[0].length
          next
        end

        char = text[index]
        if char == '"' || char == "'"
          quote = toggle_quote(quote, char)
        elsif quote.nil? && char == ">"
          return index + 1
        end
        index += 1
      end
      nil
    end

    def toggle_quote(quote, char)
      return quote unless char == '"' || char == "'"
      return char if quote.nil?
      return nil if quote == char

      quote
    end

    def xml_entity_char(entity)
      case entity.to_s.downcase
      when "&amp;" then "&"
      when "&lt;" then "<"
      when "&gt;" then ">"
      when "&quot;", "&#34;", "&#x22;" then '"'
      when "&apos;", "&#39;", "&#x27;" then "'"
      else entity
      end
    end

    def peel(text, site_url)
      if (match = text.match(%r{\A([a-z][a-z0-9+.-]*://[^/?#]+)(.*)\z}i))
        return :foreign unless same_host?(match[1], site_url)

        { origin: match[1], rest: root_rest(match[2]) }
      elsif (match = text.match(%r{\A(//[^/?#]+)(.*)\z}))
        return :foreign unless same_host?(match[1], site_url)

        { origin: match[1], rest: root_rest(match[2]) }
      end
    end

    # Same host. http and https match when the site is on the default port
    # for its scheme. A URL with any other port is a different service,
    # including an asset that omits the port while the site uses one.
    def same_host?(origin, site_url)
      site = origin_parts(site_url)
      asset = origin_parts(origin)
      return false unless site && asset && asset[:host].casecmp?(site[:host])

      site_eff = site[:port] || default_port(site[:scheme])
      return site_eff && asset[:port] == site_eff if asset[:port]
      return true if asset[:scheme].nil?

      asset_default = default_port(asset[:scheme])
      return false unless asset_default

      site_default = default_port(site[:scheme])
      site_on_default = site[:port].nil? || (site_default && site[:port] == site_default)
      web = %w[http https]
      return true if site_on_default && (site[:scheme].nil? || web.include?(site[:scheme])) && web.include?(asset[:scheme])

      site_eff && asset_default == site_eff
    end

    def origin_parts(origin)
      text = origin.to_s.strip
      scheme = nil
      if (match = text.match(%r{\A([a-z][a-z0-9+.-]*)://}i))
        scheme = match[1].downcase
        text = text.sub(%r{\A[a-z][a-z0-9+.-]*://}i, "")
      else
        text = text.delete_prefix("//")
      end
      authority = text.split(%r{[/?#]}, 2).first.to_s.sub(/\A.*@/, "")
      return nil if authority.empty?

      host, port = split_host_port(authority)
      return nil if host.nil? || host.empty?

      { host: host, port: port, scheme: scheme }
    end

    def split_host_port(authority)
      if authority.start_with?("[")
        host = authority[/\A\[[^\]]+\]/]
        port = authority[/\A\[[^\]]+\]:(\d+)\z/, 1]
        [host, port&.to_i]
      elsif (match = authority.match(/\A(.+):(\d+)\z/))
        [match[1], match[2].to_i]
      else
        [authority, nil]
      end
    end

    def default_port(scheme)
      case scheme
      when "http" then 80
      when "https" then 443
      end
    end

    # Lookup key only. The stamped URL keeps the original spelling.
    # An encoded separator or dot segment stays encoded, so %2e%2e and %2f
    # cannot select a different file. An authored "../img/a.png" is unchanged.
    def decode_percent(text)
      raw = text.to_s
      return raw if raw.match?(/%(?:2f|5c|00)/i)

      decoded = raw.dup.force_encoding(Encoding::ASCII_8BIT)
      decoded = decoded.gsub(/%([0-9A-Fa-f]{2})/i) { [Regexp.last_match(1).to_i(16)].pack("C") }
      decoded.force_encoding(Encoding::UTF_8)
      return raw unless decoded.valid_encoding?
      return raw if decoded.include?("\0")
      return raw if decoded != raw && decoded.split("/").any? { |segment| segment == "." || segment == ".." }

      decoded
    end

    def decode_amp(text)
      text.to_s.gsub(/&(?:amp|#38|#x26);/i, "&")
    end

    def root_rest(rest)
      value = rest.to_s
      return "/" if value.empty?
      return value if value.start_with?("/", "?", "#")

      "/#{value}"
    end

    def split(text)
      # &#38; and &#x26; are ampersands. The "#" inside them is not a fragment.
      protected = text.to_s.gsub(/&#(?:38|x26);/i) { |entity| entity.sub("#", "\u0001") }
      before_fragment, fragment = protected.split("#", 2)
      path, query = before_fragment.to_s.split("?", 2)
      [restore_hash(path), query.nil? ? nil : restore_hash(query), fragment.nil? ? nil : restore_hash(fragment)]
    end

    def restore_hash(value)
      value.gsub("\u0001", "#")
    end

    def build(path, query, fragment, token)
      raw = query.to_s
      joiner = query_joiner(raw)
      kept = raw.split(/&(?:amp;|#38;|#x26;)?/i).reject(&:empty?)
      kept.reject! { |part| part.split("=", 2).first == "v" }
      kept << "v=#{token}"
      url = "#{path}?#{kept.join(joiner)}"
      url = "#{url}##{fragment}" if fragment && !fragment.empty?
      url
    end

    def query_joiner(raw)
      return "&amp;" if raw.match?(/&amp;/i)
      return "&#x26;" if raw.match?(/&#x26;/i)
      return "&#38;" if raw.match?(/&#38;/i)

      "&"
    end

    def prefix_base(baseurl, path)
      base = base_path(baseurl)
      path = "/#{path}" unless path.start_with?("/")
      "#{base}#{path}"
    end

    # A second pass can see a URL this crawl already rewrote.
    # /docs/img/a.png?v=old still refers to img/a.png.
    def strip_base(baseurl, path)
      base = base_path(baseurl)
      return path if base.empty?
      return path unless path.start_with?("#{base}/")

      path.delete_prefix(base)
    end

    def base_path(baseurl)
      base = baseurl.to_s.chomp("/")
      return "" if base.empty?

      base.start_with?("/") ? base : "/#{base}"
    end

    def normalize_key(path)
      text = path.to_s.split("#", 2).first.split("?", 2).first.strip
      text = text.sub(%r{\A/}, "")
      cleaned = clean_path(text)
      return nil if cleaned.nil? || cleaned.empty?

      cleaned
    end

    def resolve_key(from_rel, path, base_dir: nil)
      return nil if path.nil? || path.empty? || path.start_with?("//")

      if path.start_with?("/")
        normalize_key(path)
      elsif base_dir == :foreign
        nil
      else
        dir = if base_dir.nil?
                dirname = File.dirname(from_rel.to_s)
                dirname == "." ? "" : dirname
              else
                base_dir
              end
        clean_path(File.join(dir, path))
      end
    end

    def clean_path(rel)
      parts = []
      rel.to_s.tr("\\", "/").split("/").each do |part|
        next if part.empty? || part == "."
        if part == ".."
          return nil if parts.empty?

          parts.pop
        else
          parts << part
        end
      end
      parts.join("/")
    end
  end
end
