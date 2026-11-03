# frozen_string_literal: true

require_relative "helper"

class StaleSmashTest < Minitest::Test
  include StaleSmash::TestHelper

  def setup
    @root = Dir.mktmpdir("stalesmash-site")
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def test_git_version_survives_other_commits_and_mtime
    write_files(@root, fixture)
    commit_site(@root)
    site = build(@root)
    first = File.read(File.join(@root, "_site", "index.html"))
    stylesheet = quoted(first, "/assets/app.css")
    image = quoted(first, "/img/a.png")
    image_commit = last_commit(@root, "img/a.png")
    assert_equal "/assets/app.css?theme=dark&v=#{image_commit}#main", stylesheet
    assert_equal "/img/a.png?v=#{image_commit}", image
    assert_equal "/css/main.css?v=#{image_commit}", quoted(first, "/css/main.css")
    assert_equal "https://cdn.example/app.css", quoted(first, "https://cdn.example/app.css")
    assert_equal "/missing.js", quoted(first, "/missing.js")

    write_files(@root, "notes.txt" => "unrelated")
    commit_site(@root)
    site.process
    after_other = File.read(File.join(@root, "_site", "index.html"))
    head, head_status = Open3.capture2("git", "-C", @root, "rev-parse", "--short=12", "HEAD")
    assert head_status.success?, head
    refute_equal image_commit, head.strip
    assert_equal image, quoted(after_other, "/img/a.png")
    assert_equal stylesheet, quoted(after_other, "/assets/app.css")

    FileUtils.touch(File.join(@root, "assets", "app.css"))
    site.process
    assert_equal stylesheet, quoted(File.read(File.join(@root, "_site", "index.html")), "/assets/app.css")

    File.write(File.join(@root, "assets", "app.css"), File.read(File.join(@root, "assets", "app.css")) + "\n.changed { color: red; }\n")
    site.process
    changed = quoted(File.read(File.join(@root, "_site", "index.html")), "/assets/app.css")
    refute_equal stylesheet, changed
    assert_match %r{\A/assets/app\.css\?theme=dark&v=[0-9a-f]{12}#main\z}, changed
  end

  def test_stylesheet_dependencies_and_rewritten_urls
    write_files(@root, fixture)
    commit_site(@root)
    build(@root)
    html = File.read(File.join(@root, "_site", "index.html"))
    page = quoted(html, "/css/main.css")
    legacy = quoted(html, "/css/legacy.css")
    image = quoted(html, "/img/a.png")
    script = quoted(html, "/assets/app.js")
    assert_match %r{\A/css/main\.css\?v=[0-9a-f]{12}\z}, page
    assert_match %r{\A/img/a\.png\?v=[0-9a-f]{12}\z}, image
    image_token = image.split("v=").last

    css = File.read(File.join(@root, "_site", "assets", "app.css"))
    assert_includes css, "/img/a.png?v=#{image_token}"
    assert_includes css, "dot.png?v="
    assert_includes css, "/img/a.png?x=1&v=#{image_token}"
    assert_includes css, "https://cdn.example/a.woff2"
    assert_includes css, "data:image/gif;base64,aaaa"
    refute_includes File.read(File.join(@root, "assets", "app.css")), "?v="

    compiled = File.read(File.join(@root, "_site", "css", "main.css"))
    assert_includes compiled, "/img/a.png?v=#{image_token}"
    refute_includes File.read(File.join(@root, "css", "main.scss")), "?v="
    refute_includes File.read(File.join(@root, "_sass", "_color.scss")), "?v="

    File.write(File.join(@root, "_sass", "_color.scss"), File.read(File.join(@root, "_sass", "_color.scss")) + "\n.extra { color: blue; }\n")
    build(@root)
    moved = File.read(File.join(@root, "_site", "index.html"))
    refute_equal page, quoted(moved, "/css/main.css")
    refute_equal legacy, quoted(moved, "/css/legacy.css")

    File.binwrite(File.join(@root, "img", "a.png"), "different-bytes")
    build(@root)
    after_image = File.read(File.join(@root, "_site", "index.html"))
    refute_equal page, quoted(after_image, "/css/main.css")
    refute_equal script, quoted(after_image, "/assets/app.js")
    refute_equal image, quoted(after_image, "/img/a.png")
  end

  def test_baseurl_and_external_urls
    write_files(@root, fixture.merge(
      "_config.yml" => "baseurl: /docs\nurl: https://example.com\n"
    ))
    commit_site(@root)
    site = build(@root)
    html = File.read(File.join(@root, "_site", "index.html"))
    assert_match %r{\A/docs/assets/app\.css\?theme=dark&v=[0-9a-f]{12}#main\z}, quoted(html, "/docs/assets/app.css")
    assert_equal "https://cdn.example/app.css", quoted(html, "https://cdn.example/app.css")
    assert_equal "/missing.js", quoted(html, "/missing.js")

    css = File.read(File.join(@root, "_site", "assets", "app.css"))
    assert_includes css, 'url("/docs/img/a.png?v='
    assert_includes css, 'url("dot.png?v='
    refute_includes css, "/docs/dot.png"
    refute_includes css, "/docs/docs/"

    File.binwrite(File.join(@root, "img", "a.png"), "second-bytes")
    site.process
    rewritten = File.read(File.join(@root, "_site", "assets", "app.css"))
    new_image = quoted(File.read(File.join(@root, "_site", "index.html")), "/docs/img/a.png")
    assert_includes rewritten, new_image
    refute_includes rewritten, "/docs/docs/"
  end

  def test_command_stamps_the_same_commits_as_jekyll
    write_files(@root, fixture)
    commit_site(@root)
    build(@root)
    hooked = quoted(File.read(File.join(@root, "_site", "index.html")), "/img/a.png")

    write_files(@root, "_config.yml" => "stalesmash:\n  enabled: false\n")
    build(@root)
    bare = File.read(File.join(@root, "_site", "index.html"))
    refute_includes bare, "?v="

    output, status = run_cli(@root)
    assert status.success?, output
    assert_equal hooked, quoted(File.read(File.join(@root, "_site", "index.html")), "/img/a.png")
  end

  def test_command_reads_baseurl_from_the_site_config
    write_files(@root, fixture.merge(
      "_config.yml" => "baseurl: /docs\nstalesmash:\n  enabled: false\n"
    ))
    commit_site(@root)
    build(@root)
    output, status = run_cli(@root)
    assert status.success?, output
    html = File.read(File.join(@root, "_site", "index.html"))
    assert_match %r{\A/docs/img/a\.png\?v=[0-9a-f]{12}\z}, quoted(html, "/docs/img/a.png")
    assert_equal "https://cdn.example/app.css", quoted(html, "https://cdn.example/app.css")
  end

  def test_disabled_build_leaves_output_alone
    write_files(@root, fixture.merge(
      "_config.yml" => "stalesmash:\n  enabled: false\n"
    ))
    commit_site(@root)
    build(@root)
    html = File.read(File.join(@root, "_site", "index.html"))
    assert_includes html, 'href="/assets/app.css?theme=dark#main"'
    refute_includes html, "?v="
    assert_equal File.read(File.join(@root, "assets", "app.css")), File.read(File.join(@root, "_site", "assets", "app.css"))
  end

  def test_inline_same_site_and_any_file_type
    write_files(@root, hole_fixture)
    commit_site(@root)
    build(@root)
    hero = last_commit(@root, "img/hero.png")
    html = File.read(File.join(@root, "_site", "index.html"))
    pdf = html[/\/docs\/files\/menu\.pdf\?v=[0-9a-f]+/]
    audio = html[/\/docs\/audio\/theme\.mp3\?v=[0-9a-f]+/]
    manifest = html[/\/docs\/site\.webmanifest\?v=[0-9a-f]+/]

    assert_includes html, "/docs/img/hero.png?v=#{hero} 1x"
    assert_includes html, "/docs/img/wide.png?v=#{hero} 2x"
    assert_includes html, "imagesrcset=\"/docs/img/hero.png?v=#{hero} 1x, /docs/img/wide.png?v=#{hero} 2x\""
    assert_includes html, 'url("/docs/img/hero.png?v='
    assert_includes html, "url('/docs/audio/theme.mp3?v=#{hero}')"
    assert_includes html, "content=\"https://example.com/docs/img/hero.png?v=#{hero}\""
    assert_includes html, "content=\"//example.com/docs/img/hero.png?v=#{hero}\""
    assert_includes html, 'content="https://cdn.example/hero.png"'
    assert_includes html, 'content="//cdn.example/hero.png"'
    refute_includes html, "cdn.example/hero.png?v="
    assert_includes html, 'href="/about.html"'
    refute_includes html, "about.html?v="
    assert_equal "/docs/files/menu.pdf?v=#{hero}", pdf
    assert_equal "/docs/audio/theme.mp3?v=#{hero}", audio
    assert_equal "/docs/downloads/pack.zip?v=#{hero}", html[/\/docs\/downloads\/pack\.zip\?v=[0-9a-f]+/]
    assert_includes html, "`/docs/downloads/pack.zip?v=#{hero}`"
    assert_includes html, '"/docs/assets/gallery.json?v='
    assert_equal "/docs/site.webmanifest?v=#{hero}", manifest
    assert_includes html, "/docs/icons/sprite.svg?v=#{hero}"
    assert_includes html, "/docs/assets/abs.css?v=#{hero}"

    manifest_body = File.read(File.join(@root, "_site", "site.webmanifest"))
    assert_includes manifest_body, '"/docs/img/hero.png?v=' + "#{hero}\""
    refute_includes File.read(File.join(@root, "site.webmanifest")), "?v="

    gallery = File.read(File.join(@root, "_site", "assets", "gallery.json"))
    assert_includes gallery, '"/docs/img/hero.png?v=' + "#{hero}\""
    refute_includes File.read(File.join(@root, "assets", "gallery.json")), "?v="

    svg = File.read(File.join(@root, "_site", "icons", "sprite.svg"))
    assert_includes svg, 'href="/docs/img/hero.png?v=' + "#{hero}\""
    assert_includes svg, 'xlink:href="/docs/img/hero.png?v=' + "#{hero}\""
    refute_includes File.read(File.join(@root, "icons", "sprite.svg")), "?v="

    css = File.read(File.join(@root, "_site", "assets", "abs.css"))
    assert_includes css, 'url("https://example.com/docs/img/hero.png?v=' + "#{hero}\")"
    assert_includes css, 'url("https://cdn.example/a.woff2")'
    refute_includes css, "cdn.example/a.woff2?v="
    refute_includes File.read(File.join(@root, "assets", "abs.css")), "?v="

    File.binwrite(File.join(@root, "img", "hero.png"), "different-bytes")
    commit_site(@root)
    build(@root)
    moved_hero = last_commit(@root, "img/hero.png")
    refute_equal hero, moved_hero
    moved = File.read(File.join(@root, "_site", "index.html"))
    assert_includes moved, "/docs/img/hero.png?v=#{moved_hero}"
    assert_includes moved, "/docs/site.webmanifest?v=#{moved_hero}"
    assert_includes moved, "/docs/icons/sprite.svg?v=#{moved_hero}"
    assert_includes moved, "/docs/assets/abs.css?v=#{moved_hero}"
    assert_includes moved, "/docs/assets/gallery.json?v=#{moved_hero}"
    assert_includes moved, pdf
    assert_includes moved, audio
    assert_includes moved, 'href="/about.html"'
    refute_includes moved, "about.html?v="
    refute_includes moved, "cdn.example/hero.png?v="
    assert_includes File.read(File.join(@root, "_site", "site.webmanifest")), moved_hero
    assert_includes File.read(File.join(@root, "_site", "assets", "abs.css")), "https://example.com/docs/img/hero.png?v=#{moved_hero}"

    write_files(@root, "_config.yml" => "url: https://example.com\nbaseurl: /docs\nstalesmash:\n  enabled: false\n")
    build(@root)
    bare = File.read(File.join(@root, "_site", "index.html"))
    refute_includes bare, "?v="
    output, status = run_cli(@root)
    assert status.success?, output
    restored = File.read(File.join(@root, "_site", "index.html"))
    assert_includes restored, "https://example.com/docs/img/hero.png?v=#{moved_hero}"
    assert_includes restored, pdf
    assert_includes restored, 'href="/about.html"'
    refute_includes restored, "cdn.example/hero.png?v="
  end

  def hole_fixture
    {
      "_config.yml" => "url: https://example.com\nbaseurl: /docs\n",
      "about.html" => "---\n---\n<p>About</p>\n",
      "index.html" => <<~HTML,
        ---
        ---
        <style>
          .hero { background: url("/img/hero.png"); }
          .remote { background: url("https://cdn.example/hero.png"); }
        </style>
        <div style="background: url('/audio/theme.mp3')"></div>
        <img src="/img/hero.png" data-srcset="/img/hero.png 1x, /img/wide.png 2x">
        <link rel="preload" as="image" imagesrcset="/img/hero.png 1x, /img/wide.png 2x">
        <meta property="og:image" content="https://example.com/docs/img/hero.png">
        <meta property="og:image" content="//example.com/docs/img/hero.png">
        <meta property="og:image" content="https://cdn.example/hero.png">
        <meta property="og:image" content="//cdn.example/hero.png">
        <a href="/about.html">About</a>
        <a href="/files/menu.pdf">Menu</a>
        <audio src="/audio/theme.mp3"></audio>
        <object data="/files/menu.pdf"></object>
        <link rel="manifest" href="/site.webmanifest">
        <img src="/icons/sprite.svg">
        <link rel="stylesheet" href="/assets/abs.css">
        <script>
          const gallery = "/assets/gallery.json";
          const remote = "https://cdn.example/app.js";
          const pack = `/downloads/pack.zip`;
        </script>
        <script type="application/ld+json">
          {"image": "https://example.com/docs/img/hero.png"}
        </script>
      HTML
      "assets/abs.css" => <<~CSS,
        .hero { background: url("https://example.com/img/hero.png"); }
        .remote { background: url("https://cdn.example/a.woff2"); }
      CSS
      "assets/gallery.json" => %({"slides": ["/img/hero.png"]}\n),
      "site.webmanifest" => %({"icons": [{"src": "/img/hero.png"}]}\n),
      "icons/sprite.svg" => <<~SVG,
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">
          <image href="/img/hero.png" xlink:href="/img/hero.png"/>
        </svg>
      SVG
      "img/hero.png" => "hero",
      "img/wide.png" => "wide",
      "audio/theme.mp3" => "mp3",
      "files/menu.pdf" => "pdf",
      "downloads/pack.zip" => "zip"
    }
  end

  def fixture
    {
      "index.html" => <<~HTML,
        ---
        ---
        <link rel="stylesheet" href="/assets/app.css?theme=dark#main">
        <link rel="stylesheet" href="/css/main.css">
        <link rel="stylesheet" href="/css/legacy.css">
        <img src="/img/a.png">
        <script src="/assets/app.js"></script>
        <script src="/missing.js"></script>
        <link rel="stylesheet" href="https://cdn.example/app.css">
      HTML
      "assets/app.css" => <<~CSS,
        body { background: url("/img/a.png"); }
        .near { background: url("dot.png"); }
        .kept { background: url("/img/a.png?x=1"); }
        .remote { background: url("https://cdn.example/a.woff2"); }
        .inline { background: url("data:image/gif;base64,aaaa"); }
      CSS
      "assets/app.js" => %(const logo = "/img/a.png";\n),
      "assets/dot.png" => "dot",
      "img/a.png" => "png-bytes",
      "css/main.scss" => <<~SCSS,
        ---
        ---
        @use "color";
      SCSS
      "css/legacy.scss" => <<~SCSS,
        ---
        ---
        @import "color";
      SCSS
      "_sass/_color.scss" => %(a { background: url("/img/a.png"); color: red; }\n)
    }
  end

  def test_site_in_a_subdirectory_keeps_import_and_commit_identity
    site = File.join(@root, "sites", "demo")
    write_files(site, {
      "index.html" => "<img src=\"/img/a.png\">\n<link rel=\"stylesheet\" href=\"/css/main.css\">\n",
      "img/a.png" => "png",
      "css/main.css" => "@import \"extra.css\" screen;\n@import url(\"plain.css\");\n",
      "css/extra.css" => "a {}\n",
      "css/plain.css" => "b {}\n"
    })
    commit_site(@root)
    publish = lambda do
      dest = File.join(site, "_site")
      FileUtils.mkdir_p(File.join(dest, "css"))
      File.write(File.join(dest, "index.html"), File.read(File.join(site, "index.html")))
      File.write(File.join(dest, "css", "main.css"), File.read(File.join(site, "css", "main.css")))
      StaleSmash.bust(source: site, dest: dest, baseurl: "/docs", url: "https://example.com")
      dest
    end
    dest = publish.call
    image = last_commit(@root, "sites/demo/img/a.png")
    extra = last_commit(@root, "sites/demo/css/extra.css")
    plain = last_commit(@root, "sites/demo/css/plain.css")
    html = File.read(File.join(dest, "index.html"))
    css = File.read(File.join(dest, "css", "main.css"))
    assert_includes html, "/docs/img/a.png?v=#{image}"
    assert_includes html, "/docs/css/main.css?v=#{extra}"
    assert_includes css, "@import \"extra.css?v=#{extra}\" screen;"
    assert_includes css, "url(\"plain.css?v=#{plain}\")"
    again = File.read(File.join(dest, "index.html"))
    StaleSmash.bust(source: site, dest: dest, baseurl: "/docs", url: "https://example.com")
    assert_equal again, File.read(File.join(dest, "index.html"))
    assert_equal css, File.read(File.join(dest, "css", "main.css"))

    File.write(File.join(site, "css", "extra.css"), "a { color: red; }\n")
    commit_site(@root)
    moved_extra = last_commit(@root, "sites/demo/css/extra.css")
    refute_equal extra, moved_extra
    dest = publish.call
    moved = File.read(File.join(dest, "index.html"))
    moved_css = File.read(File.join(dest, "css", "main.css"))
    assert_includes moved, "/docs/img/a.png?v=#{image}"
    assert_includes moved, "/docs/css/main.css?v=#{moved_extra}"
    assert_includes moved_css, "@import \"extra.css?v=#{moved_extra}\" screen;"
    assert_includes moved_css, "url(\"plain.css?v=#{plain}\")"
  end

  def test_encoded_names_foreign_ports_and_data_srcset
    write_files(@root, {
      "index.html" => <<~HTML
        <img src="/img/my%20photo.png">
        <img src="https://example.com/img/my%20photo.png">
        <img src="http://example.com/img/my%20photo.png">
        <img src="https://example.com:8443/img/my%20photo.png">
        <img src="https://www.example.com/img/my%20photo.png">
        <img srcset="data:image/gif;base64,aaaa, /img/my%20photo.png 2x">
      HTML
    })
    write_files(@root, { "img/my photo.png" => "png" })
    commit_site(@root)
    dest = File.join(@root, "_site")
    FileUtils.mkdir_p(dest)
    File.write(File.join(dest, "index.html"), File.read(File.join(@root, "index.html")))
    StaleSmash.bust(source: @root, dest: dest, baseurl: "/docs", url: "https://example.com")
    html = File.read(File.join(dest, "index.html"))
    commit = last_commit(@root, "img/my photo.png")
    stamped = "/docs/img/my%20photo.png?v=#{commit}"
    assert_includes html, "src=\"#{stamped}\""
    assert_includes html, "src=\"https://example.com#{stamped}\""
    assert_includes html, "src=\"http://example.com#{stamped}\""
    assert_includes html, 'src="https://example.com:8443/img/my%20photo.png"'
    refute_includes html, "example.com:8443/img/my%20photo.png?v="
    assert_includes html, 'src="https://www.example.com/img/my%20photo.png"'
    refute_includes html, "www.example.com/img/my%20photo.png?v="
    assert_includes html, "srcset=\"data:image/gif;base64,aaaa, #{stamped} 2x\""
    StaleSmash.bust(source: @root, dest: dest, baseurl: "/docs", url: "https://example.com")
    assert_equal html, File.read(File.join(dest, "index.html"))
  end

  def test_staged_rename_does_not_change_an_unrelated_commit
    write_files(@root, {
      "index.html" => "<img src=\"/file.png\">\n",
      "file.png" => "root",
      "ab/file.png" => "nested"
    })
    commit_site(@root)
    env = {
      "GIT_AUTHOR_NAME" => "StaleSmash",
      "GIT_AUTHOR_EMAIL" => "dev@localhost",
      "GIT_COMMITTER_NAME" => "StaleSmash",
      "GIT_COMMITTER_EMAIL" => "dev@localhost"
    }
    system(env, "git", "-C", @root, "mv", "ab/file.png", "ab/other.png", exception: true)
    dest = File.join(@root, "_site")
    FileUtils.mkdir_p(dest)
    File.write(File.join(dest, "index.html"), File.read(File.join(@root, "index.html")))
    StaleSmash.bust(source: @root, dest: dest)
    commit = last_commit(@root, "file.png")
    blob, status = Open3.capture2("git", "-C", @root, "hash-object", "--", "file.png")
    assert status.success?, blob
    refute_equal commit, blob.strip[0, 12]
    assert_includes File.read(File.join(dest, "index.html")), "/file.png?v=#{commit}"
  end

  def test_command_reads_config_that_contains_a_date
    write_files(@root, {
      "_config.yml" => "url: https://example.com\nbaseurl: /docs\nupdated: 2024-05-01\nstalesmash:\n  enabled: false\n",
      "index.html" => "---\n---\n<img src=\"/img/a.png\">\n<meta content=\"https://example.com/img/a.png\">\n",
      "img/a.png" => "png"
    })
    commit_site(@root)
    build(@root)
    output, status = run_cli(@root)
    assert status.success?, output
    html = File.read(File.join(@root, "_site", "index.html"))
    commit = last_commit(@root, "img/a.png")
    assert_includes html, "/docs/img/a.png?v=#{commit}"
    assert_includes html, "https://example.com/docs/img/a.png?v=#{commit}"
  end

  def test_entity_queries_unquoted_values_and_custom_ports
    write_files(@root, {
      "index.html" => <<~HTML,
        <img src="/img/a.png?w=800&amp;h=600">
        <img src="/img/a.png?v=old&amp;x=1">
        <img src="/img/a.png?x=1&amp;v=old">
        <img src="/img/a.png?w=800&#38;h=600#top">
        <img src="/img/a.png?v=old&#38;x=1">
        <img src="/img/a.png?x=1&#x26;v=old">
        <img src=/img/a.png alt=keep>
        <img src="/img/%2e%2e/secret.png">
        <img src="/%2e%2e/secret.png">
        <img src="/img/%2fa.png">
        <img src="/img/file%2ename.png">
        <img src="/img/a&amp;b.png">
        <img src="/img/my%20photo.png">
        <use href="/icons/s.svg#icon"/>
        <img src="https://example.com/img/a.png">
        <img src="https://example.com:8443/img/a.png">
        <img src="http://example.com/img/a.png">
        <img src="//example.com/img/a.png">
        <img src="https://user:secret@example.com:8443/img/a.png">
        <img src="https://example.com:443/img/a.png">
      HTML
      "img/a.png" => "a",
      "img/file.name.png" => "n",
      "img/a&b.png" => "amp",
      "img/my photo.png" => "photo",
      "secret.png" => "s",
      "icons/s.svg" => "<svg/>\n"
    })
    commit_site(@root)
    dest = publish_copy(@root, baseurl: "/docs", url: "https://example.com:8443")
    html = File.read(File.join(dest, "index.html"))
    image = last_commit(@root, "img/a.png")
    named = last_commit(@root, "img/file.name.png")
    amped = last_commit(@root, "img/a&b.png")
    photo = last_commit(@root, "img/my photo.png")
    icon = last_commit(@root, "icons/s.svg")
    versioned = "https://example.com:8443/docs/img/a.png?v=#{image}"

    assert_includes html, "/docs/img/a.png?w=800&amp;h=600&amp;v=#{image}"
    assert_includes html, "/docs/img/a.png?x=1&amp;v=#{image}"
    refute_includes html, "amp;x"
    refute_includes html, "v=old"
    assert_includes html, "/docs/img/a.png?w=800&#38;h=600&#38;v=#{image}#top"
    assert_includes html, "/docs/img/a.png?x=1&#x26;v=#{image}"
    assert_includes html, "src=/docs/img/a.png?v=#{image} alt=keep"
    assert_includes html, 'src="/img/%2e%2e/secret.png"'
    assert_includes html, 'src="/%2e%2e/secret.png"'
    assert_includes html, 'src="/img/%2fa.png"'
    refute_includes html, "%2e%2e/secret.png?v="
    refute_includes html, "%2fa.png?v="
    assert_includes html, "/docs/img/file%2ename.png?v=#{named}"
    assert_includes html, "/docs/img/a&amp;b.png?v=#{amped}"
    assert_includes html, "/docs/img/my%20photo.png?v=#{photo}"
    assert_includes html, "/docs/icons/s.svg?v=#{icon}#icon"
    assert_includes html, %(src="#{versioned}")
    assert_includes html, "src=\"https://user:secret@example.com:8443/docs/img/a.png?v=#{image}\""
    assert_includes html, 'src="//example.com/docs/img/a.png?v=' + "#{image}\""
    assert_includes html, 'src="https://example.com/img/a.png"'
    assert_includes html, 'src="http://example.com/img/a.png"'
    assert_includes html, 'src="https://example.com:443/img/a.png"'
    refute_includes html, "https://example.com/docs/img/a.png?v="
    refute_includes html, "http://example.com/img/a.png?v="
    refute_includes html, "example.com:443/img/a.png?v="

    StaleSmash.bust(source: @root, dest: dest, baseurl: "/docs", url: "https://example.com:8443")
    assert_equal html, File.read(File.join(dest, "index.html"))
  end

  def test_dependencies_follow_the_named_file
    write_files(@root, {
      "index.html" => <<~HTML,
        <link rel="stylesheet" href="/css/main.css">
        <link rel="stylesheet" href="/css/hero.css">
        <link rel="stylesheet" href="/css/abs.css">
        <img src="/icons/s.svg">
        <img src="/img/a.png">
        <a href="/feed.xml">Feed</a>
        <script src="/app.js"></script>
        <script>
        if (data == "/img/a.png") { go(); }
        const content = "hello";
        </script>
        <pre>&lt;img src="/img/a.png"&gt;</pre>
        <div style=background:url(/img/a.png)></div>
        <image href=/img/a.png/>
      HTML
      "css/main.css" => "@import \"extra.css\";\n",
      "css/extra.css" => "a {}\n",
      "css/_extra.scss" => "partial {}\n",
      "css/hero.css" => ".hero { background-image: image-set(\"/img/a.png\" 1x, \"/img/wide.png\" 2x); }\n.note { content: \"logo.png\"; }\n",
      "css/abs.css" => "@import \"https://example.com/css/extra.css\";\n",
      "icons/s.svg" => "<svg><image href=/img/a.png /><image srcset=\"/img/a.png 1x, /img/wide.png 2x\"/></svg>\n",
      "feed.xml" => "<enclosure url=\"/ep.mp3\"/><media:content url=\"https://example.com/ep.mp3\"/>\n",
      "app.js" => "const ready = true;\n",
      "img/a.png" => "a",
      "img/wide.png" => "w",
      "logo.png" => "l",
      "ep.mp3" => "m"
    })
    commit_site(@root)
    original = last_commit(@root, "img/a.png")

    write_files(@root, "css/_extra.scss" => "partial { color: red; }\n")
    commit_site(@root)
    partial = last_commit(@root, "css/_extra.scss")
    refute_equal original, partial
    dest = publish_copy(@root, url: "https://example.com")
    html = File.read(File.join(dest, "index.html"))
    assert_includes html, "/css/main.css?v=#{original}"
    assert_includes html, "/css/abs.css?v=#{original}"
    assert_includes html, "/css/hero.css?v=#{original}"
    refute_includes html, partial

    write_files(@root, "css/extra.css" => "a { color: red; }\n")
    commit_site(@root)
    extra = last_commit(@root, "css/extra.css")
    refute_equal original, extra
    dest = publish_copy(@root, url: "https://example.com")
    html = File.read(File.join(dest, "index.html"))
    css = File.read(File.join(dest, "css", "main.css"))
    absolute = File.read(File.join(dest, "css", "abs.css"))
    assert_includes html, "/css/main.css?v=#{extra}"
    assert_includes html, "/css/abs.css?v=#{extra}"
    assert_includes html, "/css/hero.css?v=#{original}"
    assert_includes html, "/img/a.png?v=#{original}"
    assert_includes css, "@import \"extra.css?v=#{extra}\""
    assert_includes absolute, "https://example.com/css/extra.css?v=#{extra}"
    refute_includes html, "/css/main.css?v=#{partial}"

    write_files(@root, "img/wide.png" => "wider")
    commit_site(@root)
    wide = last_commit(@root, "img/wide.png")
    refute_equal original, wide
    dest = publish_copy(@root, url: "https://example.com")
    html = File.read(File.join(dest, "index.html"))
    hero = File.read(File.join(dest, "css", "hero.css"))
    svg = File.read(File.join(dest, "icons", "s.svg"))
    assert_includes html, "/css/hero.css?v=#{wide}"
    assert_includes html, "/icons/s.svg?v=#{wide}"
    assert_includes html, "/css/main.css?v=#{extra}"
    assert_includes html, "/img/a.png?v=#{original}"
    assert_includes hero, "/img/wide.png?v=#{wide}"
    assert_includes hero, "/img/a.png?v=#{original}"
    assert_includes hero, 'content: "logo.png"'
    refute_includes hero, "logo.png?v="
    assert_includes svg, "srcset=\"/img/a.png?v=#{original} 1x, /img/wide.png?v=#{wide} 2x\""
    assert_includes svg, "href=/img/a.png?v=#{original}"

    write_files(@root, "ep.mp3" => "audio")
    commit_site(@root)
    audio = last_commit(@root, "ep.mp3")
    dest = publish_copy(@root, baseurl: "/docs", url: "https://example.com")
    html = File.read(File.join(dest, "index.html"))
    feed = File.read(File.join(dest, "feed.xml"))
    assert_includes html, "/docs/feed.xml?v=#{audio}"
    assert_includes feed, "url=\"/docs/ep.mp3?v=#{audio}\""
    assert_includes feed, "url=\"https://example.com/docs/ep.mp3?v=#{audio}\""
    assert_includes html, %(if (data == "/docs/img/a.png?v=#{original}") { go(); })
    assert_includes html, 'const content = "hello";'
    assert_includes html, "<pre>&lt;img src=\"/img/a.png\"&gt;</pre>"
    refute_includes html, "&lt;img src=\"/img/a.png?v="
    assert_includes html, "style=background:url(/docs/img/a.png?v=#{original})"
    assert_includes html, "href=/docs/img/a.png?v=#{original}/>"
    assert_includes html, "/docs/app.js?v=#{original}"

    again = File.read(File.join(dest, "index.html"))
    StaleSmash.bust(source: @root, dest: dest, baseurl: "/docs", url: "https://example.com")
    assert_equal again, File.read(File.join(dest, "index.html"))
    assert_equal feed, File.read(File.join(dest, "feed.xml"))
  end

  def test_shallow_checkout_recovers_the_commit_that_changed_the_file
    write_files(@root, {
      "index.html" => "<video src=\"/video/tour.mp4\"></video>\n",
      "video/tour.mp4" => "video-bytes"
    })
    commit_site(@root)
    video = last_commit(@root, "video/tour.mp4")
    write_files(@root, "notes.txt" => "later")
    commit_site(@root)
    head = last_commit(@root, "notes.txt")
    refute_equal video, head

    shallow = Dir.mktmpdir("stalesmash-shallow")
    system(
      "git", "-c", "protocol.file.allow=always",
      "clone", "--depth", "1", "-q", "file://#{@root}", shallow,
      exception: true
    )
    cloned = Open3.capture2("git", "-C", shallow, "rev-parse", "--is-shallow-repository")
    assert_equal "true", cloned[0].strip
    blob, blob_status = Open3.capture2("git", "-C", shallow, "hash-object", "video/tour.mp4")
    assert blob_status.success?, blob

    dest = stage_dest(shallow)
    StaleSmash.bust(source: shallow, dest: dest)
    html = File.read(File.join(dest, "index.html"))
    assert_includes html, "/video/tour.mp4?v=#{video}"
    refute_includes html, "/video/tour.mp4?v=#{head}"
    refute_includes html, "/video/tour.mp4?v=#{blob.strip[0, 12]}"
    deepened = Open3.capture2("git", "-C", shallow, "rev-parse", "--is-shallow-repository")
    assert_equal "false", deepened[0].strip
  ensure
    FileUtils.remove_entry(shallow) if shallow && File.directory?(shallow)
  end

  def test_shallow_checkout_without_a_remote_uses_a_content_hash
    write_files(@root, {
      "index.html" => "<video src=\"/video/tour.mp4\"></video>\n",
      "video/tour.mp4" => "video-bytes"
    })
    commit_site(@root)
    video = last_commit(@root, "video/tour.mp4")
    write_files(@root, "notes.txt" => "later")
    commit_site(@root)
    head = last_commit(@root, "notes.txt")

    shallow = Dir.mktmpdir("stalesmash-shallow-offline")
    system(
      "git", "-c", "protocol.file.allow=always",
      "clone", "--depth", "1", "-q", "file://#{@root}", shallow,
      exception: true
    )
    system("git", "-C", shallow, "remote", "remove", "origin", exception: true)
    blob, blob_status = Open3.capture2("git", "-C", shallow, "hash-object", "video/tour.mp4")
    assert blob_status.success?, blob
    digest = blob.strip[0, 12]
    refute_equal video, digest
    refute_equal head, digest

    dest = stage_dest(shallow)
    _out, err = capture_io { StaleSmash.bust(source: shallow, dest: dest) }
    html = File.read(File.join(dest, "index.html"))
    assert_includes err, "shallow"
    assert_includes html, "/video/tour.mp4?v=#{digest}"
    refute_includes html, "/video/tour.mp4?v=#{video}"
    refute_includes html, "/video/tour.mp4?v=#{head}"
  ensure
    FileUtils.remove_entry(shallow) if shallow && File.directory?(shallow)
  end

  def test_base_href_resolves_document_urls
    write_files(@root, {
      "blog/index.html" => <<~HTML,
        <!-- <base href="https://cdn.example/assets/"> -->
        <script>var example = '<base href="https://cdn.example/assets/">';</script>
        <base href="https://example.com/docs/">
        <img src="img/a.png">
        <img src="/img/a.png">
        <img srcset="img/a.png 1x, /img/a.png 2x">
        <style>b { background: url(img/a.png); }</style>
        <link rel="stylesheet" href="/css/site.css">
        <script>var rel = "img/a.png";</script>
      HTML
      "blog/away.html" => <<~HTML,
        <base href="https://cdn.example/assets/">
        <img src="img/a.png">
        <img src="/img/a.png">
      HTML
      "blog/noslash.html" => <<~HTML,
        <base href="https://example.com/docs/blog">
        <img src="img/a.png">
      HTML
      "other/index.html" => <<~HTML,
        <base href="https://example.com/docs/blog/">
        <img src="img/a.png">
        <img src="/img/a.png">
      HTML
      "css/site.css" => "b { background: url(img/a.png); }\n",
      "img/a.png" => "a"
    })
    commit_site(@root)
    image = last_commit(@root, "img/a.png")
    dest = publish_copy(@root, baseurl: "/docs", url: "https://example.com")
    page = File.read(File.join(dest, "blog", "index.html"))
    assert_includes page, 'src="img/a.png?v=' + "#{image}\""
    assert_includes page, 'src="/docs/img/a.png?v=' + "#{image}\""
    assert_includes page, "srcset=\"img/a.png?v=#{image} 1x, /docs/img/a.png?v=#{image} 2x\""
    assert_includes page, "url(img/a.png?v=#{image})"
    assert_includes page, 'var rel = "img/a.png";'
    refute_includes page, 'var rel = "img/a.png?v='
    css = File.read(File.join(dest, "css", "site.css"))
    assert_includes css, "url(img/a.png);"
    refute_includes css, "img/a.png?v="

    away = File.read(File.join(dest, "blog", "away.html"))
    assert_includes away, 'src="img/a.png"'
    refute_includes away, 'src="img/a.png?v='
    assert_includes away, 'src="/docs/img/a.png?v=' + "#{image}\""

    noslash = File.read(File.join(dest, "blog", "noslash.html"))
    assert_includes noslash, 'src="img/a.png?v=' + "#{image}\""
    other = File.read(File.join(dest, "other", "index.html"))
    assert_includes other, 'src="img/a.png"'
    refute_includes other, 'src="img/a.png?v='
    assert_includes other, 'src="/docs/img/a.png?v=' + "#{image}\""
  end

  def test_symlinks_inside_the_site_use_the_newer_commit
    outside = Dir.mktmpdir("stalesmash-outside")
    write_files(@root, {
      "index.html" => <<~HTML,
        <img src="/img/a.png">
        <img src="/img/link.png">
        <img src="/static/a.png">
        <img src="/img/out.png">
        <img src="/img/broken.png">
      HTML
      "img/a.png" => "a"
    })
    File.symlink("a.png", File.join(@root, "img", "link.png"))
    File.symlink(File.join(@root, "img"), File.join(@root, "static"))
    File.write(File.join(outside, "secret.png"), "secret")
    File.symlink(File.join(outside, "secret.png"), File.join(@root, "img", "out.png"))
    File.symlink("missing.png", File.join(@root, "img", "broken.png"))
    commit_site(@root)
    original = last_commit(@root, "img/a.png")
    assert_equal original, last_commit(@root, "img/link.png")

    write_files(@root, "img/a.png" => "changed")
    commit_site(@root)
    updated = last_commit(@root, "img/a.png")
    link = last_commit(@root, "img/link.png")
    refute_equal original, updated
    assert_equal original, link

    dest = publish_copy(@root)
    html = File.read(File.join(dest, "index.html"))
    assert_includes html, "/img/a.png?v=#{updated}"
    assert_includes html, "/img/link.png?v=#{updated}"
    assert_includes html, "/static/a.png?v=#{updated}"
    assert_includes html, 'src="/img/out.png"'
    assert_includes html, 'src="/img/broken.png"'
    refute_includes html, "/img/out.png?v="
    refute_includes html, "/img/broken.png?v="
    refute_includes html, "/img/link.png?v=#{link}"
  ensure
    FileUtils.remove_entry(outside) if outside && File.directory?(outside)
  end

  def test_image_set_bare_names_and_template_paths
    write_files(@root, {
      "index.html" => "<link rel=\"stylesheet\" href=\"/css/mark.css\"><script src=\"/app.js\"></script>\n",
      "css/mark.css" => ".icon { background-image: image-set(\"logo.png\" 1x, \"missing.png\" 2x); }\n.note { content: \"logo.png\"; }\n",
      "css/logo.png" => "logo",
      "app.js" => "const sized = `/img/a.png?w=${width}`;\nconst rooted = `${base}/img/a.png`;\nconst joined = prefix + \"/img/a.png\";\n",
      "img/a.png" => "a"
    })
    commit_site(@root)
    original = last_commit(@root, "css/logo.png")
    image = last_commit(@root, "img/a.png")
    assert_equal original, image

    write_files(@root, "css/logo.png" => "logo-2")
    commit_site(@root)
    logo = last_commit(@root, "css/logo.png")
    refute_equal original, logo
    dest = publish_copy(@root, baseurl: "/docs")
    html = File.read(File.join(dest, "index.html"))
    css = File.read(File.join(dest, "css", "mark.css"))
    script = File.read(File.join(dest, "app.js"))
    assert_includes html, "/docs/css/mark.css?v=#{logo}"
    assert_includes html, "/docs/app.js?v=#{original}"
    assert_includes css, 'image-set("logo.png?v=' + "#{logo}\" 1x, \"missing.png\" 2x)"
    assert_includes css, 'content: "logo.png"'
    refute_includes css, "logo.png?v=#{logo}?v="
    refute_includes css, "missing.png?v="
    assert_includes script, "/docs/img/a.png?w=${width}&v=#{original}"
    assert_includes script, "${base}/img/a.png?v=#{original}"
    refute_includes script, "${base}/docs/"
    assert_includes script, 'prefix + "/docs/img/a.png?v=' + "#{original}\""

    write_files(@root, "img/a.png" => "pixel")
    FileUtils.rm_rf(File.join(@root, "_site"))
    commit_site(@root)
    moved = last_commit(@root, "img/a.png")
    refute_equal logo, moved
    dest = publish_copy(@root, baseurl: "/docs")
    html = File.read(File.join(dest, "index.html"))
    script = File.read(File.join(dest, "app.js"))
    assert_includes html, "/docs/css/mark.css?v=#{logo}"
    assert_includes html, "/docs/app.js?v=#{moved}"
    assert_includes script, "/docs/img/a.png?w=${width}&v=#{moved}"
    assert_includes script, "${base}/img/a.png?v=#{moved}"
    StaleSmash.bust(source: @root, dest: dest, baseurl: "/docs")
    assert_equal script, File.read(File.join(dest, "app.js"))
  end

  def test_generated_feed_follows_content_and_referenced_assets
    write_files(@root, {
      "index.html" => "<a href=\"/feed.xml\">Feed</a><img src=\"/img/a.png\"><video src=\"/video/tour.mp4\"></video>\n",
      "_posts/2024-05-01-hello.md" => "---\ntitle: Hello\n---\nHi\n",
      "img/a.png" => "a",
      "video/tour.mp4" => "video"
    })
    commit_site(@root)
    image = last_commit(@root, "img/a.png")
    video = last_commit(@root, "video/tour.mp4")
    assert_equal image, video

    write_files(@root, "_posts/2024-05-01-hello.md" => "---\ntitle: Hello\n---\nHi there\n")
    commit_site(@root)
    post = last_commit(@root, "_posts/2024-05-01-hello.md")
    refute_equal image, post
    dest = stage_feed
    html = File.read(File.join(dest, "index.html"))
    feed = File.read(File.join(dest, "feed.xml"))
    assert_includes html, "/feed.xml?v=#{post}"
    assert_includes html, "/img/a.png?v=#{image}"
    assert_includes html, "/video/tour.mp4?v=#{video}"
    assert_includes feed, "&lt;img alt=&quot;a &gt; b&quot; src=&quot;/img/a.png?v=#{image}&quot;&gt;"
    refute_includes feed, "/video/tour.mp4"

    write_files(@root, "img/a.png" => "pixel")
    FileUtils.rm_rf(File.join(@root, "_site"))
    commit_site(@root)
    image = last_commit(@root, "img/a.png")
    refute_equal post, image
    dest = stage_feed
    html = File.read(File.join(dest, "index.html"))
    feed = File.read(File.join(dest, "feed.xml"))
    assert_includes html, "/feed.xml?v=#{image}"
    assert_includes html, "/img/a.png?v=#{image}"
    assert_includes html, "/video/tour.mp4?v=#{video}"
    assert_includes feed, "&lt;img alt=&quot;a &gt; b&quot; src=&quot;/img/a.png?v=#{image}&quot;&gt;"

    write_files(@root, "video/tour.mp4" => "video-2")
    FileUtils.rm_rf(File.join(@root, "_site"))
    commit_site(@root)
    video = last_commit(@root, "video/tour.mp4")
    refute_equal image, video
    dest = stage_feed
    html = File.read(File.join(dest, "index.html"))
    feed = File.read(File.join(dest, "feed.xml"))
    assert_includes html, "/feed.xml?v=#{image}"
    assert_includes html, "/video/tour.mp4?v=#{video}"
    refute_includes html, "/feed.xml?v=#{video}"
    assert_includes feed, "/img/a.png?v=#{image}"
    refute_includes feed, video
    StaleSmash.bust(source: @root, dest: dest)
    assert_equal feed, File.read(File.join(dest, "feed.xml"))
    assert_equal html, File.read(File.join(dest, "index.html"))
  end

  def stage_feed
    dest = stage_dest(@root)
    File.write(File.join(dest, "feed.xml"), <<~XML)
      <?xml version="1.0"?>
      <feed>
        <content>&lt;img alt=&quot;a &gt; b&quot; src=&quot;/img/a.png&quot;&gt;</content>
      </feed>
    XML
    StaleSmash.bust(source: @root, dest: dest)
    dest
  end

  def stage_dest(source)
    dest = File.join(source, "_site")
    FileUtils.rm_rf(dest)
    FileUtils.mkdir_p(dest)
    Dir.each_child(source) do |name|
      next if name == ".git" || name == "_site"

      FileUtils.cp_r(File.join(source, name), File.join(dest, name))
    end
    dest
  end

  def publish_copy(source, **kwargs)
    dest = File.join(source, "_site")
    FileUtils.rm_rf(dest)
    FileUtils.mkdir_p(dest)
    Dir.each_child(source) do |name|
      next if name == ".git" || name == "_site"

      FileUtils.cp_r(File.join(source, name), File.join(dest, name))
    end
    StaleSmash.bust(source: source, dest: dest, **kwargs)
    dest
  end
end
