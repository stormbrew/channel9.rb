module Channel9
  module Ruby
    class Compiler
      attr :builder
      def initialize(builder)
        @builder = builder
        @state = {}
      end

      def with_state(hash)
        begin
          old = @state.dup
          @state.merge!(hash)
          yield
        ensure
          @state = old
        end
      end

      def transform_self()
        builder.frame_get("self")
      end

      def transform_lit(literal)
        builder.push literal
      end
      def transform_str(str)
        transform_const(:String)
        builder.push(Primitive::String.new(str))
        builder.message_new(:new, 0, 1)
        builder.channel_call
        builder.pop        
      end
      def transform_evstr(ev)
        transform(ev)
      end
      def transform_dstr(initial, *strings)
        transform_const(:String)
        strings.reverse.each do |str|
          transform(str)
        end
        if (initial.length > 0)
          transform_str(initial)
          builder.string_new(:to_s_prim, 1 + strings.length)
        else
          builder.string_new(:to_s_prim, strings.length)
        end
        builder.message_new(:new, 0, 1)
        builder.channel_call
        builder.pop
      end
      def transform_array(*items)
        transform_const(:Array)
        items.reverse.each do |item|
          transform(item)
        end
        builder.tuple_new(items.length)
        builder.message_new(:new, 0, 1)
        builder.channel_call
        builder.pop
      end
      def transform_nil()
        builder.push nil.to_c9
      end
      def transform_true()
        builder.push true.to_c9
      end
      def transform_false()
        builder.push false.to_c9
      end

      def transform_while(condition, body, unk)
        begin_label = builder.make_label("while.begin")
        done_label = builder.make_label("while.done")

        builder.set_label(begin_label)
        transform(condition)
        builder.jmp_if_not(done_label)

        transform(body)
        builder.pop

        builder.jmp(begin_label)
        builder.set_label(done_label)
        builder.push(nil.to_c9)
      end

      def transform_if(cond, truthy, falsy)
        falsy_label = builder.make_label("if.falsy")
        done_label = builder.make_label("if.done")

        transform(cond)
        builder.jmp_if_not(falsy_label)

        transform(truthy)
        builder.jmp(done_label)

        builder.set_label(falsy_label)
        if (falsy)
          transform(falsy)
        else
          builder.push(nil)
        end

        builder.set_label(done_label)
      end

      def transform_or(left, right)
        done_label = builder.make_label("or.done")

        transform(left)
        builder.dup_top
        builder.jmp_if(done_label)
        builder.pop
        transform(right)
        builder.set_label(done_label)
      end
      def transform_and(left, right)
        done_label = builder.make_label("and.done")

        transform(left)
        builder.dup_top
        builder.jmp_if_not(done_label)
        builder.pop
        transform(right)
        builder.set_label(done_label)
      end

      def transform_when(comparisons, body)
        found_label = builder.make_label("when.found")
        next_label = builder.make_label("when.next")
        done_label = @state[:case_done]

        comparisons = comparisons.dup
        comparisons.shift

        comparisons.each do |cmp|
          builder.dup_top # value from enclosing case.
          transform(cmp)
          builder.swap
          builder.message_new(:===, 0, 1)
          builder.channel_call
          builder.pop
          builder.jmp_if(found_label)
          builder.jmp(next_label)
        end
        builder.set_label(found_label)
        builder.pop # value not needed anymore
        if (body.nil?)
          transform_nil
        else
          transform(body)
        end
        builder.jmp(done_label)
        builder.set_label(next_label)
      end

      def transform_case(value, *cases)
        else_case = cases.pop
        done_label = builder.make_label("case.done")

        transform(value)
        with_state(:case_done => done_label) do
          cases.each do |case_i|
            transform(case_i)
          end
        end

        builder.pop # value not needed anymore.
        if (else_case.nil?)
          builder.push(nil)
        else
          transform(else_case)
        end
        
        builder.set_label(done_label)
      end

      def transform_args(*args)
        defargs = []
        splatarg = nil
        if (args.length > 0)
          if (!args.last.is_a?(Symbol))
            defargs = args.pop.dup
            defargs.shift # get rid of the :block lead
          end
          if (match = args.last.to_s.match(%r{^\*(.+)}))
            splatarg = match[1].to_sym
            args.pop 
          end
        end

        if (defargs.length == 0)
          builder.message_unpack(args.length, splatarg ? 1 : 0, 0)
          args.each do |arg|
            builder.local_set(arg)
          end
        else
          must_have = args.length - defargs.length
          argdone_label = builder.make_label("args.done")
          defarg_labels = (0...defargs.length).collect {|i| builder.make_label("args.default.#{i}") }
          
          builder.message_count
          builder.frame_set("arg.count")
          builder.message_unpack(args.length, splatarg ? 1 : 0, 0)
          i = 0
          must_have.times do
            builder.local_set(args[i])
            i += 1
          end

          while (i < args.length)
            builder.frame_get("arg.count")
            builder.is(i)
            builder.jmp_if(defarg_labels[i-must_have])
            builder.local_set(args[i])
            i += 1
          end
          builder.jmp(argdone_label)

          defarg_labels.each do |defarg_label|
            builder.set_label(defarg_label)
            builder.pop # undef padding value
            transform(defargs.shift)
            builder.pop # result of assignment
          end

          builder.set_label(argdone_label)
        end
        if (splatarg)
          transform_const(:Array)
          builder.swap
          builder.message_new(:new, 0, 1)
          builder.channel_call
          builder.pop
          builder.local_set(splatarg)
        end
        builder.pop
      end

      def transform_scope(block = nil)
        if (block.nil?)
          transform_nil()
        else
          transform(block)
        end
      end

      def need_return_unwind(code)
        # to determine if the function body
        # requires a return unwind handler, we
        # compile the body just to find out if
        # there's a return inside an ensure
        # or a block. If there is, we know 
        # the function will need an unwind
        # handler.
        stream = Stream.new
        builder = Builder.new(stream)
        compiler = Compiler.new(builder)
        need_info = [false]
        compiler.with_state(:need_long_return => need_info) do
          compiler.transform(code)
          return need_info[0]
        end
      end

      def transform_defn(name, args, code)
        transform_defs(nil, name, args, code)
      end

      def transform_defs(on, name, args, code)
        label_prefix = "method:#{name}"
        method_label = builder.make_label(label_prefix + ".body")
        method_lret_label = builder.make_label(label_prefix + ".long_return")
        method_lret_pass = builder.make_label(label_prefix + ".long_return_pass")
        method_done_label = builder.make_label(label_prefix + ".done")

        builder.jmp(method_done_label)
        builder.set_label(method_label)
        builder.local_clean_scope
        builder.frame_set("return")
        
        if (nru = need_return_unwind(code))
          builder.channel_special(:unwinder)
          builder.channel_new(method_lret_label)
          builder.channel_call
          builder.pop
          builder.pop
        end
        
        builder.message_sys_unpack(3)
        builder.frame_set("self")
        builder.frame_set("super")
        builder.frame_set("yield")
        transform(args)

        with_state(:has_long_return => nru, :name => name) do
          transform(code)
        end

        builder.frame_get("return")
        builder.swap
        builder.channel_ret

        if (nru)
          builder.set_label(method_lret_label)
          # stack is SP -> ret -> unwind_message
          # we want to see if the unwind_message is 
          # our return message. If so, we want to return from
          # this method. Otherwise, just move on to the next
          # unwind handler.
          builder.pop # -> unwind_message
          builder.message_name # -> name -> um
          builder.is(:long_return) # -> is -> um
          builder.jmp_if_not(method_lret_pass) # -> um
          builder.dup # -> um -> um
          builder.message_unpack(1, 0, 0) # -> return_chan -> um
          builder.frame_get("return") # -> lvar_return -> return_chan -> um
          builder.is_eq # -> is -> um
          builder.jmp_if_not(method_lret_pass) # -> um
          builder.message_unpack(2, 0, 0) # -> return_chan -> ret_val -> um
          builder.swap # -> ret_val -> return_chan -> um
          builder.channel_ret

          builder.set_label(method_lret_pass) # (from jmps above) -> um
          builder.channel_special(:unwinder) # -> unwinder -> um
          builder.swap # -> um -> unwinder
          builder.channel_ret
        end
        builder.set_label(method_done_label)
        if (on.nil?)
          builder.frame_get("self")
        else
          transform(on)
        end
        builder.push(name)
        builder.channel_new(method_label)
        builder.message_new(on.nil? ? :define_method : :define_singleton_method, 0, 2)
        builder.channel_call
        builder.pop
      end

      def transform_super(*args)
        builder.frame_get("super")
        args.each do |arg|
          transform(arg)
        end
        builder.message_new(@state[:name], 0, args.length)
        builder.channel_call
        builder.pop
      end

      def transform_zsuper
        builder.frame_get("super")
        builder.push(nil)
        builder.channel_call
        builder.pop
      end

      def transform_yield(*args)
        builder.frame_get("yield")

        args.each do |arg|
          transform(arg)
        end
        builder.message_new(:call, 0, args.length)
        builder.channel_call
        builder.pop
      end

      def transform_return(val = nil)
        if (@state[:ensure] || @state[:block])
          @state[:need_long_return][0] = true if @state[:need_long_return]
          builder.channel_special(:unwinder)
          builder.frame_get("return")
          if (val)
            transform(val)
          else
            transform_nil
          end
          builder.message_new(:long_return, 0, 2)
          builder.channel_ret
        else
          builder.frame_get("return")
          if (val)
            transform(val)
          else
            transform_nil
          end
          builder.channel_ret
        end
      end

      def transform_class(name, superclass, body)
        label_prefix = "Class:#{name}"
        body_label = builder.make_label(label_prefix + ".body")
        done_label = builder.make_label(label_prefix + ".done")

        # See if it's already there
        builder.channel_special(:Object)
        builder.push(name)
        builder.message_new(:const_get, 0, 1)
        builder.channel_call
        builder.pop
        builder.dup_top
        builder.jmp_if(done_label)

        # If it's not, make a new class and set it.
        builder.pop
        builder.channel_special(:Object)
        builder.push(name)
        
        builder.channel_special(:Class)
        if (superclass.nil?)
          builder.channel_special(:Object)
        else
          transform(superclass)
        end
        builder.push(name)
        builder.message_new(:new, 0, 2)
        builder.channel_call
        builder.pop

        builder.message_new(:const_set, 0, 2)
        builder.channel_call
        builder.pop
        builder.jmp(done_label)

        builder.set_label(body_label)
        builder.local_clean_scope
        builder.frame_set("return")
        builder.message_sys_unpack(1)
        builder.frame_set("self")
        builder.pop
        transform(body)
        builder.frame_get("return")
        builder.swap
        builder.channel_ret

        builder.set_label(done_label)

        builder.dup_top
        builder.push(:__body__)
        builder.channel_new(body_label)
        builder.message_new(:define_singleton_method, 0, 2)
        builder.channel_call
        builder.pop
        builder.pop

        builder.message_new(:__body__, 0, 0)
        builder.channel_call
        builder.pop
      end

      def transform_module(name, body)
        label_prefix = "Module:#{name}"
        body_label = builder.make_label(label_prefix + ".body")
        done_label = builder.make_label(label_prefix + ".done")

        # See if it's already there
        builder.channel_special(:Object)
        builder.push(name)
        builder.message_new(:const_get, 0, 1)
        builder.channel_call
        builder.pop
        builder.dup_top
        builder.jmp_if(done_label)

        # If it's not, make a new module and set it.
        builder.pop
        builder.channel_special(:Object)
        builder.push(name)
        
        builder.channel_special(:Module)
        builder.push(name)
        builder.message_new(:new, 0, 1)
        builder.channel_call
        builder.pop

        builder.message_new(:const_set, 0, 2)
        builder.channel_call
        builder.pop
        builder.jmp(done_label)

        builder.set_label(body_label)
        builder.local_clean_scope
        builder.frame_set("return")
        builder.message_sys_unpack(1)
        builder.frame_set("self")
        builder.pop
        transform(body)
        builder.frame_get("return")
        builder.swap
        builder.channel_ret

        builder.set_label(done_label)

        builder.dup_top
        builder.push(:__body__)
        builder.channel_new(body_label)
        builder.message_new(:define_singleton_method, 0, 2)
        builder.channel_call
        builder.pop
        builder.pop

        builder.message_new(:__body__, 0, 0)
        builder.channel_call
        builder.pop
      end

      def transform_cdecl(name, val)
        # TODO: Make this look up in full proper lexical scope.
        # Currently just assumes Object is the static lexical scope
        # at all times.
        builder.channel_special(:Object)
        builder.push(name)
        transform(val)
        builder.message_new(:const_set, 0, 2)
        builder.channel_call
        builder.pop
      end
      def transform_const(name)
        # TODO: Make this look up in full proper lexical scope.
        # Currently just assumes Object is the static lexical scope
        # at all times.
        builder.channel_special(:Object)
        builder.push(name)
        builder.message_new(:const_get, 0, 1)
        builder.channel_call
        builder.pop
      end

      # If given a nil value, assumes the rhs is
      # already on the stack.
      def transform_lasgn(name, val = nil)
        transform(val) if !val.nil?
        builder.dup_top
        builder.local_set(name)
      end
      def transform_lvar(name)
        builder.local_get(name)
      end

      def transform_gasgn(name, val = nil)
        if (val.nil?)
          builder.channel_special(:Object)
          builder.swap
          builder.push(name)
          builder.swap
        else
          builder.channel_special(:Object)
          builder.push(name)
          transform(val)
        end
        builder.message_new(:global_set, 0, 2)
        builder.channel_call
        builder.pop
      end
      def transform_gvar(name)
        builder.channel_special(:Object)
        builder.push(name)
        builder.message_new(:global_get, 0, 1)
        builder.channel_call
        builder.pop
      end

      def transform_iasgn(name, val = nil)
        if (val.nil?)
          builder.frame_get("self")
          builder.swap
          builder.push(name)
          builder.swap
        else
          builder.frame_get("self")
          builder.push(name)
          transform(val)
        end
        builder.message_new(:instance_variable_set, 0, 2)
        builder.channel_call
        builder.pop
      end
      def transform_ivar(name)
        builder.frame_get("self")
        builder.push(name)
        builder.message_new(:instance_variable_get, 0, 1)
        builder.channel_call
        builder.pop
      end

      def transform_block(*lines)
        count = lines.length
        lines.each_with_index do |line, idx|
          transform(line)
          builder.pop if (count != idx + 1)
        end
      end

      def has_splat(arglist)
        arglist.each_with_index do |arg, idx|
          return idx if arg.first == :splat
        end
        return false
      end

      def transform_call(target, method, arglist, has_iter = false)
        if (target.nil?)
          transform_self()
        else
          transform(target)
        end

        if (has_iter)
          # If we were called with has_iter == true, an iterator
          # will be sitting on the stack, and we want to swap it in
          # to first sysarg position.
          builder.swap
        end

        _, *arglist = arglist
        if (first_splat = has_splat(arglist))
          i = 0
          while (i < first_splat)
            transform(arglist.shift)
            i += 1
          end
          builder.message_new(method.to_c9, has_iter ? 1 : 0, i)
          transform(arglist.shift[1])
          builder.message_new(:to_tuple_prim, 0, 0)
          builder.channel_call
          builder.pop
          builder.message_splat
        else
          arglist.each do |arg|
            transform(arg)
          end

          builder.message_new(method.to_c9, has_iter ? 1 : 0, arglist.length)
        end
        builder.channel_call
        builder.pop
      end

      def transform_attrasgn(target, method, arglist)
        transform_call(target, method, arglist)
      end

      # The sexp for this is weird. It embeds the call into
      # the iterator, so we build the iterator and then push it
      # onto the stack, then flag the upcoming call sexp so that it
      # swaps it in to the correct place.
      def transform_iter(call, args, block = nil)
        call = call.dup
        call << true

        label_prefix = builder.make_label("Iter:#{call[2]}")
        body_label = label_prefix + ".body"
        done_label = label_prefix + ".done"

        builder.jmp(done_label)

        builder.set_label(body_label)
        builder.frame_set(label_prefix + ".ret")
        if (args.nil?)
          # no args, pop the message off the stack.
          builder.pop
        else
          if (args[0] == :lasgn || args[0] == :gasgn)
            # Ruby's behaviour on a single arg block is ugly.
            # If it takes one argument, but is given multiple,
            # it's as if it were a single arg splat. Otherwise,
            # it's like a normal method invocation.
            builder.message_count
            builder.is_not(1.to_c9)
            builder.jmp_if(label_prefix + ".splatify")
            builder.message_unpack(1, 0, 0)
            builder.jmp(label_prefix + ".done_unpack")
            builder.set_label(label_prefix + ".splatify")
            builder.message_unpack(0, 1, 0)
            builder.set_label(label_prefix + ".done_unpack")
          else
            builder.message_unpack(0, 1, 0) # splat it all for the masgn
          end
          transform(args) # comes in as an lasgn or masgn
          builder.pop
          builder.pop
        end

        if (block.nil?)
          transform_nil()
        else
          with_state(:block => true) do
            transform(block)
          end
        end

        builder.frame_get(label_prefix + ".ret")
        builder.swap
        builder.channel_ret

        builder.set_label(done_label)

        builder.channel_new(body_label)

        transform(call)
      end

      def transform_resbody(comparisons, body)
        found_label = builder.make_label("resbody.found")
        next_label = builder.make_label("resbody.next")
        done_label = @state[:rescue_done]

        comparisons = comparisons.dup
        comparisons.shift

        err_assign = nil
        if (comparisons.last && comparisons.last[0] == :lasgn)
          err_assign = comparisons.pop[1]
        end          

        comparisons.each do |cmp|
          builder.dup_top # value from enclosing case.
          transform(cmp)
          builder.swap
          builder.message_new(:===, 0, 1)
          builder.channel_call
          builder.pop
          builder.jmp_if(found_label)
          builder.jmp(next_label)
        end
        builder.set_label(found_label)
        if (err_assign)
          builder.local_set(err_assign)
        else
          builder.pop
        end

        transform(body)
        builder.jmp(done_label)
        builder.set_label(next_label)
      end

      def transform_rescue(try, *handlers)
        try_label = builder.make_label("try")
        rescue_label = builder.make_label("rescue")
        not_raise_label = builder.make_label("rescue.not_raise")
        done_label = builder.make_label("rescue.done")

        # Set the unwinder.
        builder.channel_special(:unwinder)
        builder.channel_new(rescue_label)
        builder.channel_call
        builder.pop
        builder.pop

        # do the work
        transform(try)

        # if we get here, unset the unwinder and jump to the end.
        builder.channel_special(:unwinder)
        builder.push(nil)
        builder.channel_call
        builder.pop
        builder.pop
        builder.jmp(done_label)

        builder.set_label(rescue_label)

        # pop the return handler and check the message to see
        # if this is an error or if we should just call the next
        # unwinder.
        builder.pop
        builder.message_name
        builder.is(:raise.to_c9)
        builder.jmp_if_not(not_raise_label)

        builder.message_unpack(1,0,0)

        with_state(:rescue_done => done_label) do
          handlers.each do |handler|
            transform(handler)
          end
        end

        builder.pop
        builder.set_label(not_raise_label)
        builder.channel_special(:unwinder)
        builder.swap
        builder.channel_ret

        builder.set_label(done_label)
        # get rid of the unwind message.
        builder.swap
        builder.pop
      end

      def transform_ensure(body, ens)
        ens_label = builder.make_label("ensure")
        done_label = builder.make_label("ensure.done")

        builder.channel_special(:unwinder)
        builder.channel_new(ens_label)
        builder.channel_call
        builder.pop
        builder.pop

        with_state(:ensure => ens_label) do
          transform(body)
        end
        # if the body executes correctly, we push
        # nil onto the stack so that the ensure 'channel'
        # picks that up as the return path. If it
        # does, when it goes to return, it will just
        # jmp to the done label rather than calling
        # the next handler.
        builder.push(nil.to_c9)
        # clear the unwinder
        builder.channel_special(:unwinder)
        builder.push(nil)
        builder.channel_call
        builder.pop
        builder.pop

        builder.set_label(ens_label)

        # run the ensure block
        transform(ens)
        builder.pop

        # if we came here via a call (non-nil return path),
        # pass on to the next unwind handler rather than
        # leaving by the done label.
        builder.jmp_if_not(done_label)
        builder.channel_special(:unwinder)
        builder.swap
        builder.channel_ret

        builder.set_label(done_label)
      end

      def transform_file(body)
        builder.frame_set("return")
        builder.frame_set("self")
        if (!body.nil?)
          transform(body)
        else
          transform_nil
        end
        builder.frame_get("return")
        builder.swap
        builder.channel_ret
      end

      def method_missing(name, *args)
        if (match = name.to_s.match(%r{^transform_(.+)$}))
          puts "Unknown parse tree #{match[1]}:"
          pp args
        end
        super
      end

      def transform(tree)
        name, *info = tree
        send(:"transform_#{name}", *info)
      end
    end
  end
end