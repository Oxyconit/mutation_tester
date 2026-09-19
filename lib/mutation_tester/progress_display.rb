module MutationTester
  class ProgressDisplay
    MONOTONIC_CLOCK = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    ANSI_STYLE = /\e\[[\d;]*m/
    SEPARATOR = ' | '
    ESTIMATE_MIN_PROCESSED = 5
    ESTIMATE_MIN_ELAPSED = 10

    attr_reader :total, :current, :current_mutation, :survived, :timed_out

    def initialize(total, config, output_stream: $stdout.clone, clock: MONOTONIC_CLOCK)
      @output_stream = output_stream
      @total = total
      @current = 0
      @current_mutation = nil
      @survived = 0
      @timed_out = 0
      @config = config
      @clock = clock
      @start_time = @clock.call
      @rendered_length = 0
      @spinner_frames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']
      @spinner_index = 0
      @lock = Mutex.new
      @spinner_thread = nil
      @stop_spinner = false

      start_spinner if @config.show_progress
    end

    def update(mutation, index, result = nil)
      @lock.synchronize do
        @current = index
        @current_mutation = mutation
        @survived += 1 if result && result[:status] == :survived
        @timed_out += 1 if result && result[:status] == :timeout
      end
    end

    def finish
      @lock.synchronize do
        @stop_spinner = true
        if @config.show_progress
          clear_line
          elapsed = @clock.call - @start_time
          @output_stream.puts "  #{Rainbow("Completed in #{format_duration(elapsed)}").green}"
        end
      end
      stop_spinner
    end

    private

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
      segments = line_segments
      limit = line_limit
      segments.pop while limit && segments.size > 1 && visible_length(segments.join(SEPARATOR)) > limit
      segments.join(SEPARATOR)
    end

    def line_segments
      progress = (@current.to_f / @total * 100).round(1)
      spinner = @spinner_frames[@spinner_index]

      [
        "#{Rainbow(spinner).magenta} [#{create_progress_bar(progress)}] #{Rainbow("#{progress}%").bright}",
        "#{Rainbow("#{@current}/#{@total}").cyan} processed",
        time_segment(@clock.call - @start_time),
        "#{Rainbow("#{@survived} survived").color(@survived.zero? ? :green : :red)}, #{@timed_out} timed out"
      ]
    end

    def time_segment(elapsed)
      segment = "elapsed #{format_duration(elapsed.floor)}"
      remaining = estimated_remaining(elapsed)
      remaining ? "#{segment}, remaining ~#{format_duration(remaining.ceil)}" : segment
    end

    def estimated_remaining(elapsed)
      return if @current.zero? || @current >= @total
      return if @current < ESTIMATE_MIN_PROCESSED && elapsed < ESTIMATE_MIN_ELAPSED

      elapsed / @current * (@total - @current)
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

    def create_progress_bar(percentage)
      width = 20
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
      if seconds < 60
        "#{seconds.round(1)}s"
      elsif seconds < 3600
        minutes = (seconds / 60).floor
        secs = (seconds % 60).round
        "#{minutes}m #{secs}s"
      else
        hours = (seconds / 3600).floor
        minutes = ((seconds % 3600) / 60).floor
        "#{hours}h #{minutes}m"
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
