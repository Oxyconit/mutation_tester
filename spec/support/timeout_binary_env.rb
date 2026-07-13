require 'tmpdir'
require 'bundler'

# Environment setup for the specs that prove mutant deadlines are enforced even
# when the coreutils `timeout` binary is unavailable. Two independent hazards
# make a naive setup pass locally yet fail on CI; both are handled here.
#
# 1. Removing `timeout` from PATH must not take the rest of the directory with
#    it. The naive approach (drop every PATH directory that contains `timeout`)
#    is wrong on Linux: there `timeout` lives in /usr/bin and /bin alongside
#    git, sh and the other tools the spawned test subprocess needs. Dropping
#    those whole directories makes the mutant child crash on startup long before
#    it reaches the infinite loop, so it exits fast and is misclassified as
#    killed-not-timeout. On macOS the same code was a no-op only because no
#    `timeout` binary exists there by default. We instead remove exactly the
#    `timeout` binary: any PATH directory that holds it is replaced by a shadow
#    directory symlinking all of its entries except `timeout`.
#
# 2. The mutant test subprocess must be spawned unbundled. When these specs run
#    under the gem's own dev bundle, the spawned child inherits BUNDLE_GEMFILE
#    and `-rbundler/setup`, so it re-resolves our bundle on every spawn. On CI's
#    prebuilt Ruby that re-resolution aborts on default gems whose native
#    extensions are not built (json/prism/racc/rbs/...), and the child exits
#    non-zero before reaching the infinite loop -> again misclassified as
#    killed-not-timeout (deterministically on some Ruby lines, flakily on
#    others via slow bundler startup racing the 2s deadline). A real global
#    install spawns children unbundled, so we do the same with
#    Bundler.with_unbundled_env, leaving the deadline as the only thing tested.
module TimeoutBinaryEnv
  module_function

  # Build a PATH equal to +original+ but with the `timeout` binary made
  # unresolvable. +shadow_bin+ must be an existing empty directory that outlives
  # the returned PATH's use (e.g. a Dir.mktmpdir block).
  def path_without_timeout(original, shadow_bin)
    kept = []
    original.split(File::PATH_SEPARATOR).each do |dir|
      unless File.executable?(File.join(dir, 'timeout'))
        kept << dir
        next
      end
      next unless File.directory?(dir)

      Dir.children(dir).each do |name|
        next if name == 'timeout'

        link = File.join(shadow_bin, name)
        next if File.symlink?(link) || File.exist?(link)

        File.symlink(File.join(dir, name), link)
      end
    end
    # shadow_bin goes LAST so the kept directories keep priority. A timeout dir
    # like /usr/bin also carries the system `ruby`; if shadow_bin came first a
    # spawned `#!/usr/bin/env ruby` binstub (e.g. rspec) would resolve to that
    # system Ruby instead of the toolchain Ruby in the kept dirs, fail to find
    # its gems, and exit before the mutant deadline. shadow_bin only backfills
    # the tools (git, sh) that lived solely in the removed timeout dirs.
    (kept + [shadow_bin]).join(File::PATH_SEPARATOR)
  end

  # Run the given block with the mutant-spawn environment these deadline specs
  # need: unbundled (children spawn like a real install, not the dev bundle) and
  # with the coreutils `timeout` binary removed from PATH. PATH is restored after.
  def without_timeout_binary
    Bundler.with_unbundled_env do
      original_path = ENV['PATH']
      Dir.mktmpdir('mt-no-timeout-bin') do |shadow_bin|
        ENV['PATH'] = path_without_timeout(original_path, shadow_bin)
        yield
      end
    ensure
      ENV['PATH'] = original_path
    end
  end
end
