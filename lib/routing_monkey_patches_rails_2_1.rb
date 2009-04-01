# patches for Rails 2.1 to generate named route helpers lazily
# this approach reduces the number of nodes used for generated routing code ~583K to ~160K in our app
# which in turn leads to a big reduction in overall heap size
# (from 1495437 to 1068710 (roughly 1/3) when running functional tests)
# hence, garbage collection speed also improves quite a bit
# this code needs to be adapted to new Rails versions when upgrading Rails
# the generated code has been cleaned up and made shorter as well

# modified:   actionpack/lib/action_controller/base.rb
# modified:   actionpack/lib/action_controller/routing/route.rb
# modified:   actionpack/lib/action_controller/routing/route_set.rb
# modified:   actionpack/lib/action_controller/test_process.rb
# modified:   activerecord/lib/active_record/attribute_methods.rb

raise "actionpack not loaded yet, giving up" unless defined?(ActionController::Routing::RouteSet::NamedRouteCollection)

module ::ActionController
  module Routing
    class Route
      $generated_code = File.open("/tmp/generated_routing_code.rb", "w") if ENV['RAILS_DEBUG_ROUTING_CODE'].to_i==1
      def add_generated_code(code, tag, file, line)
        if $generated_code
          $generated_code.puts "# route: #{@requirements.inspect}"; $generated_code.puts code; $generated_code.puts; $generated_code.flush
        end
        instance_eval code, "generated code/#{tag}/(#{file})", line
      end

      # Write and compile a +generate+ method for this Route.
      def write_generation
        # Build the main body of the generation
        body = "expired = false\n#{generation_extraction}\n#{generation_structure}"

        # If we have conditions that must be tested first, nest the body inside an if
        body = "if #{generation_requirements}\n#{body}\nend" if generation_requirements
        args = "options, hash, expire_on = {}"

        # Nest the body inside of a def block, and then compile it.
        raw_method = method_decl = "def generate_raw(#{args})\npath = begin\n#{body}\nend\n[path, hash]\nend"
        add_generated_code method_decl, "generate_raw", "#{RAILS_ROOT}/vendor/rails/actionpack/lib/action_controller/routing/route.rb", 36

        raw_method
      end

      def generate(options, hash, expire_on = {})
        # create generate_raw method if necessary
        write_generation unless respond_to? :generate_raw
        path, hash = generate_raw(options, hash, expire_on)
        append_query_string(path, hash, extra_keys(options))
      end

      def generate_extras(options, hash, expire_on = {})
        # create generate_raw method if necessary
        write_generation unless respond_to? :generate_raw
        path, hash = generate_raw(options, hash, expire_on)
        [path, extra_keys(options)]
      end

      # Write and compile a +recognize+ method for this Route.
      def write_recognition
        # Create an if structure to extract the params from a match if it occurs.
        body = "params = parameter_shell.dup\n#{recognition_extraction * "\n"}\nparams"
        body = "if #{recognition_conditions.join(" && ")}\n#{body}\nend"

        # Build the method declaration and compile it
        method_decl = "def recognize(path, env={})\n#{body}\nend"
        add_generated_code method_decl, "recognize", "#{RAILS_ROOT}/vendor/rails/actionpack/lib/action_controller/routing/route.rb", 86
        method_decl
      end

    end

    class RouteSet
      class NamedRouteCollection
        # new method needed for test processing
        def helper_method?(method_name)
          return false unless method_name.to_s =~ /^(.+)\_(url|path)$/
          get($1) != nil
        end

        def clear!
          @routes = {}
          @helpers = []

          @module ||= Module.new
          @module.instance_methods.each do |selector|
            @module.class_eval { remove_method selector }
          end
          # puts "installing method_missing handler for named routes"
          @module.module_eval <<-'end_code', __FILE__, __LINE__
            private
            def __named_routes__; ::ActionController::Routing::Routes.named_routes; end
            def __extract_options__(args, segment_keys)
              if args.empty? || Hash === args.first
                args.first || {}
              else
                options = args.extract_options!
                more_opts = {}
                args.zip(segment_keys).each {|v, k| more_opts[k] = v }
                options.merge(more_opts)
              end
            end
            def method_missing(method_name, *args, &block)
              begin
                super
              rescue NameError
                raise unless method_name.to_s =~ /^(.+)\_(url|path)$/
                # puts "redefining #{method_name}"
                name, kind = $1.to_sym, $2.to_sym
                raise "route not found: #{name}" unless route = __named_routes__[name]
                opts = {:only_path => (kind == :path)}
                hash = route.defaults.merge(:use_route => name).merge(opts)
                __named_routes__.__send__(:define_hash_access, route, name, kind, hash)
                __named_routes__.__send__(:define_url_helper, route, name, kind, hash)
                send(method_name, *args, &block)
              end
            end
          end_code
        end
        alias clear clear!

        def add(name, route)
          routes[name.to_sym] = route
          # define_named_route_methods(name, route) # left here to allow easy measuring old vs. new
        end

        alias []=   add

        private

        $named_routes = File.open("/tmp/named_route_helpers_code.rb", "w") if ENV['RAILS_DEBUG_ROUTING_CODE'].to_i==1
        def add_routing_code(code, tag, file, line)
          if $named_routes
            $named_routes.puts; $named_routes.puts code; $named_routes.puts; $named_routes.flush
          end
          @module.module_eval code, "generated code/#{tag}/(#{file})", line # We use module_eval to avoid leaks
        end

        def define_hash_access(route, name, kind, options)
          selector = hash_access_name(name, kind)
          code = <<-"end_code"
            def #{selector}(options = nil)
              opts = #{options.inspect}
              options ? opts.merge(options) : opts
            end
            # protected :#{selector}
          end_code
          add_routing_code code, "hash_access", "#{RAILS_ROOT}/vendor/rails/actionpack/lib/action_controller/routing/route_set.rb", 141
          helpers << selector
        end

        def define_url_helper(route, name, kind, options)
          selector = url_helper_name(name, kind)
          # The segment keys used for positional paramters

          hash_access_method = hash_access_name(name, kind)

          # allow ordered parameters to be associated with corresponding
          # dynamic segments, so you can do
          #
          #   foo_url(bar, baz, bang)
          #
          # instead of
          #
          #   foo_url(:bar => bar, :baz => baz, :bang => bang)
          #
          # Also allow options hash, so you can do
          #
          #   foo_url(bar, baz, bang, :sort_by => 'baz')
          #
          code = <<-"end_code"
            def #{selector}(*args)
              #{generate_optimisation_block(route, kind)}
              url_for(#{hash_access_method}(__extract_options__(args, #{route.segment_keys.inspect})))
            end
            # protected :#{selector}
          end_code
          add_routing_code code, "url_helper", "#{RAILS_ROOT}/vendor/rails/actionpack/lib/action_controller/routing/route_set.rb", 169
          helpers << selector
        end
      end
    end
  end

  if RAILS_ENV == "test"
    require 'action_controller/test_process'
    # testing needs some brains
    module TestProcess
      def method_missing(selector, *args)
        return @controller.send!(selector, *args) if ActionController::Routing::Routes.named_routes.helper_method?(selector)
        return super
      end
    end
  end
end

raise "activerecord not loaded yet, giving up" unless defined?(ActiveRecord::AttributeMethods::ClassMethods)
# modify file name for generated attribute methods to simplify heap dump analysis
module ::ActiveRecord
  module AttributeMethods #:nodoc:
    module ClassMethods
      private
      # Evaluate the definition for an attribute related method
      def evaluate_attribute_method(attr_name, method_definition, method_name=attr_name)
        unless method_name.to_s == primary_key.to_s
          generated_methods << method_name
        end
        begin
          class_eval(method_definition, "generated code/attribute_method(#{RAILS_ROOT}/vendor/rails/activerecord/lib/active_record/attribute_methods.rb)", 211)
        rescue SyntaxError => err
          generated_methods.delete(attr_name)
          if logger
            logger.warn "Exception occurred during reader method compilation."
            logger.warn "Maybe #{attr_name} is not a valid Ruby identifier?"
            logger.warn "#{err.message}"
          end
        end
      end
    end
  end
end
