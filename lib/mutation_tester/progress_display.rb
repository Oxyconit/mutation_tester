module MutationTester
  class ProgressDisplay
    MONOTONIC_CLOCK = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    ANSI_STYLE = /\e\[[\d;]*m/
    SEPARATOR = ' | '
    BAR_WIDTH = 20
    LAYOUTS = [
      { bar_width: BAR_WIDTH, compact: false },
      { bar_width: BAR_WIDTH / 2, compact: false },
      { bar_width: BAR_WIDTH / 2, compact: true },
      { bar_width: 0, compact: true }
    ].freeze
    ESTIMATE_MIN_PROCESSED = 5
    ESTIMATE_MIN_ELAPSED = 10

    attr_reader :total, :current, :survived, :timed_out, :errored

    def initialize(total, config, output_stream: $stdout.clone, clock: MONOTONIC_CLOCK)
      @output_stream = output_stream
      @total = total
      @current = 0
      @survived = 0
      @timed_out = 0
      @errored = 0
      @config = config
      @clock = clock
      @start_time = @clock.call
      @sample_start_time = nil
      @sample_start_count = nil
      @rendered_length = 0
      @spinner_frames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']
      @spinner_index = 0
      @lock = Mutex.new
      @spinner_thread = nil
      @stop_spinner = false
      @halted = false

      start_spinner if @config.show_progress
    end

    def update(index, result = nil)
      @lock.synchronize do
        @sample_start_time ||= @clock.call
        @sample_start_count ||= index
        @current = index
        tally(result) if result
      end
    end

    def finish
      halt do
        elapsed = @clock.call - @start_time
        @output_stream.puts "  #{Rainbow("Completed in #{format_duration(elapsed)}").green}"
      end
    end

    def stop
      halt
    end

    private

    def halt
      @lock.synchronize do
        @stop_spinner = true
        if @config.show_progress && !@halted
          clear_line
          yield if block_given?
        end
        @halted = true
      end
      stop_spinner
    end

    def tally(result)
      case Reporters::BaseReporter.status_for(result)
      when :survived then @survived += 1
      when :timeout then @timed_out += 1
      when :error then @errored += 1
      end
    end

    def render(already_locked = false)
      return unless @config.show_progress

      if already_locked
        _render_internal
      else
        @lock.synchronize { _render_internal }
      end
    end

    def _render_internal
      clear_line
      line = fitted_line
      @rendered_length = visible_length(line)
      @output_stream.print line
      @output_stream.flush
    end

    def fitted_line
      limit = line_limit
      now = @clock.call
      segments = []
      LAYOUTS.each do |layout|
        segments = line_segments(now, **layout)
        break if fits?(segments, limit)
      end
      segments.pop until fits?(segments, limit)
      segments.join(SEPARATOR)
    end

    def fits?(segments, limit)
      limit.nil? || visible_length(segments.join(SEPARATOR)) <= limit
    end

    def line_segments(now, bar_width:, compact:)
      processed = Rainbow("#{@current}/#{@total}").cyan

      [
        progress_segment(bar_width),
        compact ? processed : "#{processed} processed",
        time_segment(now, compact),
        tally_segment
      ]
    end

    def progress_segment(bar_width)
      progress = (@current.to_f / @total * 100).round(1)
      spinner = Rainbow(@spinner_frames[@spinner_index]).magenta
      percentage = Rainbow("#{progress}%").bright
      return "#{spinner} #{percentage}" if bar_width.zero?

      "#{spinner} [#{create_progress_bar(progress, bar_width)}] #{percentage}"
    end

    def time_segment(now, compact)
      elapsed = format_duration((now - @start_time).floor)
      remaining = estimated_remaining(now)
      return "elapsed #{elapsed}" unless remaining

      left = format_duration(remaining.ceil)
      compact ? "#{elapsed}, ~#{left} left" : "elapsed #{elapsed}, remaining ~#{left}"
    end

    def tally_segment
      survived = Rainbow("#{@survived} survived").color(@survived.zero? ? :green : :red)
      segment = "#{survived}, #{@timed_out} timed out"
      @errored.zero? ? segment : "#{segment}, #{Rainbow("#{@errored} errored").red}"
    end

    def estimated_remaining(now)
      return if @sample_start_time.nil? || @current >= @total

      sampled = @current - @sample_start_count
      sample_elapsed = now - @sample_start_time
      return unless sampled.positive?
      return if sampled < ESTIMATE_MIN_PROCESSED && sample_elapsed < ESTIMATE_MIN_ELAPSED

      sample_elapsed.fdiv(sampled) * (@total - @current)
    end

    def visible_length(text)
      text.gsub(ANSI_STYLE, '').length
    end

    def line_limit
      return unless @output_stream.respond_to?(:winsize) && @output_stream.tty?

      columns = @output_stream.winsize[1]
      columns - 1 if columns.positive?
    rescue SystemCallError
      nil
    end

    def create_progress_bar(percentage, width = BAR_WIDTH)
      filled = (percentage / 100.0 * width).round
      empty = width - filled

      Rainbow('█' * filled).green + Rainbow('░' * empty).white
    end

    def clear_line
      @output_stream.print "\r"
      @output_stream.print ' ' * @rendered_length
      @output_stream.print "\r"
    end

    def format_duration(seconds)
      return "#{seconds.round(1)}s" if seconds.round(1) < 60

      whole = seconds.round
      if whole < 3600
        "#{whole / 60}m #{whole % 60}s"
      else
        "#{whole / 3600}h #{whole % 3600 / 60}m"
      end
    end

    def start_spinner
      return if @spinner_thread

      @stop_spinner = false
      @spinner_thread = Thread.new do
        loop do
          should_stop = @lock.synchronize do
            if @stop_spinner
              true
            else
              @spinner_index = (@spinner_index + 1) % @spinner_frames.length
              render(true) if @config.show_progress
              false
            end
          end

          break if should_stop

          sleep 0.1
        end
      end

      @spinner_thread.abort_on_exception = false
    end

    def stop_spinner
      return unless @spinner_thread

      @stop_spinner = true
      @spinner_thread.wakeup if @spinner_thread.status == 'sleep'
      @spinner_thread.join
      @spinner_thread = nil
    end
  end
end
