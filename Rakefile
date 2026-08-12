# frozen_string_literal: true

require 'bundler/setup'
require 'bundler/gem_helper'
require 'rbconfig'
require 'rubygems/package'
require 'rubygems/package_task'
require 'rake/testtask'

gemspec_path = File.expand_path('codex-notify.gemspec', __dir__)
gemspec = Gem::Specification.load(gemspec_path)
raise 'failed to load codex-notify.gemspec' unless gemspec

Gem::PackageTask.new(gemspec).define
Rake::Task[File.join('pkg', gemspec.file_name)].enhance([gemspec_path])

Bundler::GemHelper.install_tasks(name: gemspec.name)

namespace :release do
  desc 'Require the approved GitHub Actions release context'
  task :guard_environment do
    expected_workflow = %r{\Akoichiro/codex-notify/\.github/workflows/release\.yml@refs/heads/main\z}
    release_version = ENV.fetch('RELEASE_VERSION', '')
    valid_context = ENV['GITHUB_ACTIONS'] == 'true' &&
                    ENV['GITHUB_EVENT_NAME'] == 'workflow_dispatch' &&
                    ENV['GITHUB_REF'] == 'refs/heads/main' &&
                    ENV.fetch('GITHUB_WORKFLOW_REF', '').match?(expected_workflow) &&
                    release_version == gemspec.version.to_s

    raise 'release is permitted only from the approved release.yml workflow on main' unless valid_context
  end
end

Rake::Task['release:guard_clean'].enhance(['release:guard_environment'])

desc 'Build the gem and print its packaged file list'
task 'package:contents' => :gem do
  package_path = File.join('pkg', "#{gemspec.full_name}.gem")
  Gem::Package.new(package_path.to_s).contents.sort.each { |path| puts path }
end

desc 'Build, inspect, install, and exercise the gem outside the checkout'
task 'package:verify' => :gem do
  package_path = File.expand_path(File.join('pkg', gemspec.file_name), __dir__)
  verifier_path = File.expand_path('test/package_installation_test.rb', __dir__)
  sh({ 'CODEX_NOTIFY_PACKAGE_PATH' => package_path }, RbConfig.ruby, verifier_path)
end

Rake::TestTask.new(:test) do |t|
  t.libs << 'lib'
  t.libs << 'test'
  t.pattern = 'test/test_*.rb'
  t.warning = true
end

task default: :test
