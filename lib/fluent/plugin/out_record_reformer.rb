require 'socket'

module Fluent
  class RecordReformerOutput < Output
    Fluent::Plugin.register_output('record_reformer', self)

    def initialize
      super
      # require utilities for placeholder
      require 'pathname'
      require 'uri'
      require 'cgi'
    end

    config_param :output_tag, :string
    config_param :remove_keys, :string, :default => nil
    config_param :renew_record, :bool, :default => false
    config_param :enable_ruby, :bool, :default => true # true for lower version compatibility

    BUILTIN_CONFIGURATIONS = %W(type output_tag remove_keys renew_record enable_ruby)

    def configure(conf)
      super

      @map = {}
      conf.each_pair { |k, v|
        next if BUILTIN_CONFIGURATIONS.include?(k)
        conf.has_key?(k) # to suppress unread configuration warning
        @map[k] = v
      }
      # <record></record> directive
      conf.elements.select { |element| element.name == 'record' }.each { |element|
        element.each_pair { |k, v|
          element.has_key?(k) # to suppress unread configuration warning
          @map[k] = v
        }
      }

      if @remove_keys
        @remove_keys = @remove_keys.split(',')
      end

      @expand_placeholder_proc =
        if @enable_ruby
          Proc.new {|str, record, tag, tag_parts, time| expand_ruby_placeholder(str, record, tag, tag_parts, time) }
        else
          Proc.new {|str, record, tag, tag_parts, time| expand_placeholder(str, record, tag, tag_parts, time) }
        end

      @time_proc = # hmm, want to remove ${time} placeholder ...
        if @enable_ruby
          Proc.new {|time| Time.at(time) }
        else
          Proc.new {|time| time }
        end

      @hostname = Socket.gethostname
    end

    def emit(tag, es, chain)
      tag_parts = tag.split('.')
      es.each { |time, record|
        t_time = @time_proc.call(time)
        output_tag = @expand_placeholder_proc.call(@output_tag, record, tag, tag_parts, t_time)
        Engine.emit(output_tag, time, replace_record(record, tag, tag_parts, t_time))
      }
      chain.next
    rescue => e
      $log.warn "record_reformer: #{e.class} #{e.message} #{e.backtrace.join(', ')}"
    end

    private

    def replace_record(record, tag, tag_parts, time)
      new_record = @renew_record ? {} : record.dup
      @map.each_pair { |k, v|
        new_record[k] = @expand_placeholder_proc.call(v, record, tag, tag_parts, time)
      }
      @remove_keys.each { |k| new_record.delete(k) } if @remove_keys
      new_record
    end

    def expand_placeholder(str, record, tag, tag_parts, time)
      # referenced https://github.com/fluent/fluent-plugin-rewrite-tag-filter, thanks!
      placeholders = get_placeholders(record, tag, tag_parts, time)
      str.gsub(/(\${[a-z_]+(\[-?[0-9]+\])?}|__[A-Z_]+__)/) do
        $log.warn "record_reformer: unknown placeholder `#{$1}` found in a tag `#{tag}`" unless placeholders.include?($1)
        placeholders[$1]
      end
    end

    def get_placeholders(record, tag, tag_parts, time)
      placeholders = {
        '${time}' => time,
        '${tag}' => tag,
        '${hostname}' => @hostname,
      }

      size = tag_parts.size
      tag_parts.each_with_index do |t, idx|
        placeholders.store("${tag_parts[#{idx}]}", t)
        placeholders.store("${tag_parts[#{idx-size}]}", t) # support tag_parts[-1]
      end
      # tags is just for old version compatibility
      tag_parts.each_with_index do |t, idx|
        placeholders.store("${tags[#{idx}]}", t)
        placeholders.store("${tags[#{idx-size}]}", t) # support tags[-1]
      end

      record.each {|k, v|
        placeholders.store("${#{k}}", v)
      }

      return placeholders
    end

    # Replace placeholders in a string
    #
    # @param [String] str         the string to be replaced
    # @param [Hash]   record      the record, one of information
    # @param [String] tag         the tag
    # @param [Array]  tag_parts   the tag parts (tag splitted by .)
    # @param [Time]   time        the time
    def expand_ruby_placeholder(str, record, tag, tag_parts, time)
      struct = UndefOpenStruct.new(record)
      struct.tag  = tag
      struct.tags = struct.tag_parts = tag_parts # tags is for old version compatibility
      struct.time = time
      struct.hostname = @hostname
      str = str.gsub(/\$\{([^}]+)\}/, '#{\1}') # ${..} => #{..}
      eval "\"#{str}\"", struct.instance_eval { binding }
    end

    class UndefOpenStruct < OpenStruct
      (Object.instance_methods).each do |m|
        undef_method m unless m.to_s =~ /^__|respond_to_missing\?|object_id|public_methods|instance_eval|method_missing|define_singleton_method|respond_to\?|new_ostruct_member/
      end
    end
  end
end
