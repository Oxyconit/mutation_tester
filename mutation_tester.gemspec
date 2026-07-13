require_relative 'lib/mutation_tester/version'

Gem::Specification.new do |spec|
  spec.name = 'mutation_tester'
  spec.version = MutationTester::VERSION
  spec.authors = ['Kamil Dzierbicki']
  spec.email = ['dzierbicki.kamil@outlook.com']

  spec.summary = 'Simple mutation testing framework for Ruby with RSpec, AI workflow and Minitest support'
  spec.description = 'A simple mutation testing framework that runs tests in parallel, generates detailed reports, and helps improve test quality by identifying weak spots in your test suite. Especially useful for you AI workflow'
  spec.homepage = 'https://blog.oxyconit.com/'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.0.0'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/Oxyconit/mutation_tester'
  spec.metadata['changelog_uri'] = 'https://github.com/Oxyconit/mutation_tester/blob/main/CHANGELOG.md'

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files -z`.split("\x0").reject do |f|
      (f == __FILE__) ||
        f.match(%r{\A(?:(?:test|spec|features|discovery|gemfiles)/|AGENTS\.md\z|lib/tasks/bench\.rake\z|\.(?:git|travis|circleci)|appveyor)})
    end
  end

  spec.bindir = 'exe'
  spec.executables = ['mutation_test']
  spec.require_paths = ['lib']

  spec.add_dependency('parallel', '~> 1.20')
  spec.add_dependency('parser', '~> 3.3')
  spec.add_dependency('rainbow', '~> 3.0')
  spec.add_dependency('unparser', '>= 0.6', '< 0.9')

  spec.add_development_dependency('bundler', '~> 2.0')
  spec.add_development_dependency('rake', '~> 13.0')
  spec.add_development_dependency('rspec', '~> 3.0')
  spec.add_development_dependency('minitest', '~> 5.0')
end
