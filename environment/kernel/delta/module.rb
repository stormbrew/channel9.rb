class Module
  def attr_reader(*names)
    names.each do |name|
      define_method(name) do
        __c9_ivar_set__(:"@#{name}")
      end
    end
  end
  def attr_writer(*names)
    names.each do |name|
      define_method(:"#{name}=") do |val|
        __c9_ivar_set__(:"@#{name}", val)
      end
    end
  end
  def attr_accessor(*names)
    attr_reader(*names)
    attr_writer(*names)
  end
  def attr(name, write = false)
    attr_reader(name)
    attr_writer(name) if write
  end

  def class_eval(s = nil, &block)
    if (s)
      block = Channel9.compile_string(:eval, s, "__eval__", 1)
      if (!block)
        raise ParseError
      end
    end
    instance_eval(&block)
  end
  alias_method :module_eval, :class_eval

  def module_function(*names)
    # TODO: Implement.
  end

  def public_class_method(*names)
    # TODO: Implement.
  end
  def protected_class_method(*names)
    # TODO: Implement.
  end
  def private_class_method(*names)
    # TODO: Implement.
  end
  def public(*names)
    # TODO: Implement.
  end
  def private(*names)
    # TODO: Implement.
  end
  def protected(*names)
    # TODO: Implement.
  end
  def module_eval(ev)
    # TODO: Implement (how?).
  end
end