# frozen_string_literal: true

require 'stringio'
require_relative 'test_helper'

class CodexNotifyEnvironmentIsolationTest < Minitest::Test
  def test_configuration_inputs_are_removed_from_the_test_environment
    inherited_keys = ENV.keys.select { |key| TestEnvironment.configuration_key?(key) }

    assert_empty inherited_keys
    assert_equal TEST_HOME.to_s, ENV.fetch('HOME')
    assert_equal TEST_XDG_CONFIG_HOME.to_s, ENV.fetch('XDG_CONFIG_HOME')
  end

  def test_default_home_dependent_paths_are_inside_the_test_sandbox
    assert_path_inside_test_home(CodexNotify::Config::DEFAULT_SESSIONS_DIR)
    assert_path_inside_test_home(CodexNotify::Config::DEFAULT_OUTBOX_DIR)
    assert_path_inside_test_home(CodexNotify::HookConfig::DEFAULT_STATE_PATH)
  end

  def test_default_configuration_does_not_read_an_env_file_from_the_checkout
    stderr = StringIO.new
    original_parse = Dotenv.method(:parse)
    begin
      replace_dotenv_parse do
        config = CodexNotify::Config.parse_args([], stderr:)
        hook_config = CodexNotify::HookConfig.parse_args([], stderr:)

        assert_nil config.token
        assert_nil config.channel
        assert_nil hook_config.token
        assert_nil hook_config.channel
        assert_equal 'normal', hook_config.mode
      end
    ensure
      restore_dotenv_parse(original_parse)
    end

    refute_includes stderr.string, ROOT.join('.env').to_s
  end

  def test_each_test_runs_from_a_synthetic_working_directory
    working_directory = Pathname(Dir.pwd)

    assert working_directory.to_s.start_with?("#{TEST_WORKING_DIRECTORIES}#{File::SEPARATOR}")
    refute_equal ROOT, working_directory
  end

  private

  def assert_path_inside_test_home(path)
    expanded = Pathname(path).expand_path

    assert expanded.to_s.start_with?("#{TEST_HOME}#{File::SEPARATOR}"),
           "Expected #{expanded} to be inside #{TEST_HOME}"
  end

  def replace_dotenv_parse
    with_silenced_warnings do
      Dotenv.singleton_class.send(:define_method, :parse) do |_path|
        raise 'default configuration attempted to parse an env file outside its synthetic fixture'
      end
    end
    yield
  end

  def restore_dotenv_parse(original_parse)
    with_silenced_warnings do
      Dotenv.singleton_class.send(:define_method, :parse, original_parse)
    end
  end

  def with_silenced_warnings
    original_verbose = $VERBOSE
    $VERBOSE = nil
    yield
  ensure
    $VERBOSE = original_verbose
  end
end
