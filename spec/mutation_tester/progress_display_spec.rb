require 'spec_helper'
require 'stringio'

RSpec.describe MutationTester::ProgressDisplay do
  def config(show_progress:)
    cfg = MutationTester::Configuration.new
    cfg.show_progress = show_progress
    cfg
  end

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

    it 'carries a rounded-up remainder into the next unit instead of showing 60 of the smaller one' do
      expect(display.send(:format_duration, 59.96)).to eq('1m 0s')
      expect(display.send(:format_duration, 119.6)).to eq('2m 0s')
      expect(display.send(:format_duration, 3599.7)).to eq('1h 0m')
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

    it 'keeps the proportion when asked for a narrower bar' do
      half = display.send(:create_progress_bar, 50, 10)

      expect(half.count('█')).to eq(5)
      expect(half.count('░')).to eq(5)
    end
  end

  describe '#update' do
    it 'records the current index' do
      pd = described_class.new(10, config(show_progress: false), output_stream: StringIO.new)
      pd.update(4)
      expect(pd.current).to eq(4)
    end

    it 'tallies survived, timed out and errored results and leaves every other status uncounted' do
      pd = described_class.new(10, config(show_progress: false), output_stream: StringIO.new)

      %i[killed survived timeout stillborn survived error].each_with_index do |status, index|
        pd.update(index + 1, { status: status })
      end
      pd.update(7)

      expect(pd.survived).to eq(2)
      expect(pd.timed_out).to eq(1)
      expect(pd.errored).to eq(1)
    end

    it 'classifies a legacy result without a status the same way the reporters do' do
      pd = described_class.new(10, config(show_progress: false), output_stream: StringIO.new)

      pd.update(1, { killed: false })
      pd.update(2, { killed: true })

      expect(pd.survived).to eq(1)
    end
  end

  describe '#render / #_render_internal' do
    it 'writes the X/N counter and percentage to the injected stream' do
      pd, io = quiet_display(10)
      pd.update(2)

      pd.send(:render)

      expect(io.string).to include('2/10')
      expect(io.string).to include('20.0%')
    end

    it 'shows the live survived and timed out tallies' do
      pd, io = quiet_display(10)
      pd.update(1, { status: :survived })
      pd.update(2, { status: :timeout })
      pd.update(3, { status: :survived })

      pd.send(:render)

      expect(plain(io.string)).to end_with('2 survived, 1 timed out')
    end

    it 'adds an errored tally as soon as a mutant errors, so a broken environment does not look healthy' do
      pd, io = quiet_display(10)
      pd.update(1, { status: :error })
      pd.update(2, { status: :error })

      pd.send(:render)

      expect(plain(io.string)).to end_with('0 survived, 0 timed out, 2 errored')
    end

    it 'measures throughput from the first completed mutant, so startup time does not inflate the estimate' do
      now = 0.0
      pd, io = quiet_display(20, clock: -> { now })
      now = 30.0
      pd.update(1)
      now = 40.0
      pd.update(6)

      pd.send(:render)

      expect(io.string).to include('elapsed 40s, remaining ~28s')
    end

    it 'shows elapsed time without an estimate before any mutant is processed' do
      now = 0.0
      pd, io = quiet_display(20, clock: -> { now })
      now = 42.0

      pd.send(:render)

      expect(io.string).to include('elapsed 42s')
      expect(io.string).not_to include('remaining')
    end

    it 'gives no estimate from the first completed mutant alone, however long ago it completed' do
      now = 0.0
      pd, io = quiet_display(20, clock: -> { now })
      pd.update(1)
      now = 60.0

      pd.send(:render)

      expect(io.string).to include('elapsed 1m 0s')
      expect(io.string).not_to include('remaining')
    end

    it 'withholds the estimate while the sample is both small and young' do
      now = 0.0
      pd, io = quiet_display(20, clock: -> { now })
      pd.update(1)
      now = 9.0
      pd.update(5)

      pd.send(:render)

      expect(io.string).not_to include('remaining')
    end

    it 'shows the estimate once enough mutants are sampled even in a young run' do
      now = 0.0
      pd, io = quiet_display(20, clock: -> { now })
      pd.update(1)
      now = 5.0
      pd.update(6)

      pd.send(:render)

      expect(io.string).to include('remaining ~14s')
    end

    it 'shows the estimate once the sample is old enough even with a single sampled mutant' do
      now = 0.0
      pd, io = quiet_display(4, clock: -> { now })
      pd.update(1)
      now = 10.0
      pd.update(2)

      pd.send(:render)

      expect(io.string).to include('remaining ~20s')
    end

    it 'keeps the fractional throughput when the clock reports whole seconds' do
      now = 0
      pd, io = quiet_display(10, clock: -> { now })
      pd.update(1)
      now = 10
      pd.update(4)

      pd.send(:render)

      expect(io.string).to include('remaining ~20s')
    end

    it 'drops the estimate when every mutant is processed' do
      now = 0.0
      pd, io = quiet_display(5, clock: -> { now })
      pd.update(1)
      now = 60.0
      pd.update(5)

      pd.send(:render)

      expect(io.string).not_to include('remaining')
    end
  end

  describe 'fitting the line to the terminal width' do
    def long_run_line(columns)
      now = 0.0
      pd, io = quiet_display(1226, stream: terminal(columns), clock: -> { now })
      (1..170).each { |index| pd.update(index, { status: :survived }) }
      now = 2222.0
      pd.update(848)

      pd.send(:render)

      plain(io.string.split("\r").last)
    end

    it 'shows the full line when the terminal is wide enough' do
      line = long_run_line(120)

      expect(line).to end_with(
        '69.2% | 848/1226 processed | elapsed 37m 2s, remaining ~16m 32s | 170 survived, 0 timed out'
      )
      expect(line.count('█░')).to eq(20)
    end

    it 'halves the bar and shortens the labels before it drops any information' do
      line = long_run_line(100)

      expect(line).to end_with('69.2% | 848/1226 | 37m 2s, ~16m 32s left | 170 survived, 0 timed out')
      expect(line.count('█░')).to eq(10)
      expect(line.length).to be <= 99
    end

    it 'keeps the counter, both times and the tallies on a standard 80-column terminal by giving up the bar' do
      line = long_run_line(80)

      expect(line).to end_with('69.2% | 848/1226 | 37m 2s, ~16m 32s left | 170 survived, 0 timed out')
      expect(line.count('█░')).to eq(0)
      expect(line.length).to be <= 79
    end

    it 'drops trailing segments only when even the most compact layout is too wide' do
      pd, io = quiet_display(10, stream: terminal(40))
      pd.update(2, { status: :survived })

      pd.send(:render)

      line = plain(io.string.split("\r").last)
      expect(line).to end_with('20.0% | 2/10 | elapsed 0s')
      expect(line).not_to include('survived')
      expect(line.length).to be <= 39
    end

    it 'draws nothing rather than wrap when not even the percentage fits' do
      pd, io = quiet_display(10, stream: terminal(5))
      pd.update(2)

      pd.send(:render)

      expect(io.string.delete("\r")).to eq('')
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

      pd.update(1)
      pd.finish

      expect(io.string).to eq('')
    end
  end

  describe '#stop' do
    it 'clears the line and joins the spinner thread without claiming the run completed' do
      io = StringIO.new
      pd = described_class.new(3, config(show_progress: true), output_stream: io)
      thread = pd.instance_variable_get(:@spinner_thread)

      pd.stop

      expect(thread.alive?).to be(false)
      expect(io.string).not_to include('Completed in')
      expect(io.string).to end_with("\r")
    end

    it 'writes nothing more when the display already finished' do
      io = StringIO.new
      pd = described_class.new(3, config(show_progress: true), output_stream: io)
      pd.finish
      finished_output = io.string.dup

      pd.stop

      expect(io.string).to eq(finished_output)
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
        pd.update(3)
        pd.update(6)
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

  def terminal(columns)
    Class.new(StringIO) do
      define_method(:tty?) { true }
      define_method(:winsize) { [24, columns] }
    end.new
  end

  def plain(text)
    text.gsub(/\e\[[\d;]*m/, '')
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
