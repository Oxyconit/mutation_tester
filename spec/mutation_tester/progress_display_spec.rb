require 'spec_helper'
require 'stringio'

RSpec.describe MutationTester::ProgressDisplay do
  def config(show_progress:)
    cfg = MutationTester::Configuration.new
    cfg.show_progress = show_progress
    cfg
  end

  let(:mutation) { { type: :arithmetic, line: 12 } }

  let(:spinner_frames) do
    described_class.new(1, config(show_progress: false), output_stream: StringIO.new)
                   .instance_variable_get(:@spinner_frames)
  end

  describe '#format_duration' do
    let(:display) { described_class.new(10, config(show_progress: false), output_stream: StringIO.new) }

    it 'formats a sub-minute duration in seconds' do
      expect(display.send(:format_duration, 45.3)).to eq('45.3s')
    end

    it 'formats a minute-scale duration as "Xm Ys"' do
      expect(display.send(:format_duration, 125)).to eq('2m 5s')
    end

    it 'formats an hour-scale duration as "Xh Ym"' do
      expect(display.send(:format_duration, 4020)).to eq('1h 7m')
    end
  end

  describe '#create_progress_bar' do
    let(:display) { described_class.new(10, config(show_progress: false), output_stream: StringIO.new) }

    it 'fills the 20-wide bar proportionally to the percentage' do
      expect(display.send(:create_progress_bar, 0).count('░')).to eq(20)
      expect(display.send(:create_progress_bar, 100).count('█')).to eq(20)

      half = display.send(:create_progress_bar, 50)
      expect(half.count('█')).to eq(10)
      expect(half.count('░')).to eq(10)
    end
  end

  describe '#update' do
    it 'records the current index and mutation' do
      pd = described_class.new(10, config(show_progress: false), output_stream: StringIO.new)
      pd.update(mutation, 4)
      expect(pd.current).to eq(4)
      expect(pd.current_mutation).to eq(mutation)
    end

    it 'tallies survived and timed out results and leaves every other status uncounted' do
      pd = described_class.new(10, config(show_progress: false), output_stream: StringIO.new)

      %i[killed survived timeout stillborn survived error].each_with_index do |status, index|
        pd.update(mutation, index + 1, { status: status })
      end
      pd.update(nil, 7)

      expect(pd.survived).to eq(2)
      expect(pd.timed_out).to eq(1)
    end
  end

  describe '#render / #_render_internal' do
    it 'writes the X/N counter and percentage to the injected stream' do
      pd, io = quiet_display(10)
      pd.update(mutation, 2)

      pd.send(:render)

      expect(io.string).to include('2/10')
      expect(io.string).to include('20.0%')
    end

    it 'shows the live survived and timed out tallies' do
      pd, io = quiet_display(10)
      pd.update(mutation, 1, { status: :survived })
      pd.update(mutation, 2, { status: :timeout })
      pd.update(mutation, 3, { status: :survived })

      pd.send(:render)

      expect(io.string).to include('2 survived, 1 timed out')
    end

    it 'extrapolates the remaining time from the throughput so far' do
      now = 0.0
      pd, io = quiet_display(20, clock: -> { now })
      pd.update(mutation, 5)
      now = 100.0

      pd.send(:render)

      expect(io.string).to include('elapsed 1m 40s, remaining ~5m 0s')
    end

    it 'shows elapsed time without an estimate before any mutant is processed' do
      now = 0.0
      pd, io = quiet_display(20, clock: -> { now })
      now = 42.0

      pd.send(:render)

      expect(io.string).to include('elapsed 42s')
      expect(io.string).not_to include('remaining')
    end

    it 'withholds the estimate while the sample is both small and young' do
      now = 0.0
      pd, io = quiet_display(20, clock: -> { now })
      pd.update(mutation, 4)
      now = 9.0

      pd.send(:render)

      expect(io.string).not_to include('remaining')
    end

    it 'shows the estimate once enough mutants are processed even in a young run' do
      now = 0.0
      pd, io = quiet_display(20, clock: -> { now })
      pd.update(mutation, 5)
      now = 5.0

      pd.send(:render)

      expect(io.string).to include('remaining ~15s')
    end

    it 'shows the estimate once the run is old enough even with a single processed mutant' do
      now = 0.0
      pd, io = quiet_display(4, clock: -> { now })
      pd.update(mutation, 1)
      now = 10.0

      pd.send(:render)

      expect(io.string).to include('remaining ~30s')
    end

    it 'drops the estimate when every mutant is processed' do
      now = 0.0
      pd, io = quiet_display(5, clock: -> { now })
      pd.update(mutation, 5)
      now = 60.0

      pd.send(:render)

      expect(io.string).not_to include('remaining')
    end

    it 'drops trailing segments so the line never wraps in a narrow terminal' do
      narrow = Class.new(StringIO) do
        def tty? = true
        def winsize = [24, 56]
      end.new
      pd, io = quiet_display(10, stream: narrow)
      pd.update(mutation, 2, { status: :survived })

      pd.send(:render)

      rendered = io.string.split("\r").last
      expect(rendered).to include('2/10 processed')
      expect(rendered).not_to include('elapsed')
      expect(rendered).not_to include('survived')
      expect(rendered.gsub(/\e\[[\d;]*m/, '').length).to be <= 55
    end
  end

  describe '#finish' do
    it 'prints the "Completed in" line to the injected stream' do
      io = StringIO.new
      pd = described_class.new(3, config(show_progress: true), output_stream: io)

      pd.finish

      expect(io.string).to include('Completed in')
    end

    it 'writes nothing at all when show_progress is false' do
      io = StringIO.new
      pd = described_class.new(3, config(show_progress: false), output_stream: io)

      pd.update(mutation, 1)
      pd.finish

      expect(io.string).to eq('')
    end
  end

  describe 'spinner thread lifecycle' do
    it 'reliably stops and joins the spinner thread, leaving none alive' do
      io = StringIO.new
      pd = described_class.new(5, config(show_progress: true), output_stream: io)
      thread = pd.instance_variable_get(:@spinner_thread)
      expect(thread).to be_a(Thread)

      pd.finish

      expect(thread.alive?).to be(false)
      expect(pd.instance_variable_get(:@spinner_thread)).to be_nil
    end
  end

  describe 'no spinner artifact after completion' do
    it 'never draws a spinner frame after "Completed in" (repeated)' do
      50.times do
        io = StringIO.new
        pd = described_class.new(8, config(show_progress: true), output_stream: io)
        pd.update(mutation, 3)
        pd.update(mutation, 6)
        pd.finish
        assert_no_frame_after_completion(io.string)
      end
    end

    it 'keeps the completion print and stop flag under one lock even with the spinner parked' do
      io = StringIO.new
      pd = described_class.new(6, config(show_progress: true), output_stream: io)
      lock = pd.instance_variable_get(:@lock)
      thread = pd.instance_variable_get(:@spinner_thread)

      lock.lock
      Thread.pass until thread.stop?
      lock.unlock

      pd.finish

      assert_no_frame_after_completion(io.string)
      expect(thread.alive?).to be(false)
    end
  end

  def quiet_display(total, stream: StringIO.new, **options)
    io = StringIO.new
    pd = described_class.new(total, config(show_progress: true), output_stream: io, **options)
    pd.send(:stop_spinner)
    pd.instance_variable_set(:@output_stream, stream)
    [pd, stream]
  end

  def assert_no_frame_after_completion(output)
    idx = output.index('Completed in')
    expect(idx).not_to(be_nil, "expected a 'Completed in' line in: #{output.inspect}")

    tail = output[(idx + 'Completed in'.length)..]
    expect(tail).not_to include('processed')
    spinner_frames.each do |frame|
      expect(tail).not_to(include(frame), "spinner frame #{frame.inspect} leaked after completion: #{output.inspect}")
    end
  end
end
