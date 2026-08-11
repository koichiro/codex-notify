# frozen_string_literal: true

require_relative 'config_support'
require_relative 'trusted_config_loader'

module CodexNotify
  class EnvSourceLoader
    class Error < StandardError; end

    Source = Struct.new(:kind, :path, :values, keyword_init: true)
    LookupResult = Struct.new(:value, :source, keyword_init: true)

    class SourceSet
      include Enumerable

      def initialize(sources)
        @sources = sources.freeze
      end

      def each(&block)
        @sources.each(&block)
      end

      def lookup(key)
        each do |source|
          value = source.values[key]
          return LookupResult.new(value:, source:) if value && !value.empty?
        end
        nil
      end

      def excluding_kind(kind)
        self.class.new(reject { |source| source.kind == kind })
      end

      def restrict_kind(kind, keys:)
        self.class.new(map do |source|
          next source unless source.kind == kind

          Source.new(kind: source.kind, path: source.path, values: source.values.slice(*keys))
        end)
      end
    end

    include ConfigSupport
    private(*ConfigSupport.instance_methods(false))

    def initialize(legacy_checkout_root: nil, environment: ENV, stderr: $stderr, config_loader: nil)
      @legacy_checkout_root = Pathname(legacy_checkout_root).expand_path if legacy_checkout_root
      @environment = environment
      @stderr = stderr
      @config_loader = config_loader || TrustedConfigLoader.new(environment:, stderr:)
    end

    def load(path: ConfigSupport::DEFAULT_ENV_PATH, explicit: false, config_path: nil)
      process = Source.new(kind: :process, path: nil, values: @environment.to_h)
      files = resolve_env_paths(path, legacy_checkout_root:).map { |env_path| load_file(env_path, explicit:) }
      configs = @config_loader.load(explicit_path: config_path).map do |config|
        Source.new(kind: config.kind, path: config.path, values: config.values)
      end
      explicit_config, default_config = configs.partition { |source| source.kind == :config_explicit }

      ordered = if explicit
                  [process, *explicit_config, *files, *default_config]
                else
                  [process, *explicit_config, *default_config, *files]
                end
      SourceSet.new(ordered)
    end

    private

    attr_reader :legacy_checkout_root

    def load_file(path, explicit:)
      ConfigDiagnostics.warn_if_env_file_insecure(path, stderr: @stderr)
      Source.new(kind: source_kind(path, explicit:), path: path.expand_path, values: Dotenv.parse(path.to_s))
    rescue SystemCallError => e
      raise Error, "could not read env file #{path}: #{e.class}"
    end

    def source_kind(path, explicit:)
      return :explicit if explicit

      return :repository unless legacy_checkout_root

      checkout_env_path = legacy_checkout_root.join(ConfigSupport::DEFAULT_ENV_PATH)
      path.expand_path == checkout_env_path ? :tool : :repository
    end
  end
end
