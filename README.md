<p align="center">
  <img src="logo.png" alt="StaleSmash" width="250">
</p>

<h1 align="center">StaleSmash</h1>

<p align="center">
  Cache busting for Jekyll.<br>
  MIT licensed. One command for Dish and GitHub Pages.
</p>

<p align="center">
  <a href="#install">Install</a>
  &nbsp;·&nbsp;
  <a href="#command">Command</a>
  &nbsp;·&nbsp;
  <a href="#github-pages">GitHub Pages</a>
  &nbsp;·&nbsp;
  <a href="#dish">Dish</a>
  &nbsp;·&nbsp;
  <a href="#license">License</a>
</p>

StaleSmash crawls the built site and adds `?v=` to each local asset URL. The value is the commit that last changed that file.

```text
/css/main.css?v=fd8a20b62377
/video/tour.mp4?v=91ab33c0e4d1
```

A later commit writes a new query only on the files it changed. Everything else keeps its URL, so the browser and the CDN keep those copies. A stylesheet, script, manifest, SVG, or feed uses the newest commit among itself and the files it pulls in. That query is still a commit.

## Install

```ruby
gem "stalesmash", group: :jekyll_plugins,
  git: "https://github.com/peternickol/stalesmash.git",
  branch: "master"
```

Update the lockfile. With the gem in `:jekyll_plugins`, `jekyll build` and `jekyll serve` run the same function at the end of the build. `STALESMASH_DISABLE=1` or `stalesmash.enabled: false` skips that hook. The command still works.

GitHub Pages does not need the gem. The workflow below checks this repository out and runs the command.

## Command

```sh
bundle exec jekyll build
bundle exec stalesmash
```

`stalesmash` reads `url`, `baseurl`, and `destination` from `_config.yml`. Root-absolute URLs gain that prefix. An existing query and fragment stay, and an older `v` is replaced. Source files are not edited.

```sh
stalesmash [--source DIR] [--dest DIR] [--baseurl PATH] [--url ORIGIN]
```

Any real file is an asset: a pdf, a font, a video, a manifest, or a zip uses the same rule as a png. HTML pages are not assets, so a link to another page stays as written.

The crawl reads `href`, `src`, `poster`, `content`, `data`, `url`, `srcset`, `data-srcset`, and `imagesrcset`. It also reads `url()`, `@import`, and `image-set()` inside stylesheets and `<style>` blocks, including a bare name such as `image-set("logo.png")`. A quoted file name anywhere else, such as `content: "logo.png"`, stays text. Quoted paths inside `<script>`, JavaScript, JSON, and web manifests are stamped, including the static file in `` `${base}/img/a.png` `` and `` `/img/a.png?w=${width}` ``. The crawl rewrites HTML, CSS, JavaScript, JSON, web manifests, SVG, and XML. Markup that a feed escaped, such as `&lt;img src=&quot;/img/a.png&quot;&gt;`, is stamped too. An example of that markup in an HTML page is left as written.

An absolute URL is stamped when its host matches `url` in `_config.yml`. `https://example.com/img/a.png` becomes `https://example.com/img/a.png?v=...` when `url` is `https://example.com`. `http` and `https` match when the site is on the default port for its scheme. A URL on any other port is left as written. Set `url` to the origin Jekyll already uses for canonical links. Without it, root-relative and relative URLs are stamped.

A `<base href>` is where a relative URL in that HTML document is resolved, including its inline styles. The first base element wins. A root-absolute URL ignores the base path. A base on another host leaves relative URLs as written. A stylesheet still resolves `url()` from the CSS file, and a path inside `<script>` stays relative to the page file.

A symlink is versioned when its target stays inside the site. The query is the newer commit of the link and the target. A link that points outside the site is left as written.

A file that exists only in the built site, such as a generated feed or sitemap, has no source commit. Its query is the newest commit among the posts, pages, layouts, includes, data, config, and the assets that file references. A new post moves the feed. A video the feed does not mention keeps the feed's URL.

The Pages workflow checks out the full history. A shallow checkout is deepened with `git fetch --unshallow` before versions are chosen. If that fetch fails, the oldest fetched commit has no parent, so it cannot say which files it changed. Those files use a content hash. A file changed in a newer fetched commit still uses that commit.

## GitHub Pages

The legacy Pages builder will not run this command. Set Pages to build with GitHub Actions and add `.github/workflows/pages.yml`:

```yaml
name: Pages
on:
  push:
    branches: [master]
permissions:
  contents: read
  pages: write
  id-token: write
jobs:
  pages:
    uses: peternickol/stalesmash/.github/workflows/pages.yml@master
```

That workflow checks out the full history, runs `jekyll build`, then checks out this repository at the same commit the workflow was called with and runs this same command. A caller that pins the workflow to a commit pins the stamp to that commit too. Callers on `@master` stay on `@master`. The site Gemfile needs Jekyll.

To stamp a build you already produced:

```yaml
- uses: peternickol/stalesmash@master
  with:
    baseurl: ${{ steps.pages.outputs.base_path }}
```

Leave `baseurl` unset and the command reads `_config.yml`. Pass the Pages base path when another workflow builds the site, including when that path is empty. An empty value means the site is served with no prefix, which keeps the stamp on the same prefix as `jekyll build --baseurl`.

## Dish

Add the gem, then add the command to the build you already have:

```yaml
build:
  - bundle exec jekyll build
  - bundle exec stalesmash
```

Keep the `BUNDLE_PATH` and `BUNDLE_FROZEN` prefixes your site already uses on both lines. Nothing else in `dish.yml` changes.

## Caching

This plugin does not set `Cache-Control`. Cache the versioned asset URLs for a long time. Keep HTML short-lived. The HTML is what carries the new query.

## Develop

Ruby 2.7 or newer, and Jekyll from 3.9 up to but not including 5.

```sh
ruby -Ilib:test test/stalesmash_test.rb
```

This repository has no Gemfile. The tests build a temporary site.

## License

StaleSmash is [MIT licensed](LICENSE). Copyright (c) 2026 StaleSmash.

You can use it in a commercial product, modify it, and distribute it. The MIT grant includes sale. Copies and substantial portions keep the copyright notice and the permission notice from [LICENSE](LICENSE).
