# frozen_string_literal: true

require_relative 'config_support'

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

    def initialize(app_root: ConfigSupport::APP_ROOT, environment: ENV, stderr: $stderr)
      @app_root = Pathname(app_root).expand_path
      @environment = environment
      @stderr = stderr
    end

    def load(path: ConfigSupport::DEFAULT_ENV_PATH, explicit: false)
      process = Source.new(kind: :process, path: nil, values: @environment.to_h)
      files = resolve_env_paths(path).map { |env_path| load_file(env_path, explicit:) }
      SourceSet.new([process, *files])
    end

    private

    attr_reader :app_root

    def load_file(path, explicit:)
      ConfigDiagnostics.warn_if_env_file_insecure(path, stderr: @stderr)
      Source.new(kind: source_kind(path, explicit:), path: path.expand_path, values: Dotenv.parse(path.to_s))
    rescue SystemCallError => e
      raise Error, "could not read env file #{path}: #{e.class}"
    end

    def source_kind(path, explicit:)
      return :explicit if explicit

      tool_env_path = app_root.join(ConfigSupport::DEFAULT_ENV_PATH).expand_path
      path.expand_path == tool_env_path ? :tool : :repository
    end
  end
end
