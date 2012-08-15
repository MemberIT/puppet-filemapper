require 'puppet/util/filetype'

# Forward declaration
module PuppetX; end

module PuppetX::FileMapper

  def create
    # This was ripped off from parsedfile
    # Given a new provider, populate the property hash. If the associated
    # resource has a specific 'should' value then use that. If no value was
    # explicitly set, then use the default value supplied by the type.
    [@resource.class.validproperties, resource_type.parameters].flatten.each do |property|
      if value = @resource.should(property)
        @property_hash[property] = value
      end
    end

    # FIXME This is a hack. The common convention is to use :name as the
    # namevar and use it as a property, but treat it as a param. If this is
    # treated as a property then it needs to be copied in.
    @property_hash[:name] = @resource.name

    self.class.dirty_resource!(self)
  end

  def exists?
    @property_hash[:ensure] and @property_hash[:ensure] == :present
  end

  def destroy
    @property_hash[:ensure] = :absent
    self.class.dirty_resource!(self)
  end

  # Delegate flush functionality to the class
  def flush
    self.class.flush
  end

  # If a property is given a name that is also a name as a method, the
  # existing method will stomp on the method generated by
  # mk_resource_methods. The property method allows for disambiguating this.
  def property(name)
    @property_hash[name]
  end

  def self.included(klass)
    klass.extend PuppetX::FileMapper::ClassMethods
    klass.mk_resource_methods
    klass.initvars
  end

  module ClassMethods

    attr_reader :failed

    def initvars
      # Mapped_files: [Hash<filepath => Hash<:dirty => Bool, :filetype => Filetype>>]
      @mapped_files = Hash.new {|h, k| h[k] = {}}
      @failed       = false
    end

    # Returns all instances of the provider using this mixin.
    #
    # @return [Array<Puppet::Provider>]
    def instances
      provider_hashes = load_all_providers_from_disk

      provider_hashes.map do |h|
        h.merge!({:provider => self.name})
        new(h)
      end

    rescue
      # If something failed while loading instances, mark the provider class
      # as failed and pass the exception along
      @failed = true
      raise
    end

    # Validate that the required methods are available.
    #
    # @raise Puppet::DevError if an expected method is unavailable
    def validate_class!
      [:target_files, :parse_file].each do |method|
        unless self.respond_to? method
          raise Puppet::DevError, "#{self.name} has not implemented `self.#{method}`"
        end
      end
    end

    # Reads all files from disk and returns an array of hashes representing
    # provider instances.
    #
    # @return [Array<Hash<String, Hash<Symbol, Object>>>]
    #   An array containing a set of hashes, keyed with a file path and values
    #   being a hash containg the state of the file and the filetype associated
    #   with it.
    #
    def load_all_providers_from_disk
      validate_class!

      # Retrieve a list of files to fetch, and cache a copy of a filetype
      # for each one
      target_files.each do |file|
        @mapped_files[file][:filetype] = Puppet::Util::FileType.filetype(:flat).new(file)
        @mapped_files[file][:dirty]    = false
      end

      # Read and parse each file.
      provider_hashes = []
      @mapped_files.each_pair do |filename, file_attrs|
        arr = parse_file(filename, file_attrs[:filetype].read)
        provider_hashes.concat arr
      end

      provider_hashes
    end

    # Match up all resources that have existing providers.
    #
    # Pass over all provider instances, and see if there is a resource with the
    # same namevar as a provider instance. If such a resource exists, set the
    # provider field of that resource to the existing provider.
    #
    # This is a hook method that will be called by Puppet::Transaction#prefetch
    #
    # @param [Hash<String, Puppet::Resource>] resources
    def prefetch(resources = {})

      # generate hash of {provider_name => provider}
      providers = instances.inject({}) do |hash, instance|
        hash[instance.name] = instance
        hash
      end

      # For each prefetched resource, try to match it to a provider
      resources.each_pair do |resource_name, resource|
        if provider = providers[resource_name]
          resource.provider = provider
        end
      end

      nil
    end

    # Given a provider that had a property changed, locate the file that
    # this provider maps to and mark it as dirty
    #
    # @param [Puppet::Resource]
    def dirty_resource!(resource)
      dirty_file = self.select_file(resource)
      @mapped_files[dirty_file][:dirty] = true
    end

    # Generate attr_accessors for the properties, and have them mark the file
    # as modified if an attr_writer is called.
    # This is basically ripped off from ParsedFile
    def mk_resource_methods
      [resource_type.validproperties, resource_type.parameters].flatten.each do |attr|
        attr = symbolize(attr)

        # Generate the attr_reader method
        define_method(attr) do
          if @property_hash[attr]
            @property_hash[attr]
          elsif defined? @resource
            @resource.should(attr)
          end
        end

        # Generate the attr_writer and have it mark the resource as dirty when called
        define_method("#{attr}=") do |val|
          @property_hash[attr] = val
          self.class.dirty_resource!(self)
        end
      end
    end
  end
end
