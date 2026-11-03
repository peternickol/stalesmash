# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "open3"
require "tmpdir"
require "stalesmash"

Jekyll.logger.log_level = :error

module StaleSmash
  module TestHelper
    ROOT = File.expand_path("..", __dir__)
    EXE = File.join(ROOT, "exe", "stalesmash")
    def write_files(root, files)
      files.each do |rel, body|
        path = File.join(root, rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, body)
      end
    end

    def build(root, extra = {})
      dest = File.join(root, "_site")
      site = nil
      Dir.chdir(root) do
        config = Jekyll.configuration({
          "source" => root,
          "destination" => dest,
          "quiet" => true,
          "plugins_dir" => File.join(root, "_plugins")
        }.merge(extra))
        site = Jekyll::Site.new(config)
        site.process
      end
      site
    end

    def quoted(html, path)
      match = html.match(/=["']([^"']*#{Regexp.escape(path)}[^"']*)["']/)
      refute_nil match, "missing #{path} in:\n#{html}"
      match[1]
    end

    def commit_site(root)
      env = {
        "GIT_AUTHOR_NAME" => "StaleSmash",
        "GIT_AUTHOR_EMAIL" => "dev@localhost",
        "GIT_COMMITTER_NAME" => "StaleSmash",
        "GIT_COMMITTER_EMAIL" => "dev@localhost"
      }
      unless File.directory?(File.join(root, ".git"))
        system(env, "git", "-C", root, "init", "-q", exception: true)
      end
      system(env, "git", "-C", root, "add", "-A", exception: true)
      system(env, "git", "-C", root, "commit", "-q", "-m", "assets", exception: true)
    end

    def last_commit(root, path)
      output, status = Open3.capture2(
        "git", "-C", root, "log", "-1", "--abbrev=12", "--format=%h", "--", path
      )
      assert status.success?, output
      output.strip
    end

    def run_cli(root, *args)
      Open3.capture2e(
        RbConfig.ruby, "-I#{File.join(ROOT, "lib")}", EXE, *args,
        chdir: root
      )
    end
  end
end
