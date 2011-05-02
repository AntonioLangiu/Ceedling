require 'defaults'
require 'constants'
require 'file_path_utils'
require 'deep_merge'



class Configurator

  attr_reader :project_config_hash, :script_plugins, :rake_plugins
  attr_accessor :project_logging, :project_debug, :project_verbosity, :sanity_checks
  
  constructor(:configurator_setup, :configurator_builder, :configurator_plugins, :cmock_builder, :yaml_wrapper, :system_wrapper) do
    @project_logging   = false
    @project_debug     = false
    @project_verbosity = Verbosity::NORMAL
    @sanity_checks     = TestResultsSanityChecks::NORMAL
  end
  
  def setup
    # special copy of cmock config to provide to cmock for construction
    @cmock_config_hash = {}

    # note: project_config_hash is an instance variable so constants and accessors created
    # in eval() statements in build() have something of proper scope and persistence to reference
    @project_config_hash = {}
    @project_config_hash_backup = {}
    
    @script_plugins = []
    @rake_plugins   = []
  end
  
  
  def replace_flattened_config(config)
    @project_config_hash.merge!(config)
    @configurator_setup.build_constants_and_accessors(@project_config_hash, binding())
  end

  
  def store_config
    @project_config_hash_backup = @project_config_hash.clone
  end
  
  
  def restore_config
    @project_config_hash = @project_config_hash_backup
    @configurator_setup.build_constants_and_accessors(@project_config_hash, binding())
  end


  def reset_defaults(config)
    [:test_compiler,
     :test_linker,
     :test_fixture,
     :test_includes_preprocessor,
     :test_file_preprocessor,
     :test_dependencies_generator,
     :release_compiler,
     :release_assembler,
     :release_linker,
     :release_dependencies_generator].each do |tool|
      config[:tools].delete(tool) if (not (config[:tools][tool].nil?))
    end
  end


  def populate_defaults(config)
    new_config = DEFAULT_CEEDLING_CONFIG.deep_clone
    new_config.deep_merge!(config)
    config.replace(new_config)

    @configurator_builder.populate_defaults( config, DEFAULT_TOOLS_TEST )
    @configurator_builder.populate_defaults( config, DEFAULT_TOOLS_TEST_PREPROCESSORS ) if (config[:project][:use_test_preprocessor])
    @configurator_builder.populate_defaults( config, DEFAULT_TOOLS_TEST_DEPENDENCIES )  if (config[:project][:use_auxiliary_dependencies])
    
    @configurator_builder.populate_defaults( config, DEFAULT_TOOLS_RELEASE )              if (config[:project][:release_build])
    @configurator_builder.populate_defaults( config, DEFAULT_TOOLS_RELEASE_ASSEMBLER )    if (config[:project][:release_build] and config[:release_build][:use_assembly])
    @configurator_builder.populate_defaults( config, DEFAULT_TOOLS_RELEASE_DEPENDENCIES ) if (config[:project][:release_build] and config[:project][:use_auxiliary_dependencies])
  end
  
  
  def populate_cmock_defaults(config)
    # cmock has its own internal defaults handling, but we need to set these specific values
    # so they're present for the build environment to access;
    # note: these need to end up in the hash given to initialize cmock for this to be successful
    cmock = config[:cmock]

    # yes, we're duplicating the default mock_prefix in cmock, but it's because we need CMOCK_MOCK_PREFIX always available in Ceedling's environment
    cmock[:mock_prefix] = 'Mock' if (cmock[:mock_prefix].nil?)
    
    # just because strict ordering is the way to go
    cmock[:enforce_strict_ordering] = true                                                  if (cmock[:enforce_strict_ordering].nil?)
    
    cmock[:mock_path] = File.join(config[:project][:build_root], TESTS_BASE_PATH, 'mocks')  if (cmock[:mock_path].nil?)
    cmock[:verbosity] = @project_verbosity                                                  if (cmock[:verbosity].nil?)

    cmock[:plugins] = []                             if (cmock[:plugins].nil?)
    cmock[:plugins].map! { |plugin| plugin.to_sym }
    cmock[:plugins] << (:cexception)                 if (!cmock[:plugins].include?(:cexception) and (config[:project][:use_exceptions]))
    cmock[:plugins].uniq!

    cmock[:unity_helper] = false                     if (cmock[:unity_helper].nil?)
    
    if (cmock[:unity_helper])
      cmock[:includes] << File.basename(cmock[:unity_helper])
      cmock[:includes].uniq!
    end

    @runner_config = cmock
    @cmock_builder.manufacture(cmock)
  end
  
  def get_runner_config
    @runner_config
  end

  # grab tool names from yaml and insert into tool structures so available for error messages
  # set up default values
  def tools_setup(config)
    config[:tools].each_key do |name|
      tool = config[:tools][name]

      # populate name if not given      
      tool[:name] = name.to_s if (tool[:name].nil?)

      # populate stderr redirect option
      tool[:stderr_redirect] = StdErrRedirect::NONE if (tool[:stderr_redirect].nil?)

      # populate background execution option
      tool[:background_exec] = BackgroundExec::NONE if (tool[:background_exec].nil?)

      # populate optional option to control verification of executable in search paths
      tool[:optional] = false if (tool[:optional].nil?)
    end
  end
  
  def tools_supplement_arguments(config)
    config[:tools].each_key do |name|
      tool = @project_config_hash[('tools_' + name.to_s).to_sym]

      # smoosh in extra arguments if specified at top-level of config (useful for plugins & default gcc tools)
      # arguments are squirted in at beginning of list
      top_level_tool = ('tool_' + name.to_s).to_sym
      if (not config[top_level_tool].nil?)
         # adding and flattening is not a good idea: might over-flatten if there's array nesting in tool args
         # use _with_index to preserve order
         config[top_level_tool][:arguments].each_with_index { |arg, index| tool[:arguments].insert( index, arg ) }
      end
    end
  end

  def find_and_merge_plugins(config)
    # plugins must be loaded before generic path evaluation & magic that happen later: perform path magic here as discrete step
    config[:plugins][:load_paths].each do |path|
      path.replace(@system_wrapper.module_eval(path)) if (path =~ RUBY_STRING_REPLACEMENT_PATTERN)
      FilePathUtils::standardize(path)
    end
    
    paths_hash = @configurator_plugins.add_load_paths(config)
  
    @rake_plugins   = @configurator_plugins.find_rake_plugins(config)
    @script_plugins = @configurator_plugins.find_script_plugins(config)
    config_plugins  = @configurator_plugins.find_config_plugins(config)
    plugin_defaults = @configurator_plugins.find_plugin_defaults(config)
    
    config_plugins.each do |plugin|
      config.deep_merge( @yaml_wrapper.load(plugin) )
    end
    
    plugin_defaults.each do |defaults|
      @configurator_builder.populate_defaults( config, @yaml_wrapper.load(defaults) )
    end
    
    # special plugin setting for results printing
    config[:plugins][:display_raw_test_results] = true if (config[:plugins][:display_raw_test_results].nil?)
    
    paths_hash.each_pair { |name, path| config[:plugins][name] = path }
  end

  
  def eval_environment_variables(config)
    config[:environment].each do |hash|
      key   = hash.keys[0]
      value = hash[key]
      items = []
            
      interstitial = ((key == :path) ? File::PATH_SEPARATOR : '')
      items = ((value.class == Array) ? hash[key] : [value])
      
      items.map { |item| item.replace( @system_wrapper.module_eval( item ) ) if (item =~ RUBY_STRING_REPLACEMENT_PATTERN) }
      hash[key] = items.join( interstitial )
      
      @system_wrapper.env_set( key.to_s.upcase, hash[key] )
    end
  end

  
  def eval_paths(config)
    # [:plugins]:load_paths] already handled
    individual_paths = [
      config[:project][:build_root],
      config[:project][:options_paths]]
      
    individual_paths.flatten.each do |path|
      path.replace(@system_wrapper.module_eval(path)) if (path =~ RUBY_STRING_REPLACEMENT_PATTERN)
    end
  
    config[:paths].each_pair do |key, list|
      list.each { |path_entry| path_entry.replace(@system_wrapper.module_eval(path_entry)) if (path_entry =~ RUBY_STRING_REPLACEMENT_PATTERN) }
    end    
  end
  
  
  def standardize_paths(config)
    # [:plugins]:load_paths] already handled
    individual_paths = [
      config[:project][:build_root],
      config[:project][:options_paths],
      config[:cmock][:mock_path]] # cmock path in case it was explicitly set in config

    individual_paths.flatten.each { |path| FilePathUtils::standardize(path) }

    config[:paths].each_pair do |key, list|
      list.each{|path| FilePathUtils::standardize(path)}
      # ensure that list is an array (i.e. handle case of list being a single string)
      config[:paths][key] = [list].flatten
    end

    config[:tools].each_pair do |key, tool_config|
      FilePathUtils::standardize(tool_config[:executable])
    end    
  end


  def validate(config)
    # collect felonies and go straight to jail
    raise if (not @configurator_setup.validate_required_sections( config ))
    
    # collect all misdemeanors, everybody on probation
    blotter = []
    blotter << @configurator_setup.validate_required_section_values( config )
    blotter << @configurator_setup.validate_paths( config )
    blotter << @configurator_setup.validate_tools( config )
    blotter << @configurator_setup.validate_plugins( config )
    
    raise if (blotter.include?( false ))
  end
    
  
  # create constants and accessors (attached to this object) from given hash
  def build(config, *keys)
    # create flattened & expanded configuration hash
    built_config = @configurator_setup.build_project_config( config, @configurator_builder.flattenify( config ) )
    
    @project_config_hash = built_config.clone
    store_config()

    @configurator_setup.build_constants_and_accessors(built_config, binding())
    
    # top-level keys disappear when we flatten, so create global constants & accessors to any specified keys
    keys.each do |key|
      hash = { key => config[key] }
      @configurator_setup.build_constants_and_accessors(hash, binding())      
    end
  end


  # add to constants and accessors as post build step
  def build_supplement(config_base, config_more)
    # merge in our post-build additions to base configuration hash
    config_base.deep_merge!( config_more )

    # flatten our addition hash
    config_more_flattened = @configurator_builder.flattenify( config_more )
    
    # merge our flattened hash with built hash from previous build
    @project_config_hash.deep_merge!( config_more_flattened )
    store_config()

    # create more constants and accessors
    @configurator_setup.build_constants_and_accessors(config_more_flattened, binding())
    
    # recreate constants & update accessors with new merged, base values
    config_more.keys.each do |key|
      hash = { key => config_base[key] }
      @configurator_setup.build_constants_and_accessors(hash, binding())
    end
  end
    
  
  def insert_rake_plugins(plugins)
    plugins.each do |plugin|
      @project_config_hash[:project_rakefile_component_files] << plugin
    end
  end
  
end
