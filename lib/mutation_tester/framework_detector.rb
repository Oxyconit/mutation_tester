module MutationTester
  module FrameworkDetector
    MINITEST_REQUIRE = /require\s+['"]minitest/.freeze

    module_function

    def detect(spec_file)
      basename = File.basename(spec_file)

      return :rspec if basename.end_with?('_spec.rb', '.spec.rb')
      return :minitest if basename.end_with?('_test.rb') || basename.start_with?('test_')
      return :minitest if minitest_content?(spec_file)

      :rspec
    end

    def minitest_content?(spec_file)
      return false unless File.exist?(spec_file)

      File.read(spec_file).match?(MINITEST_REQUIRE)
    rescue StandardError
      false
    end
  end
end
