module Kernel
  def nil?
    false
  end

  def ==(other)
    self.equal?(other)
  end

  def eql?(other)
    self.equal?(other)
  end

  def ===(other)
    self.equal?(other)
  end

  def =~(other)
    nil
  end

  def load(name)
    $LOAD_PATH.each {|path|
      if (raw_load("#{path}/#{name}"))
        return true
      end
    }
    raise LoadError, "Could not load library #{name}"
  end

  def require(name)
    begin
      load(name)
    rescue LoadError
      load(name + ".rb")
    end
  end

  def method_missing(name, *args)
    raise NoMethodError, "undefined method `#{name}' for #{to_s}:#{self.class}"
  end

  def puts(*args)
    args.each {|arg|
      if (arg.respond_to?(:each))
        puts(*arg)
      elsif (arg.nil?)
        print("nil\n")
      else
        print arg, "\n"
      end
    }
  end

  def to_tuple_prim
    to_a.to_tuple_prim
  end
  def to_a
    [self]
  end

  def inspect
    to_s
  end
end