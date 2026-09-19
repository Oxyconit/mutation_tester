require 'spec_helper'
require 'tmpdir'
require 'mutation_tester/test_recorder/rspec_hook'

RSpec.describe MutationTester::TestRecorder do
  around do |example|
    saved = [described_class::LOG_ENV, described_class::SCOPE_ENV, described_class::ROOT_ENV].to_h { |name| [name, ENV[name]] }
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  ensure
    saved.each { |name, value| ENV[name] = value }
  end

  describe '.relative_to_root' do
    it 'strips the root even when the test path reaches it through a symlink, as a macOS temp workspace does' do
      real_root = File.join(@dir, 'real')
      FileUtils.mkdir_p(File.join(real_root, 'spec'))
      FileUtils.touch(File.join(real_root, 'spec', 'calc_spec.rb'))
      linked_root = File.join(@dir, 'linked')
      File.symlink(real_root, linked_root)
      ENV[described_class::ROOT_ENV] = linked_root

      expect(described_class.relative_to_root(File.join(File.realpath(real_root), 'spec', 'calc_spec.rb')))
        .to eq('spec/calc_spec.rb')
      expect(described_class.relative_to_root(File.join(linked_root, 'spec', 'calc_spec.rb')))
        .to eq('spec/calc_spec.rb')
    end

    it 'keeps a path outside the root untouched instead of guessing' do
      ENV[described_class::ROOT_ENV] = File.join(@dir, 'project')

      expect(described_class.relative_to_root('/elsewhere/spec/calc_spec.rb')).to eq('/elsewhere/spec/calc_spec.rb')
    end
  end

  describe '.write and .read' do
    let(:entries) do
      [
        { id: 'A#test_pass', name: 'test_pass', line: 3, status: 'passed' },
        { id: 'A#test_fail', name: 'test_fail', line: 7, status: 'failed' }
      ]
    end

    it 'keeps only the failing tests of a mutant run and every test of a baseline run' do
      log = File.join(@dir, 'tests.jsonl')
      ENV[described_class::LOG_ENV] = log

      ENV[described_class::SCOPE_ENV] = 'failures'
      described_class.write(entries)
      expect(described_class.read(log).map { |entry| entry[:id] }).to eq(['A#test_fail'])

      File.delete(log)
      ENV[described_class::SCOPE_ENV] = 'all'
      described_class.write(entries)
      expect(described_class.read(log).map { |entry| entry[:id] }).to eq(['A#test_pass', 'A#test_fail'])
    end

    it 'writes nothing when no log is named, so a normal test run is unaffected' do
      ENV.delete(described_class::LOG_ENV)

      expect(described_class.active?).to be(false)
      expect { described_class.write(entries) }.not_to(change { Dir.children(@dir) })
    end

    it 'ignores a line cut short by a killed child instead of failing the whole read' do
      log = File.join(@dir, 'tests.jsonl')
      File.write(log, "#{JSON.generate(entries.last)}\n{\"id\":\"A#test_cu")

      expect(described_class.failed_ids(described_class.read(log))).to eq(['A#test_fail'])
    end
  end

  describe 'rspec example ids' do
    def id_for(metadata)
      MutationTester::TestRecorder::RSpecHook.send(:id_for, metadata)
    end

    before { ENV[described_class::ROOT_ENV] = @dir }

    it 'uses the scoped example id, which stays unique for examples generated on one line' do
      metadata = { rerun_file_path: File.join(@dir, 'spec/calc_spec.rb'), scoped_id: '1:2:1', line_number: 9 }

      expect(id_for(metadata)).to eq('spec/calc_spec.rb[1:2:1]')
    end

    it 'falls back to file and line on rspec older than 3.3, which has no scoped ids' do
      metadata = { file_path: File.join(@dir, 'spec/calc_spec.rb'), line_number: 9 }

      expect(id_for(metadata)).to eq('spec/calc_spec.rb:9')
    end
  end
end
