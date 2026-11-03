# frozen_string_literal: true

require "find"
require_relative "url"

module StaleSmash
  # After Jekyll writes the site, stamp ?v= on local asset URLs in the output.
  # Source files stay untouched. HTML pages are not given a version.
  module Crawl
    # Unquoted values may contain "=" after ?v= is added. The next space or
    # ">" ends the value, which keeps a following attribute intact.
    # The slash in "/>" is not part of an unquoted value.
    HTML_ATTR = /\b(data-src|href|src|poster|content|data|url)\s*=\s*(?:(["'])([^"']*)\2|([^\s"'<>`]+?)(?=\s|\/?>|$))/i
    SRCSET = /\b([\w:-]*srcset)\s*=\s*(?:(["'])([^"']*)\2|([^\s"'<>`]+?)(?=\s|\/?>|$))/i
    STYLE_BLOCK = /(<style\b[^>]*>)(.*?)(<\/style>)/im
    STYLE_ATTR = /(\bstyle\s*=\s*)(?:(["'])(.*?)\2|([^\s"'<>`]+?)(?=\s|\/?>|$))/im
    SCRIPT_BLOCK = /(<script\b[^>]*>)(.*?)(<\/script>)/im
    MARKUP = /<!--.*?-->|<(?:[^>"']|"[^"]*"|'[^']*')*>/m

    module_function

    def rewrite(dest, tokens, baseurl: "", url: "")
      root = File.expand_path(dest)
      return unless File.directory?(root)

      Find.find(root) do |path|
        next if File.directory?(path)
        next if File.symlink?(path)

        rel = path.delete_prefix("#{root}/")
        next if rel.start_with?("../") || rel.include?("/../")

        case File.extname(path).downcase
        when ".html", ".htm"
          rewrite_text(path, rel) do |body|
            rewrite_html(tokens, baseurl, url, rel, body, base_dir: URL.base_directory(body, rel, baseurl, url))
          end
        when ".svg"
          rewrite_text(path, rel) { |body| rewrite_html(tokens, baseurl, url, rel, body, base_dir: nil) }
        when ".xml", ".rss", ".atom"
          rewrite_text(path, rel) { |body| rewrite_xml(tokens, baseurl, url, rel, body) }
        when ".css"
          rewrite_text(path, rel) { |body| rewrite_css(tokens, baseurl, url, rel, body, base_dir: nil) }
        when ".js", ".mjs", ".json", ".webmanifest"
          rewrite_text(path, rel) { |body| rewrite_quoted(tokens, baseurl, url, rel, body, base_dir: nil) }
        end
      end
    end

    def rewrite_text(path, rel)
      original = File.binread(path)
      text = original.dup.force_encoding(Encoding::UTF_8)
      return unless text.valid_encoding?

      updated = yield text
      return if updated == text

      File.binwrite(path, updated.encode(Encoding::UTF_8))
    rescue StandardError => error
      warn "stalesmash: could not rewrite #{rel}: #{error.message}"
    end

    def rewrite_html(tokens, baseurl, url, rel, text, base_dir: nil)
      blocks = []
      masked = text.gsub(STYLE_BLOCK) do
        open_tag = Regexp.last_match(1)
        body = Regexp.last_match(2)
        close_tag = Regexp.last_match(3)
        blocks << rewrite_css(tokens, baseurl, url, rel, body, base_dir: base_dir)
        "#{open_tag}#{placeholder(blocks.length - 1)}#{close_tag}"
      end
      masked = masked.gsub(SCRIPT_BLOCK) do
        open_tag = Regexp.last_match(1)
        body = Regexp.last_match(2)
        close_tag = Regexp.last_match(3)
        blocks << rewrite_quoted(tokens, baseurl, url, rel, body, base_dir: nil)
        "#{open_tag}#{placeholder(blocks.length - 1)}#{close_tag}"
      end
      tagged = masked.gsub(MARKUP) do
        chunk = Regexp.last_match(0)
        next chunk if chunk.start_with?("<!--")

        rewrite_tag(tokens, baseurl, url, rel, chunk, base_dir: base_dir)
      end
      restore_blocks(tagged, blocks)
    end

    def rewrite_xml(tokens, baseurl, url, rel, text)
      rewritten = rewrite_html(tokens, baseurl, url, rel, text, base_dir: nil)
      URL.rewrite_escaped_tags(rewritten) do |inner, chunk|
        updated = rewrite_tag(tokens, baseurl, url, rel, inner, base_dir: nil)
        updated == inner ? chunk : URL.xml_escape(updated)
      end
    end

    def rewrite_tag(tokens, baseurl, url, rel, tag, base_dir: nil)
      styled = tag.gsub(STYLE_ATTR) do
        prefix = Regexp.last_match(1)
        quote = Regexp.last_match(2)
        body = Regexp.last_match(3) || Regexp.last_match(4)
        rewritten = rewrite_css(tokens, baseurl, url, rel, body.to_s, base_dir: base_dir)
        quote ? "#{prefix}#{quote}#{rewritten}#{quote}" : "#{prefix}#{rewritten}"
      end
      with_srcset = styled.gsub(SRCSET) do
        attr = Regexp.last_match(1)
        quote = Regexp.last_match(2)
        raw = Regexp.last_match(3) || Regexp.last_match(4)
        body = rewrite_srcset(tokens, baseurl, url, rel, raw.to_s, base_dir: base_dir)
        quote ? %(#{attr}=#{quote}#{body}#{quote}) : %(#{attr}=#{body})
      end
      with_srcset.gsub(HTML_ATTR) do
        attr = Regexp.last_match(1)
        quote = Regexp.last_match(2)
        raw = Regexp.last_match(3) || Regexp.last_match(4)
        replacement = URL.stamp(tokens, baseurl, rel, raw, site_url: url, base_dir: base_dir) || raw
        quote ? %(#{attr}=#{quote}#{replacement}#{quote}) : %(#{attr}=#{replacement})
      end
    end

    def placeholder(index)
      "\u0000STALESMASH#{index}\u0000"
    end

    def restore_blocks(text, blocks)
      text.gsub(/\u0000STALESMASH(\d+)\u0000/) { blocks[Regexp.last_match(1).to_i] }
    end

    # Replace URL tokens in place. Splitting on every comma breaks data URIs.
    def rewrite_srcset(tokens, baseurl, url, rel, raw, base_dir: nil)
      raw.gsub(%r{(?:\A|,)\s*\K(?!data:)([^\s,]+)}i) do
        target = Regexp.last_match(1)
        URL.stamp(tokens, baseurl, rel, target, site_url: url, base_dir: base_dir) || target
      end
    end

    def rewrite_css(tokens, baseurl, url, rel, text, base_dir: nil)
      styled = text.gsub(History::CSS_URL) do
        quote = Regexp.last_match(1)
        target = (Regexp.last_match(2) || Regexp.last_match(3)).to_s
        whole = Regexp.last_match(0)
        stamped = URL.stamp(tokens, baseurl, rel, target, site_url: url, base_dir: base_dir)
        if stamped.nil? || stamped == target
          whole
        elsif quote && !quote.empty?
          "url(#{quote}#{stamped}#{quote})"
        else
          "url(#{stamped})"
        end
      end
      styled = styled.gsub(History::CSS_IMPORT) do
        quote = Regexp.last_match(1)
        target = Regexp.last_match(2)
        whole = Regexp.last_match(0)
        stamped = URL.stamp(tokens, baseurl, rel, target, site_url: url, base_dir: base_dir)
        if stamped.nil? || stamped == target
          whole
        else
          "@import #{quote}#{stamped}#{quote}"
        end
      end
      styled = rewrite_image_sets(styled, tokens, baseurl, url, rel, base_dir)
      styled.gsub(History::QUOTED_STRING) do
        quote = Regexp.last_match(1)
        value = Regexp.last_match(2) || Regexp.last_match(3)
        original = Regexp.last_match(0)
        if value.nil? || !URL.stylesheet_reference?(value)
          original
        else
          stamped = URL.stamp(tokens, baseurl, rel, value, site_url: url, base_dir: base_dir)
          replace_quoted(original, quote, value, stamped)
        end
      end
    end

    # A bare file name is a URL inside image-set() and text everywhere else.
    def rewrite_image_sets(text, tokens, baseurl, url, rel, base_dir)
      text.gsub(/image-set\([^)]*\)/i) do |block|
        block.gsub(History::QUOTED_STRING) do
          quote = Regexp.last_match(1)
          value = Regexp.last_match(2) || Regexp.last_match(3)
          original = Regexp.last_match(0)
          if value.nil? || value.include?("${") || !URL.pathlike?(value)
            original
          else
            stamped = URL.stamp(tokens, baseurl, rel, value, site_url: url, base_dir: base_dir)
            replace_quoted(original, quote, value, stamped)
          end
        end
      end
    end

    def rewrite_quoted(tokens, baseurl, url, rel, text, base_dir: nil)
      text.gsub(History::QUOTED_STRING) do
        quote = Regexp.last_match(1)
        value = Regexp.last_match(2) || Regexp.last_match(3)
        original = Regexp.last_match(0)
        stamped = if value.nil?
                    nil
                  elsif value.include?("${")
                    URL.version_template(tokens, baseurl, rel, value, site_url: url, base_dir: base_dir)
                  elsif URL.pathlike?(value)
                    URL.stamp(tokens, baseurl, rel, value, site_url: url, base_dir: base_dir)
                  end
        replace_quoted(original, quote, value, stamped)
      end
    end

    def replace_quoted(original, quote, value, stamped)
      return original if stamped.nil? || value.nil? || stamped == value
      return "#{quote}#{stamped}#{quote}" if quote

      "`#{stamped}`"
    end
  end
end
