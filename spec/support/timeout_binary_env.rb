require 'tmpdir'

# Helper for the specs that prove mutant deadlines are enforced even when the
# coreutils `timeout` binary is unavailable.
#
# The naive approach (drop every PATH directory that contains `timeout`) is
# wrong on Linux: there `timeout` lives in /usr/bin and /bin alongside git, sh
# and other tools the spawned test subprocess needs. Removing those whole
# directories makes the mutant child crash on startup (e.g. the gemspec shells
# out to `git ls-files`) long before it reaches the infinite loop, so it exits
# fast and is misclassified as killed-not-timeout. On macOS the same code was a
# no-op only because no `timeout` binary exists there by default.
#
# This helper instead removes exactly the `timeout` binary: any PATH directory
# that holds it is replaced by a shadow directory symlinking all of its entries
# except `timeout`, leaving git/sh/ruby reachable.
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
    ([shadow_bin] + kept).join(File::PATH_SEPARATOR)
  end

  # Run the given block with `timeout` removed from PATH, restoring PATH after.
  def without_timeout_binary
    original_path = ENV['PATH']
    Dir.mktmpdir('mt-no-timeout-bin') do |shadow_bin|
      ENV['PATH'] = path_without_timeout(original_path, shadow_bin)
      yield
    end
  ensure
    ENV['PATH'] = original_path
  end
end
