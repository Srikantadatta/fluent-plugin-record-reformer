require 'test/unit'
require 'test/unit/rr'
require 'timecop'
require 'fluent/log'
require 'fluent/test'

unless defined?(Test::Unit::AssertionFailedError)
  class Test::Unit::AssertionFailedError < StandardError
  end
end

# Reduce sleep period at
# https://github.com/fluent/fluentd/blob/a271b3ec76ab7cf89ebe4012aa5b3912333dbdb7/lib/fluent/test/base.rb#L81
module Fluent
  module Test
    class TestDriver
      def run(num_waits = 10, &block)
        @instance.start
        begin
          # wait until thread starts
          # num_waits.times { sleep 0.05 }
          sleep 0.05
          return yield
        ensure
          @instance.shutdown
        end
      end
    end
  end
end

require 'fluent/version'
major, minor, patch = Fluent::VERSION.split('.').map(&:to_i)
if major > 0 || (major == 0 && minor >= 14)
  require 'fluent/test/driver/output'
  require 'fluent/test/helpers'
  include Fluent::Test::Helpers

  # I do not want to use Fluent::Test::OutputTestDriver, but
  # want to have a test driver whose interface is compatible with of v0.12
  class RecordReformerOutputTestDriver < Fluent::Test::Driver::Output
    def initialize(klass, tag)
      super(klass)
      @tag = tag
    end

    def configure(conf, use_v1)
      super(conf, syntax: use_v1 ? :v1 : :v0)
    end

    def run(&block)
      super(default_tag: @tag, &block)
    end

    def emit(record, time)
      feed(time, record)
    end

    def emits
      events
    end
  end

  def create_driver(conf, use_v1)
    RecordReformerOutputTestDriver.new(Fluent::Plugin::RecordReformerOutput, @tag).configure(conf, use_v1)
  end
else
  def event_time(str)
    Time.parse(str)
  end

  def create_driver(conf, use_v1)
    Fluent::Test::OutputTestDriver.new(Fluent::RecordReformerOutput, @tag).configure(conf, use_v1)
  end
end
