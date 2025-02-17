# frozen_string_literal: true

require "active_support/core_ext/module/attribute_accessors_per_thread"

module ActiveRecord
  # = Active Record Query Logs
  #
  # Automatically tag SQL queries with runtime information.
  #
  # Default tags available for use:
  #
  # * +application+
  # * +pid+
  # * +socket+
  # * +db_host+
  # * +database+
  #
  # _Action Controller and Active Job tags are also defined when used in Rails:_
  #
  # * +controller+
  # * +action+
  # * +job+
  #
  # The tags used in a query can be configured directly:
  #
  #     ActiveRecord::QueryLogs.tags = [ :application, :controller, :action, :job ]
  #
  # or via Rails configuration:
  #
  #     config.active_record.query_log_tags = [ :application, :controller, :action, :job ]
  #
  # To add new comment tags, add a hash to the tags array containing the keys and values you
  # want to add to the comment. Dynamic content can be created by setting a proc or lambda value in a hash,
  # and can reference any value stored in the +context+ object.
  #
  # Example:
  #
  #    tags = [
  #      :application,
  #      {
  #        custom_tag: ->(context) { context[:controller]&.controller_name },
  #        custom_value: -> { Custom.value },
  #      }
  #    ]
  #    ActiveRecord::QueryLogs.tags = tags
  #
  # The QueryLogs +context+ can be manipulated via the +set_context+ method.
  #
  # Temporary updates limited to the execution of a block:
  #
  #    ActiveRecord::QueryLogs.set_context(foo: Bar.new) do
  #      posts = Post.all
  #    end
  #
  # Direct updates to a context value:
  #
  #    ActiveRecord::QueryLogs.set_context(foo: Bar.new)
  #
  # Tag comments can be prepended to the query:
  #
  #    ActiveRecord::QueryLogs.prepend_comment = true
  #
  # For applications where the content will not change during the lifetime of
  # the request or job execution, the tags can be cached for reuse in every query:
  #
  #    ActiveRecord::QueryLogs.cache_query_log_tags = true
  #
  # This option can be set during application configuration or in a Rails initializer:
  #
  #    config.active_record.cache_query_log_tags = true
  module QueryLogs
    mattr_accessor :taggings, instance_accessor: false, default: {}
    mattr_accessor :tags, instance_accessor: false, default: [ :application ]
    mattr_accessor :prepend_comment, instance_accessor: false, default: false
    mattr_accessor :cache_query_log_tags, instance_accessor: false, default: false
    thread_mattr_accessor :cached_comment, instance_accessor: false

    class << self
      # Updates the context used to construct tags in the SQL comment.
      # If a block is given, it resets the provided keys to their
      # previous value once the block exits.
      def set_context(**options)
        options.symbolize_keys!

        keys = options.keys
        previous_context = keys.zip(context.values_at(*keys)).to_h
        context.merge!(options)
        self.cached_comment = nil
        if block_given?
          begin
            yield
          ensure
            context.merge!(previous_context)
            self.cached_comment = nil
          end
        end
      end

      def clear_context # :nodoc:
        context.clear
      end

      def call(sql) # :nodoc:
        if prepend_comment
          "#{self.comment} #{sql}"
        else
          "#{sql} #{self.comment}"
        end.strip
      end

      private
        # Returns an SQL comment +String+ containing the query log tags.
        # Sets and returns a cached comment if <tt>cache_query_log_tags</tt> is +true+.
        def comment
          if cache_query_log_tags
            self.cached_comment ||= uncached_comment
          else
            uncached_comment
          end
        end

        def uncached_comment
          content = tag_content
          if content.present?
            "/*#{escape_sql_comment(content)}*/"
          end
        end

        def context
          Thread.current[:active_record_query_log_tags_context] ||= {}
        end

        def escape_sql_comment(content)
          content.to_s.gsub(%r{ (/ (?: | \g<1>) \*) \+? \s* | \s* (\* (?: | \g<2>) /) }x, "")
        end

        def tag_content
          tags.flat_map { |i| [*i] }.filter_map do |tag|
            key, handler = tag
            handler ||= taggings[key]

            val = if handler.nil?
              context[key]
            elsif handler.respond_to?(:call)
              if handler.arity == 0
                handler.call
              else
                handler.call(context)
              end
            else
              handler
            end
            "#{key}:#{val}" unless val.nil?
          end.join(",")
        end
    end
  end
end
