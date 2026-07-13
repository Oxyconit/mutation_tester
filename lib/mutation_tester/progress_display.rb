module MutationTester
  class ProgressDisplay
    attr_reader :total, :current, :current_mutation

    def initialize(total, config, output_stream: $stdout.clone)
      @output_stream = output_stream
      @total = total
      @current = 0
      @current_mutation = nil
      @config = config
      @start_time = Time.now
      @spinner_frames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']
      @spinner_index = 0
      @lock = Mutex.new
      @spinner_thread = nil
      @stop_spinner = false

      start_spinner if @config.show_progress
    end

    def update(mutation, index)
      @lock.synchronize do
        @current = index
        @current_mutation = mutation
      end
    end

    def finish
      @lock.synchronize do
        @stop_spinner = true
        if @config.show_progress
          clear_line
          elapsed = Time.now - @start_time
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

      progress = (@current.to_f / @total * 100).round(1)
      progress_bar = create_progress_bar(progress)
      spinner = @spinner_frames[@spinner_index]

      mutation_info = @current_mutation ? " | #{@current_mutation[:type]} | line #{@current_mutation[:line]}" : ''

      line = "#{Rainbow(spinner).magenta} [#{progress_bar}] #{Rainbow(progress.to_s + "%").bright} | " \
             "#{Rainbow("#{@current}/#{@total}").cyan} mutations processed#{mutation_info}"

      @output_stream.print line
      @output_stream.flush
    end

    def create_progress_bar(percentage)
      width = 20
      filled = (percentage / 100.0 * width).round
      empty = width - filled

      Rainbow('█' * filled).green + Rainbow('░' * empty).white
    end

    def clear_line
      @output_stream.print "\r"
      @output_stream.print ' ' * 100
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
