require 'ruby_parser'

require 'channel9'
require 'channel9/ruby'

module Channel9
  module Loader
    class Ruby
      attr :env

      def initialize(debug = false)
        @env = Channel9::Environment.new(debug)

        object_klass = Channel9::Ruby::RubyClass.new(env, "Object", nil)
        env.special_channel[:Object] = object_klass
        Channel9::Ruby::RubyObject.object_klass(object_klass)

        module_klass = Channel9::Ruby::RubyClass.new(env, "Module", object_klass)
        env.special_channel[:Module] = module_klass
        Channel9::Ruby::RubyModule.module_klass(module_klass)

        class_klass = Channel9::Ruby::RubyClass.new(env, "Class", module_klass)
        env.special_channel[:Class] = class_klass
        Channel9::Ruby::RubyClass.class_klass(class_klass)
        
        object_klass.rebind(class_klass)
        module_klass.rebind(class_klass)
        class_klass.rebind(class_klass)

        kernel_mod = Channel9::Ruby::RubyModule.new(env, "Kernel")
        env.special_channel[:Kernel] = kernel_mod
        Channel9::Ruby::RubyModule.kernel_mod(kernel_mod)
        object_klass.include(kernel_mod)

        env.special_channel[:loader] = self
        env.special_channel[:global_self] = Channel9::Ruby::RubyObject.new(env)
        env.special_channel[:globals] = {
          :"$LOAD_PATH" => ["environment/kernel", "environment/lib", "."]
        }
        env.special_channel[:unwinder] = Channel9::Ruby::Unwinder.new(env)
        
        object_klass.constant[:Object.to_c9] = object_klass
        object_klass.constant[:Module.to_c9] = module_klass
        object_klass.constant[:Class.to_c9] = class_klass
        object_klass.constant[:Kernel.to_c9] = kernel_mod

        # Builtin special types:
        [
          [:Fixnum, "Number"],
          [:Symbol, "String"],
          [:Tuple, "Tuple"],
          [:Table, "Table"],
          [:Message, "Message"],
          [:TrueClass, "TrueC"],
          [:FalseClass, "FalseC"],
          [:NilClass, "NilC"],
          [:UndefClass, "UndefC"]
        ].each do |ruby_name, c9_name|
          klass = Channel9::Ruby::RubyClass.new(env, ruby_name.to_c9, object_klass)
          env.special_channel["Channel9::Primitive::#{c9_name}"] = klass
          object_klass.constant[ruby_name.to_c9] = klass
        end

        dbg_set = env.debug
        env.debug = false
        object_klass.channel_send(env,
          Primitive::Message.new(:load, [], ["boot/symbol.rb"]),
          CallbackChannel.new {}
        )
        object_klass.channel_send(env,
          Primitive::Message.new(:load, [], ["boot/string.rb"]),
          CallbackChannel.new {}
        )
        object_klass.channel_send(env,
          Primitive::Message.new(:load, [], ["boot.rb"]),
          CallbackChannel.new {}
        )
        env.debug = dbg_set
      end

      def channel_send(cenv, msg, ret)
        case msg.name
        when "compile"
          compile(msg.positional.first)
          ret.channel_send(env, true, InvalidReturnChannel)
        else
          raise "BOOM: Unknown message for loader: #{msg.name}."
        end
      end

      def compile(filename)
        filename = filename.to_c9_str if filename.respond_to?(:to_c9_str)
        env.special_channel[:globals][:"$LOAD_PATH"].each do |path|
          begin
            File.open("#{path}/#{filename}", "r") do |f|
              stream = Channel9::Stream.new
              stream.build do |builder|
                tree = RubyParser.new.parse(f.read)
                tree = [:file, tree]
                compiler = Channel9::Ruby::Compiler.new(builder)
                compiler.transform(tree)
              end
              return stream
            end
          rescue Errno::ENOENT
          end
        end
        raise LoadError, "Could not find #{filename} in $LOAD_PATH"
      end
    end
  end
end